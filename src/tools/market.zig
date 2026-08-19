//! Market tool adapters — observation only (§4.4).
//! Build ToolResult envelopes from OKX public market data. Payloads are
//! untrusted data for the agent context; never instructions.

const std = @import("std");
const rest = @import("../exchange/okx/rest.zig");
const registry = @import("registry.zig");
const limits = @import("../security/limits.zig");
const Decimal = @import("../core/decimal.zig").Decimal;

pub fn formatTickerData(
    buf: []u8,
    instrument: []const u8,
    t: rest.Ticker,
) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"instrument\":\"{s}\",\"bid\":\"{f}\",\"ask\":\"{f}\",\"last\":\"{f}\",\"ts_ms\":{d}}}",
        .{ instrument, t.bid, t.ask, t.last, t.ts_ms },
    ) catch return error.BufferTooSmall;
}

pub fn formatCandlesData(
    buf: []u8,
    instrument: []const u8,
    candles: []const rest.Candle,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"instrument\":\"{s}\",\"bar\":\"1H\",\"candles\":[", .{instrument}) catch return error.BufferTooSmall;
    for (candles, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print(
            "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\"}}",
            .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol },
        ) catch return error.BufferTooSmall;
    }
    w.writeAll("]}") catch return error.BufferTooSmall;
    return w.buffered();
}

/// One timeframe of OHLCV bars for the multi-frame candles observation.
pub const CandleFrame = struct {
    bar: []const u8,
    candles: []const rest.Candle,
};

/// Multi-timeframe candles payload: `{"instrument":...,"frames":[{"bar":"1D",...},...]}`.
/// Frames are rendered in the order given; bars inside stay newest-first.
pub fn formatCandleFramesData(
    buf: []u8,
    instrument: []const u8,
    frames: []const CandleFrame,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"instrument\":\"{s}\",\"frames\":[", .{instrument}) catch return error.BufferTooSmall;
    for (frames, 0..) |f, fi| {
        if (fi > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print("{{\"bar\":\"{s}\",\"candles\":[", .{f.bar}) catch return error.BufferTooSmall;
        for (f.candles, 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
            w.print(
                "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\"}}",
                .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol },
            ) catch return error.BufferTooSmall;
        }
        w.writeAll("]}") catch return error.BufferTooSmall;
    }
    w.writeAll("]}") catch return error.BufferTooSmall;
    return w.buffered();
}

/// Compact newest-first rows for the agent: more bars, fewer tokens.
/// `structure_json` is a precomputed HTF object or null.
pub fn formatCandleFramesCompact(
    buf: []u8,
    instrument: []const u8,
    frames: []const CandleFrame,
    structure_json: ?[]const u8,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(
        "{{\"instrument\":\"{s}\",\"newest\":\"first\",\"layout\":[\"ts_ms\",\"o\",\"h\",\"l\",\"c\",\"vol\"],\"frames\":[",
        .{instrument},
    ) catch return error.BufferTooSmall;
    for (frames, 0..) |f, fi| {
        if (fi > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print("{{\"bar\":\"{s}\",\"n\":{d},\"rows\":[", .{ f.bar, f.candles.len }) catch return error.BufferTooSmall;
        for (f.candles, 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
            w.print(
                "[{d},\"{f}\",\"{f}\",\"{f}\",\"{f}\",\"{f}\"]",
                .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol },
            ) catch return error.BufferTooSmall;
        }
        w.writeAll("]}") catch return error.BufferTooSmall;
    }
    w.writeByte(']') catch return error.BufferTooSmall;
    if (structure_json) |st| {
        w.writeAll(",\"structure\":") catch return error.BufferTooSmall;
        w.writeAll(st) catch return error.BufferTooSmall;
    }
    w.writeByte('}') catch return error.BufferTooSmall;
    return w.buffered();
}

/// Optional positioning extras (all best-effort; null/empty when fetch failed).
pub const PositioningExtras = struct {
    long_short_ratio: ?Decimal = null,
    /// Long/short ratio ~4h before the latest sample (rubik 1H series).
    long_short_ratio_4h_ago: ?Decimal = null,
    /// Long/short ratio ~24h before the latest sample (rubik 1H series).
    long_short_ratio_24h_ago: ?Decimal = null,
    taker_buy_vol: ?Decimal = null,
    taker_sell_vol: ?Decimal = null,
    mark_px: ?Decimal = null,
    index_px: ?Decimal = null,
    basis_bps: ?Decimal = null,
    /// Recent realized funding settlements, newest first (empty when unavailable).
    funding_history: []const rest.FundingHist = &.{},
};

