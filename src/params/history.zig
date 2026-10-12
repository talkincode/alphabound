//! Load candles and recorded decisions for the parameter backtest gate.
//!
//! The daemon path reads 1m equity marks (bid only) and buckets them to 15m,
//! plus AGENT_PROPOSAL_OK rebalances. HOLD is not a target weight. Exported
//! CSV uses the same columns as `zig build backtest`. Live balances are not
//! returned.

const std = @import("std");
const db = @import("../storage/db.zig");
const clock = @import("../core/clock.zig");
const dec = @import("../core/decimal.zig");
const backtest = @import("../backtest.zig");
const guard = @import("../risk/guardrails.zig");

const Decimal = dec.Decimal;

pub const bar_ms: i64 = 15 * 60_000;
const max_marks: i64 = 60_000;
const max_decisions: i64 = 4_000;

pub const Series = struct {
    bars: std.ArrayList(backtest.Bar) = .empty,
    decisions: std.ArrayList(backtest.Decision) = .empty,

    pub fn deinit(self: *Series, gpa: std.mem.Allocator) void {
        self.bars.deinit(gpa);
        self.decisions.deinit(gpa);
    }
};

pub fn fromCsv(gpa: std.mem.Allocator, candles: []const u8, decisions: []const u8) !Series {
    var series = Series{};
    errdefer series.deinit(gpa);
    series.bars = try backtest.parseBars(gpa, candles);
    series.decisions = try backtest.parseDecisions(gpa, decisions);
    return series;
}

/// Newest ~40 days of 1m bids, bucketed to 15m, and recorded rebalances inside
/// that window. An empty book is an empty series, not an error.
pub fn fromDb(gpa: std.mem.Allocator, database: *db.Db) !Series {
    var series = Series{};
    errdefer series.deinit(gpa);
    try loadBars(gpa, database, &series.bars);
    try loadDecisions(gpa, database, &series.decisions);
    if (series.bars.items.len == 0) return series;
    const start = series.bars.items[0].ts;
    const end = series.bars.items[series.bars.items.len - 1].ts;
    var kept: std.ArrayList(backtest.Decision) = .empty;
    errdefer kept.deinit(gpa);
    for (series.decisions.items) |d| {
        if (d.ts >= start and d.ts <= end) try kept.append(gpa, d);
    }
    series.decisions.deinit(gpa);
    series.decisions = kept;
    return series;
}

fn loadBars(gpa: std.mem.Allocator, database: *db.Db, out: *std.ArrayList(backtest.Bar)) !void {
    var stmt = try database.prepare(
        \\SELECT ts, bid_price FROM (
        \\  SELECT ts, bid_price FROM equity_samples
        \\  WHERE interval = '1m' AND bid_price != ''
        \\  ORDER BY ts DESC LIMIT ?1
        \\) ORDER BY ts ASC
    );
    defer stmt.finalize();
    try stmt.bindInt(1, max_marks);
    var current: i64 = std.math.minInt(i64);
    while (try stmt.step()) {
        const ts = clock.parseRfc3339Ms(stmt.columnText(0)) catch continue;
        const bid = Decimal.parse(stmt.columnText(1)) catch continue;
        if (!bid.gt(Decimal.zero)) continue;
        const bucket = @divFloor(ts, bar_ms) * bar_ms;
        if (bucket < current) continue;
        if (bucket != current) {
            try out.append(gpa, .{ .ts = bucket, .open = bid, .close = bid });
            current = bucket;
        } else if (out.items.len > 0) {
            out.items[out.items.len - 1].close = bid;
        }
    }
}

