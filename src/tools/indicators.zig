//! Deterministic indicator calculator — the agent's on-demand math tool.
//!
//! The LLM may reply with `{"tool_requests":[...]}` instead of a proposal
//! (one round only). Each request names an indicator, a timeframe and a
//! period; the daemon computes the value locally from exchange candles and
//! feeds the result back as a `market.indicators` observation. The system
//! prescribes no meaning to any indicator — the model chooses what to
//! compute and how to interpret it.
//!
//! All math is pure f64 over candles ordered oldest-first. Same candles +
//! same request → same bytes out (rendered with fixed precision), so the
//! decision context stays replayable.

const std = @import("std");
const okx_rest = @import("../exchange/okx/rest.zig");

pub const Candle = okx_rest.Candle;

pub const MAX_REQUESTS = 6;
pub const MIN_PERIOD = 2;
pub const MAX_PERIOD = 100;

pub const Kind = enum {
    sma,
    ema,
    rsi,
    atr,
    vol, // realized volatility (stdev of log returns, annualized)
    bollinger,
    range, // donchian range position

    pub fn parse(s: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn text(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// Whitelisted timeframes (must match OKX bar strings used elsewhere).
pub const bars = [_][]const u8{ "1m", "5m", "15m", "1H", "4H", "1D" };

pub fn barValid(bar: []const u8) bool {
    for (bars) |b| {
        if (std.mem.eql(u8, b, bar)) return true;
    }
    return false;
}

/// Bars per year for annualizing realized volatility.
fn barsPerYear(bar: []const u8) f64 {
    if (std.mem.eql(u8, bar, "1m")) return 525_600.0;
    if (std.mem.eql(u8, bar, "5m")) return 105_120.0;
    if (std.mem.eql(u8, bar, "15m")) return 35_040.0;
    if (std.mem.eql(u8, bar, "1H")) return 8_760.0;
    if (std.mem.eql(u8, bar, "4H")) return 2_190.0;
    return 365.0; // 1D
}

pub const Request = struct {
    kind: Kind,
    bar: []const u8, // slice into caller-provided backing
    period: usize,
};

pub const ParseError = error{
    NotToolRequest,
    TooManyRequests,
    BadRequest,
    BufferTooSmall,
};

/// Detect + parse a `{"tool_requests":[...]}` reply. Returns request count,
/// or error.NotToolRequest when the key is absent (caller then treats the
/// reply as a Decision Proposal). Bar strings are copied into `backing`.
pub fn parseRequests(
    gpa: std.mem.Allocator,
    json_slice: []const u8,
    backing: []u8,
    out: []Request,
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
        const kind = Kind.parse(name_v.string) orelse return error.BadRequest;
        const bar_v = obj.get("bar") orelse return error.BadRequest;
        if (bar_v != .string) return error.BadRequest;
        if (!barValid(bar_v.string)) return error.BadRequest;
        var period: usize = defaultPeriod(kind);
        if (obj.get("period")) |p| {
            if (p != .integer) return error.BadRequest;
            if (p.integer < MIN_PERIOD or p.integer > MAX_PERIOD) return error.BadRequest;
            period = @intCast(p.integer);
        }
        if (off + bar_v.string.len > backing.len) return error.BufferTooSmall;
        const bar_copy = backing[off .. off + bar_v.string.len];
        @memcpy(@constCast(bar_copy), bar_v.string);
        off += bar_v.string.len;
        out[i] = .{ .kind = kind, .bar = bar_copy, .period = period };
    }
    return items.len;
}

pub fn defaultPeriod(kind: Kind) usize {
    return switch (kind) {
        .sma, .ema, .bollinger, .range => 20,
        .rsi, .atr => 14,
        .vol => 30,
    };
}

/// Candles needed to compute a request with a warm-up margin.
pub fn candlesNeeded(req: Request) usize {
    return switch (req.kind) {
        .sma, .bollinger, .range => req.period + 1,
        .ema, .rsi, .atr => req.period * 3, // seeded recursions want warm-up
        .vol => req.period + 2,
    };
}

pub const ComputeError = error{InsufficientData};

/// Compute one indicator over candles ordered OLDEST-FIRST; write a compact
/// JSON object (no trailing separator) into `w`.
pub fn compute(w: *std.Io.Writer, req: Request, candles: []const Candle) (ComputeError || std.Io.Writer.Error)!void {
    const n = candles.len;
    if (n < candlesNeeded(req) or n < 2) return error.InsufficientData;

    var closes_buf: [512]f64 = undefined;
    if (n > closes_buf.len) return error.InsufficientData;
    for (candles, 0..) |c, i| closes_buf[i] = c.close.toF64Lossy();
    const closes = closes_buf[0..n];
    const last_close = closes[n - 1];

    switch (req.kind) {
        .sma => {
            const v = mean(closes[n - req.period ..]);
            try head(w, req);
            try w.print("\"value\":{d:.2},\"close\":{d:.2}}}", .{ v, last_close });
        },
        .ema => {
            const v = ema(closes, req.period);
            try head(w, req);
            try w.print("\"value\":{d:.2},\"close\":{d:.2}}}", .{ v, last_close });
        },
        .rsi => {
            const v = rsi(closes, req.period);
            try head(w, req);
            try w.print("\"value\":{d:.1}}}", .{v});
        },
        .atr => {
            const v = atr(candles, req.period);
            try head(w, req);
            try w.print("\"value\":{d:.2},\"pct_of_close\":{d:.3}}}", .{ v, 100.0 * v / last_close });
        },
        .vol => {
            const v = realizedVol(closes, req.period, barsPerYear(req.bar));
            try head(w, req);
            try w.print("\"annualized_pct\":{d:.1}}}", .{v * 100.0});
        },
        .bollinger => {
            const window = closes[n - req.period ..];
            const mid = mean(window);
            const sd = stdev(window, mid);
            const upper = mid + 2.0 * sd;
            const lower = mid - 2.0 * sd;
            const width = upper - lower;
            const pos = if (width > 0) (last_close - lower) / width else 0.5;
            try head(w, req);
            try w.print(
                "\"mid\":{d:.2},\"upper\":{d:.2},\"lower\":{d:.2},\"pos\":{d:.2},\"width_pct\":{d:.2}}}",
                .{ mid, upper, lower, pos, 100.0 * width / mid },
            );
        },
        .range => {
            var hi: f64 = -std.math.inf(f64);
            var lo: f64 = std.math.inf(f64);
            for (candles[n - req.period ..]) |c| {
                hi = @max(hi, c.high.toF64Lossy());
                lo = @min(lo, c.low.toF64Lossy());
            }
            const width = hi - lo;
            const pos = if (width > 0) (last_close - lo) / width else 0.5;
            try head(w, req);
            try w.print("\"high\":{d:.2},\"low\":{d:.2},\"pos\":{d:.2}}}", .{ hi, lo, pos });
        },
    }
}

fn head(w: *std.Io.Writer, req: Request) std.Io.Writer.Error!void {
    try w.print("{{\"name\":\"{s}\",\"bar\":\"{s}\",\"period\":{d},", .{ req.kind.text(), req.bar, req.period });
}

/// One error entry so the model sees why a request produced no value.
pub fn writeError(w: *std.Io.Writer, req: Request, reason: []const u8) std.Io.Writer.Error!void {
    try head(w, req);
    try w.print("\"error\":\"{s}\"}}", .{reason});
}

// --- math (all slices oldest-first) ---------------------------------------

fn mean(xs: []const f64) f64 {
    var s: f64 = 0;
    for (xs) |x| s += x;
    return s / @as(f64, @floatFromInt(xs.len));
}

fn stdev(xs: []const f64, mu: f64) f64 {
    if (xs.len < 2) return 0;
    var s: f64 = 0;
    for (xs) |x| s += (x - mu) * (x - mu);
    return @sqrt(s / @as(f64, @floatFromInt(xs.len - 1)));
}

fn ema(closes: []const f64, period: usize) f64 {
    const k = 2.0 / (@as(f64, @floatFromInt(period)) + 1.0);
    var v = mean(closes[0..period]); // SMA seed
    for (closes[period..]) |c| v = c * k + v * (1.0 - k);
    return v;
}

/// Wilder RSI.
fn rsi(closes: []const f64, period: usize) f64 {
    var gain: f64 = 0;
    var loss: f64 = 0;
    var i: usize = 1;
    while (i <= period) : (i += 1) {
        const d = closes[i] - closes[i - 1];
        if (d > 0) gain += d else loss -= d;
    }
    var avg_gain = gain / @as(f64, @floatFromInt(period));
    var avg_loss = loss / @as(f64, @floatFromInt(period));
    const p: f64 = @floatFromInt(period);
    while (i < closes.len) : (i += 1) {
        const d = closes[i] - closes[i - 1];
        const g = if (d > 0) d else 0;
        const l = if (d < 0) -d else 0;
        avg_gain = (avg_gain * (p - 1) + g) / p;
        avg_loss = (avg_loss * (p - 1) + l) / p;
    }
    if (avg_loss == 0) return 100.0;
    const rs = avg_gain / avg_loss;
    return 100.0 - 100.0 / (1.0 + rs);
}

/// Wilder ATR.
fn atr(candles: []const Candle, period: usize) f64 {
    var v: f64 = 0;
    var i: usize = 1;
    // seed: simple mean of first `period` true ranges
    while (i <= period) : (i += 1) {
        v += trueRange(candles[i], candles[i - 1]);
    }
    v /= @as(f64, @floatFromInt(period));
    const p: f64 = @floatFromInt(period);
    while (i < candles.len) : (i += 1) {
        v = (v * (p - 1) + trueRange(candles[i], candles[i - 1])) / p;
    }
    return v;
}

fn trueRange(c: Candle, prev: Candle) f64 {
    const h = c.high.toF64Lossy();
    const l = c.low.toF64Lossy();
    const pc = prev.close.toF64Lossy();
    return @max(h - l, @max(@abs(h - pc), @abs(l - pc)));
}

/// Annualized stdev of the last `period` log returns.
fn realizedVol(closes: []const f64, period: usize, per_year: f64) f64 {
    const n = closes.len;
    var rets_buf: [512]f64 = undefined;
    var cnt: usize = 0;
    var i = n - period;
    while (i < n) : (i += 1) {
        if (closes[i - 1] <= 0 or closes[i] <= 0) continue;
        rets_buf[cnt] = @log(closes[i] / closes[i - 1]);
        cnt += 1;
    }
    if (cnt < 2) return 0;
    const rets = rets_buf[0..cnt];
    const mu = mean(rets);
    return stdev(rets, mu) * @sqrt(per_year);
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Decimal = @import("../core/decimal.zig").Decimal;

fn mkCandle(o: f64, h: f64, l: f64, c: f64) Candle {
    var buf: [64]u8 = undefined;
    return .{
        .ts_ms = 0,
        .open = parseF(&buf, o),
        .high = parseF(&buf, h),
        .low = parseF(&buf, l),
        .close = parseF(&buf, c),
        .vol = Decimal.zero,
    };
}

fn parseF(buf: []u8, v: f64) Decimal {
    const s = std.fmt.bufPrint(buf, "{d:.4}", .{v}) catch unreachable;
    return Decimal.parse(s) catch unreachable;
}

test "rsi on known series matches reference" {
    // Classic Wilder example-style series: steady gains → RSI near 100.
    var candles: [50]Candle = undefined;
    for (0..50) |i| {
        const px = 100.0 + @as(f64, @floatFromInt(i));
        candles[i] = mkCandle(px, px + 1, px - 1, px);
    }
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try compute(&w, .{ .kind = .rsi, .bar = "1H", .period = 14 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"value\":100.0") != null);

    // Alternating up/down of equal size → RSI ≈ 50.
    var candles2: [60]Candle = undefined;
    for (0..60) |i| {
        const px: f64 = if (i % 2 == 0) 100.0 else 101.0;
        candles2[i] = mkCandle(px, px + 1, px - 1, px);
    }
    var w2: std.Io.Writer = .fixed(&buf);
    try compute(&w2, .{ .kind = .rsi, .bar = "1H", .period = 14 }, &candles2);
    const out = w2.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"rsi\"") != null);
    // parse value and assert 45..55
    const key = "\"value\":";
    const vi = std.mem.indexOf(u8, out, key).? + key.len;
    const ve = std.mem.indexOfScalarPos(u8, out, vi, '}').?;
    const v = try std.fmt.parseFloat(f64, out[vi..ve]);
    try testing.expect(v > 45.0 and v < 55.0);
}

test "sma and ema of constant series equal the constant" {
    var candles: [64]Candle = undefined;
    for (0..64) |i| candles[i] = mkCandle(50, 51, 49, 50);
    var buf: [256]u8 = undefined;

    var w: std.Io.Writer = .fixed(&buf);
    try compute(&w, .{ .kind = .sma, .bar = "4H", .period = 20 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"value\":50.00") != null);

    var w2: std.Io.Writer = .fixed(&buf);
    try compute(&w2, .{ .kind = .ema, .bar = "4H", .period = 20 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"value\":50.00") != null);
}

test "atr of fixed-range candles equals the range" {
    var candles: [50]Candle = undefined;
    for (0..50) |i| candles[i] = mkCandle(100, 102, 98, 100); // TR = 4 every bar
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try compute(&w, .{ .kind = .atr, .bar = "1D", .period = 14 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"value\":4.00") != null);
}

test "bollinger and range position at top of band" {
    var candles: [30]Candle = undefined;
    for (0..30) |i| {
        const px = 100.0 + @as(f64, @floatFromInt(i)) * 0.5;
        candles[i] = mkCandle(px, px + 0.5, px - 0.5, px);
    }
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try compute(&w, .{ .kind = .bollinger, .bar = "1H", .period = 20 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"pos\":") != null);

    var w2: std.Io.Writer = .fixed(&buf);
    try compute(&w2, .{ .kind = .range, .bar = "1H", .period = 20 }, &candles);
    // Uptrend close sits near the top of the donchian range.
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "\"pos\":0.95") != null);
}

