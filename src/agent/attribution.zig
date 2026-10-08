//! Timing attribution — what the agent's own weight changes earned.
//!
//! A window's price-only book return is split into what the window's average
//! BTC weight would have earned if held constant (`static_return`) and the
//! remainder produced by changing the weight inside the window
//! (`timing_return`). Positive timing means exposure tended to be higher
//! before rises and lower before falls; negative means the changes cost money
//! relative to simply holding the average.
//!
//! Self-review facts only. Floats are acceptable here because nothing in this
//! module sizes, admits or executes an order (those paths stay on Decimal).
//! Fees, slippage and external capital flows are excluded by construction:
//! returns are compounded from marked prices and the weight held over each
//! interval, never from equity steps.

const std = @import("std");

/// One hourly mark, oldest first.
pub const Point = struct {
    ts_ms: i64,
    price: f64,
    /// BTC notional / equity at the mark.
    btc_weight: f64,
};

/// Below this many usable marks a window is reported as unavailable: a few
/// hours of weight path say nothing about timing.
pub const MIN_POINTS: usize = 12;

pub const Window = struct {
    span_ms: i64,
    points: usize,
    btc_return: f64,
    /// Time-weighted mean of the weight held over each interval.
    avg_btc_weight: f64,
    min_btc_weight: f64,
    max_btc_weight: f64,
    /// Compounded price-only return of the actual weight path.
    book_return: f64,
    /// Same intervals at `avg_btc_weight` held constant.
    static_return: f64,
    /// book_return − static_return.
    timing_return: f64,
};

fn usable(p: Point) bool {
    return std.math.isFinite(p.price) and p.price > 0 and
        std.math.isFinite(p.btc_weight) and p.btc_weight >= 0;
}

/// Attribution over `points` (oldest first). Unusable marks are skipped, not
/// interpolated. Returns null when fewer than `MIN_POINTS` remain or time
/// does not advance.
pub fn compute(points: []const Point) ?Window {
    var prev: ?Point = null;
    var first: ?Point = null;
    var n: usize = 0;
    var total_ms: f64 = 0;
    var weighted: f64 = 0;
    var min_w: f64 = std.math.inf(f64);
    var max_w: f64 = -std.math.inf(f64);
    for (points) |p| {
        if (!usable(p)) continue;
        n += 1;
        min_w = @min(min_w, p.btc_weight);
        max_w = @max(max_w, p.btc_weight);
        if (prev) |q| {
            if (p.ts_ms <= q.ts_ms) continue;
            const dt: f64 = @floatFromInt(p.ts_ms - q.ts_ms);
            total_ms += dt;
            weighted += q.btc_weight * dt;
        } else first = p;
        prev = p;
    }
    if (n < MIN_POINTS or total_ms <= 0) return null;
    const avg = weighted / total_ms;

    var book: f64 = 1;
    var static: f64 = 1;
    prev = null;
    for (points) |p| {
        if (!usable(p)) continue;
        if (prev) |q| {
            if (p.ts_ms <= q.ts_ms) continue;
            const r = p.price / q.price - 1.0;
            book *= 1.0 + q.btc_weight * r;
            static *= 1.0 + avg * r;
        }
        prev = p;
    }
    const f = first.?;
    const l = prev.?;
    return .{
        .span_ms = l.ts_ms - f.ts_ms,
        .points = n,
        .btc_return = l.price / f.price - 1.0,
        .avg_btc_weight = avg,
        .min_btc_weight = min_w,
        .max_btc_weight = max_w,
        .book_return = book - 1.0,
        .static_return = static - 1.0,
        .timing_return = book - static,
    };
}

/// A labelled window for the decision context.
pub const Labelled = struct {
    label: []const u8,
    /// The evidence cohort started inside the requested window, so `span`
    /// is shorter than the label.
    clipped: bool,
    window: ?Window,
};

