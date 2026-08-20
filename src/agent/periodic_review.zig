//! Periodic review (定期复盘): fixed-cadence self review over a *window* of
//! trading history, not a single episode.
//!
//! Two cycles run side by side:
//!   short — every `short_interval_ms` (default 8h): what happened this shift,
//!           did the decisions match their stated theses, any drift.
//!   long  — every `long_interval_ms` (default 7d): does the strategy still
//!           hold across shifts; consolidates the short reviews it contains.
//!
//! Everything here is pure: cycle scheduling (a function of timestamps), the
//! deterministic facts blob handed to the model, and strict validation of the
//! model's answer. No clock reads, no I/O, no storage. The core loop collects
//! `Facts` from SQLite, calls the LLM, and applies the parsed `memory_ops`
//! through the same fail-closed path as per-episode reflection: a malformed
//! document mutates nothing.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const mem_store = @import("../memory/store.zig");
const reflection = @import("reflection.zig");

const Decimal = dec.Decimal;

pub const MAX_LIST_ITEMS = 8;
pub const MAX_STRING_LEN = 400;
pub const MAX_SUMMARY_LEN = 900;
pub const MAX_OPS = 8;

/// Minimum spacing between any two periodic reviews, so a long cycle falling
/// due in the same tick as a short one cannot chain two LLM calls back to back
/// and stall the loop (fast risk reaction beats punctual bookkeeping).
pub const MIN_GAP_MS: i64 = 120_000;

pub const Cycle = enum {
    short,
    long,

    pub fn text(self: Cycle) []const u8 {
        return switch (self) {
            .short => "short",
            .long => "long",
        };
    }

    pub fn fromString(s: []const u8) ?Cycle {
        if (std.mem.eql(u8, s, "short")) return .short;
        if (std.mem.eql(u8, s, "long")) return .long;
        return null;
    }
};

/// Deterministic cadence for both cycles. `last_*_ms == 0` means "never ran";
/// the core loop seeds it from the newest stored report at boot (or from the
/// boot timestamp on a fresh DB, so a restart cannot fire an empty review).
pub const Schedule = struct {
    /// 0 disables the cycle entirely.
    short_interval_ms: i64 = 0,
    long_interval_ms: i64 = 0,
    last_short_ms: i64 = 0,
    last_long_ms: i64 = 0,
    /// Newest run of *either* cycle; guards MIN_GAP_MS.
    last_any_ms: i64 = 0,

    pub fn initAt(now_ms: i64, short_interval_ms: i64, long_interval_ms: i64) Schedule {
        return .{
            .short_interval_ms = short_interval_ms,
            .long_interval_ms = long_interval_ms,
            .last_short_ms = now_ms,
            .last_long_ms = now_ms,
            .last_any_ms = now_ms,
        };
    }

    fn elapsed(last_ms: i64, interval_ms: i64, now_ms: i64) bool {
        if (interval_ms <= 0) return false;
        if (last_ms <= 0) return true;
        return now_ms - last_ms >= interval_ms;
    }

    /// Which cycle (if any) is due now. Long wins when both are due: it is the
    /// rarer, higher-signal pass, and the short one refires on the next tick.
    pub fn due(self: Schedule, now_ms: i64) ?Cycle {
        if (self.last_any_ms > 0 and now_ms - self.last_any_ms < MIN_GAP_MS) return null;
        if (elapsed(self.last_long_ms, self.long_interval_ms, now_ms)) return .long;
        if (elapsed(self.last_short_ms, self.short_interval_ms, now_ms)) return .short;
        return null;
    }

    /// Mark a cycle as run at `now_ms` (call even when the run degraded, so a
    /// broken LLM cannot spin the loop on retries).
    pub fn commit(self: *Schedule, cycle: Cycle, now_ms: i64) void {
        switch (cycle) {
            .short => self.last_short_ms = now_ms,
            .long => self.last_long_ms = now_ms,
        }
        self.last_any_ms = now_ms;
    }

    /// Window start for a cycle: one full interval back from `now_ms`.
    pub fn windowStartMs(self: Schedule, cycle: Cycle, now_ms: i64) i64 {
        const span = switch (cycle) {
            .short => self.short_interval_ms,
            .long => self.long_interval_ms,
        };
        return now_ms - @max(span, 0);
    }

    /// ms until the next run of `cycle`; 0 when due or disabled-safe.
    pub fn msUntil(self: Schedule, cycle: Cycle, now_ms: i64) i64 {
        const interval = switch (cycle) {
            .short => self.short_interval_ms,
            .long => self.long_interval_ms,
        };
        if (interval <= 0) return 0;
        const last = switch (cycle) {
            .short => self.last_short_ms,
            .long => self.last_long_ms,
        };
        if (last <= 0) return 0;
        return @max(@as(i64, 0), last + interval - now_ms);
    }
};

