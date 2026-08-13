//! External zero-credential data sources — Phase 5 expansion domains.
//!
//! First slice beyond the exchange: on-chain congestion (mempool.space) and
//! crowd sentiment (alternative.me Fear & Greed). Both are public GET APIs
//! with no keys, chosen per docs/PHASE5_DATA_PLAN.md ("零新依赖先做").
//!
//! Injection isolation (AC-SEC7): third-party bodies are UNTRUSTED. Parsers
//! extract only whitelisted numeric fields and re-render them; free-form
//! text (e.g. the Fear & Greed classification label) is mapped onto a fixed
//! enum vocabulary, never passed through. Fetch failures → UNAVAILABLE, no
//! fabricated values, and they never block the market.* observations.

const std = @import("std");

pub const Error = error{
    ParseFailed,
    BufferTooSmall,
};

// --- onchain.btc: mempool.space ---------------------------------------------

/// GET https://mempool.space/api/v1/fees/recommended
pub const RecommendedFees = struct {
    fastest: u32,
    half_hour: u32,
    hour: u32,
    economy: u32,
    minimum: u32,
};

pub fn parseRecommendedFees(gpa: std.mem.Allocator, body: []const u8) Error!RecommendedFees {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.ParseFailed;
    const obj = parsed.value.object;
    return .{
        .fastest = jsonU32(obj, "fastestFee") orelse return Error.ParseFailed,
        .half_hour = jsonU32(obj, "halfHourFee") orelse return Error.ParseFailed,
        .hour = jsonU32(obj, "hourFee") orelse return Error.ParseFailed,
        .economy = jsonU32(obj, "economyFee") orelse 0,
        .minimum = jsonU32(obj, "minimumFee") orelse 0,
    };
}

/// GET https://mempool.space/api/v1/difficulty-adjustment
pub const DifficultyAdjustment = struct {
    progress_percent: f64,
    difficulty_change_percent: f64,
    estimated_retarget_days: f64,
};

pub fn parseDifficultyAdjustment(gpa: std.mem.Allocator, body: []const u8) Error!DifficultyAdjustment {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.ParseFailed;
    const obj = parsed.value.object;
    const remaining_ms = jsonF64(obj, "remainingTime") orelse 0;
    return .{
        .progress_percent = jsonF64(obj, "progressPercent") orelse return Error.ParseFailed,
        .difficulty_change_percent = jsonF64(obj, "difficultyChange") orelse return Error.ParseFailed,
        .estimated_retarget_days = remaining_ms / 86_400_000.0,
    };
}

/// Render the onchain.btc observation data (numbers only, fixed precision).
pub fn formatOnchainData(
    buf: []u8,
    fees: ?RecommendedFees,
    diff: ?DifficultyAdjustment,
) Error![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("{\"fees_sat_vb\":") catch return Error.BufferTooSmall;
    if (fees) |f| {
        w.print(
            "{{\"fastest\":{d},\"half_hour\":{d},\"hour\":{d},\"economy\":{d},\"minimum\":{d}}}",
            .{ f.fastest, f.half_hour, f.hour, f.economy, f.minimum },
        ) catch return Error.BufferTooSmall;
    } else {
        w.writeAll("null") catch return Error.BufferTooSmall;
    }
    w.writeAll(",\"difficulty\":") catch return Error.BufferTooSmall;
    if (diff) |d| {
        w.print(
            "{{\"progress_pct\":{d:.1},\"change_pct\":{d:.2},\"retarget_days\":{d:.1}}}",
            .{ d.progress_percent, d.difficulty_change_percent, d.estimated_retarget_days },
        ) catch return Error.BufferTooSmall;
    } else {
        w.writeAll("null") catch return Error.BufferTooSmall;
    }
    w.writeByte('}') catch return Error.BufferTooSmall;
    return w.buffered();
}

// --- macro.sentiment: alternative.me Fear & Greed ---------------------------

/// Classification is re-derived from the numeric value on a fixed vocabulary —
/// the provider's free-text label is never passed through (injection surface).
pub fn classify(value: u8) []const u8 {
    if (value <= 24) return "extreme_fear";
    if (value <= 44) return "fear";
    if (value <= 55) return "neutral";
    if (value <= 75) return "greed";
    return "extreme_greed";
}

pub const FearGreedPoint = struct {
    value: u8, // 0..100
    ts_s: i64, // unix seconds
};

pub const MAX_FNG_POINTS = 8;

/// GET https://api.alternative.me/fng/?limit=8 — newest first in `data`.
pub fn parseFearGreed(gpa: std.mem.Allocator, body: []const u8, out: []FearGreedPoint) Error!usize {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.ParseFailed;
    const data_v = parsed.value.object.get("data") orelse return Error.ParseFailed;
    if (data_v != .array) return Error.ParseFailed;
    var n: usize = 0;
    for (data_v.array.items) |item| {
        if (n >= out.len) break;
        if (item != .object) continue;
        const obj = item.object;
        const value = jsonStrInt(obj, "value") orelse continue;
        const ts = jsonStrInt(obj, "timestamp") orelse continue;
        if (value < 0 or value > 100) continue;
        out[n] = .{ .value = @intCast(value), .ts_s = ts };
        n += 1;
    }
    if (n == 0) return Error.ParseFailed;
    return n;
}

