//! Backtest gate for filter-layer parameter changes (phase 3).
//!
//! Replays recorded decisions through the same admission and guardrail code
//! as `src/backtest.zig`. It does not call the LLM and does not place orders.
//! `max_drawdown` stays the kernel constant 0.10.
//!
//! A candidate passes only when the sample is large enough and, on the
//! out-of-sample slice and on a strict majority of four rolling windows, it
//! is not worse than the active parameters by more than the noise band below.
//! Every one of those slices must also keep max drawdown under 8%.

const std = @import("std");
const db = @import("../storage/db.zig");
const dec = @import("../core/decimal.zig");
const backtest = @import("../backtest.zig");
const dynamic = @import("dynamic.zig");

const Decimal = dec.Decimal;

pub const report_ttl_ms: i64 = dynamic.day_ms;
pub const in_sample_percent: usize = 70;
pub const window_count: usize = 4;
pub const min_bars: usize = 192;
pub const min_oos_bars: usize = 32;
pub const min_window_bars: usize = 32;
pub const min_decisions: usize = 8;
pub const min_oos_decisions: usize = 2;
/// Absolute cap. A slice at exactly 0.08 fails.
pub const max_window_drawdown: f64 = 0.08;
/// Return or alpha gaps inside this band are ties, not improvements and not regressions.
pub const return_noise: f64 = 0.002;
pub const alpha_noise: f64 = 0.002;
/// Drawdown may be this much worse than the baseline before the slice fails.
pub const drawdown_noise: f64 = 0.005;
pub const fee_noise_abs: f64 = 0.05;
pub const fee_noise_frac: f64 = 0.10;
pub const turnover_noise_abs: f64 = 1.0;
pub const turnover_noise_frac: f64 = 0.10;

pub const limitations = [_][]const u8{
    "Evaluates filter-layer parameters on recorded decisions only. It does not call the LLM and cannot say what the model would have proposed under these parameters.",
    "Scheduler knobs event_price_move, event_drawdown_step, event_price_drift, volatility_window_ms and volatility_gap_ms do not change the replay.",
    "max_drawdown stays 0.10 and is not a tuned field.",
    "Each slice starts from a flat 1000 USDT paper book. Live balances, order ids and external capital flows are not read.",
    "Fills use the same offline model as zig build backtest: bar open, fixed taker fee and slippage. No order book, partial fills or latency.",
    "A passing report expires 24h after as_of_ms. It is evidence about this sample only, not a forecast.",
};

pub const Metrics = struct {
    twr_return: f64 = 0,
    hold_return: f64 = 0,
    alpha: f64 = 0,
    max_drawdown: f64 = 0,
    trades: u32 = 0,
    fees_usdt: f64 = 0,
    turnover_usdt: f64 = 0,
};

pub const Window = struct {
    start: usize,
    end: usize,
};

pub const Plan = struct {
    is_end: usize,
    oos_start: usize,
    windows: [window_count]Window,
};

pub const Meta = struct {
    source: []const u8 = "",
    operator: []const u8 = "",
    reason: []const u8 = "",
};

pub const Report = struct {
    passed: bool = false,
    as_of_ms: i64 = 0,
    id: [32]u8 = undefined,
    id_len: usize = 0,
    range_hash: [64]u8 = undefined,
    digest: [64]u8 = undefined,
    params_json: [2048]u8 = undefined,
    params_len: usize = 0,
    baseline_json: [2048]u8 = undefined,
    baseline_len: usize = 0,
    baseline_version_id: i64 = 0,
    /// Points at `out` passed to `evaluate`.
    body: []const u8 = "",
    /// Out-of-sample alpha(candidate) − alpha(baseline). Zero when the sample
    /// was too short to score. The strategy review uses this to rank passes.
    oos_alpha_delta: f64 = 0,
    oos_candidate_drawdown: f64 = 0,
    summary_buf: [384]u8 = undefined,
    summary_len: usize = 0,

    pub fn idText(self: *const Report) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn paramsText(self: *const Report) []const u8 {
        return self.params_json[0..self.params_len];
    }
    pub fn baselineText(self: *const Report) []const u8 {
        return self.baseline_json[0..self.baseline_len];
    }
    pub fn rangeHashText(self: *const Report) []const u8 {
        return &self.range_hash;
    }
    pub fn digestText(self: *const Report) []const u8 {
        return &self.digest;
    }
    pub fn summaryText(self: *const Report) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
};

pub const EvalError = error{ OutOfMemory, ReportTooSmall, ReplayFailed };

