//! Long-term memory store — five layers, versioned, append-only (§4.5, FR-07).
//!
//! Layers: Current State (from the state engine, always included), Working,
//! Episodic, Strategy, Reflection. This module owns the last four as
//! versioned records plus the structured `memory_ops` that Reflection emits
//! (CREATE / UPDATE / INVALIDATE / MERGE). No hidden chain-of-thought is
//! stored — only auditable structured content.
//!
//! Determinism: applying the same ops to the same store yields the same
//! versions; retrieval scoring is pure integer/decimal arithmetic.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

/// Bump to start a clean decision-memory epoch without rewriting DB history.
pub const CURRENT_POLICY_EPOCH: u32 = 1;
pub const MAX_DECISION_AGE_MS: i64 = 48 * 60 * 60 * 1000;

/// Opt-in decision context, supplied by trusted runtime configuration, never
/// parsed from an agent operation. Active memories remain provisional context,
/// not validated alpha. A caller may tighten, but cannot extend, the age bound.
pub const DecisionScope = struct {
    policy_epoch: u32 = CURRENT_POLICY_EPOCH,
    mode: @import("../config.zig").Mode,
    max_age_ms: i64 = MAX_DECISION_AGE_MS,
    /// Trusted, persisted start of the current policy/mode evidence cohort.
    /// Returning to an earlier trading mode must not revive its earlier notes.
    /// Inclusive and nonnegative; a boundary after now fails closed.
    not_before_ms: i64 = 0,
};

const Provenance = struct {
    policy_epoch: u32,
    mode: @import("../config.zig").Mode,
    content_ms: i64,
};

/// Only applyOpWithScope writes this envelope. Agent-supplied JSON is nested
/// under content and cannot select/override the outer provenance. No migration
/// is needed: the existing append-only content_json column persists it.
const DecisionEnvelope = struct {
    _decision_scope: Provenance,
    content: std.json.Value,
};

const ParsedEnvelope = struct {
    allocation: std.json.Parsed(std.json.Value),
    value: DecisionEnvelope,

    fn deinit(self: ParsedEnvelope) void {
        self.allocation.deinit();
    }
};

pub const Kind = enum {
    working,
    episodic,
    strategy,
    reflection,

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "working")) return .working;
        if (std.mem.eql(u8, s, "episodic")) return .episodic;
        if (std.mem.eql(u8, s, "strategy")) return .strategy;
        if (std.mem.eql(u8, s, "reflection")) return .reflection;
        // Design uses "hypothesis" as strategy-layer content.
        if (std.mem.eql(u8, s, "hypothesis")) return .strategy;
        return null;
    }

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .working => "working",
            .episodic => "episodic",
            .strategy => "strategy",
            .reflection => "reflection",
        };
    }
};

pub const Status = enum {
    active,
    unverified,
    invalidated,
    merged,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "unverified")) return .unverified;
        if (std.mem.eql(u8, s, "invalidated")) return .invalidated;
        if (std.mem.eql(u8, s, "merged")) return .merged;
        return null;
    }

    pub fn text(self: Status) []const u8 {
        return switch (self) {
            .active => "active",
            .unverified => "unverified",
            .invalidated => "invalidated",
            .merged => "merged",
        };
    }
};

/// One version of one memory. Newer versions supersede older ones; history
/// is preserved (append-only, mirrors the `memories` table PK (id, version)).
pub const Memory = struct {
    memory_id: []const u8,
    version: u32,
    kind: Kind,
    status: Status,
    /// Confidence in [0,1].
    confidence: Decimal,
    evidence_count: u32,
    /// Structured content (thesis, market regime tags, outcome...). Untrusted
    /// free text stays inside; it is data, never instructions.
    content_json: []const u8,
    created_ms: i64,
};

pub const Op = union(enum) {
    create: struct {
        memory_id: []const u8,
        kind: Kind,
        status: Status = .unverified,
        confidence: Decimal = Decimal.zero,
        content_json: []const u8 = "{}",
    },
    update: struct {
        memory_id: []const u8,
        /// Signed confidence delta, clamped into [0,1].
        confidence_delta: Decimal = Decimal.zero,
        evidence_increment: u32 = 0,
        new_status: ?Status = null,
        content_json: ?[]const u8 = null,
    },
    invalidate: struct {
        memory_id: []const u8,
    },
    merge: struct {
        /// Losing memory is marked merged; surviving one gains its evidence.
        from_id: []const u8,
        into_id: []const u8,
    },
};

pub const StoreError = error{
    DuplicateId,
    UnknownId,
    StoreFull,
    SelfMerge,
    OutOfMemory,
    InvalidDecisionScope,
    InvalidContent,
    ScopeMismatch,
    ContentReplacementRequired,
};

pub const MAX_MEMORIES = 1024;

