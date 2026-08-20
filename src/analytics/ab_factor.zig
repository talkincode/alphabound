//! AB 因子（实验性复盘因子）— pure analytics over the 1m equity trail.
//!
//! Research-only: the factor and its component z-scores exist to be *observed*
//! on the 复盘 tab (指标↔因子↔未来收益 correlation), never to trade. Floats are
//! deliberate here and only here — they feed z-scores and Pearson correlations,
//! not order sizing, admission or risk gates (those stay on `Decimal`).
//!
//! Hard boundary: this module must never be imported from `src/agent`,
//! `src/risk` or `src/execution`. Promoting the factor into the decision path
//! requires an explicit design change, not an import.
//!
//! v1 composition (equal weight, oriented z-scores):
//!   +pos   BTC 仓位占比        btc_value / equity
//!   +ret   净值滚动收益        equity[t] / equity[t-30m] - 1
//!   +alpha 超额净值            equity / bh_equity - 1     (migration-0006 marks)
//!   -dd    回撤                drawdown column
//!   -vol   已实现波动          std of 1m log bid returns over 30m (marks)
//!   +mom   BTC 动量            bid[t] / bid[t-30m] - 1    (marks)
//! Orientations are arbitrary research priors; revisit with IC evidence and
//! bump `factor_version` before changing weights or components.

const std = @import("std");
const storage = @import("../storage/db.zig");

pub const factor_version = "v1";

pub const component_count = 6;
pub const component_keys = [component_count][]const u8{ "pos", "ret", "alpha", "dd", "vol", "mom" };
pub const component_signs = [component_count]f64{ 1, 1, 1, -1, -1, 1 };

pub const idx_pos = 0;
pub const idx_ret = 1;
pub const idx_alpha = 2;
pub const idx_dd = 3;
pub const idx_vol = 4;
pub const idx_mom = 5;

/// 48h of 1m samples. Series buffers are sized for this; callers pass at most
/// this many points (extra points are ignored from the front, keeping newest).
pub const max_points = 2880;
/// Output downsample step (indices ≈ minutes). Keeps the JSON blob bounded.
pub const out_step = 5;

pub const Params = struct {
    ret_window_min: i64 = 30,
    vol_window_min: i64 = 30,
    mom_window_min: i64 = 30,
    /// A lookback window is void when the nearest sample is older than
    /// gap_factor × window (process downtime); components report NaN instead
    /// of pretending the trail was continuous.
    gap_factor: i64 = 2,
    /// Minimum 1m log-returns inside the vol window.
    min_vol_returns: usize = 10,
    /// Minimum finite component z-scores required to emit an AB value.
    min_ab_components: usize = 3,
    /// Minimum paired samples for a reportable IC.
    min_ic_samples: usize = 30,
};

pub const Series = struct {
    n: usize = 0,
    ts_sec: [max_points]i64 = undefined,
    /// Raw component values; NaN = not computable at that sample.
    comp: [component_count][max_points]f64 = undefined,
    /// Full-window z-scores of `comp` (NaN when the series is degenerate).
    z: [component_count][max_points]f64 = undefined,
    /// Equal-weight oriented mean of available z-scores; NaN when < min components.
    ab: [max_points]f64 = undefined,
};

pub const IcEntry = struct { r: f64, n: usize };

pub const IcRow = struct {
    horizon_min: i64,
    comp: [component_count]IcEntry,
    ab: IcEntry,
};

const nan = std.math.nan(f64);

fn isNum(v: f64) bool {
    return std.math.isFinite(v);
}

/// Largest j < i with ts[j] <= ts[i] - window_ms, rejected when the nearest
/// candidate is older than gap_factor × window (data gap).
fn lookbackIndex(pts: []const storage.EquityPoint, i: usize, window_ms: i64, gap_factor: i64) ?usize {
    const cutoff = pts[i].ts_ms - window_ms;
    var lo: usize = 0;
    var hi: usize = i; // search in [0, i)
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pts[mid].ts_ms <= cutoff) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null; // nothing at/before cutoff
    const j = lo - 1;
    if (pts[i].ts_ms - pts[j].ts_ms > window_ms * gap_factor) return null;
    return j;
}

/// Smallest k > i with ts[k] >= ts[i] + horizon_ms, rejected when it lands
/// far beyond the horizon (gap): tolerance is horizon/2.
fn forwardIndex(pts: []const storage.EquityPoint, i: usize, horizon_ms: i64) ?usize {
    const target = pts[i].ts_ms + horizon_ms;
    var lo: usize = i + 1;
    var hi: usize = pts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pts[mid].ts_ms < target) lo = mid + 1 else hi = mid;
    }
    if (lo >= pts.len) return null;
    if (pts[lo].ts_ms - target > @divTrunc(horizon_ms, 2)) return null;
    return lo;
}