pub const RefError = dynamic.BacktestRefError || db.DbError || error{
    ReportNotFound,
    Expired,
    ParamsMismatch,
    DigestMismatch,
    AsOfMismatch,
    BaselineMismatch,
    NotPassedRow,
};

/// 70/30 chronological split plus four rolling windows on the full series.
/// Returns null when the series cannot satisfy the minimums.
pub fn planSample(n: usize) ?Plan {
    if (n < min_bars) return null;
    const is_end = n * in_sample_percent / 100;
    const oos = n - is_end;
    if (oos < min_oos_bars or is_end < min_window_bars) return null;
    const length = @max(min_window_bars, n / 2);
    if (length >= n) return null;
    const span = n - length;
    if (span < window_count - 1) return null;
    const step = span / (window_count - 1);
    if (step == 0) return null;
    var plan = Plan{
        .is_end = is_end,
        .oos_start = is_end,
        .windows = undefined,
    };
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        const start = i * step;
        const end = start + length;
        if (end > n) return null;
        plan.windows[i] = .{ .start = start, .end = end };
    }
    return plan;
}

/// True when `candidate` is inside the noise band of `baseline`.
/// The absolute 8% drawdown cap is `drawdownWithinCap`, not this function.
pub fn notWorse(baseline: Metrics, candidate: Metrics) bool {
    if (candidate.twr_return < baseline.twr_return - return_noise) return false;
    if (candidate.alpha < baseline.alpha - alpha_noise) return false;
    if (candidate.max_drawdown > baseline.max_drawdown + drawdown_noise) return false;
    const return_improved = candidate.twr_return >= baseline.twr_return + return_noise;
    if (!return_improved) {
        const fee_band = @max(fee_noise_abs, @abs(baseline.fees_usdt) * fee_noise_frac);
        if (candidate.fees_usdt > baseline.fees_usdt + fee_band) return false;
        const turn_band = @max(turnover_noise_abs, @abs(baseline.turnover_usdt) * turnover_noise_frac);
        if (candidate.turnover_usdt > baseline.turnover_usdt + turn_band) return false;
    }
    return true;
}

pub fn drawdownWithinCap(max_drawdown: f64) bool {
    return max_drawdown < max_window_drawdown;
}

pub fn simOf(p: dynamic.Params) backtest.SimConfig {
    return .{
        .initial_cash = Decimal.fromInt(1000),
        .max_drawdown = dynamic.max_drawdown_locked,
        .exit_reserve = p.exit_reserve,
        .price_shock = p.price_shock,
        .trend_period = p.trend_ma_period,
    };
}

