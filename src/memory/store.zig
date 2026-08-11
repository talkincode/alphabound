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

    /// Apply one structured memory operation. Returns the new latest version
    /// of every touched memory so the caller can persist rows + events.
    pub fn applyOp(self: *Store, op: Op, now_ms: i64, out: *std.ArrayList(Memory)) StoreError!void {
        switch (op) {
            .create => |c| {
                if (self.find(c.memory_id) != null) return error.DuplicateId;
                if (self.items.items.len >= MAX_MEMORIES) return error.StoreFull;
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
        for (q.tags) |t| {
            if (matchTags(m.content_json, t)) tag_hits += 1;
        }

        // recency in [0,1000]: 1000 at age 0, halved every half_life.
        const age: i64 = @max(0, q.now_ms - m.created_ms);
        var recency: i64 = 1000;
        var remaining = age;
        while (remaining >= q.half_life_ms and recency > 0) : (remaining -= q.half_life_ms) {
            recency = @divTrunc(recency, 2);
        }

        // evidence strength saturates at 10.
        const evidence: i64 = @min(10, @as(i64, m.evidence_count));

        // confidence in [0,1000] fixed-point.
        const conf: i64 = @intCast(@divTrunc(m.confidence.raw * 1000, dec.ONE_RAW));

        const score = tag_hits * 4000 + recency + evidence * 200 + conf;
        try out.append(gpa, .{ .memory = m, .score = score });
    }

    std.mem.sort(Scored, out.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
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