fn loadDecisions(gpa: std.mem.Allocator, database: *db.Db, out: *std.ArrayList(backtest.Decision)) !void {
    var stmt = try database.prepare(
        \\SELECT ts, payload_json FROM (
        \\  SELECT ts, payload_json FROM events
        \\  WHERE type = 'AGENT_PROPOSAL_OK'
        \\  ORDER BY ts DESC LIMIT ?1
        \\) ORDER BY ts ASC
    );
    defer stmt.finalize();
    try stmt.bindInt(1, max_decisions);
    var prev: i64 = std.math.minInt(i64);
    while (try stmt.step()) {
        const ts = clock.parseRfc3339Ms(stmt.columnText(0)) catch continue;
        if (ts < prev) continue;
        const payload = stmt.columnText(1);
        const dc = parseRebalance(payload, ts) orelse continue;
        try out.append(gpa, dc);
        prev = ts;
    }
}

fn parseRebalance(payload: []const u8, ts: i64) ?backtest.Decision {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const action = obj.get("action") orelse return null;
    if (action != .string or !std.mem.eql(u8, action.string, "REBALANCE")) return null;
    const weight_v = obj.get("target_btc_weight") orelse return null;
    if (weight_v != .string) return null;
    const weight = Decimal.parse(weight_v.string) catch return null;
    if (weight.isNegative() or weight.gt(Decimal.one)) return null;
    var dc = backtest.Decision{ .ts = ts, .weight = weight };
    if (obj.get("thesis")) |thesis| {
        if (thesis == .array) {
            var lines: [6][]const u8 = undefined;
            var n: usize = 0;
            for (thesis.array.items) |item| {
                if (n >= lines.len) break;
                if (item == .string) {
                    lines[n] = item.string;
                    n += 1;
                }
            }
            dc.macro = guard.isMacroDriven(lines[0..n]);
        }
    }
    return dc;
}

const testing = std.testing;

test "database loader buckets marks and skips HOLD" {
    var database = try db.Db.open(":memory:");
    defer database.close();
    const t0: i64 = 1_700_000_000_000;
    var i: usize = 0;
    while (i < 45) : (i += 1) {
        var ts_buf: [40]u8 = undefined;
        const ts = try clock.formatRfc3339Ms(t0 + @as(i64, @intCast(i)) * 60_000, &ts_buf);
        var stmt = try database.prepare(
            \\INSERT INTO equity_samples (ts, interval, equity, hwm, drawdown, cash, btc_value, bid_price)
            \\VALUES (?1, '1m', '1000', '1000', '0', '1000', '0', '100')
        );
        defer stmt.finalize();
        try stmt.bindText(1, ts);
        _ = try stmt.stepCritical();
    }
    var hold_ts: [40]u8 = undefined;
    var reb_ts: [40]u8 = undefined;
    const hold = try clock.formatRfc3339Ms(t0 + 60_000, &hold_ts);
    const reb = try clock.formatRfc3339Ms(t0 + 15 * 60_000, &reb_ts);
    try insertEvent(&database, hold, "{\"action\":\"HOLD\",\"target_btc_weight\":\"0\"}");
    try insertEvent(&database, reb, "{\"action\":\"REBALANCE\",\"target_btc_weight\":\"0.4\",\"thesis\":[\"FOMC risk\"]}");
    var series = try fromDb(testing.allocator, &database);
    defer series.deinit(testing.allocator);
    try testing.expect(series.bars.items.len >= 3);
    try testing.expect(series.bars.items.len <= 4);
    try testing.expectEqual(@as(usize, 1), series.decisions.items.len);
    try testing.expect(series.decisions.items[0].weight.eql(Decimal.parse("0.4") catch unreachable));
    try testing.expect(series.decisions.items[0].macro);
}

fn insertEvent(database: *db.Db, ts: []const u8, payload: []const u8) !void {
    var stmt = try database.prepare(
        \\INSERT INTO events (event_id, ts, type, source, severity, payload_json)
        \\VALUES (?1, ?2, 'AGENT_PROPOSAL_OK', 'agent', 'INFO', ?3)
    );
    defer stmt.finalize();
    try stmt.bindText(1, ts);
    try stmt.bindText(2, ts);
    try stmt.bindText(3, payload);
    _ = try stmt.stepCritical();
}