pub fn evaluate(
    gpa: std.mem.Allocator,
    bars: []const backtest.Bar,
    decisions: []const backtest.Decision,
    baseline: dynamic.Params,
    candidate: dynamic.Params,
    baseline_version_id: i64,
    min_notional: Decimal,
    now_ms: i64,
    meta: Meta,
    out: []u8,
) EvalError!Report {
    var report = Report{
        .as_of_ms = now_ms,
        .baseline_version_id = baseline_version_id,
    };
    report.params_len = try writeParams(&report.params_json, candidate);
    report.baseline_len = try writeParams(&report.baseline_json, baseline);

    const in_range = try decisionsInRange(gpa, bars, decisions);
    defer gpa.free(in_range);
    fillRangeHash(&report.range_hash, bars, in_range);
    fillDigest(&report.digest, &report.range_hash, report.paramsText());
    report.id_len = fillId(&report.id, &report.range_hash, report.paramsText(), report.baselineText(), now_ms);

    var reasons: [8][]const u8 = undefined;
    var nreason: usize = 0;
    const plan = planSample(bars.len);
    if (bars.len < min_bars) pushReason(&reasons, &nreason, "insufficient_bars");
    if (in_range.len < min_decisions) pushReason(&reasons, &nreason, "insufficient_decisions");
    if (bars.len >= min_bars and plan == null) pushReason(&reasons, &nreason, "insufficient_windows");
    if (plan) |p| {
        if (bars.len >= p.oos_start and countDecisions(bars[p.oos_start..], in_range) < min_oos_decisions) {
            pushReason(&reasons, &nreason, "insufficient_oos");
        }
        var bare = false;
        for (p.windows) |w| {
            if (countDecisions(bars[w.start..w.end], in_range) == 0) bare = true;
        }
        if (bare) pushReason(&reasons, &nreason, "window_without_decisions");
    } else if (bars.len >= min_bars) {
        // planSample already reported insufficient_windows.
    } else if (in_range.len >= min_decisions) {
        // Short series: the decision count is not the reason.
    }

    if (nreason > 0) {
        report.passed = false;
        fillSummary(&report);
        report.body = try writeReport(out, &report, meta, reasons[0..nreason], null, null, &.{});
        return report;
    }
    const p = plan.?;

    var daily = backtest.dailyFromBars(gpa, bars) catch return error.ReplayFailed;
    defer daily.deinit(gpa);
    const base_dec = try clipDecisions(gpa, baseline, in_range);
    defer gpa.free(base_dec);
    const cand_dec = try clipDecisions(gpa, candidate, in_range);
    defer gpa.free(cand_dec);

    const is_score = try scoreSlice(gpa, baseline, candidate, min_notional, bars[0..p.is_end], daily.items, base_dec, cand_dec);
    const oos_score = try scoreSlice(gpa, baseline, candidate, min_notional, bars[p.oos_start..], daily.items, base_dec, cand_dec);
    var windows: [window_count]SliceScore = undefined;
    for (p.windows, 0..) |w, i| {
        windows[i] = try scoreSlice(gpa, baseline, candidate, min_notional, bars[w.start..w.end], daily.items, base_dec, cand_dec);
    }

    var wins: usize = 0;
    var dd_fail = !oos_score.drawdown_ok;
    for (windows) |w| {
        if (w.not_worse) wins += 1;
        if (!w.drawdown_ok) dd_fail = true;
    }
    if (!oos_score.not_worse) pushReason(&reasons, &nreason, "oos_worse");
    if (wins * 2 <= window_count) pushReason(&reasons, &nreason, "windows_majority");
    if (dd_fail) pushReason(&reasons, &nreason, "drawdown_cap");
    report.passed = nreason == 0;
    report.oos_alpha_delta = oos_score.candidate.alpha - oos_score.baseline.alpha;
    report.oos_candidate_drawdown = oos_score.candidate.max_drawdown;
    fillSummary(&report);
    report.body = try writeReport(out, &report, meta, reasons[0..nreason], &is_score, &oos_score, &windows);
    return report;
}

/// Look up a passing, unexpired report whose candidate params match `params_json`
/// and whose baseline version is still the active one. Shape is checked first.
pub fn validateStoredRef(
    database: *db.Db,
    raw: []const u8,
    params_json: []const u8,
    active_version_id: i64,
    now_ms: i64,
) RefError!void {
    try dynamic.validateBacktestRef(std.heap.page_allocator, raw);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return error.Malformed;
    defer parsed.deinit();
    const obj = parsed.value.object;
    const id = obj.get("id").?.string;
    var stmt = try database.prepare(
        \\SELECT passed, params_json, baseline_version_id, as_of_ms, digest
        \\FROM backtest_reports WHERE id = ?1
    );
    defer stmt.finalize();
    try stmt.bindText(1, id);
    if (!try stmt.step()) return error.ReportNotFound;
    const passed_row = stmt.columnInt(0) == 1;
    const stored_params = stmt.columnText(1);
    const baseline_version = stmt.columnInt(2);
    const as_of = stmt.columnInt(3);
    const digest = stmt.columnText(4);
    if (!passed_row) return error.NotPassedRow;
    if (as_of > now_ms or now_ms - as_of > report_ttl_ms) return error.Expired;
    if (!std.mem.eql(u8, stored_params, params_json)) return error.ParamsMismatch;
    if (baseline_version != active_version_id) return error.BaselineMismatch;
    if (obj.get("digest")) |d| {
        if (d != .string or !std.mem.eql(u8, d.string, digest)) return error.DigestMismatch;
    }
    if (obj.get("as_of_ms")) |at| {
        if (at != .integer or at.integer != as_of) return error.AsOfMismatch;
    }
}

pub fn refField(err: RefError) []const u8 {
    return switch (err) {
        error.ReportNotFound => "backtest_not_found",
        error.Expired => "backtest_expired",
        error.ParamsMismatch => "backtest_params",
        error.DigestMismatch => "backtest_digest",
        error.AsOfMismatch => "backtest_as_of",
        error.BaselineMismatch => "backtest_baseline",
        error.NotPassed, error.NotPassedRow => "backtest_not_passed",
        else => "backtest_summary",
    };
}

// ---------------------------------------------------------------------------

const SliceScore = struct {
    baseline: Metrics = .{},
    candidate: Metrics = .{},
    not_worse: bool = false,
    drawdown_ok: bool = false,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    bars: usize = 0,
    decisions: usize = 0,
};