/// Deterministic window facts. Collected from SQLite by the core loop; the
/// model never queries anything itself during a periodic review.
pub const Facts = struct {
    cycle: Cycle,
    window_from: []const u8 = "",
    window_to: []const u8 = "",
    window_hours: i64 = 0,
    mode: []const u8 = "shadow",
    instrument: []const u8 = "",

    // --- decisions ---
    proposals: i64 = 0,
    holds: i64 = 0,
    rebalances: i64 = 0,
    runs_invalid: i64 = 0,
    runs_error: i64 = 0,
    // --- risk admission ---
    admitted: i64 = 0,
    reduced: i64 = 0,
    rejected: i64 = 0,
    // --- execution ---
    executed: i64 = 0,
    fills: i64 = 0,
    // --- portfolio ---
    equity_start: Decimal = Decimal.zero,
    equity_end: Decimal = Decimal.zero,
    window_return: Decimal = Decimal.zero,
    max_drawdown: Decimal = Decimal.zero,
    hwm: Decimal = Decimal.zero,
    btc_weight: Decimal = Decimal.zero,
    risk_mode: []const u8 = "NORMAL",
    // --- benchmark (shadow buy-and-hold) ---
    has_benchmark: bool = false,
    bh_return: Decimal = Decimal.zero,
    alpha_return: Decimal = Decimal.zero,
    // --- health ---
    audit_alerts: i64 = 0,
    audit_warns: i64 = 0,
    faults: i64 = 0,
    memories_active: i64 = 0,
    /// Short reviews already stored inside this window (long cycle input).
    prior_short_reviews: i64 = 0,

    /// Compact JSON for the prompt and for the persisted report row.
    pub fn writeJson(self: Facts, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "{{\"cycle\":\"{s}\",\"window\":{{\"from\":\"{s}\",\"to\":\"{s}\",\"hours\":{d}}}," ++
                "\"mode\":\"{s}\",\"instrument\":\"{s}\"," ++
                "\"decisions\":{{\"proposals\":{d},\"hold\":{d},\"rebalance\":{d},\"invalid\":{d},\"error\":{d}}}," ++
                "\"admission\":{{\"approved\":{d},\"reduced\":{d},\"rejected\":{d}}}," ++
                "\"execution\":{{\"executed\":{d},\"fills\":{d}}}," ++
                "\"portfolio\":{{\"equity_start\":\"{f}\",\"equity_end\":\"{f}\",\"return\":\"{f}\"," ++
                "\"max_drawdown\":\"{f}\",\"hwm\":\"{f}\",\"btc_weight\":\"{f}\",\"risk_mode\":\"{s}\"}},",
            .{
                self.cycle.text(),        self.window_from, self.window_to,   self.window_hours,
                self.mode,                self.instrument,  self.proposals,   self.holds,
                self.rebalances,          self.runs_invalid, self.runs_error, self.admitted,
                self.reduced,             self.rejected,    self.executed,    self.fills,
                self.equity_start,        self.equity_end,  self.window_return,
                self.max_drawdown,        self.hwm,         self.btc_weight,  self.risk_mode,
            },
        );
        if (self.has_benchmark) {
            try w.print(
                "\"benchmark\":{{\"buy_and_hold_return\":\"{f}\",\"alpha\":\"{f}\"}},",
                .{ self.bh_return, self.alpha_return },
            );
        } else {
            try w.writeAll("\"benchmark\":null,");
        }
        try w.print(
            "\"health\":{{\"audit_alerts\":{d},\"audit_warns\":{d},\"faults\":{d}}}," ++
                "\"memories_active\":{d},\"prior_short_reviews\":{d}}}",
            .{ self.audit_alerts, self.audit_warns, self.faults, self.memories_active, self.prior_short_reviews },
        );
    }
};