/// Population mean/std z-score over the finite entries of `vals[0..n]`.
/// Degenerate series (fewer than 8 samples or ~zero variance) yield all-NaN.
fn zscore(vals: []const f64, out: []f64) void {
    var sum: f64 = 0;
    var count: usize = 0;
    for (vals) |v| {
        if (isNum(v)) {
            sum += v;
            count += 1;
        }
    }
    if (count < 8) {
        for (out) |*o| o.* = nan;
        return;
    }
    const mean = sum / @as(f64, @floatFromInt(count));
    var ss: f64 = 0;
    for (vals) |v| {
        if (isNum(v)) {
            const d = v - mean;
            ss += d * d;
        }
    }
    const sd = @sqrt(ss / @as(f64, @floatFromInt(count)));
    if (sd < 1e-12) {
        for (out) |*o| o.* = nan;
        return;
    }
    for (vals, out) |v, *o| {
        o.* = if (isNum(v)) (v - mean) / sd else nan;
    }
}

/// Pearson correlation over pairs where both values are finite.
pub fn pearson(xs: []const f64, ys: []const f64) IcEntry {
    std.debug.assert(xs.len == ys.len);
    var n: usize = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (xs, ys) |x, y| {
        if (isNum(x) and isNum(y)) {
            n += 1;
            sx += x;
            sy += y;
        }
    }
    if (n < 2) return .{ .r = nan, .n = n };
    const fnum = @as(f64, @floatFromInt(n));
    const mx = sx / fnum;
    const my = sy / fnum;
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (xs, ys) |x, y| {
        if (isNum(x) and isNum(y)) {
            const dx = x - mx;
            const dy = y - my;
            sxy += dx * dy;
            sxx += dx * dx;
            syy += dy * dy;
        }
    }
    if (sxx < 1e-18 or syy < 1e-18) return .{ .r = nan, .n = n };
    return .{ .r = sxy / @sqrt(sxx * syy), .n = n };
}

/// Compute component values, z-scores and the AB factor for a 1m ascending
/// equity trail. Rows with `marks_ok = false` (pre-migration-0006) yield NaN
/// for the marks-dependent components — never a guessed price.
pub fn compute(points_in: []const storage.EquityPoint, params: Params, out: *Series) void {
    const pts = if (points_in.len > max_points)
        points_in[points_in.len - max_points ..]
    else
        points_in;
    const n = pts.len;
    out.n = n;
    if (n == 0) return;

    for (pts, 0..) |p, i| out.ts_sec[i] = @divTrunc(p.ts_ms, 1000);

    const ret_ms = params.ret_window_min * std.time.ms_per_min;
    const vol_ms = params.vol_window_min * std.time.ms_per_min;
    const mom_ms = params.mom_window_min * std.time.ms_per_min;

    for (pts, 0..) |p, i| {
        // pos: BTC 仓位占比
        out.comp[idx_pos][i] = if (p.equity > 1e-9) p.btc_value / p.equity else nan;
        // dd: drawdown column as-is
        out.comp[idx_dd][i] = p.drawdown;
        // alpha: vs buy-and-hold marks
        out.comp[idx_alpha][i] = if (p.marks_ok and p.bh_equity > 1e-9)
            p.equity / p.bh_equity - 1
        else
            nan;
        // ret: rolling equity return
        out.comp[idx_ret][i] = blk: {
            const j = lookbackIndex(pts, i, ret_ms, params.gap_factor) orelse break :blk nan;
            if (pts[j].equity <= 1e-9) break :blk nan;
            break :blk p.equity / pts[j].equity - 1;
        };
        // mom: BTC price momentum
        out.comp[idx_mom][i] = blk: {
            const j = lookbackIndex(pts, i, mom_ms, params.gap_factor) orelse break :blk nan;
            if (!p.marks_ok or !pts[j].marks_ok or pts[j].bid_price <= 1e-9) break :blk nan;
            break :blk p.bid_price / pts[j].bid_price - 1;
        };
        // vol: realized vol of 1m log bid returns inside the window
        out.comp[idx_vol][i] = blk: {
            const j0 = lookbackIndex(pts, i, vol_ms, params.gap_factor) orelse break :blk nan;
            var rets: [64]f64 = undefined;
            var m: usize = 0;
            var j = j0;
            while (j < i and m < rets.len) : (j += 1) {
                const a = pts[j];
                const b = pts[j + 1];
                if (!a.marks_ok or !b.marks_ok) continue;
                if (a.bid_price <= 1e-9 or b.bid_price <= 1e-9) continue;
                if (b.ts_ms - a.ts_ms > 3 * std.time.ms_per_min) continue;
                rets[m] = @log(b.bid_price / a.bid_price);
                m += 1;
            }
            if (m < params.min_vol_returns) break :blk nan;
            var mean: f64 = 0;
            for (rets[0..m]) |r| mean += r;
            mean /= @as(f64, @floatFromInt(m));
            var ss: f64 = 0;
            for (rets[0..m]) |r| {
                const d = r - mean;
                ss += d * d;
            }
            break :blk @sqrt(ss / @as(f64, @floatFromInt(m)));
        };
    }

    var c: usize = 0;
    while (c < component_count) : (c += 1) {
        zscore(out.comp[c][0..n], out.z[c][0..n]);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sum: f64 = 0;
        var m: usize = 0;
        c = 0;
        while (c < component_count) : (c += 1) {
            const zv = out.z[c][i];
            if (isNum(zv)) {
                sum += component_signs[c] * zv;
                m += 1;
            }
        }
        out.ab[i] = if (m >= params.min_ab_components)
            sum / @as(f64, @floatFromInt(m))
        else
            nan;
    }
}