/// In-process memory index: latest version per memory_id. The SQLite
/// `memories` table stays the durable append-only log; this index is rebuilt
/// from it at boot (latest version per id) and mutated via applyOp.
pub const Store = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Memory),

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .items = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        self.items.deinit(self.gpa);
        self.arena.deinit();
    }

    pub fn count(self: *const Store) usize {
        return self.items.items.len;
    }

    pub fn find(self: *const Store, memory_id: []const u8) ?*Memory {
        for (self.items.items) |*m| {
            if (std.mem.eql(u8, m.memory_id, memory_id)) return m;
        }
        return null;
    }

    /// Seed with an existing latest-version row (boot-time rebuild).
    pub fn load(self: *Store, m: Memory) StoreError!void {
        if (self.find(m.memory_id) != null) return error.DuplicateId;
        if (self.items.items.len >= MAX_MEMORIES) return error.StoreFull;
        try self.items.append(self.gpa, try self.own(m));
    }

    /// Generic writes never acquire decision provenance, even when their
    /// content imitates an envelope. A generic UPDATE also revokes any existing
    /// stamp; use applyOpWithScope for all decision-memory writers.
    pub fn applyOp(self: *Store, op: Op, now_ms: i64, out: *std.ArrayList(Memory)) StoreError!void {
        var clean = op;
        switch (op) {
            .create => |c| {
                const content = try withoutProvenance(self.gpa, c.content_json);
                defer if (content) |s| self.gpa.free(s);
                clean.create.content_json = content orelse c.content_json;
                return self.applyRawOp(clean, now_ms, out);
            },
            .update => |u| {
                const m = self.find(u.memory_id) orelse return error.UnknownId;
                const original = u.content_json orelse m.content_json;
                const content = try withoutProvenance(self.gpa, original);
                defer if (content) |s| self.gpa.free(s);
                clean.update.content_json = content orelse u.content_json;
                return self.applyRawOp(clean, now_ms, out);
            },
            else => return self.applyRawOp(clean, now_ms, out),
        }
    }

    /// Append-only scoped operations; persist each returned version as usual.
    /// CREATE and explicit full-content UPDATE stamp an envelope. Equivalent
    /// same-scope replacement content retains its original content age, even if
    /// already expired. Replacement UPDATE inherits neither status nor
    /// confidence/evidence from the prior
    /// version (including legacy or another mode). Callers must build replacement
    /// content from current inputs, not copy historical narratives into it.
    /// Partial UPDATE / MERGE require usable same-scope content, cannot promote
    /// unverified content, and preserve content age. Repetition is not evidence:
    /// confidence/evidence deltas never increase authority in this path.
    pub fn applyOpWithScope(self: *Store, op: Op, now_ms: i64, scope: DecisionScope, out: *std.ArrayList(Memory)) StoreError!void {
        if (!validScope(scope, now_ms)) return error.InvalidDecisionScope;
        // Reserve before mutating so a failed append cannot hide a new version.
        try out.ensureUnusedCapacity(self.gpa, 2);
        switch (op) {
            .create => |c| {
                if (self.find(c.memory_id) != null) return error.DuplicateId;
                const content = try stampContent(self.gpa, c.content_json, scope, now_ms, null);
                defer self.gpa.free(content);
                if (self.items.items.len >= MAX_MEMORIES) _ = try self.evictDecisionIneligible(scope, now_ms);
                try self.applyRawOp(.{ .create = .{
                    .memory_id = c.memory_id,
                    .kind = c.kind,
                    .status = c.status,
                    .confidence = Decimal.zero,
                    .content_json = content,
                } }, now_ms, out);
            },
            .update => |u| {
                const m = self.find(u.memory_id) orelse return error.UnknownId;
                if (u.content_json) |replacement| {
                    const content = try stampContent(self.gpa, replacement, scope, now_ms, m.*);
                    defer self.gpa.free(content);
                    // Allocate before changing the indexed version.
                    const owned = try self.ownStr(content);
                    m.version += 1;
                    m.content_json = owned;
                    m.status = u.new_status orelse .unverified;
                    m.confidence = Decimal.zero;
                    m.evidence_count = 0;
                    m.created_ms = now_ms;
                    out.appendAssumeCapacity(m.*);
                } else {
                    try requireScope(self.gpa, m.*, scope);
                    if (!try isDecisionEligible(self.gpa, m.*, scope, now_ms)) return error.ContentReplacementRequired;
                    m.version += 1;
                    if (u.new_status) |status| m.status = status;
                    m.confidence = Decimal.zero;
                    m.evidence_count = 0;
                    m.created_ms = now_ms;
                    out.appendAssumeCapacity(m.*);
                }
            },
            .invalidate => |i| {
                const m = self.find(i.memory_id) orelse return error.UnknownId;
                try requireScope(self.gpa, m.*, scope);
                try self.applyRawOp(op, now_ms, out);
            },
            .merge => |merge| {
                if (std.mem.eql(u8, merge.from_id, merge.into_id)) return error.SelfMerge;
                const from = self.find(merge.from_id) orelse return error.UnknownId;
                const into = self.find(merge.into_id) orelse return error.UnknownId;
                try requireScope(self.gpa, from.*, scope);
                try requireScope(self.gpa, into.*, scope);
                if (!try isDecisionEligible(self.gpa, from.*, scope, now_ms) or
                    !try isDecisionEligible(self.gpa, into.*, scope, now_ms)) return error.ContentReplacementRequired;
                // A merge retires a duplicate, not independent confirmation. It
                // does not copy content, boost confidence, or renew content age.
                from.version += 1;
                from.status = .merged;
                from.created_ms = now_ms;
                into.version += 1;
                into.confidence = Decimal.zero;
                into.evidence_count = 0;
                into.created_ms = now_ms;
                out.appendAssumeCapacity(from.*);
                out.appendAssumeCapacity(into.*);
            },
        }
    }

    /// Apply one generic structured operation without changing its semantics.
    /// Kept private so untrusted content cannot stamp decision provenance.
    fn applyRawOp(self: *Store, op: Op, now_ms: i64, out: *std.ArrayList(Memory)) StoreError!void {
        switch (op) {
            .create => |c| {
                if (self.find(c.memory_id) != null) return error.DuplicateId;
                if (self.items.items.len >= MAX_MEMORIES) try self.evictForCreate();
                const m = try self.own(.{
                    .memory_id = c.memory_id,
                    .version = 1,
                    .kind = c.kind,
                    .status = c.status,
                    .confidence = clamp01(c.confidence),
                    .evidence_count = 0,
                    .content_json = c.content_json,
                    .created_ms = now_ms,
                });
                try self.items.append(self.gpa, m);
                try out.append(self.gpa, m);
            },
            .update => |u| {
                const m = self.find(u.memory_id) orelse return error.UnknownId;
                m.version += 1;
                m.confidence = clamp01(m.confidence.add(u.confidence_delta) catch Decimal.zero);
                m.evidence_count += u.evidence_increment;
                if (u.new_status) |s| m.status = s;
                if (u.content_json) |c| m.content_json = try self.ownStr(c);
                m.created_ms = now_ms;
                try out.append(self.gpa, m.*);
            },
            .invalidate => |i| {
                const m = self.find(i.memory_id) orelse return error.UnknownId;
                m.version += 1;
                m.status = .invalidated;
                m.created_ms = now_ms;
                try out.append(self.gpa, m.*);
            },
            .merge => |g| {
                if (std.mem.eql(u8, g.from_id, g.into_id)) return error.SelfMerge;
                const from = self.find(g.from_id) orelse return error.UnknownId;
                const into = self.find(g.into_id) orelse return error.UnknownId;
                from.version += 1;
                from.status = .merged;
                from.created_ms = now_ms;
                into.version += 1;
                into.evidence_count += from.evidence_count;
                into.created_ms = now_ms;
                try out.append(self.gpa, from.*);
                try out.append(self.gpa, into.*);
            },
        }
    }

    /// Prefer quarantined content over any usable decision memory when a
    /// scoped CREATE needs room. Protected names do not protect legacy priors.
    /// This changes only the bounded index, never the durable version history.
    fn evictDecisionIneligible(self: *Store, scope: DecisionScope, now_ms: i64) StoreError!bool {
        var best: ?usize = null;
        for (self.items.items, 0..) |m, index| {
            if (try isDecisionEligible(self.gpa, m, scope, now_ms)) continue;
            if (best) |b| {
                const prior = self.items.items[b];
                if (m.created_ms < prior.created_ms or
                    (m.created_ms == prior.created_ms and std.mem.lessThan(u8, m.memory_id, prior.memory_id)))
                    best = index;
            } else best = index;
        }
        if (best) |index| {
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }

    /// Deterministic eviction when the index is at MAX_MEMORIES: drop the
    /// least valuable record from the in-process index only — the SQLite
    /// `memories` log keeps full append-only history for audit. Order:
    /// oldest terminal (invalidated/merged), then oldest ephemeral
    /// (`E_run_*` / `R_run_*` / dated `PR_short_*`), then other reflection,
    /// then other episodic. Working, strategy, and rolling ids
    /// (`E_hold_streak`, `R_hold_streak`, `PR_short`, `PR_long`) stay.
    /// Fails closed if only protected records remain.
    fn evictForCreate(self: *Store) StoreError!void {
        if (self.evictMatching(evictableTerminal)) return;
        if (self.evictMatching(isEphemeralIdMem)) return;
        if (self.evictMatching(evictableReflection)) return;
        if (self.evictMatching(evictableEpisodic)) return;
        return error.StoreFull;
    }

    /// Drop ephemeral/terminal rows until `count + headroom <= MAX_MEMORIES`.
    /// Used at boot so a full store has room for new rolling reviews.
    pub fn compactEphemeral(self: *Store, headroom: usize) usize {
        var dropped: usize = 0;
        const target = if (headroom >= MAX_MEMORIES) 0 else MAX_MEMORIES - headroom;
        while (self.items.items.len > target) {
            if (self.evictMatching(evictableTerminal) or self.evictMatching(isEphemeralIdMem)) {
                dropped += 1;
                continue;
            }
            break;
        }
        return dropped;
    }

    fn evictMatching(self: *Store, pred: *const fn ([]const u8, Memory) bool) bool {
        var best: ?usize = null;
        for (self.items.items, 0..) |m, i| {
            if (!pred(m.memory_id, m)) continue;
            if (best) |b| {
                const cur = self.items.items[b];
                if (m.created_ms < cur.created_ms or
                    (m.created_ms == cur.created_ms and std.mem.lessThan(u8, m.memory_id, cur.memory_id)))
                    best = i;
            } else {
                best = i;
            }
        }
        if (best) |b| {
            _ = self.items.orderedRemove(b);
            return true;
        }
        return false;
    }

    fn own(self: *Store, m: Memory) StoreError!Memory {
        var copy = m;
        copy.memory_id = try self.ownStr(m.memory_id);
        copy.content_json = try self.ownStr(m.content_json);
        return copy;
    }

    fn ownStr(self: *Store, s: []const u8) StoreError![]const u8 {
        return self.arena.allocator().dupe(u8, s) catch return error.OutOfMemory;
    }
};