fn writeOptDec(w: *std.Io.Writer, key: []const u8, v: ?Decimal) error{BufferTooSmall}!void {
    if (v) |val| {
        w.print(",\"{s}\":\"{f}\"", .{ key, val }) catch return error.BufferTooSmall;
    } else {
        w.print(",\"{s}\":null", .{key}) catch return error.BufferTooSmall;
    }
}

/// Perp derivatives + positioning snapshot. Funding is required; other fields
/// may be null when their fetch failed (still a valid observation).
pub fn formatDerivativesData(
    buf: []u8,
    swap_instrument: []const u8,
    fr: rest.FundingRate,
    oi: ?rest.OpenInterest,
    extras: PositioningExtras,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(
        "{{\"instrument\":\"{s}\",\"funding_rate\":\"{f}\",\"next_funding_ms\":{d}",
        .{ swap_instrument, fr.funding_rate, fr.next_funding_ms },
    ) catch return error.BufferTooSmall;
    if (oi) |v| {
        w.print(
            ",\"oi_contracts\":\"{f}\",\"oi_ccy\":\"{f}\"",
            .{ v.oi_contracts, v.oi_ccy },
        ) catch return error.BufferTooSmall;
    } else {
        w.writeAll(",\"oi_contracts\":null,\"oi_ccy\":null") catch return error.BufferTooSmall;
    }
    try writeOptDec(&w, "long_short_ratio", extras.long_short_ratio);
    try writeOptDec(&w, "long_short_ratio_4h_ago", extras.long_short_ratio_4h_ago);
    try writeOptDec(&w, "long_short_ratio_24h_ago", extras.long_short_ratio_24h_ago);
    try writeOptDec(&w, "taker_buy_vol", extras.taker_buy_vol);
    try writeOptDec(&w, "taker_sell_vol", extras.taker_sell_vol);
    try writeOptDec(&w, "mark_px", extras.mark_px);
    try writeOptDec(&w, "index_px", extras.index_px);
    try writeOptDec(&w, "basis_bps", extras.basis_bps);
    w.writeAll(",\"funding_history\":[") catch return error.BufferTooSmall;
    for (extras.funding_history, 0..) |fh, i| {
        if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print(
            "{{\"ts_ms\":{d},\"rate\":\"{f}\"}}",
            .{ fh.funding_time_ms, fh.funding_rate },
        ) catch return error.BufferTooSmall;
    }
    w.writeByte(']') catch return error.BufferTooSmall;
    w.print(",\"ts_ms\":{d}}}", .{fr.ts_ms}) catch return error.BufferTooSmall;
    return w.buffered();
}

pub fn okResult(
    source: []const u8,
    as_of_ms: i64,
    latency_ms: u32,
    data_json: []const u8,
) registry.ToolResult {
    return .{
        .status = .ok,
        .source = source,
        .as_of_ms = as_of_ms,
        .latency_ms = latency_ms,
        .cost_usd = Decimal.zero,
        .data_json = data_json,
    };
}

pub fn errResult(source: []const u8, now_ms: i64, latency_ms: u32, reason: []const u8) registry.ToolResult {
    // reason is a short stable token (not free-form exchange dump)
    _ = reason;
    return .{
        .status = .err,
        .source = source,
        .as_of_ms = now_ms,
        .latency_ms = latency_ms,
        .data_json = "{\"error\":\"fetch_failed\"}",
    };
}

pub fn unavailableResult(source: []const u8, now_ms: i64) registry.ToolResult {
    return .{
        .status = .unavailable,
        .source = source,
        .as_of_ms = now_ms,
        .data_json = "null",
    };
}

/// Observation JSON line for agent context (status + digest + data).
/// data_json is untrusted (AC-SEC7): unless it passes the structural scan it
/// is replaced by null so it can never break out of the `data` field or
/// smuggle sibling keys into the context document.
pub fn formatObservation(
    buf: []u8,
    tool_name: []const u8,
    rec: registry.AuditRecord,
    data_json: []const u8,
) error{BufferTooSmall}![]const u8 {
    const safe_data = if (limits.jsonStructureSane(data_json, limits.max_json_depth))
        data_json
    else
        "null";
    return std.fmt.bufPrint(
        buf,
        "{{\"tool\":\"{s}\",\"status\":\"{s}\",\"source\":\"{s}\",\"as_of_ms\":{d},\"latency_ms\":{d},\"result_digest\":\"{s}\",\"data\":{s}}}",
        .{ tool_name, rec.status, rec.source, rec.as_of_ms, rec.latency_ms, &rec.result_digest, safe_data },
    ) catch return error.BufferTooSmall;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "formatTickerData is stable JSON" {
    var buf: [256]u8 = undefined;
    const s = try formatTickerData(&buf, "BTC-USDT", .{
        .ts_ms = 1000,
        .bid = d("1.5"),
        .ask = d("1.6"),
        .last = d("1.55"),
    });
    try testing.expect(std.mem.indexOf(u8, s, "\"instrument\":\"BTC-USDT\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"bid\":\"1.5\"") != null);
}

test "formatCandlesData joins rows" {
    var buf: [512]u8 = undefined;
    const candles = [_]rest.Candle{.{
        .ts_ms = 1,
        .open = d("1"),
        .high = d("2"),
        .low = d("0.5"),
        .close = d("1.5"),
        .vol = d("10"),
    }};
    const s = try formatCandlesData(&buf, "BTC-USDT", &candles);
    try testing.expect(std.mem.indexOf(u8, s, "\"candles\":[") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"vol\":\"10\"") != null);
}

