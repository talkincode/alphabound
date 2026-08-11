//! Decision Proposal schema and strict validation (§4.3, FR-04).
//!
//! The agent's only pathway to the market is this structured document.
//! Anything malformed — bad JSON, missing fields, out-of-range values,
//! unknown action, wrong types — voids the proposal (fail-closed HOLD).

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

pub const Action = enum {
    hold,
    rebalance,

    fn fromString(s: []const u8) ?Action {
        if (std.mem.eql(u8, s, "HOLD")) return .hold;
        if (std.mem.eql(u8, s, "REBALANCE")) return .rebalance;
        return null;
    }
};

pub const OrderPolicyType = enum {
    limit_or_market,
    limit_only,
    market_only,

    fn fromString(s: []const u8) ?OrderPolicyType {
        if (std.mem.eql(u8, s, "LIMIT_OR_MARKET")) return .limit_or_market;
        if (std.mem.eql(u8, s, "LIMIT_ONLY")) return .limit_only;
        if (std.mem.eql(u8, s, "MARKET_ONLY")) return .market_only;
        return null;
    }
};

pub const MAX_LIST_ITEMS = 16;
pub const MAX_STRING_LEN = 512;

pub const Proposal = struct {
    decision_id: []const u8,
    snapshot_version: u64,
    action: Action,
    /// Target BTC portfolio weight in [0,1]; 0 for HOLD.
    target_btc_weight: Decimal,
    order_policy: OrderPolicy = .{},
    /// Confidence in [0,1].
    confidence: Decimal,
    thesis: [][]const u8,
    invalid_if: [][]const u8,
    /// ISO-8601 duration for scheduled review, e.g. "PT4H" (kept as text).
    review_after: ?[]const u8,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Proposal) void {
        self.arena.deinit();
    }
};

pub const OrderPolicy = struct {
    type: OrderPolicyType = .limit_or_market,
    /// Urgency in [0,1]; drives limit price aggressiveness.
    urgency: Decimal = Decimal.zero,
    max_wait_ms: u32 = 120_000,
};

pub const ValidationError = error{
    MalformedJson,
    MissingField,
    WrongType,
    UnknownAction,
    UnknownOrderPolicy,
    WeightOutOfRange,
    ConfidenceOutOfRange,
    UrgencyOutOfRange,
    DecisionIdInvalid,
    ListTooLong,
    StringTooLong,
    RebalanceRequiresTarget,
    OutOfMemory,
};

/// Parse and validate a raw model response into a Proposal.
/// Caller owns the returned Proposal and must call deinit().
pub fn parse(gpa: std.mem.Allocator, raw: []const u8) ValidationError!Proposal {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{
        .max_value_len = 64 * 1024,
    }) catch return error.MalformedJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const decision_id = try dupString(a, try getString(obj, "decision_id"));
    if (decision_id.len < 4 or decision_id.len > 64 or !std.mem.startsWith(u8, decision_id, "dec_"))
        return error.DecisionIdInvalid;

    const snapshot_version = try getU64(obj, "snapshot_version");

    const action_str = try getString(obj, "action");
    const action = Action.fromString(action_str) orelse return error.UnknownAction;

    var target_weight = Decimal.zero;
    if (action == .rebalance) {
        const target_v = obj.get("target") orelse return error.RebalanceRequiresTarget;
        if (target_v != .object) return error.WrongType;
        const ttype = try getString(target_v.object, "type");
        if (!std.mem.eql(u8, ttype, "portfolio_weight")) return error.RebalanceRequiresTarget;
        target_weight = try getUnitDecimal(target_v.object, "btc", error.WeightOutOfRange);
    }

    const confidence = try getUnitDecimal(obj, "confidence", error.ConfidenceOutOfRange);

    var policy = OrderPolicy{};
    if (obj.get("order_policy")) |pv| {
        if (pv != .object) return error.WrongType;
        const pobj = pv.object;
        const ptype_str = try getString(pobj, "type");
        policy.type = OrderPolicyType.fromString(ptype_str) orelse return error.UnknownOrderPolicy;
        policy.urgency = try getUnitDecimal(pobj, "urgency", error.UrgencyOutOfRange);
        if (pobj.get("max_wait_ms")) |mw| {
            if (mw != .integer or mw.integer < 0 or mw.integer > 3_600_000) return error.WrongType;
            policy.max_wait_ms = @intCast(mw.integer);
        }
    } else if (action == .rebalance) {
        return error.MissingField; // rebalance must state an execution policy
    }

    const thesis = try getStringList(a, obj, "thesis");
    const invalid_if = try getStringList(a, obj, "invalid_if");

    var review_after: ?[]const u8 = null;
    if (obj.get("review_after")) |rv| {
        if (rv != .string) return error.WrongType;
        if (rv.string.len > 32) return error.StringTooLong;
        review_after = try dupString(a, rv.string);
    }

    return .{
        .decision_id = decision_id,
        .snapshot_version = snapshot_version,
        .action = action,
        .target_btc_weight = target_weight,
        .order_policy = policy,
        .confidence = confidence,
        .thesis = thesis,
        .invalid_if = invalid_if,
        .review_after = review_after,
        .arena = arena,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ValidationError![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .string) return error.WrongType;
    if (v.string.len > MAX_STRING_LEN) return error.StringTooLong;
    return v.string;
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) ValidationError!u64 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .integer or v.integer < 0) return error.WrongType;
    return @intCast(v.integer);
}

