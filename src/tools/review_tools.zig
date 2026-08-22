//! Review-agent tool protocol (复盘工具环): a bounded superset of the main
//! agent's indicator round. The review LLM may reply ONCE with
//! `{"tool_requests":[...]}` to pull read-only data before answering:
//!
//!   {"name":"rsi","bar":"1H","period":14,"at":"anchor"}   // indicators.zig kinds
//!   {"name":"candles","bar":"1H","count":24}              // OHLCV window around anchor
//!   {"name":"decisions","hours":48}                       // proposals around anchor
//!   {"name":"equity","hours":48}                          // equity trail around anchor
//!   {"name":"memories"}                                   // retrieved agent memories
//!   {"name":"intel","at":"now"}                           // signed intel; now or at anchor
//!
//! Everything is read-only market/audit data; nothing here can reach the
//! trading path. Parsing is strict and bounded like indicators.parseRequests.

const std = @import("std");
const indicators = @import("indicators.zig");
const okx_rest = @import("../exchange/okx/rest.zig");

pub const Candle = okx_rest.Candle;

pub const MAX_REQUESTS = 6;
pub const MAX_HOURS = 14 * 24;
pub const DEFAULT_HOURS = 48;
pub const MAX_CANDLES = 48;
pub const DEFAULT_CANDLES = 24;

pub const At = enum { anchor, now };

pub const Tool = union(enum) {
    indicator: struct { req: indicators.Request, at: At },
    candles: struct { bar: []const u8, count: usize },
    decisions: struct { hours: u32 },
    equity: struct { hours: u32 },
    memories: void,
    intel: struct { at: At },

    pub fn name(self: Tool) []const u8 {
        return switch (self) {
            .indicator => |i| i.req.kind.text(),
            .candles => "candles",
            .decisions => "decisions",
            .equity => "equity",
            .memories => "memories",
            .intel => "intel",
        };
    }
};

pub const ParseError = indicators.ParseError;

fn parseHours(obj: std.json.ObjectMap) ParseError!u32 {
    var hours: u32 = DEFAULT_HOURS;
    if (obj.get("hours")) |h| {
        if (h != .integer) return error.BadRequest;
        if (h.integer < 1 or h.integer > MAX_HOURS) return error.BadRequest;
        hours = @intCast(h.integer);
    }
    return hours;
}

/// Detect + parse a review `{"tool_requests":[...]}` reply. Returns request
/// count, or error.NotToolRequest when absent (caller treats the reply as the
/// final answer). Bar strings are copied into `backing`.
pub fn parseRequests(
    gpa: std.mem.Allocator,
    json_slice: []const u8,
    backing: []u8,
    out: []Tool,
) ParseError!usize {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_slice, .{}) catch
        return error.NotToolRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotToolRequest;
    const arr_v = parsed.value.object.get("tool_requests") orelse return error.NotToolRequest;
    if (arr_v != .array) return error.BadRequest;
    const items = arr_v.array.items;
    if (items.len == 0) return error.BadRequest;
    if (items.len > MAX_REQUESTS or items.len > out.len) return error.TooManyRequests;

    var off: usize = 0;
    for (items, 0..) |item, i| {
        if (item != .object) return error.BadRequest;
        const obj = item.object;
        const name_v = obj.get("name") orelse return error.BadRequest;
        if (name_v != .string) return error.BadRequest;
        const nm = name_v.string;

        if (indicators.Kind.parse(nm)) |kind| {
            const bar_v = obj.get("bar") orelse return error.BadRequest;
            if (bar_v != .string) return error.BadRequest;
            if (!indicators.barValid(bar_v.string)) return error.BadRequest;
            var period: usize = indicators.defaultPeriod(kind);
            if (obj.get("period")) |p| {
                if (p != .integer) return error.BadRequest;
                if (p.integer < indicators.MIN_PERIOD or p.integer > indicators.MAX_PERIOD) return error.BadRequest;
                period = @intCast(p.integer);
            }
            var at: At = .anchor;
            if (obj.get("at")) |a| {
                if (a != .string) return error.BadRequest;
                if (std.mem.eql(u8, a.string, "now")) {
                    at = .now;
                } else if (std.mem.eql(u8, a.string, "anchor")) {
                    at = .anchor;
                } else return error.BadRequest;
            }
            if (off + bar_v.string.len > backing.len) return error.BufferTooSmall;
            const bar_copy = backing[off .. off + bar_v.string.len];
            @memcpy(@constCast(bar_copy), bar_v.string);
            off += bar_v.string.len;
            out[i] = .{ .indicator = .{
                .req = .{ .kind = kind, .bar = bar_copy, .period = period },
                .at = at,
            } };
        } else if (std.mem.eql(u8, nm, "candles")) {
            const bar_v = obj.get("bar") orelse return error.BadRequest;
            if (bar_v != .string) return error.BadRequest;
            if (!indicators.barValid(bar_v.string)) return error.BadRequest;
            var count: usize = DEFAULT_CANDLES;
            if (obj.get("count")) |c| {
                if (c != .integer) return error.BadRequest;
                if (c.integer < 4 or c.integer > MAX_CANDLES) return error.BadRequest;
                count = @intCast(c.integer);
            }
            if (off + bar_v.string.len > backing.len) return error.BufferTooSmall;
            const bar_copy = backing[off .. off + bar_v.string.len];
            @memcpy(@constCast(bar_copy), bar_v.string);
            off += bar_v.string.len;
            out[i] = .{ .candles = .{ .bar = bar_copy, .count = count } };
        } else if (std.mem.eql(u8, nm, "decisions")) {
            out[i] = .{ .decisions = .{ .hours = try parseHours(obj) } };
        } else if (std.mem.eql(u8, nm, "equity")) {
            out[i] = .{ .equity = .{ .hours = try parseHours(obj) } };
        } else if (std.mem.eql(u8, nm, "memories")) {
            out[i] = .memories;
        } else if (std.mem.eql(u8, nm, "intel")) {
            var at: At = .now;
            if (obj.get("at")) |a| {
                if (a != .string) return error.BadRequest;
                if (std.mem.eql(u8, a.string, "now")) {
                    at = .now;
                } else if (std.mem.eql(u8, a.string, "anchor")) {
                    at = .anchor;
                } else return error.BadRequest;
            }
            out[i] = .{ .intel = .{ .at = at } };
        } else {
            return error.BadRequest;
        }
    }
    return items.len;
}