fn clamp01(v: Decimal) Decimal {
    if (v.isNegative()) return Decimal.zero;
    if (v.gt(Decimal.one)) return Decimal.one;
    return v;
}

/// Rolling / policy ids the index must not drop to make room for run noise.
pub fn isProtectedId(id: []const u8) bool {
    if (std.mem.eql(u8, id, "E_hold_streak")) return true;
    if (std.mem.eql(u8, id, "R_hold_streak")) return true;
    if (std.mem.eql(u8, id, "PR_short")) return true;
    if (std.mem.eql(u8, id, "PR_long")) return true;
    if (std.mem.eql(u8, id, "PR_low_execution_rate")) return true;
    if (std.mem.eql(u8, id, "PR_opportunity_cost")) return true;
    if (std.mem.startsWith(u8, id, "W_")) return true;
    if (std.mem.startsWith(u8, id, "H_")) return true;
    return false;
}

/// Per-run episodes and dated periodic-review copies. Safe to evict first.
pub fn isEphemeralId(id: []const u8) bool {
    return isEphemeralIdMem(id, undefined);
}

fn isEphemeralIdMem(id: []const u8, _: Memory) bool {
    if (isProtectedId(id)) return false;
    if (std.mem.startsWith(u8, id, "E_run_")) return true;
    if (std.mem.startsWith(u8, id, "R_run_")) return true;
    if (std.mem.startsWith(u8, id, "PR_short_")) return true;
    if (std.mem.startsWith(u8, id, "PR_long_")) return true;
    return false;
}

