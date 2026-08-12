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

/// Perp derivatives snapshot (funding + open interest). `oi` may be null when
/// the open-interest fetch failed; funding alone is still a valid observation.
pub fn formatDerivativesData(
    buf: []u8,
    swap_instrument: []const u8,
    fr: rest.FundingRate,
    oi: ?rest.OpenInterest,
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

test "formatDerivativesData with and without open interest" {
    var buf: [512]u8 = undefined;
    const fr = rest.FundingRate{
        .funding_rate = d("0.0001"),
        .next_funding_ms = 1786291200000,
        .ts_ms = 1786264264482,
    };
    const full = try formatDerivativesData(&buf, "BTC-USDT-SWAP", fr, .{
        .oi_contracts = d("2895813.4"),
        .oi_ccy = d("28958.134"),
        .ts_ms = 1786264264482,
    });
    try testing.expect(std.mem.indexOf(u8, full, "\"funding_rate\":\"0.0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, full, "\"oi_contracts\":\"2895813.4\"") != null);

    var buf2: [512]u8 = undefined;
    const partial = try formatDerivativesData(&buf2, "BTC-USDT-SWAP", fr, null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"oi_contracts\":null") != null);
    try testing.expect(std.mem.indexOf(u8, partial, "\"next_funding_ms\":1786291200000") != null);
}
