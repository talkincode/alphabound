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
    w.print("{{\"instrument\":\"{s}\",\"bar\":\"1H\",\"ts_basis\":\"bar_open\",\"candles\":[", .{instrument}) catch return error.BufferTooSmall;
    for (candles, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print(
            "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\",\"confirmed\":{s}}}",
            .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol, confirmationJson(c) },
        ) catch return error.BufferTooSmall;
    }
    w.writeAll("]}") catch return error.BufferTooSmall;
    return w.buffered();
}

/// One timeframe of OHLCV bars for the multi-frame candles observation.
pub const CandleFrame = struct {
    bar: []const u8,
    candles: []const rest.Candle,
    /// Successful fetch completion time; 0 means unknown (never bar open).
    fetched_at_ms: i64 = 0,
};

/// Exchange interval duration. No UTC alignment is assumed: OKX daily bars
/// may open in the venue timezone. Progression uses adjacent opens instead.
pub fn barDurationMs(bar: []const u8) ?i64 {
    const names = [_][]const u8{ "1m", "5m", "15m", "30m", "1H", "4H", "1D" };
    const minutes = [_]i64{ 1, 5, 15, 30, 60, 240, 1440 };
    for (names, minutes) |name, mins| {
        if (std.mem.eql(u8, bar, name)) return mins * 60_000;
    }
    return null;
}

/// A short venue publication grace, not an extra bar of permitted lag.
pub const CANDLE_CLOSE_GRACE_MS: i64 = 60_000;

/// Validate fetch recency independently from candle progression. Re-fetching
/// an old/missing/future bar never makes it current. This cannot detect an
/// unchanged forming OHLC within its own interval (venue has no update time).
/// Unknown confirmation fails closed; callers must omit that frame AND any
/// structure/indicators derived from it rather than merely relabel the data.
pub fn candleFrameUsable(frame: CandleFrame, fetched_at_ms: i64, now_ms: i64, max_fetch_age_ms: i64) bool {
    if (!registry.timestampFresh(fetched_at_ms, now_ms, max_fetch_age_ms)) return false;
    const interval = barDurationMs(frame.bar) orelse return false;
    if (frame.candles.len == 0) return false;
    for (frame.candles, 0..) |c, i| {
        if (c.ts_ms <= 0 or c.ts_ms > fetched_at_ms) return false;
        const confirmed = candleConfirmed(c) orelse return false;
        // Guard arithmetic even for malformed exchange timestamps.
        const end = std.math.add(i64, c.ts_ms, interval) catch return false;
        if (confirmed and end > fetched_at_ms) return false;
        if (i > 0) {
            if (!confirmed or frame.candles[i - 1].ts_ms - c.ts_ms != interval) return false;
        } else {
            // Latest bar must still be forming or just have completed. Apply
            // at admission time too, so a slow multi-frame fetch cannot retain
            // a frame that has since missed its next expected opening.
            const deadline = std.math.add(i64, end, CANDLE_CLOSE_GRACE_MS) catch return false;
            if (now_ms > deadline) return false;
        }
    }
    return true;
}

/// Missing venue confirmation is unknown, never silently completed.
pub fn candleConfirmed(c: rest.Candle) ?bool {
    return c.confirmed;
}

fn confirmationJson(c: rest.Candle) []const u8 {
    const confirmed = candleConfirmed(c) orelse return "null";
    return if (confirmed) "true" else "false";
}

/// Snapshot sources have independent sample and fetch clocks. Appropriate
/// sample budgets differ (e.g. hourly positioning vs second-level quotes).
/// A recent fetch must never rejuvenate an old funding/OI/positioning sample.
pub fn snapshotUsable(sample_ms: i64, fetched_at_ms: i64, now_ms: i64, max_sample_age_ms: i64, max_fetch_age_ms: i64) bool {
    return registry.timestampFresh(fetched_at_ms, now_ms, max_fetch_age_ms) and
        registry.timestampFresh(sample_ms, fetched_at_ms, max_sample_age_ms) and
        registry.timestampFresh(sample_ms, now_ms, max_sample_age_ms);
}