test "formatCandleFramesData renders multiple timeframes" {
    var buf: [1024]u8 = undefined;
    const daily = [_]rest.Candle{.{
        .ts_ms = 86_400_000,
        .open = d("100"),
        .high = d("110"),
        .low = d("95"),
        .close = d("105"),
        .vol = d("1000"),
    }};
    const hourly = [_]rest.Candle{.{
        .ts_ms = 3_600_000,
        .open = d("104"),
        .high = d("106"),
        .low = d("103"),
        .close = d("105"),
        .vol = d("50"),
    }};
    const frames = [_]CandleFrame{
        .{ .bar = "1D", .candles = &daily },
        .{ .bar = "1H", .candles = &hourly },
    };
    const s = try formatCandleFramesData(&buf, "BTC-USDT", &frames);
    try testing.expect(std.mem.indexOf(u8, s, "\"frames\":[") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"bar\":\"1D\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"bar\":\"1H\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"vol\":\"1000\"") != null);
    // Empty frame set still yields valid JSON.
    var buf2: [128]u8 = undefined;
    const empty = try formatCandleFramesData(&buf2, "BTC-USDT", &.{});
    try testing.expect(std.mem.indexOf(u8, empty, "\"frames\":[]") != null);
}

test "formatCandleFramesCompact is array-encoded and can embed structure" {
    var buf: [512]u8 = undefined;
    const daily = [_]rest.Candle{.{
        .ts_ms = 86_400_000,
        .open = d("100"),
        .high = d("110"),
        .low = d("95"),
        .close = d("105"),
        .vol = d("1000"),
    }};
    const frames = [_]CandleFrame{.{ .bar = "1D", .candles = &daily }};
    const s = try formatCandleFramesCompact(&buf, "BTC-USDT", &frames, "{\"1D\":{\"broke_prior_high\":true}}");
    try testing.expect(std.mem.indexOf(u8, s, "\"layout\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[86400000,\"100\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"structure\":{\"1D\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"n\":1") != null);
}

test "formatDerivativesData with and without open interest" {
    var buf: [1024]u8 = undefined;
    const fr = rest.FundingRate{
        .funding_rate = d("0.0001"),
        .next_funding_ms = 1786291200000,
        .ts_ms = 1786264264482,
    };
    const hist = [_]rest.FundingHist{
        .{ .funding_rate = d("0.0001"), .funding_time_ms = 1786262400000 },
        .{ .funding_rate = d("-0.00005"), .funding_time_ms = 1786233600000 },
    };
    const full = try formatDerivativesData(&buf, "BTC-USDT-SWAP", fr, .{
        .oi_contracts = d("2895813.4"),
        .oi_ccy = d("28958.134"),
        .ts_ms = 1786264264482,
    }, .{
        .long_short_ratio = d("1.71"),
        .long_short_ratio_4h_ago = d("1.65"),
        .long_short_ratio_24h_ago = d("1.5"),
        .taker_buy_vol = d("100"),
        .taker_sell_vol = d("90"),
        .mark_px = d("64000"),
        .index_px = d("63990"),
        .basis_bps = d("1.56"),
        .funding_history = &hist,
    });
    try testing.expect(std.mem.indexOf(u8, full, "\"funding_rate\":\"0.0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"oi_contracts\":\"2895813.4\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"long_short_ratio\":\"1.71\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"long_short_ratio_4h_ago\":\"1.65\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"long_short_ratio_24h_ago\":\"1.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"basis_bps\":\"1.56\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"funding_history\":[{\"ts_ms\":1786262400000,\"rate\":\"0.0001\"}") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"rate\":\"-0.00005\"") != null);

    var buf2: [1024]u8 = undefined;
    const partial = try formatDerivativesData(&buf2, "BTC-USDT-SWAP", fr, null, .{});
    try testing.expect(std.mem.indexOf(u8, partial, "\"oi_contracts\":null") != null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"long_short_ratio\":null") != null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"long_short_ratio_4h_ago\":null") != null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"funding_history\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"next_funding_ms\":1786291200000") != null);
}