pub const ParseError = reflection.ValidationError || error{
    CycleMismatch,
    SummaryEmpty,
};

/// A validated periodic review document. Arena-owned like `Reflection`.
pub const Document = struct {
    cycle: Cycle,
    summary: []const u8,
    findings: [][]const u8,
    lessons: [][]const u8,
    risks: [][]const u8,
    memory_ops: []mem_store.Op,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// Parse and validate a raw model review. Fail-closed: anything malformed
/// voids the whole document, so no memory mutation can ride in on a bad doc.
pub fn parse(gpa: std.mem.Allocator, raw: []const u8, expect: Cycle) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{
        .max_value_len = 64 * 1024,
    }) catch return error.MalformedJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const cycle_v = obj.get("cycle") orelse return error.MissingField;
    if (cycle_v != .string) return error.WrongType;
    const cycle = Cycle.fromString(cycle_v.string) orelse return error.CycleMismatch;
    if (cycle != expect) return error.CycleMismatch;

    const summary_v = obj.get("summary") orelse return error.MissingField;
    if (summary_v != .string) return error.WrongType;
    if (summary_v.string.len > MAX_SUMMARY_LEN) return error.StringTooLong;
    const summary = std.mem.trim(u8, summary_v.string, " \t\r\n");
    if (summary.len == 0) return error.SummaryEmpty;

    const findings = try stringList(a, obj, "findings");
    const lessons = try stringList(a, obj, "lessons");
    const risks = try stringListOptional(a, obj, "risks");

    const ops_v = obj.get("memory_ops") orelse return error.MissingField;
    if (ops_v != .array) return error.WrongType;
    if (ops_v.array.items.len > MAX_OPS) return error.TooManyOps;
    var ops = a.alloc(mem_store.Op, ops_v.array.items.len) catch return error.OutOfMemory;
    for (ops_v.array.items, 0..) |item, i| {
        ops[i] = try reflection.parseOp(a, item);
    }

    return .{
        .cycle = cycle,
        .summary = a.dupe(u8, summary) catch return error.OutOfMemory,
        .findings = findings,
        .lessons = lessons,
        .risks = risks,
        .memory_ops = ops,
        .arena = arena,
    };
}

fn stringList(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![][]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return listFromValue(a, v);
}