fn evictableTerminal(id: []const u8, m: Memory) bool {
    _ = id;
    return m.status == .invalidated or m.status == .merged;
}

fn evictableReflection(id: []const u8, m: Memory) bool {
    if (isProtectedId(id)) return false;
    if (m.status == .invalidated or m.status == .merged) return false;
    return m.kind == .reflection;
}

fn evictableEpisodic(id: []const u8, m: Memory) bool {
    if (isProtectedId(id)) return false;
    if (m.status == .invalidated or m.status == .merged) return false;
    return m.kind == .episodic;
}

fn validScope(scope: DecisionScope, now_ms: i64) bool {
    return scope.policy_epoch > 0 and scope.max_age_ms > 0 and scope.max_age_ms <= MAX_DECISION_AGE_MS and
        scope.not_before_ms >= 0 and scope.not_before_ms <= now_ms;
}

fn parseEnvelope(gpa: std.mem.Allocator, content: []const u8) StoreError!?ParsedEnvelope {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var keep = false;
    defer if (!keep) parsed.deinit();
    const root = parsed.value;
    if (root != .object or root.object.count() != 2) return null;
    const provenance = root.object.get("_decision_scope") orelse return null;
    const payload = root.object.get("content") orelse return null;
    if (provenance != .object or provenance.object.count() != 3 or payload != .object) return null;
    const epoch = provenance.object.get("policy_epoch") orelse return null;
    const mode = provenance.object.get("mode") orelse return null;
    const timestamp = provenance.object.get("content_ms") orelse return null;
    // Typed JSON parsing accepts numeric strings; provenance deliberately does
    // not. Only the exact schema produced by stampContent is admissible.
    if (epoch != .integer or epoch.integer <= 0 or epoch.integer > std.math.maxInt(u32) or
        timestamp != .integer or mode != .string) return null;
    const parsed_mode = std.meta.stringToEnum(@import("../config.zig").Mode, mode.string) orelse return null;
    keep = true;
    return .{ .allocation = parsed, .value = .{
        ._decision_scope = .{ .policy_epoch = @intCast(epoch.integer), .mode = parsed_mode, .content_ms = timestamp.integer },
        .content = payload,
    } };
}