/// Multi-timeframe candles payload: `{"instrument":...,"frames":[{"bar":"1D",...},...]}`.
/// Frames are rendered in the order given; bars inside stay newest-first.
pub fn formatCandleFramesData(
    buf: []u8,
    instrument: []const u8,
    frames: []const CandleFrame,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"instrument\":\"{s}\",\"ts_basis\":\"bar_open\",\"frames\":[", .{instrument}) catch return error.BufferTooSmall;
    for (frames, 0..) |f, fi| {
        if (fi > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print("{{\"bar\":\"{s}\",\"fetched_at_ms\":{d},\"candles\":[", .{ f.bar, f.fetched_at_ms }) catch return error.BufferTooSmall;
        for (f.candles, 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
            w.print(
                "{{\"ts_ms\":{d},\"o\":\"{f}\",\"h\":\"{f}\",\"l\":\"{f}\",\"c\":\"{f}\",\"vol\":\"{f}\",\"confirmed\":{s}}}",
                .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol, confirmationJson(c) },
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
    return formatCandleFramesCompactCoverage(buf, instrument, frames, structure_json, &.{});
}

/// Explicit coverage prevents partial intake from masquerading as a complete
/// five-frame snapshot. Missing/invalid frames have no rows or structure.
pub fn formatCandleFramesCompactCoverage(
    buf: []u8,
    instrument: []const u8,
    frames: []const CandleFrame,
    structure_json: ?[]const u8,
    expected_bars: []const []const u8,
) error{BufferTooSmall}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(
        "{{\"instrument\":\"{s}\",\"newest\":\"first\",\"ts_basis\":\"bar_open\",\"layout\":[\"ts_ms\",\"o\",\"h\",\"l\",\"c\",\"vol\",\"confirmed\"],\"frames\":[",
        .{instrument},
    ) catch return error.BufferTooSmall;
    for (frames, 0..) |f, fi| {
        if (fi > 0) w.writeByte(',') catch return error.BufferTooSmall;
        w.print("{{\"bar\":\"{s}\",\"n\":{d},\"fetched_at_ms\":{d},\"rows\":[", .{ f.bar, f.candles.len, f.fetched_at_ms }) catch return error.BufferTooSmall;
        for (f.candles, 0..) |c, i| {
            if (i > 0) w.writeByte(',') catch return error.BufferTooSmall;
            w.print(
                "[{d},\"{f}\",\"{f}\",\"{f}\",\"{f}\",\"{f}\",{s}]",
                .{ c.ts_ms, c.open, c.high, c.low, c.close, c.vol, confirmationJson(c) },
            ) catch return error.BufferTooSmall;
        }
        w.writeAll("]}") catch return error.BufferTooSmall;
    }
    w.writeAll("],\"missing_frames\":[") catch return error.BufferTooSmall;
    var missing_n: usize = 0;
    for (expected_bars) |expected| {
        var found = false;
        for (frames) |frame| {
            if (std.mem.eql(u8, frame.bar, expected)) found = true;
        }
        if (!found) {
            if (missing_n > 0) w.writeByte(',') catch return error.BufferTooSmall;
            w.print("\"{s}\"", .{expected}) catch return error.BufferTooSmall;
            missing_n += 1;
        }
    }
    w.print("],\"coverage_known\":{},\"complete\":{}", .{ expected_bars.len > 0, expected_bars.len > 0 and missing_n == 0 }) catch return error.BufferTooSmall;
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
    long_short_ratio_ts_ms: ?i64 = null,
    long_short_ratio_4h_ago_ts_ms: ?i64 = null,
    long_short_ratio_24h_ago_ts_ms: ?i64 = null,
    taker_ts_ms: ?i64 = null,
    mark_ts_ms: ?i64 = null,
    index_ts_ms: ?i64 = null,
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

/// Revalidate all positioning sources at the common rendering time. Fetching
/// a later endpoint must not renew an earlier endpoint's sample timestamp.
pub fn discardStalePositioning(oi: *?rest.OpenInterest, extras: *PositioningExtras, now_ms: i64, fast_age_ms: i64) void {
    if (oi.*) |v| {
        if (!registry.timestampFresh(v.ts_ms, now_ms, fast_age_ms)) oi.* = null;
    }
    const hourly_age_ms = 3_600_000 + 120_000;
    if (!registry.timestampFresh(extras.long_short_ratio_ts_ms orelse 0, now_ms, hourly_age_ms)) {
        extras.long_short_ratio = null;
        extras.long_short_ratio_4h_ago = null;
        extras.long_short_ratio_24h_ago = null;
    }
    if (!registry.timestampFresh(extras.taker_ts_ms orelse 0, now_ms, hourly_age_ms)) {
        extras.taker_buy_vol = null;
        extras.taker_sell_vol = null;
    }
    if (!registry.timestampFresh(extras.mark_ts_ms orelse 0, now_ms, fast_age_ms)) extras.mark_px = null;
    if (!registry.timestampFresh(extras.index_ts_ms orelse 0, now_ms, fast_age_ms)) extras.index_px = null;
    extras.basis_bps = if (extras.mark_px != null and extras.index_px != null)
        rest.basisBps(extras.mark_px.?, extras.index_px.?)
    else
        null;
}

fn writeOptDec(w: *std.Io.Writer, key: []const u8, v: ?Decimal) error{BufferTooSmall}!void {
    if (v) |val| {
        w.print(",\"{s}\":\"{f}\"", .{ key, val }) catch return error.BufferTooSmall;
    } else {
        w.print(",\"{s}\":null", .{key}) catch return error.BufferTooSmall;
    }
}

fn writeOptTs(w: *std.Io.Writer, key: []const u8, ts: ?i64) error{BufferTooSmall}!void {
    if (ts) |value| {
        w.print(",\"{s}\":{d}", .{ key, value }) catch return error.BufferTooSmall;
    } else {
        w.print(",\"{s}\":null", .{key}) catch return error.BufferTooSmall;
    }
}

/// Perp derivatives + positioning snapshot. Caller must validate each source
/// independently with snapshotUsable and its cadence-specific sample budget.
/// Failed/stale extras stay null; their ages are never reset by funding/fetch.
/// Funding history is explicitly historical, not a current snapshot.
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
            ",\"oi_contracts\":\"{f}\",\"oi_ccy\":\"{f}\",\"oi_ts_ms\":{d}",
            .{ v.oi_contracts, v.oi_ccy, v.ts_ms },
        ) catch return error.BufferTooSmall;
    } else {
        w.writeAll(",\"oi_contracts\":null,\"oi_ccy\":null,\"oi_ts_ms\":null") catch return error.BufferTooSmall;
    }
    try writeOptDec(&w, "long_short_ratio", extras.long_short_ratio);
    try writeOptDec(&w, "long_short_ratio_4h_ago", extras.long_short_ratio_4h_ago);
    try writeOptDec(&w, "long_short_ratio_24h_ago", extras.long_short_ratio_24h_ago);
    try writeOptDec(&w, "taker_buy_vol", extras.taker_buy_vol);
    try writeOptDec(&w, "taker_sell_vol", extras.taker_sell_vol);
    try writeOptDec(&w, "mark_px", extras.mark_px);
    try writeOptDec(&w, "index_px", extras.index_px);
    try writeOptDec(&w, "basis_bps", extras.basis_bps);
    try writeOptTs(&w, "long_short_ratio_ts_ms", extras.long_short_ratio_ts_ms);
    try writeOptTs(&w, "long_short_ratio_4h_ago_ts_ms", extras.long_short_ratio_4h_ago_ts_ms);
    try writeOptTs(&w, "long_short_ratio_24h_ago_ts_ms", extras.long_short_ratio_24h_ago_ts_ms);
    try writeOptTs(&w, "taker_ts_ms", extras.taker_ts_ms);
    try writeOptTs(&w, "mark_ts_ms", extras.mark_ts_ms);
    try writeOptTs(&w, "index_ts_ms", extras.index_ts_ms);
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
    const safe_data = if (std.mem.eql(u8, rec.status, registry.ResultStatus.ok.text()) and
        limits.jsonStructureSane(data_json, limits.max_json_depth))
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