/// IC = Pearson(component z at t, forward equity return over `horizon_min`).
/// Rows with too few paired samples report r = NaN (rendered as null).
pub fn computeIc(
    points_in: []const storage.EquityPoint,
    series: *const Series,
    params: Params,
    horizon_min: i64,
) IcRow {
    const pts = if (points_in.len > max_points)
        points_in[points_in.len - max_points ..]
    else
        points_in;
    const n = @min(pts.len, series.n);
    var fwd: [max_points]f64 = undefined;
    const horizon_ms = horizon_min * std.time.ms_per_min;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        fwd[i] = blk: {
            const k = forwardIndex(pts, i, horizon_ms) orelse break :blk nan;
            if (pts[i].equity <= 1e-9) break :blk nan;
            break :blk pts[k].equity / pts[i].equity - 1;
        };
    }
    var row = IcRow{
        .horizon_min = horizon_min,
        .comp = undefined,
        .ab = undefined,
    };
    var c: usize = 0;
    while (c < component_count) : (c += 1) {
        var e = pearson(series.z[c][0..n], fwd[0..n]);
        if (e.n < params.min_ic_samples) e.r = nan;
        row.comp[c] = e;
    }
    var e = pearson(series.ab[0..n], fwd[0..n]);
    if (e.n < params.min_ic_samples) e.r = nan;
    row.ab = e;
    return row;
}

fn writeNum(w: *std.Io.Writer, v: f64) !void {
    // Analytics values live in small ranges; anything huge means a data bug —
    // emit null instead of ballooning the fixed buffer.
    if (!isNum(v) or @abs(v) > 1e6) {
        try w.writeAll("null");
        return;
    }
    try w.print("{d:.6}", .{v});
}

/// Render the analytics blob: downsampled raw component values + AB factor
/// (z-based), plus IC rows. Chronological ascending; the newest 1m sample is
/// always included. NaN → null.
pub fn writeJson(
    out: []u8,
    series: *const Series,
    ics: []const IcRow,
) error{Overflow}![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    render(&w, series, ics) catch return error.Overflow;
    return w.buffered();
}

fn render(w: *std.Io.Writer, series: *const Series, ics: []const IcRow) !void {
    const n = series.n;
    try w.print(
        "{{\"factor_version\":\"{s}\",\"experimental\":true,\"n_1m\":{d},\"step_minutes\":{d}," ++
            "\"orientation\":{{\"pos\":1,\"ret\":1,\"alpha\":1,\"dd\":-1,\"vol\":-1,\"mom\":1}},\"points\":[",
        .{ factor_version, n, out_step },
    );
    if (n > 0) {
        const offset = (n - 1) % out_step;
        var i: usize = offset;
        var first = true;
        while (i < n) : (i += out_step) {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"t\":{d}", .{series.ts_sec[i]});
            var c: usize = 0;
            while (c < component_count) : (c += 1) {
                try w.print(",\"{s}\":", .{component_keys[c]});
                try writeNum(w, series.comp[c][i]);
            }
            try w.writeAll(",\"ab\":");
            try writeNum(w, series.ab[i]);
            try w.writeAll("}");
        }
    }
    try w.writeAll("],\"ic\":[");
    for (ics, 0..) |row, ri| {
        if (ri > 0) try w.writeAll(",");
        try w.print("{{\"horizon_minutes\":{d}", .{row.horizon_min});
        var c: usize = 0;
        while (c < component_count) : (c += 1) {
            try w.print(",\"{s}\":{{\"r\":", .{component_keys[c]});
            try writeNum(w, row.comp[c].r);
            try w.print(",\"n\":{d}}}", .{row.comp[c].n});
        }
        try w.writeAll(",\"ab\":{\"r\":");
        try writeNum(w, row.ab.r);
        try w.print(",\"n\":{d}}}}}", .{row.ab.n});
    }
    try w.writeAll("]}");
}

