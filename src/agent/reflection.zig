//! Reflection schema and strict validation (§4.5, FR-07).
//!
//! Reflection closes the slow loop: expected vs actual outcome, error
//! attribution, lessons, and *structured* memory operations. No hidden
//! chain-of-thought — everything here is auditable. Like proposals,
//! anything malformed voids the whole reflection (fail-closed: no memory
//! mutation from a bad document).

const std = @import("std");
const dec = @import("../core/decimal.zig");
const mem_store = @import("../memory/store.zig");
const Decimal = dec.Decimal;

pub const MAX_LIST_ITEMS = 16;
pub const MAX_STRING_LEN = 512;
pub const MAX_OPS = 32;

pub const Reflection = struct {
    episode_id: []const u8,
    expected_outcome: []const u8,
    /// Raw JSON of the observed multi-window outcome (kept verbatim for audit).
    actual_outcome_json: []const u8,
    error_types: [][]const u8,
    lessons: [][]const u8,
    memory_ops: []mem_store.Op,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Reflection) void {
        self.arena.deinit();
    }
};

pub const ValidationError = error{
    MalformedJson,
    MissingField,
    WrongType,
    EpisodeIdInvalid,
    ListTooLong,
    StringTooLong,
    TooManyOps,
    UnknownOp,
    UnknownKind,
    UnknownStatus,
    ConfidenceOutOfRange,
    MemoryIdInvalid,
    OutOfMemory,
};

/// Parse and validate a raw model reflection. Caller owns the result.
pub fn parse(gpa: std.mem.Allocator, raw: []const u8) ValidationError!Reflection {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{
        .max_value_len = 64 * 1024,
    }) catch return error.MalformedJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const episode_id = try dupString(a, try getString(obj, "episode_id"));
    if (episode_id.len < 4 or episode_id.len > 64 or !std.mem.startsWith(u8, episode_id, "ep_"))
        return error.EpisodeIdInvalid;

    const expected = try dupString(a, try getString(obj, "expected_outcome"));

    const actual_v = obj.get("actual_outcome") orelse return error.MissingField;
    if (actual_v != .object) return error.WrongType;
    const actual_json = std.json.Stringify.valueAlloc(a, actual_v, .{}) catch return error.OutOfMemory;

    const error_types = try getStringList(a, obj, "error_type");
    const lessons = try getStringList(a, obj, "lessons");

    const ops_v = obj.get("memory_ops") orelse return error.MissingField;
    if (ops_v != .array) return error.WrongType;
    if (ops_v.array.items.len > MAX_OPS) return error.TooManyOps;

    var ops = a.alloc(mem_store.Op, ops_v.array.items.len) catch return error.OutOfMemory;
    for (ops_v.array.items, 0..) |item, i| {
        ops[i] = try parseOp(a, item);
    }

    return .{
        .episode_id = episode_id,
        .expected_outcome = expected,
        .actual_outcome_json = actual_json,
        .error_types = error_types,
        .lessons = lessons,
        .memory_ops = ops,
        .arena = arena,
    };
}

/// Parse one structured memory op. Shared with periodic review (定期复盘) so
/// both loops mutate memory through exactly the same validated grammar.
pub fn parseOp(a: std.mem.Allocator, v: std.json.Value) ValidationError!mem_store.Op {
    if (v != .object) return error.WrongType;
    const obj = v.object;
    const op_str = try getString(obj, "op");

    if (std.mem.eql(u8, op_str, "CREATE")) {
        const kind_str = try getString(obj, "kind");
        const kind = mem_store.Kind.fromString(kind_str) orelse return error.UnknownKind;
        var status: mem_store.Status = .unverified;
        if (obj.get("status")) |sv| {
            if (sv != .string) return error.WrongType;
            status = mem_store.Status.fromString(sv.string) orelse return error.UnknownStatus;
        }
        var confidence = Decimal.zero;
        if (obj.get("confidence") != null) {
            confidence = try getUnitDecimal(obj, "confidence");
        }
        var content: []const u8 = "{}";
        if (obj.get("content")) |cv| {
            if (cv != .object) return error.WrongType;
            content = std.json.Stringify.valueAlloc(a, cv, .{}) catch return error.OutOfMemory;
        }
        // CREATE may omit memory_id (store assigns externally) — but if
        // present it must be sane; we require it for deterministic replay.
        const id = try memoryId(a, obj);
        return .{ .create = .{
            .memory_id = id,
            .kind = kind,
            .status = status,
            .confidence = confidence,
            .content_json = content,
        } };
    }
    if (std.mem.eql(u8, op_str, "UPDATE")) {
        const id = try memoryId(a, obj);
        var delta = Decimal.zero;
        if (obj.get("confidence_delta")) |dv| {
            delta = try signedUnit(dv);
        }
        var evidence: u32 = 0;
        if (obj.get("evidence_increment")) |ev| {
            if (ev != .integer or ev.integer < 0 or ev.integer > 1000) return error.WrongType;
            evidence = @intCast(ev.integer);
        }
        var new_status: ?mem_store.Status = null;
        if (obj.get("status")) |sv| {
            if (sv != .string) return error.WrongType;
            new_status = mem_store.Status.fromString(sv.string) orelse return error.UnknownStatus;
        }
        var content: ?[]const u8 = null;
        if (obj.get("content")) |cv| {
            if (cv != .object) return error.WrongType;
            content = std.json.Stringify.valueAlloc(a, cv, .{}) catch return error.OutOfMemory;
        }
        return .{ .update = .{
            .memory_id = id,
            .confidence_delta = delta,
            .evidence_increment = evidence,
            .new_status = new_status,
            .content_json = content,
        } };
    }
    if (std.mem.eql(u8, op_str, "INVALIDATE")) {
        return .{ .invalidate = .{ .memory_id = try memoryId(a, obj) } };
    }
    if (std.mem.eql(u8, op_str, "MERGE")) {
        const from = try dupString(a, try getString(obj, "from_id"));
        const into = try dupString(a, try getString(obj, "into_id"));
        if (!validMemoryId(from) or !validMemoryId(into)) return error.MemoryIdInvalid;
        return .{ .merge = .{ .from_id = from, .into_id = into } };
    }
    return error.UnknownOp;
}