fn scoreSlice(
    gpa: std.mem.Allocator,
    baseline: dynamic.Params,
    candidate: dynamic.Params,
    min_notional: Decimal,
    bars: []const backtest.Bar,
    daily: []const backtest.DailyBar,
    base_dec: []const backtest.Decision,
    cand_dec: []const backtest.Decision,
) EvalError!SliceScore {
    if (bars.len < 2) return error.ReplayFailed;
    const base = try replay(gpa, simOf(baseline), baseline, min_notional, bars, daily, base_dec);
    const cand = try replay(gpa, simOf(candidate), candidate, min_notional, bars, daily, cand_dec);
    const bm = metricsOf(base);
    const cm = metricsOf(cand);
    return .{
        .baseline = bm,
        .candidate = cm,
        .not_worse = notWorse(bm, cm),
        .drawdown_ok = drawdownWithinCap(cm.max_drawdown),
        .start_ms = bars[0].ts,
        .end_ms = bars[bars.len - 1].ts,
        .bars = bars.len,
        .decisions = countDecisions(bars, cand_dec),
    };
}

fn replay(
    gpa: std.mem.Allocator,
    sim: backtest.SimConfig,
    params: dynamic.Params,
    min_notional: Decimal,
    bars: []const backtest.Bar,
    daily: []const backtest.DailyBar,
    decisions: []const backtest.Decision,
) EvalError!backtest.Result {
    var filtered: std.ArrayList(backtest.Decision) = .empty;
    defer filtered.deinit(gpa);
    const t0 = bars[0].ts;
    const t1 = bars[bars.len - 1].ts;
    for (decisions) |d| {
        if (d.ts >= t0 and d.ts <= t1) filtered.append(gpa, d) catch return error.OutOfMemory;
    }
    return backtest.run(gpa, sim, "gate", params.guardOf(min_notional), bars, daily, filtered.items, &.{}) catch return error.ReplayFailed;
}

fn metricsOf(r: backtest.Result) Metrics {
    return .{
        .twr_return = r.twr_return,
        .hold_return = r.hold_return,
        .alpha = r.alpha,
        .max_drawdown = r.max_drawdown,
        .trades = r.trades,
        .fees_usdt = r.fees_usdt,
        .turnover_usdt = r.turnover_usdt,
    };
}

fn countDecisions(bars: []const backtest.Bar, decisions: []const backtest.Decision) usize {
    if (bars.len == 0) return 0;
    const a = bars[0].ts;
    const b = bars[bars.len - 1].ts;
    var n: usize = 0;
    for (decisions) |d| {
        if (d.ts >= a and d.ts <= b) n += 1;
    }
    return n;
}

fn decisionsInRange(gpa: std.mem.Allocator, bars: []const backtest.Bar, decisions: []const backtest.Decision) EvalError![]backtest.Decision {
    if (bars.len == 0) return gpa.alloc(backtest.Decision, 0) catch return error.OutOfMemory;
    var list: std.ArrayList(backtest.Decision) = .empty;
    errdefer list.deinit(gpa);
    const a = bars[0].ts;
    const b = bars[bars.len - 1].ts;
    for (decisions) |d| {
        if (d.ts >= a and d.ts <= b) list.append(gpa, d) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

fn clipDecisions(gpa: std.mem.Allocator, params: dynamic.Params, src: []const backtest.Decision) EvalError![]backtest.Decision {
    const out = gpa.alloc(backtest.Decision, src.len) catch return error.OutOfMemory;
    for (src, out) |s, *d| {
        d.* = s;
        d.weight = params.applyPositionCap(s.weight);
    }
    return out;
}

fn writeParams(buf: *[2048]u8, params: dynamic.Params) EvalError!usize {
    var w: std.Io.Writer = .fixed(buf);
    params.writeJson(&w) catch return error.ReportTooSmall;
    return w.buffered().len;
}

fn pushReason(buf: *[8][]const u8, n: *usize, reason: []const u8) void {
    if (n.* >= buf.len) return;
    buf[n.*] = reason;
    n.* += 1;
}

fn fillRangeHash(out: *[64]u8, bars: []const backtest.Bar, decisions: []const backtest.Decision) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var line: [96]u8 = undefined;
    for (bars) |b| {
        const n = std.fmt.bufPrint(&line, "{d},{d},{d}\n", .{ b.ts, b.open.raw, b.close.raw }) catch continue;
        h.update(n);
    }
    h.update("|\n");
    for (decisions) |d| {
        const n = std.fmt.bufPrint(&line, "{d},{d},{d},{d}\n", .{
            d.ts,
            d.weight.raw,
            @intFromBool(d.operator),
            @intFromBool(d.macro),
        }) catch continue;
        h.update(n);
    }
    var dig: [32]u8 = undefined;
    h.final(&dig);
    hex64(out, &dig);
}

fn fillDigest(out: *[64]u8, range_hash: *const [64]u8, params_json: []const u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(range_hash);
    h.update("|");
    h.update(params_json);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    hex64(out, &dig);
}

fn fillId(id: *[32]u8, range_hash: *const [64]u8, params_json: []const u8, baseline_json: []const u8, as_of: i64) usize {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(range_hash);
    h.update("|");
    h.update(params_json);
    h.update("|");
    h.update(baseline_json);
    var stamp: [32]u8 = undefined;
    const n = std.fmt.bufPrint(&stamp, "|{d}", .{as_of}) catch "|0";
    h.update(n);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    id[0..3].* = "bt_".*;
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        id[3 + i * 2] = hex[dig[i] >> 4];
        id[4 + i * 2] = hex[dig[i] & 0x0f];
    }
    return 19;
}