fn sameScope(provenance: Provenance, scope: DecisionScope) bool {
    return provenance.policy_epoch == scope.policy_epoch and provenance.mode == scope.mode;
}

fn requireScope(gpa: std.mem.Allocator, m: Memory, scope: DecisionScope) StoreError!void {
    const parsed = (try parseEnvelope(gpa, m.content_json)) orelse return error.ScopeMismatch;
    defer parsed.deinit();
    if (!sameScope(parsed.value._decision_scope, scope)) return error.ScopeMismatch;
}

fn eligibleEnvelope(m: Memory, envelope: DecisionEnvelope, scope: DecisionScope, now_ms: i64) bool {
    if (!validScope(scope, now_ms) or m.status != .active) return false;
    const provenance = envelope._decision_scope;
    if (!sameScope(provenance, scope)) return false;
    // Inspect original content time, never the latest UPDATE/MERGE timestamp.
    // Negative/future timestamps fail closed rather than appearing age zero.
    if (provenance.content_ms < scope.not_before_ms or provenance.content_ms > now_ms or
        m.created_ms < provenance.content_ms or m.created_ms > now_ms) return false;
    return now_ms - provenance.content_ms <= scope.max_age_ms;
}

/// Shared eligibility predicate for boot filtering and direct lookup surfaces.
/// load() is for trusted persisted rows; untrusted input must use an op writer.
pub fn isDecisionEligible(gpa: std.mem.Allocator, m: Memory, scope: DecisionScope, now_ms: i64) StoreError!bool {
    const parsed = (try parseEnvelope(gpa, m.content_json)) orelse return false;
    defer parsed.deinit();
    return eligibleEnvelope(m, parsed.value, scope, now_ms);
}

/// Structural JSON equality: whitespace, object key order, and equivalent
/// string escapes are immaterial; array order and value types remain semantic.
fn equivalentContent(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |value| value == b.bool,
        .integer => |value| value == b.integer,
        .float => |value| value == b.float,
        .number_string => |value| std.mem.eql(u8, value, b.number_string),
        .string => |value| std.mem.eql(u8, value, b.string),
        .array => |array| blk: {
            if (array.items.len != b.array.items.len) break :blk false;
            for (array.items, b.array.items) |left, right| {
                if (!equivalentContent(left, right)) break :blk false;
            }
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != b.object.count()) break :blk false;
            for (object.keys(), object.values()) |key, value| {
                if (!equivalentContent(value, b.object.get(key) orelse break :blk false)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn stampContent(gpa: std.mem.Allocator, content: []const u8, scope: DecisionScope, now_ms: i64, previous: ?Memory) StoreError![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidContent,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidContent;
    var content_ms = now_ms;
    if (previous) |m| {
        if (try parseEnvelope(gpa, m.content_json)) |prior| {
            defer prior.deinit();
            if (sameScope(prior.value._decision_scope, scope) and equivalentContent(prior.value.content, parsed.value))
                content_ms = prior.value._decision_scope.content_ms;
        }
    }
    return std.json.Stringify.valueAlloc(gpa, DecisionEnvelope{
        ._decision_scope = .{ .policy_epoch = scope.policy_epoch, .mode = scope.mode, .content_ms = content_ms },
        .content = parsed.value,
    }, .{}) catch return error.OutOfMemory;
}

/// Remove the reserved outer stamp on generic ingestion, including escaped
/// JSON keys. A substring test here would allow a forged provenance bypass.
fn withoutProvenance(gpa: std.mem.Allocator, content: []const u8) StoreError!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object or !parsed.value.object.swapRemove("_decision_scope")) return null;
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{}) catch return error.OutOfMemory;
}

/// Only top-level content.tags string-array members are tags. Text in lessons,
/// nested objects, or partial identifiers is not a match. Invalid tag arrays
/// fail closed; duplicate query tags are counted once by the caller.
fn exactTagMatch(content: std.json.Value, tag: []const u8) bool {
    if (content != .object) return false;
    const tags = content.object.get("tags") orelse return false;
    if (tags != .array) return false;
    var found = false;
    for (tags.array.items) |item| {
        if (item != .string) return false;
        if (std.mem.eql(u8, item.string, tag)) found = true;
    }
    return found;
}

// ---------------------------------------------------------------------------
// Retrieval scoring (§4.5): relevance ⊕ recency ⊕ evidence strength.
// Pure and deterministic; tag relevance is exact-match set overlap so the
// same query over the same store always ranks identically.

pub const Query = struct {
    /// Market-regime / instrument tags; matched against content tags.
    tags: []const []const u8 = &.{},
    now_ms: i64,
    /// Half-life for recency decay.
    half_life_ms: i64 = 6 * 60 * 60 * 1000,
    /// Only these kinds are eligible (empty = all).
    kinds: []const Kind = &.{},
    limit: usize = 8,
    /// Strict isolation for decision/review context. Null preserves generic
    /// historical retrieval. Scoped queries ignore the callback matcher and use
    /// exact JSON tags; with tags supplied, at least one must match.
    decision_scope: ?DecisionScope = null,
};