fn memoryId(a: std.mem.Allocator, obj: std.json.ObjectMap) ValidationError![]const u8 {
    const id = try dupString(a, try getString(obj, "memory_id"));
    if (!validMemoryId(id)) return error.MemoryIdInvalid;
    return id;
}

fn validMemoryId(id: []const u8) bool {
    if (id.len < 2 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ValidationError![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .string) return error.WrongType;
    if (v.string.len > MAX_STRING_LEN) return error.StringTooLong;
    return v.string;
}

fn getStringList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ValidationError![][]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .array) return error.WrongType;
    if (v.array.items.len > MAX_LIST_ITEMS) return error.ListTooLong;
    var out = a.alloc([]const u8, v.array.items.len) catch return error.OutOfMemory;
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.WrongType;
        if (item.string.len > MAX_STRING_LEN) return error.StringTooLong;
        out[i] = try dupString(a, item.string);
    }
    return out;
}

/// Read a JSON number in [0,1] as Decimal.
fn getUnitDecimal(obj: std.json.ObjectMap, key: []const u8) ValidationError!Decimal {
    const v = obj.get(key) orelse return error.MissingField;
    const val = try numberToDecimal(v);
    if (val.isNegative() or val.gt(Decimal.one)) return error.ConfidenceOutOfRange;
    return val;
}

/// Read a JSON number in [-1,1] as Decimal (confidence deltas).
fn signedUnit(v: std.json.Value) ValidationError!Decimal {
    const val = try numberToDecimal(v);
    if (val.abs().gt(Decimal.one)) return error.ConfidenceOutOfRange;
    return val;
}

fn numberToDecimal(v: std.json.Value) ValidationError!Decimal {
    return switch (v) {
        .integer => |i| Decimal.fromInt(std.math.cast(i64, i) orelse return error.WrongType),
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return error.WrongType;
            const scaled = f * @as(f64, @floatFromInt(dec.ONE_RAW));
            if (scaled > 9.2e18 or scaled < -9.2e18) return error.WrongType;
            break :blk Decimal.fromRaw(@intFromFloat(@round(scaled)));
        },
        else => error.WrongType,
    };
}