/// Index of the last candle with ts_ms <= anchor_ms, or null when the anchor
/// predates the series (history beyond the public window).
pub fn anchorIndex(candles: []const Candle, anchor_ms: i64) ?usize {
    if (candles.len == 0) return null;
    if (candles[0].ts_ms > anchor_ms) return null;
    var idx: usize = 0;
    for (candles, 0..) |c, i| {
        if (c.ts_ms <= anchor_ms) idx = i else break;
    }
    return idx;
}

/// Compact OHLCV window around the anchor (half before, half after, clipped),
/// oldest-first: {"name":"candles","bar":..,"anchor_ts_ms":..,"rows":[...]}.
pub fn writeCandlesWindow(
    w: *std.Io.Writer,
    bar: []const u8,
    candles: []const Candle,
    anchor_ms: i64,
    count: usize,
) std.Io.Writer.Error!void {
    try w.print("{{\"name\":\"candles\",\"bar\":\"{s}\",\"anchor_ts_ms\":{d},", .{ bar, anchor_ms });
    const idx = anchorIndex(candles, anchor_ms) orelse {
        try w.writeAll("\"error\":\"anchor_out_of_range_try_larger_bar\"}");
        return;
    };
    const half = @max(count / 2, 1);
    const lo = if (idx > half) idx - half else 0;
    const hi = @min(candles.len, lo + count);
    try w.writeAll("\"rows\":[");
    var first = true;
    for (candles[lo..hi], lo..) |c, i| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print(
            "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\"{s}}}",
            .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol, if (i == idx) ",\"anchor\":true" else "" },
        );
    }
    try w.writeAll("]}");
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkCandle(ts_ms: i64, close: f64) Candle {
    const d = @import("../core/decimal.zig").Decimal;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{close}) catch unreachable;
    const v = d.parse(s) catch unreachable;
    return .{ .ts_ms = ts_ms, .open = v, .high = v, .low = v, .close = v, .vol = v };
}

test "parseRequests handles mixed review tools" {
    var backing: [64]u8 = undefined;
    var out: [MAX_REQUESTS]Tool = undefined;
    const j =
        \\{"tool_requests":[
        \\ {"name":"rsi","bar":"1H","period":14},
        \\ {"name":"candles","bar":"4H","count":12},
        \\ {"name":"decisions","hours":72},
        \\ {"name":"equity"},
        \\ {"name":"intel","at":"anchor"}
        \\]}
    ;
    const n = try parseRequests(testing.allocator, j, &backing, &out);
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqualStrings("rsi", out[0].name());
    try testing.expectEqual(At.anchor, out[0].indicator.at);
    try testing.expectEqualStrings("4H", out[1].candles.bar);
    try testing.expectEqual(@as(usize, 12), out[1].candles.count);
    try testing.expectEqual(@as(u32, 72), out[2].decisions.hours);
    try testing.expectEqual(@as(u32, DEFAULT_HOURS), out[3].equity.hours);
    try testing.expectEqualStrings("intel", out[4].name());
    try testing.expectEqual(At.anchor, out[4].intel.at);
}

test "parseRequests intel defaults to now" {
    var backing: [32]u8 = undefined;
    var out: [MAX_REQUESTS]Tool = undefined;
    const n = try parseRequests(testing.allocator, "{\"tool_requests\":[{\"name\":\"intel\"}]}", &backing, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(At.now, out[0].intel.at);
}

test "parseRequests rejects bad input and non-tool replies" {
    var backing: [64]u8 = undefined;
    var out: [MAX_REQUESTS]Tool = undefined;
    try testing.expectError(error.NotToolRequest, parseRequests(testing.allocator, "{\"answer\":\"text\"}", &backing, &out));
    try testing.expectError(error.BadRequest, parseRequests(testing.allocator, "{\"tool_requests\":[{\"name\":\"nope\"}]}", &backing, &out));
    try testing.expectError(error.BadRequest, parseRequests(testing.allocator, "{\"tool_requests\":[{\"name\":\"decisions\",\"hours\":100000}]}", &backing, &out));
    try testing.expectError(error.BadRequest, parseRequests(testing.allocator, "{\"tool_requests\":[{\"name\":\"rsi\",\"bar\":\"2H\"}]}", &backing, &out));
}

test "anchorIndex and candles window clip correctly" {
    var rows: [10]Candle = undefined;
    for (0..10) |i| rows[i] = mkCandle(@as(i64, @intCast(i)) * 1000, 100.0 + @as(f64, @floatFromInt(i)));
    try testing.expectEqual(@as(usize, 5), anchorIndex(&rows, 5500).?);
    try testing.expect(anchorIndex(&rows, -1) == null);

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeCandlesWindow(&w, "1m", &rows, 5500, 4);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "\"anchor\":true") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"error\"") == null);

    var w2: std.Io.Writer = .fixed(&buf);
    try writeCandlesWindow(&w2, "1D", &rows, -5, 4);
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "anchor_out_of_range") != null);
}