pub const Scored = struct {
    memory: Memory,
    /// Fixed-point score, larger = better.
    score: i64,
};

/// Rank active/unverified memories. Invalidated and merged records never
/// surface (they remain in history for audit only).
pub fn retrieve(store: *const Store, gpa: std.mem.Allocator, q: Query, matchTags: *const fn (content_json: []const u8, tag: []const u8) bool) !std.ArrayList(Scored) {
    var out: std.ArrayList(Scored) = .empty;
    errdefer out.deinit(gpa);

    for (store.items.items) |m| {
        if (m.status == .invalidated or m.status == .merged) continue;
        var parsed: ?ParsedEnvelope = null;
        defer if (parsed) |p| p.deinit();
        if (q.decision_scope) |scope| {
            parsed = (try parseEnvelope(gpa, m.content_json)) orelse continue;
            if (!eligibleEnvelope(m, parsed.?.value, scope, q.now_ms)) continue;
        }
        if (q.kinds.len > 0) {
            var ok = false;
            for (q.kinds) |k| {
                if (m.kind == k) {
                    ok = true;
                    break;
                }
            }
            if (!ok) continue;
        }

        var tag_hits: i64 = 0;
        for (q.tags, 0..) |t, index| {
            if (parsed) |p| {
                var duplicate = false;
                for (q.tags[0..index]) |prior| {
                    if (std.mem.eql(u8, prior, t)) duplicate = true;
                }
                if (!duplicate and exactTagMatch(p.value.content, t)) tag_hits += 1;
            } else if (matchTags(m.content_json, t)) tag_hits += 1;
        }
        if (parsed != null and q.tags.len > 0 and tag_hits == 0) continue;

        // A decision view carries content time, not the last repetition time,
        // and never presents model confidence / repetition as corroboration.
        var view = m;
        if (parsed) |p| {
            view.created_ms = p.value._decision_scope.content_ms;
            view.confidence = Decimal.zero;
            view.evidence_count = 0;
        }
        // recency in [0,1000]: 1000 at age 0, halved every half_life.
        const age: i64 = @max(0, q.now_ms -| view.created_ms);
        var recency: i64 = 1000;
        var remaining = age;
        const half_life_ms = @max(1, q.half_life_ms);
        while (remaining >= half_life_ms and recency > 0) : (remaining -= half_life_ms) {
            recency = @divTrunc(recency, 2);
        }

        // evidence strength saturates at 10.
        const evidence: i64 = @min(10, @as(i64, view.evidence_count));

        // confidence in [0,1000] fixed-point.
        const conf: i64 = @intCast(@divTrunc(clamp01(view.confidence).raw * 1000, dec.ONE_RAW));

        var score = tag_hits * 4000 + recency + evidence * 200 + conf;
        // Generic history favors rolling reviews. Decision context must not
        // give an old repeated narrative authority merely because of its ID.
        if (q.decision_scope == null and isEphemeralId(m.memory_id)) score -= 8000;
        try out.append(gpa, .{ .memory = view, .score = score });
    }

    std.mem.sort(Scored, out.items, q.decision_scope != null, struct {
        fn lessThan(scoped: bool, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            if (scoped and a.memory.created_ms != b.memory.created_ms)
                return a.memory.created_ms > b.memory.created_ms;
            // stable, deterministic tiebreak on id
            return std.mem.lessThan(u8, a.memory.memory_id, b.memory.memory_id);
        }
    }.lessThan);

    if (out.items.len > q.limit) out.shrinkRetainingCapacity(q.limit);
    return out;
}