test "vol of constant series is zero" {
    var candles: [40]Candle = undefined;
    for (0..40) |i| candles[i] = mkCandle(50, 50, 50, 50);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try compute(&w, .{ .kind = .vol, .bar = "1D", .period = 30 }, &candles);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"annualized_pct\":0.0") != null);
}

test "insufficient data errors instead of fabricating" {
    var candles: [5]Candle = undefined;
    for (0..5) |i| candles[i] = mkCandle(50, 51, 49, 50);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.InsufficientData, compute(&w, .{ .kind = .rsi, .bar = "1H", .period = 14 }, &candles));
}

test "parseRequests: valid batch, defaults, and rejections" {
    const gpa = testing.allocator;
    var backing: [128]u8 = undefined;
    var reqs: [MAX_REQUESTS]Request = undefined;

    const ok_json =
        \\{"tool_requests":[{"name":"rsi","bar":"4H","period":14},{"name":"atr","bar":"1D"}]}
    ;
    const n = try parseRequests(gpa, ok_json, &backing, &reqs);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(Kind.rsi, reqs[0].kind);
    try testing.expectEqualStrings("4H", reqs[0].bar);
    try testing.expectEqual(@as(usize, 14), reqs[0].period);
    try testing.expectEqual(@as(usize, defaultPeriod(.atr)), reqs[1].period);

    // Not a tool request → caller falls through to proposal parsing.
    try testing.expectError(error.NotToolRequest, parseRequests(gpa, "{\"action\":\"HOLD\"}", &backing, &reqs));
    // Unknown indicator / bad bar / bad period rejected.
    try testing.expectError(error.BadRequest, parseRequests(gpa, "{\"tool_requests\":[{\"name\":\"macd\",\"bar\":\"1H\"}]}", &backing, &reqs));
    try testing.expectError(error.BadRequest, parseRequests(gpa, "{\"tool_requests\":[{\"name\":\"rsi\",\"bar\":\"3m\"}]}", &backing, &reqs));
    try testing.expectError(error.BadRequest, parseRequests(gpa, "{\"tool_requests\":[{\"name\":\"rsi\",\"bar\":\"1H\",\"period\":500}]}", &backing, &reqs));
    // Too many requests bounded.
    const many =
        \\{"tool_requests":[{"name":"rsi","bar":"1H"},{"name":"rsi","bar":"4H"},{"name":"rsi","bar":"1D"},{"name":"atr","bar":"1H"},{"name":"atr","bar":"4H"},{"name":"atr","bar":"1D"},{"name":"sma","bar":"1H"}]}
    ;
    try testing.expectError(error.TooManyRequests, parseRequests(gpa, many, &backing, &reqs));
}