/// Read a JSON number and validate it lies in [0,1], returning a Decimal.
fn getUnitDecimal(obj: std.json.ObjectMap, key: []const u8, range_err: ValidationError) ValidationError!Decimal {
    const v = obj.get(key) orelse return error.MissingField;
    const d = switch (v) {
        .integer => |i| Decimal.fromInt(std.math.cast(i64, i) orelse return error.WrongType),
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return error.WrongType;
            // Model outputs are advisory; convert via rounding to 1e-8.
            const scaled = f * @as(f64, @floatFromInt(dec.ONE_RAW));
            if (scaled > 9.2e18 or scaled < -9.2e18) return error.WrongType;
            break :blk Decimal.fromRaw(@intFromFloat(@round(scaled)));
        },
        .number_string => |s| Decimal.parse(s) catch return error.WrongType,
        else => return error.WrongType,
    };
    if (d.isNegative() or d.gt(Decimal.one)) return range_err;
    return d;
}

fn getStringList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ValidationError![][]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .array) return error.WrongType;
    const arr = v.array;
    if (arr.items.len > MAX_LIST_ITEMS) return error.ListTooLong;
    var out = a.alloc([]const u8, arr.items.len) catch return error.OutOfMemory;
    for (arr.items, 0..) |item, i| {
        if (item != .string) return error.WrongType;
        if (item.string.len > MAX_STRING_LEN) return error.StringTooLong;
        out[i] = try dupString(a, item.string);
    }
    return out;
}

fn dupString(a: std.mem.Allocator, s: []const u8) ValidationError![]const u8 {
    return a.dupe(u8, s) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const valid_json =
    \\{
    \\  "decision_id": "dec_01JTEST",
    \\  "snapshot_version": 184392,
    \\  "action": "REBALANCE",
    \\  "target": { "type": "portfolio_weight", "btc": 0.62 },
    \\  "order_policy": { "type": "LIMIT_OR_MARKET", "urgency": 0.40, "max_wait_ms": 120000 },
    \\  "confidence": 0.71,
    \\  "thesis": ["4h trend remains positive", "exchange inflow is neutral"],
    \\  "evidence": [{"tool": "okx.market", "as_of": "2026-08-09T08:30:00Z"}],
    \\  "invalid_if": ["4h structure breaks", "wallet inflow spikes"],
    \\  "review_after": "PT4H"
    \\}
;

test "design example proposal parses" {
    var p = try parse(testing.allocator, valid_json);
    defer p.deinit();
    try testing.expectEqualStrings("dec_01JTEST", p.decision_id);
    try testing.expectEqual(@as(u64, 184392), p.snapshot_version);
    try testing.expectEqual(Action.rebalance, p.action);
    try testing.expect(p.target_btc_weight.eql(Decimal.parse("0.62") catch unreachable));
    try testing.expect(p.confidence.eql(Decimal.parse("0.71") catch unreachable));
    try testing.expectEqual(@as(usize, 2), p.thesis.len);
    try testing.expectEqual(@as(usize, 2), p.invalid_if.len);
    try testing.expectEqualStrings("PT4H", p.review_after.?);
}

test "hold without target is fine" {
    const hold_json =
        \\{"decision_id":"dec_x1","snapshot_version":5,"action":"HOLD",
        \\ "confidence":0.5,"thesis":["wait"],"invalid_if":[]}
    ;
    var p = try parse(testing.allocator, hold_json);
    defer p.deinit();
    try testing.expectEqual(Action.hold, p.action);
    try testing.expect(p.target_btc_weight.isZero());
}

test "malformed inputs are rejected fail-closed" {
    const gpa = testing.allocator;
    try testing.expectError(error.MalformedJson, parse(gpa, "not json"));
    try testing.expectError(error.MalformedJson, parse(gpa, "[1,2,3]"));
    try testing.expectError(error.MissingField, parse(gpa,
        \\{"snapshot_version":1,"action":"HOLD","confidence":0.5,"thesis":[],"invalid_if":[]}
    ));
    try testing.expectError(error.UnknownAction, parse(gpa,
        \\{"decision_id":"dec_a","snapshot_version":1,"action":"YOLO","confidence":0.5,"thesis":[],"invalid_if":[]}
    ));
    try testing.expectError(error.WeightOutOfRange, parse(gpa,
        \\{"decision_id":"dec_a","snapshot_version":1,"action":"REBALANCE",
        \\ "target":{"type":"portfolio_weight","btc":1.5},
        \\ "order_policy":{"type":"LIMIT_ONLY","urgency":0},
        \\ "confidence":0.5,"thesis":[],"invalid_if":[]}
    ));
    try testing.expectError(error.ConfidenceOutOfRange, parse(gpa,
        \\{"decision_id":"dec_a","snapshot_version":1,"action":"HOLD","confidence":-0.1,"thesis":[],"invalid_if":[]}
    ));
    try testing.expectError(error.DecisionIdInvalid, parse(gpa,
        \\{"decision_id":"nope","snapshot_version":1,"action":"HOLD","confidence":0.5,"thesis":[],"invalid_if":[]}
    ));
    try testing.expectError(error.MissingField, parse(gpa,
        \\{"decision_id":"dec_a","snapshot_version":1,"action":"REBALANCE",
        \\ "target":{"type":"portfolio_weight","btc":0.5},
        \\ "confidence":0.5,"thesis":[],"invalid_if":[]}
    )); // rebalance without order_policy
}

test "fuzz: random bytes never crash the parser" {
    var prng = std.Random.DefaultPrng.init(0xfeed);
    const random = prng.random();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const len = random.intRangeAtMost(usize, 0, buf.len);
        random.bytes(buf[0..len]);
        var p = parse(testing.allocator, buf[0..len]) catch continue;
        p.deinit(); // in the absurd case random bytes parse, it must still be well-formed
    }
}