/// Default tag matcher: substring on content_json. Callers may supply a
/// stricter JSON-aware matcher.
pub fn substringTagMatch(content_json: []const u8, tag: []const u8) bool {
    return std.mem.indexOf(u8, content_json, tag) != null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = @import("decision_policy_tests.zig");
}

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "create/update/invalidate/merge version chain is deterministic" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var touched: std.ArrayList(Memory) = .empty;
    defer touched.deinit(testing.allocator);

    try store.applyOp(.{ .create = .{
        .memory_id = "H17",
        .kind = .strategy,
        .confidence = d("0.6"),
        .content_json = "{\"hypothesis\":\"breakout holds in low ATR\"}",
    } }, 1000, &touched);
    try testing.expectEqual(@as(u32, 1), store.find("H17").?.version);
    try testing.expectEqual(Status.unverified, store.find("H17").?.status);

    // duplicate create rejected
    try testing.expectError(error.DuplicateId, store.applyOp(.{ .create = .{
        .memory_id = "H17",
        .kind = .strategy,
    } }, 1001, &touched));

    // update: confidence delta + evidence, clamped into [0,1]
    try store.applyOp(.{ .update = .{
        .memory_id = "H17",
        .confidence_delta = d("-0.15"),
        .evidence_increment = 2,
        .new_status = .active,
    } }, 2000, &touched);
    const h = store.find("H17").?;
    try testing.expectEqual(@as(u32, 2), h.version);
    try testing.expect(h.confidence.eql(d("0.45")));
    try testing.expectEqual(@as(u32, 2), h.evidence_count);
    try testing.expectEqual(Status.active, h.status);

    // clamp at zero
    try store.applyOp(.{ .update = .{
        .memory_id = "H17",
        .confidence_delta = d("-9"),
    } }, 2500, &touched);
    try testing.expect(store.find("H17").?.confidence.isZero());

    // unknown id rejected
    try testing.expectError(error.UnknownId, store.applyOp(.{ .update = .{
        .memory_id = "nope",
    } }, 2600, &touched));

    // merge: H18 into H17 — H18 marked merged, evidence transferred
    try store.applyOp(.{ .create = .{
        .memory_id = "H18",
        .kind = .strategy,
        .content_json = "{\"hypothesis\":\"same thing duplicated\"}",
    } }, 3000, &touched);
    try store.applyOp(.{ .update = .{ .memory_id = "H18", .evidence_increment = 5 } }, 3100, &touched);
    try store.applyOp(.{ .merge = .{ .from_id = "H18", .into_id = "H17" } }, 3200, &touched);
    try testing.expectEqual(Status.merged, store.find("H18").?.status);
    try testing.expectEqual(@as(u32, 7), store.find("H17").?.evidence_count);
    try testing.expectError(error.SelfMerge, store.applyOp(.{ .merge = .{ .from_id = "H17", .into_id = "H17" } }, 3300, &touched));

    // invalidate
    try store.applyOp(.{ .invalidate = .{ .memory_id = "H17" } }, 4000, &touched);
    try testing.expectEqual(Status.invalidated, store.find("H17").?.status);

    // touched log recorded every new version (audit trail for persistence)
    try testing.expectEqual(@as(usize, 8), touched.items.len);
}

test "retrieval ranks by tags, recency, evidence; hides invalidated" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var touched: std.ArrayList(Memory) = .empty;
    defer touched.deinit(testing.allocator);

    const now: i64 = 100_000_000;
    try store.load(.{
        .memory_id = "old-tagged",
        .version = 1,
        .kind = .strategy,
        .status = .active,
        .confidence = d("0.5"),
        .evidence_count = 3,
        .content_json = "{\"tags\":[\"high_atr\",\"breakout\"]}",
        .created_ms = now - 48 * 60 * 60 * 1000,
    });
    try store.load(.{
        .memory_id = "fresh-untagged",
        .version = 1,
        .kind = .strategy,
        .status = .active,
        .confidence = d("0.9"),
        .evidence_count = 1,
        .content_json = "{\"tags\":[\"chop\"]}",
        .created_ms = now - 1000,
    });
    try store.load(.{
        .memory_id = "dead",
        .version = 3,
        .kind = .strategy,
        .status = .invalidated,
        .confidence = d("0.99"),
        .evidence_count = 9,
        .content_json = "{\"tags\":[\"high_atr\"]}",
        .created_ms = now,
    });

    var res = try retrieve(&store, testing.allocator, .{
        .tags = &.{"high_atr"},
        .now_ms = now,
        .limit = 10,
    }, substringTagMatch);
    defer res.deinit(testing.allocator);

    // invalidated never surfaces; tag match dominates recency
    try testing.expectEqual(@as(usize, 2), res.items.len);
    try testing.expectEqualStrings("old-tagged", res.items[0].memory.memory_id);
    try testing.expectEqualStrings("fresh-untagged", res.items[1].memory.memory_id);

    // kind filter excludes non-matching kinds
    var res2 = try retrieve(&store, testing.allocator, .{
        .tags = &.{},
        .now_ms = now,
        .kinds = &.{.episodic},
    }, substringTagMatch);
    defer res2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), res2.items.len);

    // limit respected, deterministic order on rerun
    var res3 = try retrieve(&store, testing.allocator, .{
        .tags = &.{"high_atr"},
        .now_ms = now,
        .limit = 1,
    }, substringTagMatch);
    defer res3.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res3.items.len);
    try testing.expectEqualStrings("old-tagged", res3.items[0].memory.memory_id);
}