fn hex64(out: *[64]u8, dig: *const [32]u8) void {
    const hex = "0123456789abcdef";
    for (dig, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

fn writeReport(
    out: []u8,
    report: *const Report,
    meta: Meta,
    reasons: []const []const u8,
    in_sample: ?*const SliceScore,
    oos: ?*const SliceScore,
    windows: []const SliceScore,
) EvalError![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll("{\"schema\":\"") catch return error.ReportTooSmall;
    w.writeAll(dynamic.backtest_ref_schema) catch return error.ReportTooSmall;
    w.writeAll("\",\"id\":\"") catch return error.ReportTooSmall;
    w.writeAll(report.idText()) catch return error.ReportTooSmall;
    w.print("\",\"passed\":{},\"as_of_ms\":{d},\"expires_at_ms\":{d},\"digest\":\"{s}\",\"range_hash\":\"{s}\"", .{
        report.passed,
        report.as_of_ms,
        report.as_of_ms + report_ttl_ms,
        report.digestText(),
        report.rangeHashText(),
    }) catch return error.ReportTooSmall;
    w.print(",\"baseline_version_id\":{d},\"max_drawdown_locked\":\"{f}\"", .{
        report.baseline_version_id,
        dynamic.max_drawdown_locked,
    }) catch return error.ReportTooSmall;
    w.writeAll(",\"source\":\"") catch return error.ReportTooSmall;
    writeEscaped(&w, meta.source) catch return error.ReportTooSmall;
    w.writeAll("\",\"operator\":\"") catch return error.ReportTooSmall;
    writeEscaped(&w, meta.operator) catch return error.ReportTooSmall;
    w.writeAll("\",\"reason\":\"") catch return error.ReportTooSmall;
    writeEscaped(&w, meta.reason) catch return error.ReportTooSmall;
    w.writeAll("\",\"rules\":{") catch return error.ReportTooSmall;
    w.print("\"in_sample_percent\":{d},\"out_of_sample_percent\":{d},\"min_windows\":{d},\"min_bars\":{d},\"min_decisions\":{d},\"min_oos_decisions\":{d},\"max_window_drawdown\":{d:.3},\"return_noise\":{d:.3},\"alpha_noise\":{d:.3},\"drawdown_noise\":{d:.3},\"majority\":\"strict\",\"ttl_ms\":{d}", .{
        in_sample_percent,
        100 - in_sample_percent,
        window_count,
        min_bars,
        min_decisions,
        min_oos_decisions,
        max_window_drawdown,
        return_noise,
        alpha_noise,
        drawdown_noise,
        report_ttl_ms,
    }) catch return error.ReportTooSmall;
    w.writeAll("},\"reasons\":") catch return error.ReportTooSmall;
    writeStringArray(&w, reasons) catch return error.ReportTooSmall;
    w.writeAll(",\"candidate_params\":") catch return error.ReportTooSmall;
    w.writeAll(report.paramsText()) catch return error.ReportTooSmall;
    w.writeAll(",\"baseline_params\":") catch return error.ReportTooSmall;
    w.writeAll(report.baselineText()) catch return error.ReportTooSmall;
    w.writeAll(",\"in_sample\":") catch return error.ReportTooSmall;
    writeSlice(&w, in_sample) catch return error.ReportTooSmall;
    w.writeAll(",\"out_of_sample\":") catch return error.ReportTooSmall;
    writeSlice(&w, oos) catch return error.ReportTooSmall;
    w.writeAll(",\"windows\":[") catch return error.ReportTooSmall;
    for (windows, 0..) |win, i| {
        if (i > 0) w.writeByte(',') catch return error.ReportTooSmall;
        writeSlice(&w, &win) catch return error.ReportTooSmall;
    }
    w.writeAll("],\"backtest_summary\":\"") catch return error.ReportTooSmall;
    writeSummary(&w, report) catch return error.ReportTooSmall;
    w.writeAll("\",\"limitations\":") catch return error.ReportTooSmall;
    writeStringArray(&w, &limitations) catch return error.ReportTooSmall;
    w.writeByte('}') catch return error.ReportTooSmall;
    return w.buffered();
}

fn fillSummary(report: *Report) void {
    var inner: std.Io.Writer = .fixed(&report.summary_buf);
    inner.print("{{\"schema\":\"{s}\",\"id\":\"{s}\",\"passed\":{},\"digest\":\"{s}\",\"as_of_ms\":{d}}}", .{
        dynamic.backtest_ref_schema,
        report.idText(),
        report.passed,
        report.digestText(),
        report.as_of_ms,
    }) catch {
        report.summary_len = 0;
        return;
    };
    report.summary_len = inner.buffered().len;
}

fn writeSummary(w: *std.Io.Writer, report: *const Report) std.Io.Writer.Error!void {
    try writeEscaped(w, report.summaryText());
}

fn writeSlice(w: *std.Io.Writer, slice: ?*const SliceScore) std.Io.Writer.Error!void {
    const s = slice orelse {
        try w.writeAll("null");
        return;
    };
    try w.print("{{\"start_ms\":{d},\"end_ms\":{d},\"bars\":{d},\"decisions\":{d},\"not_worse\":{},\"drawdown_ok\":{},\"candidate\":", .{
        s.start_ms,
        s.end_ms,
        s.bars,
        s.decisions,
        s.not_worse,
        s.drawdown_ok,
    });
    try writeMetrics(w, s.candidate);
    try w.writeAll(",\"baseline\":");
    try writeMetrics(w, s.baseline);
    try w.writeByte('}');
}

fn writeMetrics(w: *std.Io.Writer, m: Metrics) std.Io.Writer.Error!void {
    try w.print("{{\"twr_return\":{d:.6},\"hold_return\":{d:.6},\"alpha\":{d:.6},\"max_drawdown\":{d:.6},\"trades\":{d},\"fees_usdt\":{d:.4},\"turnover_usdt\":{d:.4}}}", .{
        m.twr_return,
        m.hold_return,
        m.alpha,
        m.max_drawdown,
        m.trades,
        m.fees_usdt,
        m.turnover_usdt,
    });
}

fn writeStringArray(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('"');
        try writeEscaped(w, item);
        try w.writeByte('"');
    }
    try w.writeByte(']');
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n', '\r' => try w.writeByte(' '),
        else => if (c >= 0x20) try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn usd(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn flatBars(gpa: std.mem.Allocator, n: usize, price: i64) ![]backtest.Bar {
    const out = try gpa.alloc(backtest.Bar, n);
    for (out, 0..) |*b, i| {
        const px = Decimal.fromInt(price);
        b.* = .{ .ts = @as(i64, @intCast(i)) * 15 * 60_000, .open = px, .close = px };
    }
    return out;
}

fn every(gpa: std.mem.Allocator, n_bars: usize, stride: usize, hi: Decimal, lo: Decimal) ![]backtest.Decision {
    var list: std.ArrayList(backtest.Decision) = .empty;
    var i: usize = 0;
    var flip = false;
    while (i < n_bars) : (i += stride) {
        try list.append(gpa, .{
            .ts = @as(i64, @intCast(i)) * 15 * 60_000,
            .weight = if (flip) lo else hi,
        });
        flip = !flip;
    }
    return try list.toOwnedSlice(gpa);
}

test "split is 70/30 and four rolling windows cover the series" {
    try testing.expect(planSample(191) == null);
    try testing.expect(planSample(min_bars - 1) == null);
    const p = planSample(192) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 134), p.is_end);
    try testing.expectEqual(@as(usize, 134), p.oos_start);
    try testing.expectEqual(@as(usize, 58), 192 - p.is_end);
    try testing.expectEqual(@as(usize, 4), p.windows.len);
    try testing.expectEqual(@as(usize, 0), p.windows[0].start);
    try testing.expectEqual(@as(usize, 96), p.windows[0].end);
    try testing.expectEqual(@as(usize, 32), p.windows[1].start);
    try testing.expectEqual(@as(usize, 128), p.windows[1].end);
    try testing.expectEqual(@as(usize, 64), p.windows[2].start);
    try testing.expectEqual(@as(usize, 160), p.windows[2].end);
    try testing.expectEqual(@as(usize, 96), p.windows[3].start);
    try testing.expectEqual(@as(usize, 192), p.windows[3].end);
    const wide = planSample(1000) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 700), wide.is_end);
    try testing.expect(wide.windows[3].end <= 1000);
    try testing.expect(wide.windows[0].end - wide.windows[0].start >= min_window_bars);
    // Strict majority of four windows: two passes still fail, three pass.
    try testing.expect(2 * 2 <= window_count);
    try testing.expect(!(3 * 2 <= window_count));
}