// ===== tests =====

const testing = std.testing;

fn mkPoint(min: i64, equity: f64, btc_value: f64, bid: f64, bh: f64, marks: bool) storage.EquityPoint {
    return .{
        .ts_ms = min * std.time.ms_per_min,
        .equity = equity,
        .hwm = equity,
        .drawdown = 0,
        .cash = equity - btc_value,
        .btc_value = btc_value,
        .bid_price = bid,
        .btc_qty = if (bid > 0) btc_value / bid else 0,
        .bh_equity = bh,
        .marks_ok = marks,
    };
}

test "zscore golden values" {
    const vals = [_]f64{ 1, 2, 3, 4 };
    var out: [4]f64 = undefined;
    // fewer than 8 samples → all NaN
    zscore(&vals, &out);
    for (out) |v| try testing.expect(std.math.isNan(v));

    const vals8 = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var out8: [8]f64 = undefined;
    zscore(&vals8, &out8);
    // mean 4.5, population std sqrt(5.25) = 2.291288
    try testing.expectApproxEqAbs(@as(f64, -1.527525), out8[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 1.527525), out8[7], 1e-5);

    // constant series is degenerate
    const flat = [_]f64{ 5, 5, 5, 5, 5, 5, 5, 5 };
    var outf: [8]f64 = undefined;
    zscore(&flat, &outf);
    for (outf) |v| try testing.expect(std.math.isNan(v));
}

test "pearson correlation extremes" {
    const xs = [_]f64{ 1, 2, 3, 4, 5 };
    const ys_pos = [_]f64{ 3, 5, 7, 9, 11 }; // y = 2x + 1
    const ys_neg = [_]f64{ -1, -2, -3, -4, -5 };
    try testing.expectApproxEqAbs(@as(f64, 1), pearson(&xs, &ys_pos).r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1), pearson(&xs, &ys_neg).r, 1e-12);

    // NaN pairs are dropped
    const xs2 = [_]f64{ 1, nan, 3, 4, 5 };
    const p = pearson(&xs2, &ys_pos);
    try testing.expectEqual(@as(usize, 4), p.n);
    try testing.expectApproxEqAbs(@as(f64, 1), p.r, 1e-12);
}

test "compute: components, marks gating and gap guard" {
    var pts: [120]storage.EquityPoint = undefined;
    for (0..120) |i| {
        const fi = @as(f64, @floatFromInt(i));
        const eq = 100 + fi * 0.5 + 3 * @sin(fi / 5.0);
        const bid = 50000 + 200 * @sin(fi / 7.0);
        // first 20 rows predate migration 0006
        pts[i] = mkPoint(@intCast(i), eq, eq * 0.6, bid, 100 + fi * 0.4, i >= 20);
    }
    var series: Series = .{};
    compute(&pts, .{}, &series);
    try testing.expectEqual(@as(usize, 120), series.n);

    // pos is defined everywhere and equals btc_value/equity
    try testing.expectApproxEqAbs(@as(f64, 0.6), series.comp[idx_pos][10], 1e-12);
    // ret needs a 30m lookback: index 10 has none, index 60 does
    try testing.expect(std.math.isNan(series.comp[idx_ret][10]));
    const expect_ret = pts[60].equity / pts[30].equity - 1;
    try testing.expectApproxEqAbs(expect_ret, series.comp[idx_ret][60], 1e-12);
    // alpha/mom NaN on pre-marks rows, defined later
    try testing.expect(std.math.isNan(series.comp[idx_alpha][10]));
    try testing.expect(std.math.isNan(series.comp[idx_mom][25])); // lookback hits marks_ok=false row
    const expect_alpha = pts[80].equity / pts[80].bh_equity - 1;
    try testing.expectApproxEqAbs(expect_alpha, series.comp[idx_alpha][80], 1e-12);
    const expect_mom = pts[80].bid_price / pts[50].bid_price - 1;
    try testing.expectApproxEqAbs(expect_mom, series.comp[idx_mom][80], 1e-12);
    // vol defined once enough marked returns exist
    try testing.expect(isNum(series.comp[idx_vol][80]));
    // AB factor defined where >=3 components have finite z
    try testing.expect(isNum(series.ab[80]));
}