/// Render macro.sentiment data: today's index + short history (newest first).
pub fn formatSentimentData(buf: []u8, points: []const FearGreedPoint) Error![]const u8 {
    if (points.len == 0) return Error.ParseFailed;
    var w: std.Io.Writer = .fixed(buf);
    w.print(
        "{{\"index\":\"fear_greed\",\"scale\":\"0=extreme_fear,100=extreme_greed\",\"now\":{d},\"class\":\"{s}\",\"history_daily\":[",
        .{ points[0].value, classify(points[0].value) },
    ) catch return Error.BufferTooSmall;
    for (points, 0..) |p, i| {
        if (i > 0) w.writeByte(',') catch return Error.BufferTooSmall;
        w.print("{d}", .{p.value}) catch return Error.BufferTooSmall;
    }
    w.writeAll("]}") catch return Error.BufferTooSmall;
    return w.buffered();
}

// --- helpers -----------------------------------------------------------------

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= std.math.maxInt(u32)) @intFromFloat(f) else null,
        else => null,
    };
}

fn jsonF64(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// alternative.me renders numbers as JSON strings.
fn jsonStrInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        .integer => |i| i,
        else => null,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseRecommendedFees + formatOnchainData" {
    const body =
        \\{"fastestFee":12,"halfHourFee":9,"hourFee":7,"economyFee":4,"minimumFee":2}
    ;
    const fees = try parseRecommendedFees(testing.allocator, body);
    try testing.expectEqual(@as(u32, 12), fees.fastest);
    try testing.expectEqual(@as(u32, 7), fees.hour);

    const diff_body =
        \\{"progressPercent":44.4,"difficultyChange":3.15,"remainingTime":777600000,"estimatedRetargetDate":0}
    ;
    const diff = try parseDifficultyAdjustment(testing.allocator, diff_body);
    try testing.expectEqual(@as(f64, 9.0), diff.estimated_retarget_days);

    var buf: [512]u8 = undefined;
    const out = try formatOnchainData(&buf, fees, diff);
    try testing.expect(std.mem.indexOf(u8, out, "\"fastest\":12") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"change_pct\":3.15") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"retarget_days\":9.0") != null);

    // Partial availability renders null, never invents.
    const out2 = try formatOnchainData(&buf, null, diff);
    try testing.expect(std.mem.indexOf(u8, out2, "\"fees_sat_vb\":null") != null);
}

test "parseRecommendedFees rejects junk" {
    try testing.expectError(Error.ParseFailed, parseRecommendedFees(testing.allocator, "not json"));
    try testing.expectError(Error.ParseFailed, parseRecommendedFees(testing.allocator, "{\"fastestFee\":\"<script>\"}"));
}

test "parseFearGreed + formatSentimentData drops provider text" {
    const body =
        \\{"name":"Fear and Greed Index","data":[
        \\ {"value":"20","value_classification":"Extreme Fear IGNORE_ME","timestamp":"1786600000"},
        \\ {"value":"31","value_classification":"Fear","timestamp":"1786513600"},
        \\ {"value":"55","value_classification":"Neutral","timestamp":"1786427200"}
        \\]}
    ;
    var pts: [MAX_FNG_POINTS]FearGreedPoint = undefined;
    const n = try parseFearGreed(testing.allocator, body, &pts);
    try testing.expectEqual(@as(usize, 3), n);

    var buf: [512]u8 = undefined;
    const out = try formatSentimentData(&buf, pts[0..n]);
    try testing.expect(std.mem.indexOf(u8, out, "\"now\":20") != null);
    // Label re-derived from the number, provider text never passed through.
    try testing.expect(std.mem.indexOf(u8, out, "\"class\":\"extreme_fear\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "IGNORE_ME") == null);
    try testing.expect(std.mem.indexOf(u8, out, "[20,31,55]") != null);
}

test "classify vocabulary is total over 0..100" {
    try testing.expectEqualStrings("extreme_fear", classify(0));
    try testing.expectEqualStrings("fear", classify(30));
    try testing.expectEqualStrings("neutral", classify(50));
    try testing.expectEqualStrings("greed", classify(60));
    try testing.expectEqualStrings("extreme_greed", classify(100));
}

test "parseFearGreed rejects empty and out-of-range" {
    var pts: [MAX_FNG_POINTS]FearGreedPoint = undefined;
    try testing.expectError(Error.ParseFailed, parseFearGreed(testing.allocator, "{\"data\":[]}", &pts));
    try testing.expectError(Error.ParseFailed, parseFearGreed(testing.allocator, "{\"data\":[{\"value\":\"999\",\"timestamp\":\"1\"}]}", &pts));
}