test "noise band treats ties as not worse and rejects a real regression" {
    const base = Metrics{ .twr_return = 0.01, .alpha = 0.004, .max_drawdown = 0.02, .fees_usdt = 1.0, .turnover_usdt = 400 };
    try testing.expect(notWorse(base, base));
    var tie = base;
    tie.twr_return = base.twr_return - 0.001;
    tie.alpha = base.alpha - 0.001;
    tie.max_drawdown = base.max_drawdown + 0.004;
    try testing.expect(notWorse(base, tie));
    var worse_ret = base;
    worse_ret.twr_return = base.twr_return - 0.01;
    try testing.expect(!notWorse(base, worse_ret));
    var worse_alpha = base;
    worse_alpha.alpha = base.alpha - 0.01;
    try testing.expect(!notWorse(base, worse_alpha));
    var worse_dd = base;
    worse_dd.max_drawdown = base.max_drawdown + 0.01;
    try testing.expect(!notWorse(base, worse_dd));
    var costlier = base;
    costlier.fees_usdt = 1.30;
    try testing.expect(!notWorse(base, costlier));
    var paid_for_edge = costlier;
    paid_for_edge.twr_return = base.twr_return + 0.01;
    paid_for_edge.alpha = base.alpha + 0.01;
    try testing.expect(notWorse(base, paid_for_edge));
    try testing.expect(drawdownWithinCap(0.079));
    try testing.expect(!drawdownWithinCap(0.08));
    try testing.expect(!drawdownWithinCap(0.10));
    try testing.expect(simOf(.{}).max_drawdown.eql(dynamic.max_drawdown_locked));
    try testing.expect(dynamic.max_drawdown_locked.eql(usd("0.10")));
}