fn stringListOptional(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![][]const u8 {
    const v = obj.get(key) orelse return a.alloc([]const u8, 0) catch return error.OutOfMemory;
    if (v == .null) return a.alloc([]const u8, 0) catch return error.OutOfMemory;
    return listFromValue(a, v);
}

fn listFromValue(a: std.mem.Allocator, v: std.json.Value) ParseError![][]const u8 {
    if (v != .array) return error.WrongType;
    if (v.array.items.len > MAX_LIST_ITEMS) return error.ListTooLong;
    var out = a.alloc([]const u8, v.array.items.len) catch return error.OutOfMemory;
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.WrongType;
        if (item.string.len > MAX_STRING_LEN) return error.StringTooLong;
        out[i] = a.dupe(u8, item.string) catch return error.OutOfMemory;
    }
    return out;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const hour_ms: i64 = 3_600_000;

test "schedule fires each cycle on its own cadence" {
    const t0: i64 = 1_000_000_000;
    var s = Schedule.initAt(t0, 8 * hour_ms, 7 * 24 * hour_ms);

    try testing.expect(s.due(t0) == null);
    try testing.expect(s.due(t0 + 7 * hour_ms) == null);

    // 8h in: short due, long not.
    try testing.expectEqual(Cycle.short, s.due(t0 + 8 * hour_ms).?);
    s.commit(.short, t0 + 8 * hour_ms);
    try testing.expect(s.due(t0 + 8 * hour_ms) == null);

    // Next short only after another 8h.
    try testing.expect(s.due(t0 + 15 * hour_ms) == null);
    try testing.expectEqual(Cycle.short, s.due(t0 + 16 * hour_ms).?);

    // A week in the long cycle wins the tie, short refires afterwards.
    const week = t0 + 7 * 24 * hour_ms;
    try testing.expectEqual(Cycle.long, s.due(week).?);
    s.commit(.long, week);
    try testing.expect(s.due(week) == null); // MIN_GAP_MS holds the short back
    try testing.expectEqual(Cycle.short, s.due(week + MIN_GAP_MS).?);
}

test "schedule: zero interval disables a cycle; unknown last fires immediately" {
    const t0: i64 = 5_000_000;
    var off = Schedule.initAt(t0, 0, 0);
    try testing.expect(off.due(t0 + 30 * 24 * hour_ms) == null);

    // Restored-from-DB style: long never ran (0) → due at once.
    var s: Schedule = .{ .short_interval_ms = 8 * hour_ms, .long_interval_ms = 7 * 24 * hour_ms };
    try testing.expectEqual(Cycle.long, s.due(t0).?);
    s.commit(.long, t0);
    try testing.expectEqual(Cycle.short, s.due(t0 + MIN_GAP_MS).?);

    // Windows span exactly one interval back.
    try testing.expectEqual(t0 - 8 * hour_ms, s.windowStartMs(.short, t0));
    try testing.expectEqual(t0 - 7 * 24 * hour_ms, s.windowStartMs(.long, t0));
    s.commit(.short, t0 + MIN_GAP_MS);
    try testing.expectEqual(@as(i64, 8 * hour_ms), s.msUntil(.short, t0 + MIN_GAP_MS));
}

test "downtime longer than the interval fires once, not once per missed slot" {
    const t0: i64 = 100_000_000;
    var s = Schedule.initAt(t0, 8 * hour_ms, 0);
    const late = t0 + 3 * 24 * hour_ms; // daemon was down for 3 days
    try testing.expectEqual(Cycle.short, s.due(late).?);
    s.commit(.short, late);
    try testing.expect(s.due(late + 7 * hour_ms) == null);
}

test "facts render compact json with and without benchmark" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const f: Facts = .{
        .cycle = .short,
        .window_from = "2026-08-20T00:00:00.000Z",
        .window_to = "2026-08-20T08:00:00.000Z",
        .window_hours = 8,
        .instrument = "BTC-USDT",
        .proposals = 12,
        .holds = 10,
        .rebalances = 2,
        .admitted = 11,
        .reduced = 1,
        .executed = 2,
        .fills = 3,
        .equity_start = try Decimal.parse("100"),
        .equity_end = try Decimal.parse("101.5"),
        .window_return = try Decimal.parse("0.015"),
        .max_drawdown = try Decimal.parse("0.004"),
        .has_benchmark = true,
        .bh_return = try Decimal.parse("0.02"),
        .alpha_return = try Decimal.parse("-0.005"),
        .memories_active = 14,
    };
    try f.writeJson(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"cycle\":\"short\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"hours\":8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"hold\":10") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"alpha\":\"-0.005\"") != null);
    // Must be valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    parsed.deinit();

    var buf2: [2048]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var f2 = f;
    f2.has_benchmark = false;
    f2.cycle = .long;
    try f2.writeJson(&w2);
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"benchmark\":null") != null);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, w2.buffered(), .{});
    parsed2.deinit();
}