test "create at capacity evicts deterministically: terminal, then oldest reflection/episodic; strategy protected" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var touched: std.ArrayList(Memory) = .empty;
    defer touched.deinit(testing.allocator);

    // Fill to MAX_MEMORIES: 1 strategy + 1 merged + 1 episodic + reflections.
    try store.load(.{
        .memory_id = "S_keep",
        .version = 1,
        .kind = .strategy,
        .status = .active,
        .confidence = d("0.9"),
        .evidence_count = 5,
        .content_json = "{}",
        .created_ms = 1,
    });
    try store.load(.{
        .memory_id = "M_dead",
        .version = 2,
        .kind = .reflection,
        .status = .merged,
        .confidence = d("0.1"),
        .evidence_count = 0,
        .content_json = "{}",
        .created_ms = 2,
    });
    try store.load(.{
        .memory_id = "E_old",
        .version = 1,
        .kind = .episodic,
        .status = .active,
        .confidence = d("0.5"),
        .evidence_count = 1,
        .content_json = "{}",
        .created_ms = 3,
    });
    var i: usize = 0;
    var id_buf: [32]u8 = undefined;
    while (store.count() < MAX_MEMORIES) : (i += 1) {
        const id = try std.fmt.bufPrint(&id_buf, "R_{d:0>6}", .{i});
        try store.load(.{
            .memory_id = id,
            .version = 1,
            .kind = .reflection,
            .status = .active,
            .confidence = d("0.3"),
            .evidence_count = 0,
            .content_json = "{}",
            .created_ms = 100 + @as(i64, @intCast(i)),
        });
    }
    try testing.expectEqual(@as(usize, MAX_MEMORIES), store.count());

    // 1st create at capacity: terminal M_dead evicted first.
    try store.applyOp(.{ .create = .{ .memory_id = "R_new_1", .kind = .reflection, .content_json = "{}" } }, 9000, &touched);
    try testing.expectEqual(@as(usize, MAX_MEMORIES), store.count());
    try testing.expect(store.find("M_dead") == null);
    try testing.expect(store.find("R_new_1") != null);

    // 2nd: no terminal left -> oldest reflection R_000000 goes.
    try store.applyOp(.{ .create = .{ .memory_id = "R_new_2", .kind = .reflection, .content_json = "{}" } }, 9001, &touched);
    try testing.expect(store.find("R_000000") == null);
    try testing.expect(store.find("E_old") != null);
    try testing.expect(store.find("S_keep") != null);

    // Strategy is never evicted and duplicate create still rejected at capacity.
    try testing.expectError(error.DuplicateId, store.applyOp(.{ .create = .{ .memory_id = "R_new_2", .kind = .reflection } }, 9002, &touched));
    try testing.expect(store.find("S_keep") != null);
}

test "ephemeral run copies evict before rolling PR_short; compact frees headroom" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var touched: std.ArrayList(Memory) = .empty;
    defer touched.deinit(testing.allocator);

    try store.load(.{
        .memory_id = "PR_short",
        .version = 14,
        .kind = .reflection,
        .status = .active,
        .confidence = d("0.3"),
        .evidence_count = 13,
        .content_json = "{}",
        .created_ms = 1,
    });
    try store.load(.{
        .memory_id = "E_hold_streak",
        .version = 2,
        .kind = .episodic,
        .status = .active,
        .confidence = d("0.5"),
        .evidence_count = 10,
        .content_json = "{}",
        .created_ms = 2,
    });
    var i: usize = 0;
    var id_buf: [32]u8 = undefined;
    while (store.count() < MAX_MEMORIES) : (i += 1) {
        const id = try std.fmt.bufPrint(&id_buf, "R_run_{d:0>4}", .{i});
        try store.load(.{
            .memory_id = id,
            .version = 1,
            .kind = .reflection,
            .status = .active,
            .confidence = d("0.4"),
            .evidence_count = 0,
            .content_json = "{}",
            .created_ms = 100 + @as(i64, @intCast(i)),
        });
    }

    try store.applyOp(.{ .create = .{ .memory_id = "R_new_keep", .kind = .reflection, .content_json = "{}" } }, 9000, &touched);
    try testing.expect(store.find("R_run_0000") == null);
    try testing.expect(store.find("PR_short") != null);
    try testing.expect(store.find("E_hold_streak") != null);

    const dropped = store.compactEphemeral(32);
    try testing.expect(dropped >= 32);
    try testing.expect(store.count() <= MAX_MEMORIES - 32);
    try testing.expect(store.find("PR_short") != null);
    try testing.expect(store.find("E_hold_streak") != null);
}

test "retrieve downranks ephemeral dated review copies" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const now: i64 = 100_000_000;
    try store.load(.{
        .memory_id = "PR_short",
        .version = 1,
        .kind = .reflection,
        .status = .active,
        .confidence = d("0.3"),
        .evidence_count = 2,
        .content_json = "{\"tags\":[\"periodic_review\",\"BTC-USDT\"]}",
        .created_ms = now - 60_000,
    });
    try store.load(.{
        .memory_id = "PR_short_20260824_1646",
        .version = 1,
        .kind = .reflection,
        .status = .active,
        .confidence = d("0.35"),
        .evidence_count = 0,
        .content_json = "{\"tags\":[\"periodic_review\",\"BTC-USDT\"]}",
        .created_ms = now,
    });
    var res = try retrieve(&store, testing.allocator, .{
        .tags = &.{"periodic_review"},
        .now_ms = now,
        .limit = 1,
    }, substringTagMatch);
    defer res.deinit(testing.allocator);
    try testing.expectEqualStrings("PR_short", res.items[0].memory.memory_id);
}