test "compute: time gap voids lookback windows" {
    var pts: [80]storage.EquityPoint = undefined;
    for (0..80) |i| {
        // 70-minute hole between i=39 and i=40
        const minute: i64 = if (i < 40) @intCast(i) else @intCast(i + 70);
        const fi = @as(f64, @floatFromInt(i));
        pts[i] = mkPoint(minute, 100 + fi, 60, 50000, 100, true);
    }
    var series: Series = .{};
    compute(&pts, .{}, &series);
    // right after the hole the nearest 30m-lookback sample is 71min old > 2×30m
    try testing.expect(std.math.isNan(series.comp[idx_ret][40]));
    // well past the hole the window is clean again
    try testing.expect(isNum(series.comp[idx_ret][75]));
}

test "computeIc: engineered pos component predicts forward return with IC ~ 1" {
    const n = 300;
    const horizon = 60;
    var eq: [n]f64 = undefined;
    for (0..n) |i| {
        const fi = @as(f64, @floatFromInt(i));
        eq[i] = 100 + 5 * @sin(fi / 7.0);
    }
    var pts: [n]storage.EquityPoint = undefined;
    for (0..n) |i| {
        // engineer pos[i] = 0.5 + forward-60m-return so corr(pos_z, fwd) = 1
        const fwd = if (i + horizon < n) eq[i + horizon] / eq[i] - 1 else 0;
        pts[i] = mkPoint(@intCast(i), eq[i], eq[i] * (0.5 + fwd), 50000, 100, true);
    }
    var series: Series = .{};
    compute(&pts, .{}, &series);
    const row = computeIc(&pts, &series, .{}, horizon);
    try testing.expectEqual(@as(i64, horizon), row.horizon_min);
    try testing.expect(row.comp[idx_pos].n >= 100);
    try testing.expectApproxEqAbs(@as(f64, 1), row.comp[idx_pos].r, 1e-9);
}

test "writeJson: shape, null emission and newest point included" {
    var pts: [40]storage.EquityPoint = undefined;
    for (0..40) |i| {
        const fi = @as(f64, @floatFromInt(i));
        pts[i] = mkPoint(@intCast(i), 100 + fi, 60, 50000 + fi, 0, false); // no marks
    }
    var series: Series = .{};
    compute(&pts, .{}, &series);
    const ics = [_]IcRow{computeIc(&pts, &series, .{}, 60)};
    var buf: [16384]u8 = undefined;
    const json = try writeJson(&buf, &series, &ics);
    try testing.expect(std.mem.indexOf(u8, json, "\"factor_version\":\"v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"experimental\":true") != null);
    // no marks → alpha is null somewhere
    try testing.expect(std.mem.indexOf(u8, json, "\"alpha\":null") != null);
    // newest sample (t = 39min) always present
    var tbuf: [32]u8 = undefined;
    const tlast = try std.fmt.bufPrint(&tbuf, "\"t\":{d}", .{@as(i64, 39 * 60)});
    try testing.expect(std.mem.indexOf(u8, json, tlast) != null);
    // valid JSON braces balance (cheap sanity: parseable)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    try testing.expect(parsed == .object);
}

test "writeJson: worst-case max-size series fits the cache buffer" {
    var series: Series = .{};
    series.n = max_points;
    for (0..max_points) |i| {
        series.ts_sec[i] = 1_800_000_000 + @as(i64, @intCast(i)) * 60;
        for (0..component_count) |c| series.comp[c][i] = -999999.987654;
        series.ab[i] = -9.876543;
    }
    const ics = [_]IcRow{
        .{ .horizon_min = 60, .comp = @splat(.{ .r = -0.987654, .n = 99999 }), .ab = .{ .r = -0.987654, .n = 99999 } },
        .{ .horizon_min = 240, .comp = @splat(.{ .r = -0.987654, .n = 99999 }), .ab = .{ .r = -0.987654, .n = 99999 } },
    };
    // Must match WebState.analytics_buf in src/web/cache.zig.
    var buf: [131072]u8 = undefined;
    const json = try writeJson(&buf, &series, &ics);
    try testing.expect(json.len < buf.len);
}