fn dupString(a: std.mem.Allocator, s: []const u8) ValidationError![]const u8 {
    return a.dupe(u8, s) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const good_json =
    \\{
    \\  "episode_id": "ep_01J8",
    \\  "expected_outcome": "price rises within 24h",
    \\  "actual_outcome": { "return_4h": -0.8, "return_24h": -2.1 },
    \\  "error_type": ["regime_mismatch", "overweighted_news"],
    \\  "lessons": ["breakout signal degraded during high ATR"],
    \\  "memory_ops": [
    \\    { "op": "UPDATE", "memory_id": "H17", "confidence_delta": -0.15, "evidence_increment": 1 },
    \\    { "op": "CREATE", "memory_id": "H22", "kind": "hypothesis", "status": "unverified",
    \\      "confidence": 0.4, "content": {"tags": ["high_atr"]} },
    \\    { "op": "INVALIDATE", "memory_id": "H03" },
    \\    { "op": "MERGE", "from_id": "H05", "into_id": "H17" }
    \\  ]
    \\}
;

test "parses well-formed reflection with all four op kinds" {
    var r = try parse(testing.allocator, good_json);
    defer r.deinit();

    try testing.expectEqualStrings("ep_01J8", r.episode_id);
    try testing.expectEqualStrings("price rises within 24h", r.expected_outcome);
    try testing.expect(std.mem.indexOf(u8, r.actual_outcome_json, "return_24h") != null);
    try testing.expectEqual(@as(usize, 2), r.error_types.len);
    try testing.expectEqual(@as(usize, 1), r.lessons.len);
    try testing.expectEqual(@as(usize, 4), r.memory_ops.len);

    const upd = r.memory_ops[0].update;
    try testing.expectEqualStrings("H17", upd.memory_id);
    try testing.expect(upd.confidence_delta.eql(try Decimal.parse("-0.15")));
    try testing.expectEqual(@as(u32, 1), upd.evidence_increment);

    const cre = r.memory_ops[1].create;
    try testing.expectEqual(mem_store.Kind.strategy, cre.kind); // "hypothesis" maps to strategy
    try testing.expectEqual(mem_store.Status.unverified, cre.status);
    try testing.expect(std.mem.indexOf(u8, cre.content_json, "high_atr") != null);

    try testing.expectEqualStrings("H03", r.memory_ops[2].invalidate.memory_id);
    try testing.expectEqualStrings("H05", r.memory_ops[3].merge.from_id);
}

test "reflection ops drive the memory store end to end" {
    var r = try parse(testing.allocator, good_json);
    defer r.deinit();

    var store = mem_store.Store.init(testing.allocator);
    defer store.deinit();
    // Seed the memories referenced by UPDATE/INVALIDATE/MERGE.
    inline for (.{ "H17", "H03", "H05" }) |id| {
        try store.load(.{
            .memory_id = id,
            .version = 1,
            .kind = .strategy,
            .status = .active,
            .confidence = try Decimal.parse("0.5"),
            .evidence_count = 1,
            .content_json = "{}",
            .created_ms = 1000,
        });
    }

    var touched: std.ArrayList(mem_store.Memory) = .empty;
    defer touched.deinit(testing.allocator);
    for (r.memory_ops) |op| {
        try store.applyOp(op, 2000, &touched);
    }

    try testing.expect(store.find("H17").?.confidence.eql(try Decimal.parse("0.35")));
    try testing.expectEqual(mem_store.Status.invalidated, store.find("H03").?.status);
    try testing.expectEqual(mem_store.Status.merged, store.find("H05").?.status);
    try testing.expectEqual(@as(u32, 0), store.find("H22").?.evidence_count); // created fresh
}

test "malformed reflections are rejected fail-closed" {
    const cases = [_]struct {
        raw: []const u8,
        err: ValidationError,
    }{
        .{ .raw = "not json", .err = error.MalformedJson },
        .{ .raw = "[]", .err = error.MalformedJson },
        .{ .raw = "{\"episode_id\":\"nope\"}", .err = error.EpisodeIdInvalid },
        .{ .raw = "{\"episode_id\":\"ep_1x\"}", .err = error.MissingField },
        .{
            .raw =
            \\{"episode_id":"ep_1x","expected_outcome":"e","actual_outcome":{},
            \\ "error_type":[],"lessons":[],
            \\ "memory_ops":[{"op":"DELETE","memory_id":"H1"}]}
            ,
            .err = error.UnknownOp,
        },
        .{
            .raw =
            \\{"episode_id":"ep_1x","expected_outcome":"e","actual_outcome":{},
            \\ "error_type":[],"lessons":[],
            \\ "memory_ops":[{"op":"UPDATE","memory_id":"H1","confidence_delta":1.5}]}
            ,
            .err = error.ConfidenceOutOfRange,
        },
        .{
            .raw =
            \\{"episode_id":"ep_1x","expected_outcome":"e","actual_outcome":{},
            \\ "error_type":[],"lessons":[],
            \\ "memory_ops":[{"op":"CREATE","memory_id":"H9","kind":"prophecy"}]}
            ,
            .err = error.UnknownKind,
        },
        .{
            .raw =
            \\{"episode_id":"ep_1x","expected_outcome":"e","actual_outcome":{},
            \\ "error_type":[],"lessons":[],
            \\ "memory_ops":[{"op":"UPDATE","memory_id":"bad id!"}]}
            ,
            .err = error.MemoryIdInvalid,
        },
        .{
            .raw =
            \\{"episode_id":"ep_1x","expected_outcome":"e","actual_outcome":"flat",
            \\ "error_type":[],"lessons":[],"memory_ops":[]}
            ,
            .err = error.WrongType,
        },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parse(testing.allocator, case.raw));
    }
}