test "a short sample fails closed and names the reason" {
    const gpa = testing.allocator;
    const bars = try flatBars(gpa, 10, 100);
    defer gpa.free(bars);
    var out: [8192]u8 = undefined;
    const report = try evaluate(gpa, bars, &.{}, .{}, .{}, 1, Decimal.zero, 1_700_000_000_000, .{}, &out);
    try testing.expect(!report.passed);
    try testing.expect(std.mem.indexOf(u8, report.body, "\"passed\":false") != null);
    try testing.expect(std.mem.indexOf(u8, report.body, "insufficient_bars") != null);
    try testing.expect(std.mem.indexOf(u8, report.body, "insufficient_decisions") != null);
    try testing.expect(std.mem.indexOf(u8, report.body, dynamic.backtest_ref_schema) != null);
    try testing.expect(std.mem.startsWith(u8, report.idText(), "bt_"));
    try testing.expect(std.mem.indexOf(u8, report.body, "cannot say what the model would have proposed") != null);
}

test "equal parameters pass and a looser churn filter fails the out-of-sample slice" {
    const gpa = testing.allocator;
    const bars = try flatBars(gpa, 192, 100);
    defer gpa.free(bars);
    const decs = try every(gpa, 192, 16, usd("0.4"), usd("0.4"));
    defer gpa.free(decs);
    var out: [32768]u8 = undefined;
    const same = try evaluate(gpa, bars, decs, .{}, .{}, 1, Decimal.zero, 1_700_000_000_000, .{ .operator = "ops", .reason = "same" }, &out);
    try testing.expect(same.passed);
    try testing.expect(std.mem.indexOf(u8, same.body, "\"reasons\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, same.body, "\"max_drawdown_locked\":\"0.1\"") != null);

    const churn = try every(gpa, 192, 8, usd("0.8"), usd("0.2"));
    defer gpa.free(churn);
    var loose = dynamic.Params{};
    loose.reverse_cooldown_ms = 0;
    loose.daily_trade_cap = 48;
    var out2: [32768]u8 = undefined;
    const worse = try evaluate(gpa, bars, churn, .{}, loose, 1, Decimal.zero, 1_700_000_000_000, .{}, &out2);
    try testing.expect(!worse.passed);
    try testing.expect(std.mem.indexOf(u8, worse.body, "oos_worse") != null);
}