/// Deterministic JSON: `{"label":"7d","clipped":false,"span_hours":168.0,...}`
/// or `{"label":"7d","clipped":true,"available":false}`.
pub fn writeJson(w: *std.Io.Writer, item: Labelled) std.Io.Writer.Error!void {
    try w.print("{{\"label\":\"{s}\",\"clipped\":{}", .{ item.label, item.clipped });
    const win = item.window orelse {
        try w.writeAll(",\"available\":false}");
        return;
    };
    const span_h = @as(f64, @floatFromInt(win.span_ms)) / 3_600_000.0;
    try w.print(
        ",\"available\":true,\"span_hours\":{d:.1},\"marks\":{d},\"btc_return\":{d:.4},\"avg_btc_weight\":{d:.3},\"min_btc_weight\":{d:.3},\"max_btc_weight\":{d:.3},\"book_return\":{d:.4},\"static_return\":{d:.4},\"timing_return\":{d:.4}}}",
        .{ span_h, win.points, win.btc_return, win.avg_btc_weight, win.min_btc_weight, win.max_btc_weight, win.book_return, win.static_return, win.timing_return },
    );
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn hourly(prices: []const f64, weights: []const f64, out: []Point) []Point {
    for (prices, weights, 0..) |px, wt, i| out[i] = .{ .ts_ms = @as(i64, @intCast(i)) * 3_600_000, .price = px, .btc_weight = wt };
    return out[0..prices.len];
}

test "constant weight has zero timing and tracks weight times market" {
    var prices: [24]f64 = undefined;
    var weights: [24]f64 = undefined;
    for (0..24) |i| {
        prices[i] = 100.0 + @as(f64, @floatFromInt(i));
        weights[i] = 0.5;
    }
    var buf: [24]Point = undefined;
    const win = compute(hourly(&prices, &weights, &buf)).?;
    try testing.expectApproxEqAbs(@as(f64, 0.5), win.avg_btc_weight, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), win.timing_return, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.23), win.btc_return, 1e-12);
    try testing.expect(win.book_return > 0 and win.book_return < win.btc_return);
}

test "buying after a rise and selling after a fall is negative timing" {
    // Range: 100 → 110 → 100 → 110. The book adds at the top and cuts at the
    // bottom of each swing, as the production whipsaw did.
    const prices = [_]f64{ 100, 105, 110, 110, 105, 100, 100, 105, 110, 110, 105, 100, 100 };
    const weights = [_]f64{ 0.2, 0.2, 0.6, 0.6, 0.6, 0.2, 0.2, 0.2, 0.6, 0.6, 0.6, 0.2, 0.2 };
    var buf: [prices.len]Point = undefined;
    const win = compute(hourly(&prices, &weights, &buf)).?;
    try testing.expect(win.timing_return < 0);
    try testing.expectApproxEqAbs(@as(f64, 0.2), win.min_btc_weight, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.6), win.max_btc_weight, 1e-12);

    // Mirror: heavy before rises, light before falls.
    const good = [_]f64{ 0.6, 0.6, 0.2, 0.2, 0.2, 0.6, 0.6, 0.6, 0.2, 0.2, 0.2, 0.6, 0.6 };
    var buf2: [prices.len]Point = undefined;
    try testing.expect(compute(hourly(&prices, &good, &buf2)).?.timing_return > 0);
}

test "too few or unusable marks are unavailable, never fabricated" {
    const prices = [_]f64{ 100, 101, 102 };
    const weights = [_]f64{ 0.5, 0.5, 0.5 };
    var buf: [3]Point = undefined;
    try testing.expect(compute(hourly(&prices, &weights, &buf)) == null);

    var many: [MIN_POINTS + 2]Point = undefined;
    for (&many, 0..) |*p, i| p.* = .{ .ts_ms = @as(i64, @intCast(i)) * 3_600_000, .price = 0, .btc_weight = 0.5 };
    try testing.expect(compute(&many) == null);
    many[0].price = std.math.nan(f64);
    try testing.expect(compute(&many) == null);
}

test "writeJson renders available and unavailable windows deterministically" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeJson(&w, .{ .label = "30d", .clipped = true, .window = null });
    try testing.expectEqualStrings("{\"label\":\"30d\",\"clipped\":true,\"available\":false}", w.buffered());

    var prices: [MIN_POINTS]f64 = undefined;
    var weights: [MIN_POINTS]f64 = undefined;
    for (0..MIN_POINTS) |i| {
        prices[i] = 100;
        weights[i] = 0.25;
    }
    var pts: [MIN_POINTS]Point = undefined;
    var w2: std.Io.Writer = .fixed(&buf);
    try writeJson(&w2, .{ .label = "7d", .clipped = false, .window = compute(hourly(&prices, &weights, &pts)) });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, w2.buffered(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expect(o.get("available").?.bool);
    try testing.expectApproxEqAbs(@as(f64, 11.0), o.get("span_hours").?.float, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.25), o.get("avg_btc_weight").?.float, 1e-9);
}