const good_doc =
    \\{
    \\  "cycle": "short",
    \\  "summary": "本轮 12 次决策中 10 次 HOLD，净值 +1.5%，但同期买入持有 +2%，超额为负。",
    \\  "findings": ["HOLD 连续 10 次期间价格单边上行", "两次调仓都在冲高后执行"],
    \\  "lessons": ["单边上行时的 HOLD 需要按机会成本计负分"],
    \\  "risks": ["样本仅 8 小时，结论置信度低"],
    \\  "memory_ops": [
    \\    { "op": "UPDATE", "memory_id": "H17", "confidence_delta": -0.05, "evidence_increment": 1 },
    \\    { "op": "CREATE", "memory_id": "PR_short_1", "kind": "reflection", "status": "active",
    \\      "confidence": 0.3, "content": {"tags": ["periodic_review", "BTC-USDT"]} }
    \\  ]
    \\}
;

test "parses a well-formed periodic review document" {
    var d = try parse(testing.allocator, good_doc, .short);
    defer d.deinit();

    try testing.expectEqual(Cycle.short, d.cycle);
    try testing.expect(std.mem.indexOf(u8, d.summary, "超额为负") != null);
    try testing.expectEqual(@as(usize, 2), d.findings.len);
    try testing.expectEqual(@as(usize, 1), d.lessons.len);
    try testing.expectEqual(@as(usize, 1), d.risks.len);
    try testing.expectEqual(@as(usize, 2), d.memory_ops.len);
    try testing.expectEqualStrings("H17", d.memory_ops[0].update.memory_id);
    try testing.expectEqual(mem_store.Kind.reflection, d.memory_ops[1].create.kind);
}

test "risks is optional; missing/null yields an empty list" {
    const raw =
        \\{"cycle":"long","summary":"周度无显著变化。","findings":[],"lessons":[],"memory_ops":[]}
    ;
    var d = try parse(testing.allocator, raw, .long);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.risks.len);
    try testing.expectEqual(@as(usize, 0), d.memory_ops.len);
}

test "malformed periodic reviews are rejected fail-closed" {
    const cases = [_]struct { raw: []const u8, expect: Cycle, err: anyerror }{
        .{ .raw = "not json", .expect = .short, .err = error.MalformedJson },
        .{ .raw = "[]", .expect = .short, .err = error.MalformedJson },
        // cycle must match the one we asked for (no silent relabeling)
        .{ .raw = good_doc, .expect = .long, .err = error.CycleMismatch },
        .{
            .raw = "{\"cycle\":\"yearly\",\"summary\":\"x\",\"findings\":[],\"lessons\":[],\"memory_ops\":[]}",
            .expect = .short,
            .err = error.CycleMismatch,
        },
        .{
            .raw = "{\"cycle\":\"short\",\"summary\":\"   \",\"findings\":[],\"lessons\":[],\"memory_ops\":[]}",
            .expect = .short,
            .err = error.SummaryEmpty,
        },
        .{
            .raw = "{\"cycle\":\"short\",\"findings\":[],\"lessons\":[],\"memory_ops\":[]}",
            .expect = .short,
            .err = error.MissingField,
        },
        .{
            .raw =
            \\{"cycle":"short","summary":"s","findings":[],"lessons":[],
            \\ "memory_ops":[{"op":"DROP","memory_id":"H1"}]}
            ,
            .expect = .short,
            .err = error.UnknownOp,
        },
        .{
            .raw =
            \\{"cycle":"short","summary":"s","findings":[],"lessons":[],
            \\ "memory_ops":[{"op":"UPDATE","memory_id":"bad id!"}]}
            ,
            .expect = .short,
            .err = error.MemoryIdInvalid,
        },
        .{
            .raw =
            \\{"cycle":"short","summary":"s","findings":["a","b","c","d","e","f","g","h","i"],
            \\ "lessons":[],"memory_ops":[]}
            ,
            .expect = .short,
            .err = error.ListTooLong,
        },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parse(testing.allocator, case.raw, case.expect));
    }
}

test "too many memory ops are rejected" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"cycle\":\"short\",\"summary\":\"s\",\"findings\":[],\"lessons\":[],\"memory_ops\":[");
    for (0..MAX_OPS + 1) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"op\":\"INVALIDATE\",\"memory_id\":\"H{d}\"}}", .{i});
    }
    try w.writeAll("]}");
    try testing.expectError(error.TooManyOps, parse(testing.allocator, w.buffered(), .short));
}