test "any window at or above 8 percent drawdown fails" {
    const gpa = testing.allocator;
    const bars = try gpa.alloc(backtest.Bar, 192);
    defer gpa.free(bars);
    for (bars, 0..) |*b, i| {
        const px: i64 = if (i < 150) 100 else @max(100 - @as(i64, @intCast(i - 150)) * 3, 20);
        const price = Decimal.fromInt(px);
        b.* = .{ .ts = @as(i64, @intCast(i)) * 15 * 60_000, .open = price, .close = price };
    }
    const decs = try every(gpa, 192, 16, usd("0.9"), usd("0.9"));
    defer gpa.free(decs);
    var out: [32768]u8 = undefined;
    const report = try evaluate(gpa, bars, decs, .{}, .{}, 1, Decimal.zero, 1_700_000_000_000, .{}, &out);
    try testing.expect(!report.passed);
    try testing.expect(std.mem.indexOf(u8, report.body, "drawdown_cap") != null);
}

fn seedRow(
    database: *db.Db,
    id: []const u8,
    params_json: []const u8,
    as_of: i64,
    passed: bool,
    baseline_version: i64,
    digest: []const u8,
) !void {
    var stmt = try database.prepare(
        \\INSERT INTO backtest_reports (
        \\  id, created_ts, as_of_ms, passed, params_json, baseline_json,
        \\  baseline_version_id, range_hash, digest, report_json
        \\) VALUES (?1, '2023-11-14T22:13:20.000Z', ?2, ?3, ?4, '{}', ?5, 'range', ?6, '{}')
    );
    defer stmt.finalize();
    try stmt.bindText(1, id);
    try stmt.bindInt(2, as_of);
    try stmt.bindInt(3, if (passed) 1 else 0);
    try stmt.bindText(4, params_json);
    try stmt.bindInt(5, baseline_version);
    try stmt.bindText(6, digest);
    _ = try stmt.stepCritical();
}

test "stored ref must exist, match params, and be inside 24h" {
    var database = try db.Db.open(":memory:");
    defer database.close();
    const params = "{\"daily_trade_cap\":7}";
    const t0: i64 = 1_700_000_000_000;
    try seedRow(&database, "bt_ok", params, t0, true, 3, "digestok");
    const ref = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true,\"digest\":\"digestok\",\"as_of_ms\":1700000000000}";
    try validateStoredRef(&database, ref, params, 3, t0 + 1_000);
    try validateStoredRef(&database, ref, params, 3, t0 + report_ttl_ms);
    try testing.expectError(error.Expired, validateStoredRef(&database, ref, params, 3, t0 + report_ttl_ms + 1));
    try testing.expectError(error.Expired, validateStoredRef(&database, ref, params, 3, t0 - 1));
    try testing.expectError(error.ParamsMismatch, validateStoredRef(&database, ref, "{\"daily_trade_cap\":6}", 3, t0 + 1_000));
    try testing.expectError(error.BaselineMismatch, validateStoredRef(&database, ref, params, 4, t0 + 1_000));
    try testing.expectError(error.ReportNotFound, validateStoredRef(&database, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_missing\",\"passed\":true}", params, 3, t0));
    try testing.expectError(error.DigestMismatch, validateStoredRef(&database, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true,\"digest\":\"nope\"}", params, 3, t0 + 1_000));
    try testing.expectError(error.AsOfMismatch, validateStoredRef(&database, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true,\"as_of_ms\":1}", params, 3, t0 + 1_000));
    try testing.expectError(error.NotPassed, validateStoredRef(&database, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":false}", params, 3, t0));

    try seedRow(&database, "bt_fail", params, t0, false, 3, "digestok");
    try testing.expectError(error.NotPassedRow, validateStoredRef(&database, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_fail\",\"passed\":true}", params, 3, t0 + 1_000));
    try testing.expectEqualStrings("backtest_expired", refField(error.Expired));
    try testing.expectEqualStrings("backtest_not_found", refField(error.ReportNotFound));
    try testing.expectEqualStrings("backtest_params", refField(error.ParamsMismatch));
}