test "positioning sources expire independently at final render time" {
    const now: i64 = 40_000_000;
    var oi: ?rest.OpenInterest = .{ .oi_contracts = d("10"), .oi_ccy = d("1"), .ts_ms = now - 60_001 };
    var extras = PositioningExtras{
        .long_short_ratio = d("1"),
        .long_short_ratio_ts_ms = now - 3_600_000,
        .taker_buy_vol = d("10"),
        .taker_sell_vol = d("9"),
        .taker_ts_ms = now - 3_600_000,
        .mark_px = d("100"),
        .mark_ts_ms = now - 60_001,
        .index_px = d("99"),
        .index_ts_ms = now,
        .basis_bps = d("1"),
    };
    discardStalePositioning(&oi, &extras, now, 60_000);
    try testing.expect(oi == null);
    try testing.expect(extras.long_short_ratio != null);
    try testing.expect(extras.taker_buy_vol != null);
    try testing.expect(extras.mark_px == null and extras.basis_bps == null);
    try testing.expect(extras.index_px != null);
    discardStalePositioning(&oi, &extras, now + 120_001, 60_000);
    try testing.expect(extras.long_short_ratio == null and extras.taker_buy_vol == null);
    try testing.expect(extras.index_px == null);
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

fn testCandle(ts_ms: i64, confirmed: ?bool) rest.Candle {
    return .{ .ts_ms = ts_ms, .confirmed = confirmed, .open = d("100"), .high = d("101"), .low = d("99"), .close = d("100"), .vol = d("1") };
}

test "fresh candles use fetch recency and per-frame progression not bar-open age" {
    const open: i64 = 1_700_000_000_000; // deliberately not UTC-aligned
    for ([_][]const u8{ "1D", "4H", "1H", "30m", "15m", "5m", "1m" }) |bar| {
        const interval = barDurationMs(bar).?;
        const now = open + @divTrunc(interval, 2);
        const candles = [_]rest.Candle{ testCandle(open, false), testCandle(open - interval, true) };
        const frame = CandleFrame{ .bar = bar, .candles = &candles };
        try testing.expect(candleFrameUsable(frame, now, now, 120_000));
        try testing.expect(!candleFrameUsable(frame, now - 120_001, now, 120_000));
        try testing.expect(!candleFrameUsable(frame, now + 1, now, 120_000));
        try testing.expect(!candleFrameUsable(frame, 0, now, 120_000));
        // Fetching this same frozen series in the following interval is not
        // fresh just because HTTP succeeded recently.
        const late = open + interval + CANDLE_CLOSE_GRACE_MS + 1;
        try testing.expect(!candleFrameUsable(frame, late, late, 120_000));
    }
}

test "candle progression rejects missing future malformed and unknown bars" {
    const open: i64 = 1_700_000_000_000;
    const interval = barDurationMs("4H").?;
    const now = open + 100_000;
    var candles = [_]rest.Candle{ testCandle(open, false), testCandle(open - interval, true) };
    var frame = CandleFrame{ .bar = "4H", .candles = &candles };
    try testing.expect(candleFrameUsable(frame, now, now, 120_000));
    candles[1].ts_ms -= interval;
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[1].ts_ms = open; // duplicate
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[1] = testCandle(open - interval, false);
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[1].confirmed = null;
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[1].confirmed = true;
    candles[0].ts_ms = now + 1;
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[0] = testCandle(open, true); // premature completion
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    candles[0].confirmed = null;
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    frame.bar = "unsupported";
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
    frame = .{ .bar = "4H", .candles = &.{} };
    try testing.expect(!candleFrameUsable(frame, now, now, 120_000));
}

test "completed-only newest bar permits publication grace not a whole missing interval" {
    const open: i64 = 1_700_000_000_000;
    const interval = barDurationMs("1D").?;
    const candles = [_]rest.Candle{testCandle(open, true)};
    const frame = CandleFrame{ .bar = "1D", .candles = &candles };
    const boundary = open + interval;
    try testing.expect(candleFrameUsable(frame, boundary, boundary, 120_000));
    try testing.expect(candleFrameUsable(frame, boundary, boundary + CANDLE_CLOSE_GRACE_MS, 120_000));
    try testing.expect(!candleFrameUsable(frame, boundary, boundary + CANDLE_CLOSE_GRACE_MS + 1, 120_000));
}

test "sample and fetch clocks cannot rejuvenate stale derivatives" {
    const now: i64 = 1_700_000_000_000;
    try testing.expect(snapshotUsable(now - 5_000, now, now, 60_000, 120_000));
    try testing.expect(!snapshotUsable(now - 300_000, now, now, 60_000, 120_000));
    // Hourly positioning has a different cadence from current OI/quotes.
    try testing.expect(snapshotUsable(now - 3_600_000, now, now, 4_500_000, 120_000));
    try testing.expect(!snapshotUsable(now - 3_600_000, now, now, 60_000, 120_000));
    try testing.expect(!snapshotUsable(now - 5_000, now - 121_000, now, 300_000, 120_000));
    try testing.expect(!snapshotUsable(now + 1, now, now, 60_000, 120_000));
    try testing.expect(!snapshotUsable(0, now, now, 60_000, 120_000));
}

test "unusable or unknown observation statuses cannot leak actionable data" {
    var buf: [1024]u8 = undefined;
    const payload = "{\"last\":\"98765\"}";
    var rec = registry.auditRecord(&.{ .name = "market.ticker", .domain = .market, .source = "test", .max_age_ms = 60_000 }, okResult("test", 1_000_000, 0, payload), 1_000_000);
    for ([_][]const u8{ "STALE", "UNAVAILABLE", "ERROR", "unknown", "ok", "" }) |status| {
        rec.status = status;
        const text = try formatObservation(&buf, "market.ticker", rec, payload);
        try testing.expect(std.mem.indexOf(u8, text, "98765") == null);
        try testing.expect(std.mem.indexOf(u8, text, "\"data\":null") != null);
    }
    rec.status = "OK";
    const text = try formatObservation(&buf, "market.ticker", rec, payload);
    try testing.expect(std.mem.indexOf(u8, text, payload) != null);
}

test "compact candle coverage exposes missing frames and confirmation layout" {
    var buf: [2048]u8 = undefined;
    const candles = [_]rest.Candle{testCandle(1_700_000_000_000, false)};
    const text = try formatCandleFramesCompactCoverage(&buf, "SYNTH-USDT", &.{.{ .bar = "4H", .candles = &candles, .fetched_at_ms = 1_700_000_050_000 }}, null, &.{ "1D", "4H" });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expect(root.get("coverage_known").?.bool);
    try testing.expect(!root.get("complete").?.bool);
    try testing.expectEqualStrings("1D", root.get("missing_frames").?.array.items[0].string);
    try testing.expectEqualStrings("bar_open", root.get("ts_basis").?.string);
    try testing.expectEqualStrings("confirmed", root.get("layout").?.array.items[6].string);
    const frame = root.get("frames").?.array.items[0].object;
    try testing.expectEqual(@as(i64, 1_700_000_050_000), frame.get("fetched_at_ms").?.integer);
    try testing.expect(!frame.get("rows").?.array.items[0].array.items[6].bool);
}
