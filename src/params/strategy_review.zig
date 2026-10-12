//! Scheduled strategy review (phase 4).
//!
//! One round replays recorded history, reconciles it with the equity curve,
//! classifies the regime, and searches a small deterministic neighborhood of
//! the active filter parameters. A candidate is applied only through
//! `apply_params` (source=review) after the phase-3 backtest gate passes and
//! the live book is calm. The 72h window after an apply can roll the change
//! back; it never opens an order. `max_drawdown` stays 0.10.
//!
//! The trading loop does not call this file. Any error stores a failed
//! report and leaves the active version alone.

const std = @import("std");
const db = @import("../storage/db.zig");
const clock = @import("../core/clock.zig");
const dec = @import("../core/decimal.zig");
const backtest = @import("../backtest.zig");
const dynamic = @import("dynamic.zig");
const store = @import("store.zig");
const gate = @import("gate.zig");
const history = @import("history.zig");
const backtest_api = @import("backtest_api.zig");
const write = @import("write.zig");

const Decimal = dec.Decimal;
const heap = std.heap.page_allocator;

pub const schema = "alphabound.strategy_review.v1";
pub const reconcile_deviation_max: f64 = 0.05;
pub const apply_drawdown_max: f64 = 0.05;
pub const observe_ms: i64 = 72 * dynamic.day_ms / 24;
pub const observe_drawdown_widen: f64 = 0.02;
pub const observe_trade_multiple: f64 = 2.0;
pub const observe_trade_floor: f64 = 1.0;
pub const max_candidates: usize = 8;
pub const low_position_weight: f64 = 0.55;
pub const operator_name = "strategy_review";

pub const Switch = enum { auto, propose_only, off };

pub const Phase = enum {
    skipped,
    aborted,
    failed,
    observe_hold,
    rolled_back,
    proposed,
    applied,
    no_candidate,

    pub fn text(self: Phase) []const u8 {
        return @tagName(self);
    }
};

pub const Effect = enum { none, propose, apply, rollback };

pub const Trend = enum { up, down, flat };
pub const Vol = enum { low, normal, high };

pub const Regime = struct {
    trend: Trend = .flat,
    volatility: Vol = .normal,
    strategy_return: f64 = 0,
    hold_return: f64 = 0,
    alpha: f64 = 0,
    avg_weight: f64 = 0,
    /// Hold return minus strategy return, in percentage points. Positive means
    /// the book lagged a BTC hold.
    lag_pp: f64 = 0,
    /// Hold return left on the table by not being fully invested.
    cash_drag: f64 = 0,
    cause: []const u8 = "inline",
};

pub const Live = struct {
    drawdown: f64 = 0,
    risk_normal: bool = false,
    last_apply_ms: i64 = 0,
    trades_per_day: f64 = 0,
};

pub const Watch = struct {
    active: bool = false,
    started_ms: i64 = 0,
    until_ms: i64 = 0,
    previous_version_id: i64 = 0,
    applied_version_id: i64 = 0,
    baseline_drawdown: f64 = 0,
    baseline_trades_per_day: f64 = 0,
    expected_max_drawdown: f64 = 0,
};

pub const CandidateView = struct {
    params: dynamic.Params = .{},
    passed: bool = false,
    improvement: f64 = 0,
    oos_drawdown: f64 = 0,
    summary_buf: [384]u8 = undefined,
    summary_len: usize = 0,

    pub fn summary(self: *const CandidateView) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
};

pub const RoundInput = struct {
    now_ms: i64,
    mode: Switch,
    deviation: ?f64 = null,
    deviation_threshold: f64 = reconcile_deviation_max,
    live: Live = .{},
    watch: Watch = .{},
    candidates: []const CandidateView = &.{},
    fault: bool = false,
};

pub const RoundPlan = struct {
    phase: Phase,
    reason: []const u8,
    effect: Effect = .none,
    selected: ?usize = null,
    clear_watch: bool = false,
    open_watch: bool = false,
};

pub fn parseSwitch(s: []const u8) ?Switch {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "propose_only")) return .propose_only;
    if (std.mem.eql(u8, s, "off")) return .off;
    return null;
}

/// Max absolute gap between two growth indexes. Points are aligned by
/// position when the lengths differ. Empty input is unavailable, not zero.
pub fn reconcileGap(replay: []const f64, actual: []const f64) ?f64 {
    if (replay.len < 2 or actual.len < 2) return null;
    var max_gap: f64 = 0;
    var i: usize = 0;
    while (i < replay.len) : (i += 1) {
        if (!std.math.isFinite(replay[i])) return null;
        const j: usize = if (replay.len == 1) 0 else i * (actual.len - 1) / (replay.len - 1);
        if (!std.math.isFinite(actual[j])) return null;
        const gap = @abs(replay[i] - actual[j]);
        if (gap > max_gap) max_gap = gap;
    }
    return max_gap;
}

pub fn classifyRegime(closes: []const f64, strategy_return: f64, hold_return: f64, avg_weight: f64) Regime {
    var trend: Trend = .flat;
    var vol: Vol = .normal;
    if (closes.len >= 8 and closes[0] > 0 and std.math.isFinite(closes[0])) {
        const total = closes[closes.len - 1] / closes[0] - 1.0;
        if (total > 0.02) trend = .up else if (total < -0.02) trend = .down;
        var sum: f64 = 0;
        var sumsq: f64 = 0;
        var n: f64 = 0;
        var i: usize = 1;
        while (i < closes.len) : (i += 1) {
            if (!(closes[i - 1] > 0)) continue;
            const r = closes[i] / closes[i - 1] - 1.0;
            sum += r;
            sumsq += r * r;
            n += 1;
        }
        if (n >= 2) {
            const mean = sum / n;
            const variance = @max(sumsq / n - mean * mean, 0);
            const sigma = @sqrt(variance);
            if (sigma < 0.004) vol = .low else if (sigma > 0.015) vol = .high;
        }
    }
    const weight = std.math.clamp(avg_weight, 0, 1);
    const lag = hold_return - strategy_return;
    const drag = hold_return * (1.0 - weight);
    var cause: []const u8 = "inline";
    if (lag * 100.0 >= 1.0 and weight < low_position_weight and trend == .up and
        (drag >= lag * 0.6 or @abs(drag - lag) <= 0.02))
    {
        cause = "low_position";
    } else if (lag * 100.0 >= 1.0) {
        cause = "underperform_other";
    }
    return .{
        .trend = trend,
        .volatility = vol,
        .strategy_return = strategy_return,
        .hold_return = hold_return,
        .alpha = strategy_return - hold_return,
        .avg_weight = avg_weight,
        .lag_pp = lag * 100.0,
        .cash_drag = drag,
        .cause = cause,
    };
}

fn nudgeRaw(current: i128, up: bool) ?i128 {
    if (current <= 0) return null;
    const delta = @divTrunc(current, 5);
    if (delta <= 0) return null;
    return if (up) current + delta else current - delta;
}

const NudgeField = enum { min_trade, daily_cap, cooldown, trend, sell_exempt };

fn nudged(base: dynamic.Params, field: NudgeField, up: bool) ?dynamic.Params {
    var p = base;
    switch (field) {
        .min_trade => {
            const n = nudgeRaw(base.min_trade_equity_frac.raw, up) orelse return null;
            p.min_trade_equity_frac = Decimal.fromRaw(n);
        },
        .daily_cap => {
            const n = nudgeRaw(base.daily_trade_cap, up) orelse return null;
            if (n < 0 or n > std.math.maxInt(u32)) return null;
            p.daily_trade_cap = @intCast(n);
        },
        .cooldown => {
            const n = nudgeRaw(base.reverse_cooldown_ms, up) orelse return null;
            p.reverse_cooldown_ms = @intCast(n);
        },
        .trend => {
            const n = nudgeRaw(base.trend_ma_period, up) orelse return null;
            if (n < 0 or n > std.math.maxInt(u32)) return null;
            p.trend_ma_period = @intCast(n);
        },
        .sell_exempt => {
            const n = nudgeRaw(base.sell_exempt_drawdown.raw, up) orelse return null;
            p.sell_exempt_drawdown = Decimal.fromRaw(n);
        },
    }
    return p;
}

/// At most eight single-field steps, each within 20% and the absolute
/// bounds. Order is fixed: down then up, across the fields the replay
/// actually scores. One-way knobs and scheduler knobs are left to a manual
/// proposal; a step that `validate` rejects is skipped.
pub fn neighborhood(active: dynamic.Params, out: *[max_candidates]dynamic.Params) usize {
    const fields = [_]NudgeField{ .min_trade, .daily_cap, .cooldown, .trend, .sell_exempt };
    var n: usize = 0;
    for (fields) |field| {
        for ([_]bool{ false, true }) |up| {
            if (n >= max_candidates) return n;
            const cand = nudged(active, field, up) orelse continue;
            const verdict = dynamic.validate(active, cand, 1, 0);
            if (verdict.reason != .ok) continue;
            out[n] = cand;
            n += 1;
        }
    }
    return n;
}

pub fn deteriorated(watch: Watch, live_dd: f64, trades_per_day: f64, elapsed_ms: i64) bool {
    if (live_dd > watch.baseline_drawdown + observe_drawdown_widen) return true;
    if (live_dd > watch.expected_max_drawdown + observe_drawdown_widen) return true;
    if (elapsed_ms >= 3_600_000) {
        const band = @max(watch.baseline_trades_per_day * observe_trade_multiple, watch.baseline_trades_per_day + observe_trade_floor);
        if (trades_per_day > band and trades_per_day >= 2.0) return true;
    }
    return false;
}

/// Best passing candidate whose out-of-sample alpha clears the noise band.
/// Ties keep the earlier index.
pub fn pickBest(cands: []const CandidateView) ?usize {
    var best: ?usize = null;
    var best_imp: f64 = gate.alpha_noise;
    for (cands, 0..) |c, i| {
        if (!c.passed) continue;
        if (c.improvement > best_imp) {
            best = i;
            best_imp = c.improvement;
        }
    }
    return best;
}

pub fn planRound(in: RoundInput) RoundPlan {
    if (in.fault) return .{ .phase = .failed, .reason = "exception" };
    if (in.watch.active and in.now_ms < in.watch.until_ms) {
        const elapsed = in.now_ms - in.watch.started_ms;
        if (deteriorated(in.watch, in.live.drawdown, in.live.trades_per_day, elapsed)) {
            return .{ .phase = .rolled_back, .reason = "observe_deteriorated", .effect = .rollback };
        }
        if (in.mode == .off) return .{ .phase = .skipped, .reason = "switch_off" };
        return .{ .phase = .observe_hold, .reason = "observation_window" };
    }
    const clear = in.watch.active and in.now_ms >= in.watch.until_ms;
    if (in.mode == .off) return .{ .phase = .skipped, .reason = "switch_off", .clear_watch = clear };
    if (in.deviation == null) return .{ .phase = .failed, .reason = "reconcile_unavailable", .clear_watch = clear };
    if (in.deviation.? > in.deviation_threshold) {
        return .{ .phase = .aborted, .reason = "reconcile_deviation", .clear_watch = clear };
    }
    const selected = pickBest(in.candidates);
    if (selected == null) return .{ .phase = .no_candidate, .reason = "no_improvement", .clear_watch = clear };
    if (in.mode == .propose_only) {
        return .{ .phase = .proposed, .reason = "switch_propose_only", .effect = .propose, .selected = selected, .clear_watch = clear };
    }
    if (!(in.live.drawdown < apply_drawdown_max)) {
        return .{ .phase = .proposed, .reason = "drawdown", .effect = .propose, .selected = selected, .clear_watch = clear };
    }
    if (!in.live.risk_normal) {
        return .{ .phase = .proposed, .reason = "risk_mode", .effect = .propose, .selected = selected, .clear_watch = clear };
    }
    if (in.live.last_apply_ms > 0 and in.now_ms - in.live.last_apply_ms < dynamic.day_ms) {
        return .{ .phase = .proposed, .reason = "too_soon", .effect = .propose, .selected = selected, .clear_watch = clear };
    }
    return .{
        .phase = .applied,
        .reason = "auto_apply",
        .effect = .apply,
        .selected = selected,
        .clear_watch = clear,
        .open_watch = true,
    };
}

// ---------------------------------------------------------------------------
// Storage and the round itself

pub const ReadStatus = enum { ok, bad_id, not_found };

pub fn listJson(database: *db.Db, out: []u8) ![]const u8 {
    var stmt = try database.prepare(
        \\SELECT review_id, ts, status, trigger, summary FROM strategy_reviews
        \\ORDER BY id DESC LIMIT 20
    );
    defer stmt.finalize();
    var w: std.Io.Writer = .fixed(out);
    w.writeByte('[') catch return error.ResponseTooSmall;
    var n: usize = 0;
    while (try stmt.step()) : (n += 1) {
        if (n > 0) w.writeByte(',') catch return error.ResponseTooSmall;
        w.writeAll("{\"review_id\":\"") catch return error.ResponseTooSmall;
        writeEscaped(&w, stmt.columnText(0)) catch return error.ResponseTooSmall;
        w.writeAll("\",\"ts\":\"") catch return error.ResponseTooSmall;
        writeEscaped(&w, stmt.columnText(1)) catch return error.ResponseTooSmall;
        w.writeAll("\",\"status\":\"") catch return error.ResponseTooSmall;
        writeEscaped(&w, stmt.columnText(2)) catch return error.ResponseTooSmall;
        w.writeAll("\",\"trigger\":\"") catch return error.ResponseTooSmall;
        writeEscaped(&w, stmt.columnText(3)) catch return error.ResponseTooSmall;
        w.writeAll("\",\"summary\":\"") catch return error.ResponseTooSmall;
        writeEscaped(&w, stmt.columnText(4)) catch return error.ResponseTooSmall;
        w.writeAll("\"}") catch return error.ResponseTooSmall;
    }
    w.writeByte(']') catch return error.ResponseTooSmall;
    return w.buffered();
}

pub fn getJson(database: *db.Db, id: []const u8, out: []u8) !struct { status: ReadStatus, body: []const u8 } {
    if (!idOk(id)) return .{ .status = .bad_id, .body = "{\"error\":\"bad_id\"}" };
    var stmt = try database.prepare("SELECT report_json FROM strategy_reviews WHERE review_id = ?1");
    defer stmt.finalize();
    try stmt.bindText(1, id);
    if (!try stmt.step()) return .{ .status = .not_found, .body = "{\"error\":\"not_found\"}" };
    const raw = stmt.columnText(0);
    if (raw.len > out.len) return error.ResponseTooSmall;
    @memcpy(out[0..raw.len], raw);
    return .{ .status = .ok, .body = out[0..raw.len] };
}

pub fn execute(
    database: *db.Db,
    min_notional: Decimal,
    now_ms: i64,
    mode: Switch,
    trigger: []const u8,
    live_drawdown: f64,
    risk_normal: bool,
) void {
    finish(database, min_notional, now_ms, mode, trigger, live_drawdown, risk_normal, false);
}

fn finish(
    database: *db.Db,
    min_notional: Decimal,
    now_ms: i64,
    mode: Switch,
    trigger: []const u8,
    live_drawdown: f64,
    risk_normal: bool,
    fault: bool,
) void {
    executeInner(database, min_notional, now_ms, mode, trigger, live_drawdown, risk_normal, fault) catch |err| {
        std.debug.print("[strategy-review] {t}; parameters unchanged\n", .{err});
        failClosed(database, now_ms, trigger) catch {};
    };
}

fn executeInner(
    database: *db.Db,
    min_notional: Decimal,
    now_ms: i64,
    mode: Switch,
    trigger: []const u8,
    live_drawdown: f64,
    risk_normal: bool,
    fault: bool,
) !void {
    if (fault) return error.Injected;
    var watch = try loadWatch(database);
    const live = Live{
        .drawdown = live_drawdown,
        .risk_normal = risk_normal,
        .last_apply_ms = try lastApplyMs(database),
        .trades_per_day = try tradeRate(database, if (watch.active) watch.started_ms else now_ms - dynamic.day_ms, now_ms),
    };
    if (watch.active and now_ms < watch.until_ms) {
        const plan = planRound(.{
            .now_ms = now_ms,
            .mode = mode,
            .deviation = 0,
            .live = live,
            .watch = watch,
        });
        if (plan.effect == .rollback) {
            const outcome = try commitPlan(database, .{
                .now_ms = now_ms,
                .plan = plan,
                .live_drawdown = live_drawdown,
                .trades_per_day = live.trades_per_day,
                .active_version_id = try activeId(database),
                .previous_version_id = watch.previous_version_id,
                .expected_drawdown = watch.expected_max_drawdown,
            });
            try storeRound(database, now_ms, trigger, mode, outcome.phase, outcome.reason, .{}, &.{}, null, null, live, watch, outcome.watch_active, outcome.watch_until);
            return;
        }
        try storeRound(database, now_ms, trigger, mode, plan.phase, plan.reason, .{}, &.{}, null, null, live, watch, true, watch.until_ms);
        return;
    }
    if (watch.active and now_ms >= watch.until_ms) {
        try clearWatch(database);
        watch.active = false;
    }
    if (mode == .off) {
        try storeRound(database, now_ms, trigger, mode, .skipped, "switch_off", .{}, &.{}, null, null, live, .{}, false, 0);
        return;
    }

    const active = (try store.loadActive(database)) orelse return error.NoActive;
    var series = try history.fromDb(heap, database);
    defer series.deinit(heap);
    if (series.bars.items.len < 2) {
        try storeRound(database, now_ms, trigger, mode, .failed, "reconcile_unavailable", .{}, &.{}, null, null, live, .{}, false, 0);
        return;
    }

    const book = (try loadBook(database, series.bars.items)) orelse {
        try storeRound(database, now_ms, trigger, mode, .failed, "reconcile_unavailable", seriesBounds(series.bars.items, series.decisions.items), &.{}, null, null, live, .{}, false, 0);
        return;
    };
    defer heap.free(book.index);
    defer heap.free(book.replay_index);

    var sim = gate.simOf(active.params);
    sim.initial_cash = book.cash;
    sim.initial_btc = book.btc;
    var daily = try backtest.dailyFromBars(heap, series.bars.items);
    defer daily.deinit(heap);
    const flows = try loadFlows(database, series.bars.items[0].ts, series.bars.items[series.bars.items.len - 1].ts);
    defer heap.free(flows);
    const replay = backtest.runWithIndex(
        heap,
        sim,
        "review",
        active.params.guardOf(min_notional),
        series.bars.items,
        daily.items,
        series.decisions.items,
        flows,
        book.replay_index,
    ) catch {
        try storeRound(database, now_ms, trigger, mode, .failed, "replay_failed", seriesBounds(series.bars.items, series.decisions.items), &.{}, null, null, live, .{}, false, 0);
        return;
    };
    const gap = reconcileGap(book.replay_index, book.index);
    const closes = try heap.alloc(f64, series.bars.items.len);
    defer heap.free(closes);
    for (series.bars.items, closes) |bar, *c| c.* = bar.close.toF64Lossy();
    const regime = classifyRegime(closes, replay.twr_return, replay.hold_return, replay.avg_weight);
    const bounds = seriesBounds(series.bars.items, series.decisions.items);

    var params_buf: [max_candidates]dynamic.Params = undefined;
    const n = neighborhood(active.params, &params_buf);
    var views: [max_candidates]CandidateView = undefined;
    var scored: usize = 0;
    const eval_buf = try heap.alloc(u8, 65_536);
    defer heap.free(eval_buf);
    for (params_buf[0..n]) |cand| {
        const report = gate.evaluate(
            heap,
            series.bars.items,
            series.decisions.items,
            active.params,
            cand,
            active.version_id,
            min_notional,
            now_ms,
            .{ .source = "review", .operator = operator_name, .reason = "strategy review candidate" },
            eval_buf,
        ) catch {
            try storeRound(database, now_ms, trigger, mode, .failed, "replay_failed", bounds, views[0..scored], regime, null, live, .{}, false, 0);
            return;
        };
        backtest_api.persist(database, now_ms, &report) catch {
            try storeRound(database, now_ms, trigger, mode, .failed, "backtest_store_failed", bounds, views[0..scored], regime, null, live, .{}, false, 0);
            return;
        };
        views[scored] = .{
            .params = cand,
            .passed = report.passed,
            .improvement = report.oos_alpha_delta,
            .oos_drawdown = report.oos_candidate_drawdown,
        };
        const summary = report.summaryText();
        const copy_len = @min(summary.len, views[scored].summary_buf.len);
        @memcpy(views[scored].summary_buf[0..copy_len], summary[0..copy_len]);
        views[scored].summary_len = copy_len;
        scored += 1;
    }

    const fresh = (try store.loadActive(database)) orelse return error.NoActive;
    if (fresh.version_id != active.version_id) {
        try storeRound(database, now_ms, trigger, mode, .failed, "active_moved", bounds, views[0..scored], regime, null, live, .{}, false, 0);
        return;
    }
    const plan = planRound(.{
        .now_ms = now_ms,
        .mode = mode,
        .deviation = gap,
        .live = live,
        .candidates = views[0..scored],
    });
    if (plan.effect == .none) {
        try storeRound(database, now_ms, trigger, mode, plan.phase, plan.reason, bounds, views[0..scored], regime, plan.selected, live, .{}, false, 0);
        return;
    }
    const sel = plan.selected orelse {
        try storeRound(database, now_ms, trigger, mode, .failed, "exception", bounds, views[0..scored], regime, null, live, .{}, false, 0);
        return;
    };
    const outcome = try commitPlan(database, .{
        .now_ms = now_ms,
        .plan = plan,
        .candidate = views[sel].params,
        .backtest_summary = views[sel].summary(),
        .live_drawdown = live_drawdown,
        .trades_per_day = try tradeRate(database, now_ms - dynamic.day_ms, now_ms),
        .active_version_id = active.version_id,
        .previous_version_id = active.version_id,
        .expected_drawdown = views[sel].oos_drawdown,
    });
    const saved = try loadWatch(database);
    try storeRound(database, now_ms, trigger, mode, outcome.phase, outcome.reason, bounds, views[0..scored], regime, sel, live, saved, outcome.watch_active, outcome.watch_until);
}

const Bounds = struct {
    from_ms: i64 = 0,
    to_ms: i64 = 0,
    bars: usize = 0,
    decisions: usize = 0,
};

fn seriesBounds(bars: []const backtest.Bar, decisions: []const backtest.Decision) Bounds {
    if (bars.len == 0) return .{};
    return .{
        .from_ms = bars[0].ts,
        .to_ms = bars[bars.len - 1].ts,
        .bars = bars.len,
        .decisions = decisions.len,
    };
}

const Commit = struct {
    now_ms: i64,
    plan: RoundPlan,
    candidate: dynamic.Params = .{},
    backtest_summary: []const u8 = "",
    live_drawdown: f64 = 0,
    trades_per_day: f64 = 0,
    active_version_id: i64 = 0,
    previous_version_id: i64 = 0,
    expected_drawdown: f64 = 0,
};

const Outcome = struct {
    phase: Phase,
    reason: []const u8,
    watch_active: bool = false,
    watch_until: i64 = 0,
};

fn commitPlan(database: *db.Db, in: Commit) !Outcome {
    if (in.plan.effect == .rollback) {
        var body: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(&body, "{{\"source\":\"review\",\"operator\":\"{s}\",\"reason\":\"observation deterioration\",\"version_id\":{d},\"expected_active_version\":{d}}}", .{
            operator_name,
            in.previous_version_id,
            in.active_version_id,
        }) catch return error.ResponseTooSmall;
        var out: [4096]u8 = undefined;
        const result = try write.writeApi(database, false, in.now_ms, .rollback, req, &out);
        if (result.status != .ok) {
            return .{ .phase = .failed, .reason = "rollback_rejected" };
        }
        try clearWatch(database);
        return .{ .phase = .rolled_back, .reason = "observe_deteriorated" };
    }
    if (in.plan.effect != .propose and in.plan.effect != .apply) {
        return .{ .phase = in.plan.phase, .reason = in.plan.reason };
    }
    var params_buf: [2048]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&params_buf);
    in.candidate.writeJson(&pw) catch return error.ResponseTooSmall;
    var body: [4096]u8 = undefined;
    const propose_req = std.fmt.bufPrint(&body, "{{\"source\":\"review\",\"operator\":\"{s}\",\"reason\":\"{s}\",\"params\":{s}}}", .{
        operator_name,
        in.plan.reason,
        pw.buffered(),
    }) catch return error.ResponseTooSmall;
    var propose_out: [8192]u8 = undefined;
    const proposed = try write.writeApi(database, false, in.now_ms, .propose, propose_req, &propose_out);
    if (!std.mem.eql(u8, codeOf(proposed.body), "ok")) {
        return .{ .phase = .failed, .reason = "propose_rejected" };
    }
    const pending = jsonFieldInt(proposed.body, "version_id") orelse return error.BadResponse;
    if (in.plan.effect == .propose) {
        return .{ .phase = .proposed, .reason = in.plan.reason };
    }
    var apply_body: [4096]u8 = undefined;
    var aw: std.Io.Writer = .fixed(&apply_body);
    aw.print("{{\"source\":\"review\",\"operator\":\"{s}\",\"reason\":\"auto apply within bounds\",\"version_id\":{d},\"expected_active_version\":{d},\"backtest_summary\":\"", .{
        operator_name,
        pending,
        in.active_version_id,
    }) catch return error.ResponseTooSmall;
    writeEscaped(&aw, in.backtest_summary) catch return error.ResponseTooSmall;
    aw.writeAll("\"}") catch return error.ResponseTooSmall;
    var apply_out: [8192]u8 = undefined;
    const applied = try write.writeApi(database, false, in.now_ms, .apply, aw.buffered(), &apply_out);
    if (applied.status != .ok) {
        return .{ .phase = .proposed, .reason = "apply_rejected" };
    }
    const new_id = jsonFieldInt(applied.body, "active_version_id") orelse pending;
    const until = in.now_ms + observe_ms;
    try saveWatch(database, .{
        .active = true,
        .started_ms = in.now_ms,
        .until_ms = until,
        .previous_version_id = in.active_version_id,
        .applied_version_id = new_id,
        .baseline_drawdown = in.live_drawdown,
        .baseline_trades_per_day = in.trades_per_day,
        .expected_max_drawdown = in.expected_drawdown,
    });
    return .{ .phase = .applied, .reason = "auto_apply", .watch_active = true, .watch_until = until };
}

fn failClosed(database: *db.Db, now_ms: i64, trigger: []const u8) !void {
    try storeRound(database, now_ms, trigger, .auto, .failed, "exception", .{}, &.{}, null, null, .{}, .{}, false, 0);
}

const Book = struct {
    cash: Decimal,
    btc: Decimal,
    index: []f64,
    replay_index: []f64,
};

fn loadBook(database: *db.Db, bars: []const backtest.Bar) !?Book {
    if (bars.len < 2) return null;
    var from_buf: [40]u8 = undefined;
    var to_buf: [40]u8 = undefined;
    const from_ts = try stamp(bars[0].ts, &from_buf);
    const to_ts = try stamp(bars[bars.len - 1].ts + history.bar_ms, &to_buf);
    var stmt = try database.prepare(
        \\SELECT ts, equity, cash, btc_qty, btc_value, bid_price, capital_flow FROM equity_samples
        \\WHERE interval = '1m' AND ts >= ?1 AND ts <= ?2
        \\ORDER BY ts ASC LIMIT 80000
    );
    defer stmt.finalize();
    try stmt.bindText(1, from_ts);
    try stmt.bindText(2, to_ts);
    var samples: std.ArrayList(struct { ts: i64, perf: f64, cash: f64, btc: f64 }) = .empty;
    defer samples.deinit(heap);
    var cum: f64 = 0;
    while (try stmt.step()) {
        const ts = clock.parseRfc3339Ms(stmt.columnText(0)) catch continue;
        const equity = parseF64(stmt.columnText(1)) orelse continue;
        const flow = parseF64(stmt.columnText(6)) orelse 0;
        cum += flow;
        const perf = equity - cum;
        if (!std.math.isFinite(perf)) continue;
        const cash = parseF64(stmt.columnText(2)) orelse 0;
        var btc = parseF64(stmt.columnText(3)) orelse 0;
        if (btc == 0) {
            const btc_value = parseF64(stmt.columnText(4)) orelse 0;
            const bid = parseF64(stmt.columnText(5)) orelse 0;
            if (bid > 0 and btc_value > 0) btc = btc_value / bid;
        }
        try samples.append(heap, .{ .ts = ts, .perf = perf, .cash = cash, .btc = btc });
    }
    if (samples.items.len < 2) return null;
    const index = try heap.alloc(f64, bars.len);
    errdefer heap.free(index);
    const replay_index = try heap.alloc(f64, bars.len);
    errdefer heap.free(replay_index);
    @memset(replay_index, 0);
    var si: usize = 0;
    var last: f64 = 0;
    var have = false;
    var cash0: f64 = 0;
    var btc0: f64 = 0;
    var took_start = false;
    for (bars, 0..) |bar, i| {
        const bar_end = bar.ts + history.bar_ms;
        while (si < samples.items.len and samples.items[si].ts < bar_end) : (si += 1) {
            last = samples.items[si].perf;
            have = true;
            if (!took_start) {
                cash0 = samples.items[si].cash;
                btc0 = samples.items[si].btc;
                took_start = true;
            }
        }
        if (!have) {
            heap.free(replay_index);
            heap.free(index);
            return null;
        }
        index[i] = last;
    }
    if (!(index[0] > 0)) {
        heap.free(replay_index);
        heap.free(index);
        return null;
    }
    const base = index[0];
    for (index) |*v| v.* = v.* / base;
    var cash_buf: [64]u8 = undefined;
    var btc_buf: [64]u8 = undefined;
    const cash_s = std.fmt.bufPrint(&cash_buf, "{d:.8}", .{cash0}) catch "0";
    const btc_s = std.fmt.bufPrint(&btc_buf, "{d:.8}", .{btc0}) catch "0";
    const cash = Decimal.parseLossy(cash_s) catch Decimal.zero;
    const btc = Decimal.parseLossy(btc_s) catch Decimal.zero;
    if (!cash.gt(Decimal.zero) and !btc.gt(Decimal.zero)) {
        heap.free(replay_index);
        heap.free(index);
        return null;
    }
    return .{ .cash = cash, .btc = btc, .index = index, .replay_index = replay_index };
}

fn loadFlows(database: *db.Db, from_ms: i64, to_ms: i64) ![]backtest.Flow {
    var from_buf: [40]u8 = undefined;
    var to_buf: [40]u8 = undefined;
    const from_ts = try stamp(from_ms, &from_buf);
    const to_ts = try stamp(to_ms, &to_buf);
    var stmt = try database.prepare(
        \\SELECT ts, cash_delta, btc_delta FROM capital_flows
        \\WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts ASC LIMIT 4000
    );
    defer stmt.finalize();
    try stmt.bindText(1, from_ts);
    try stmt.bindText(2, to_ts);
    var list: std.ArrayList(backtest.Flow) = .empty;
    errdefer list.deinit(heap);
    while (try stmt.step()) {
        const ts = clock.parseRfc3339Ms(stmt.columnText(0)) catch continue;
        const cash = Decimal.parse(stmt.columnText(1)) catch continue;
        const btc = Decimal.parse(stmt.columnText(2)) catch continue;
        try list.append(heap, .{ .ts = ts, .cash = cash, .btc = btc });
    }
    return list.toOwnedSlice(heap) catch return error.OutOfMemory;
}

fn parseF64(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    const d = Decimal.parse(s) catch return null;
    const v = d.toF64Lossy();
    if (!std.math.isFinite(v)) return null;
    return v;
}

fn loadWatch(database: *db.Db) !Watch {
    var stmt = try database.prepare(
        \\SELECT active, started_ms, until_ms, previous_version_id, applied_version_id,
        \\       baseline_drawdown, baseline_trades_per_day, expected_max_drawdown
        \\FROM strategy_review_watch WHERE id = 1
    );
    defer stmt.finalize();
    if (!try stmt.step()) return .{};
    return .{
        .active = stmt.columnInt(0) == 1,
        .started_ms = stmt.columnInt(1),
        .until_ms = stmt.columnInt(2),
        .previous_version_id = stmt.columnInt(3),
        .applied_version_id = stmt.columnInt(4),
        .baseline_drawdown = stmt.columnFloat(5),
        .baseline_trades_per_day = stmt.columnFloat(6),
        .expected_max_drawdown = stmt.columnFloat(7),
    };
}

fn saveWatch(database: *db.Db, watch: Watch) !void {
    var stmt = try database.prepare(
        \\INSERT INTO strategy_review_watch (
        \\  id, active, started_ms, until_ms, previous_version_id, applied_version_id,
        \\  baseline_drawdown, baseline_trades_per_day, expected_max_drawdown
        \\) VALUES (1, 1, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
        \\ON CONFLICT(id) DO UPDATE SET
        \\  active = 1, started_ms = ?1, until_ms = ?2, previous_version_id = ?3,
        \\  applied_version_id = ?4, baseline_drawdown = ?5, baseline_trades_per_day = ?6,
        \\  expected_max_drawdown = ?7
    );
    defer stmt.finalize();
    try stmt.bindInt(1, watch.started_ms);
    try stmt.bindInt(2, watch.until_ms);
    try stmt.bindInt(3, watch.previous_version_id);
    try stmt.bindInt(4, watch.applied_version_id);
    try stmt.bindFloat(5, watch.baseline_drawdown);
    try stmt.bindFloat(6, watch.baseline_trades_per_day);
    try stmt.bindFloat(7, watch.expected_max_drawdown);
    _ = try stmt.stepCritical();
}

fn clearWatch(database: *db.Db) !void {
    try database.execAll("UPDATE strategy_review_watch SET active = 0 WHERE id = 1");
}

fn activeId(database: *db.Db) !i64 {
    const snap = (try store.loadActive(database)) orelse return error.NoActive;
    return snap.version_id;
}

fn lastApplyMs(database: *db.Db) !i64 {
    var stmt = try database.prepare(
        \\SELECT ts FROM param_audit
        \\WHERE action = 'apply' AND instr(detail_json, '"code":"ok"') > 0
        \\ORDER BY id DESC LIMIT 1
    );
    defer stmt.finalize();
    if (!try stmt.step()) return 0;
    return clock.parseRfc3339Ms(stmt.columnText(0)) catch error.Clock;
}

fn tradeRate(database: *db.Db, since_ms: i64, now_ms: i64) !f64 {
    if (now_ms <= since_ms) return 0;
    var from_buf: [40]u8 = undefined;
    var to_buf: [40]u8 = undefined;
    const from_ts = try stamp(since_ms, &from_buf);
    const to_ts = try stamp(now_ms, &to_buf);
    var stmt = try database.prepare("SELECT COUNT(*) FROM fills WHERE ts >= ?1 AND ts <= ?2");
    defer stmt.finalize();
    try stmt.bindText(1, from_ts);
    try stmt.bindText(2, to_ts);
    if (!try stmt.step()) return 0;
    const count = stmt.columnInt(0);
    if (count <= 0) return 0;
    const days = @as(f64, @floatFromInt(now_ms - since_ms)) / @as(f64, @floatFromInt(dynamic.day_ms));
    return @as(f64, @floatFromInt(count)) / @max(days, 1.0 / 24.0);
}

fn storeRound(
    database: *db.Db,
    now_ms: i64,
    trigger: []const u8,
    mode: Switch,
    phase: Phase,
    reason: []const u8,
    bounds: Bounds,
    candidates: []const CandidateView,
    regime: ?Regime,
    selected: ?usize,
    live: Live,
    watch: Watch,
    watch_active: bool,
    watch_until: i64,
) !void {
    const body = try heap.alloc(u8, 49_152);
    defer heap.free(body);
    const json = render(body, now_ms, trigger, mode, phase, reason, bounds, candidates, regime, selected, live, watch, watch_active, watch_until) catch return error.ResponseTooSmall;
    var ts_buf: [40]u8 = undefined;
    const ts = try stamp(now_ms, &ts_buf);
    var id_buf: [64]u8 = undefined;
    var count_stmt = try database.prepare("SELECT COUNT(*) FROM strategy_reviews");
    defer count_stmt.finalize();
    const n: i64 = if (try count_stmt.step()) count_stmt.columnInt(0) else 0;
    const id = std.fmt.bufPrint(&id_buf, "sr_{d}_{d}", .{ now_ms, n + 1 }) catch return error.ResponseTooSmall;
    var stmt = try database.prepare(
        \\INSERT INTO strategy_reviews (review_id, ts, as_of_ms, status, trigger, summary, report_json)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    );
    defer stmt.finalize();
    try stmt.bindText(1, id);
    try stmt.bindText(2, ts);
    try stmt.bindInt(3, now_ms);
    try stmt.bindText(4, phase.text());
    try stmt.bindText(5, trigger);
    try stmt.bindText(6, reason);
    try stmt.bindText(7, json);
    _ = try stmt.stepCritical();
}

fn render(
    out: []u8,
    now_ms: i64,
    trigger: []const u8,
    mode: Switch,
    phase: Phase,
    reason: []const u8,
    bounds: Bounds,
    candidates: []const CandidateView,
    regime: ?Regime,
    selected: ?usize,
    live: Live,
    watch: Watch,
    watch_active: bool,
    watch_until: i64,
) ![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    try w.print("{{\"schema\":\"{s}\",\"as_of_ms\":{d},\"trigger\":\"", .{ schema, now_ms });
    try writeEscaped(&w, trigger);
    try w.print("\",\"mode\":\"{s}\",\"status\":\"{s}\",\"reason\":\"", .{ @tagName(mode), phase.text() });
    try writeEscaped(&w, reason);
    try w.print("\",\"max_drawdown_locked\":\"{f}\",\"data_range\":{{\"from_ms\":{d},\"to_ms\":{d},\"bars\":{d},\"decisions\":{d}}}", .{
        dynamic.max_drawdown_locked,
        bounds.from_ms,
        bounds.to_ms,
        bounds.bars,
        bounds.decisions,
    });
    try w.writeAll(",\"regime\":");
    if (regime) |r| {
        try w.print("{{\"trend\":\"{s}\",\"volatility\":\"{s}\",\"strategy_return\":{d:.6},\"hold_return\":{d:.6},\"alpha\":{d:.6},\"avg_weight\":{d:.6},\"lag_pp\":{d:.4},\"cash_drag\":{d:.6},\"cause\":\"{s}\"}}", .{
            @tagName(r.trend),
            @tagName(r.volatility),
            r.strategy_return,
            r.hold_return,
            r.alpha,
            r.avg_weight,
            r.lag_pp,
            r.cash_drag,
            r.cause,
        });
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"candidates\":[");
    for (candidates, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"index\":{d},\"passed\":{},\"improvement\":{d:.6},\"oos_drawdown\":{d:.6},\"backtest_summary\":\"", .{
            i,
            c.passed,
            c.improvement,
            c.oos_drawdown,
        });
        try writeEscaped(&w, c.summary());
        try w.writeAll("\"}");
    }
    try w.writeAll("],\"selected_index\":");
    if (selected) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
    try w.print(",\"live\":{{\"drawdown\":{d:.6},\"risk_normal\":{},\"trades_per_day\":{d:.4}}}", .{
        live.drawdown,
        live.risk_normal,
        live.trades_per_day,
    });
    try w.print(",\"observation\":{{\"active\":{},\"until_ms\":{d},\"started_ms\":{d},\"baseline_drawdown\":{d:.6},\"expected_max_drawdown\":{d:.6}}}}}", .{
        watch_active,
        if (watch_active) watch_until else watch.until_ms,
        watch.started_ms,
        watch.baseline_drawdown,
        watch.expected_max_drawdown,
    });
    return w.buffered();
}

fn stamp(now_ms: i64, buf: []u8) ![]const u8 {
    return clock.formatRfc3339Ms(now_ms, buf) catch error.Clock;
}

fn codeOf(body: []const u8) []const u8 {
    const key = "\"code\":\"";
    const at = std.mem.indexOf(u8, body, key) orelse return "";
    const rest = body[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return "";
    return rest[0..end];
}

fn jsonFieldInt(body: []const u8, key: []const u8) ?i64 {
    var needle: [40]u8 = undefined;
    const prefix = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, body, prefix) orelse return null;
    var rest = body[at + prefix.len ..];
    if (rest.len > 0 and rest[0] == '"') return null;
    const end = std.mem.indexOfAny(u8, rest, ",}") orelse return null;
    rest = rest[0..end];
    return std.fmt.parseInt(i64, rest, 10) catch null;
}

fn idOk(id: []const u8) bool {
    if (id.len < 4 or id.len > 80) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
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
const config = @import("../config.zig");

const sample_candidates = [_]CandidateView{
    .{ .passed = true, .improvement = 0.02, .oos_drawdown = 0.03 },
};

fn calm(now_ms: i64) RoundInput {
    return .{
        .now_ms = now_ms,
        .mode = .auto,
        .deviation = 0.01,
        .live = .{ .drawdown = 0.01, .risk_normal = true, .last_apply_ms = 0, .trades_per_day = 0.5 },
        .candidates = &sample_candidates,
    };
}

test "reconcile deviation aborts the round and does not select a candidate" {
    const gap = reconcileGap(&[_]f64{ 1.0, 1.01, 1.02 }, &[_]f64{ 1.0, 1.08, 1.20 });
    try testing.expect(gap.? > reconcile_deviation_max);
    var in = calm(1_700_000_000_000);
    in.deviation = gap;
    const plan = planRound(in);
    try testing.expectEqual(Phase.aborted, plan.phase);
    try testing.expectEqual(Effect.none, plan.effect);
    try testing.expectEqualStrings("reconcile_deviation", plan.reason);
    try testing.expect(plan.selected == null);
    try testing.expect(reconcileGap(&[_]f64{1.0}, &[_]f64{ 1.0, 1.1 }) == null);
}

test "apply requires drawdown under 5 percent, NORMAL, and an open 24h gate" {
    const now: i64 = 1_700_000_000_000;
    const ok = planRound(calm(now));
    try testing.expectEqual(Phase.applied, ok.phase);
    try testing.expectEqual(Effect.apply, ok.effect);
    try testing.expect(ok.open_watch);

    var deep = calm(now);
    deep.live.drawdown = 0.05;
    try testing.expectEqual(Effect.propose, planRound(deep).effect);
    try testing.expectEqualStrings("drawdown", planRound(deep).reason);

    var stressed = calm(now);
    stressed.live.risk_normal = false;
    try testing.expectEqualStrings("risk_mode", planRound(stressed).reason);
    try testing.expectEqual(Effect.propose, planRound(stressed).effect);

    var recent = calm(now);
    recent.live.last_apply_ms = now - dynamic.day_ms + 1;
    try testing.expectEqualStrings("too_soon", planRound(recent).reason);
    try testing.expectEqual(Effect.propose, planRound(recent).effect);

    var aged = calm(now);
    aged.live.last_apply_ms = now - dynamic.day_ms;
    try testing.expectEqual(Effect.apply, planRound(aged).effect);
}

test "observation rolls back on deterioration and blocks a new change" {
    const now: i64 = 1_700_000_000_000;
    var in = calm(now);
    in.watch = .{
        .active = true,
        .started_ms = now - 3_600_000,
        .until_ms = now + observe_ms,
        .previous_version_id = 1,
        .applied_version_id = 2,
        .baseline_drawdown = 0.01,
        .baseline_trades_per_day = 1,
        .expected_max_drawdown = 0.03,
    };
    const held = planRound(in);
    try testing.expectEqual(Phase.observe_hold, held.phase);
    try testing.expectEqual(Effect.none, held.effect);
    try testing.expect(held.selected == null);

    in.live.drawdown = 0.04;
    const rolled = planRound(in);
    try testing.expectEqual(Phase.rolled_back, rolled.phase);
    try testing.expectEqual(Effect.rollback, rolled.effect);

    in.live.drawdown = 0.01;
    in.live.trades_per_day = 6;
    try testing.expectEqual(Effect.rollback, planRound(in).effect);

    in.live.trades_per_day = 0.5;
    in.now_ms = in.watch.until_ms;
    in.watch.until_ms = in.now_ms;
    const after = planRound(in);
    try testing.expectEqual(Effect.apply, after.effect);
    try testing.expect(after.clear_watch);
}

test "the switch is auto, propose-only, or off" {
    const now: i64 = 1_700_000_000_000;
    var off = calm(now);
    off.mode = .off;
    const skipped = planRound(off);
    try testing.expectEqual(Phase.skipped, skipped.phase);
    try testing.expectEqual(Effect.none, skipped.effect);

    var only = calm(now);
    only.mode = .propose_only;
    const proposed = planRound(only);
    try testing.expectEqual(Phase.proposed, proposed.phase);
    try testing.expectEqual(Effect.propose, proposed.effect);
    try testing.expect(!proposed.open_watch);

    try testing.expectEqual(Effect.apply, planRound(calm(now)).effect);
    try testing.expect(parseSwitch("auto") == .auto);
    try testing.expect(parseSwitch("propose_only") == .propose_only);
    try testing.expect(parseSwitch("off") == .off);
    try testing.expect(parseSwitch("live") == null);
}

test "an injected fault does not select an effect" {
    var in = calm(1_700_000_000_000);
    in.fault = true;
    const plan = planRound(in);
    try testing.expectEqual(Phase.failed, plan.phase);
    try testing.expectEqual(Effect.none, plan.effect);
}

test "low position explains a hold-relative lag and the neighborhood stays inside 20 percent" {
    var closes: [16]f64 = undefined;
    var i: usize = 0;
    while (i < closes.len) : (i += 1) {
        closes[i] = 100.0 + @as(f64, @floatFromInt(i));
    }
    const regime = classifyRegime(&closes, 0.023, 0.10, 0.23);
    try testing.expectEqual(Trend.up, regime.trend);
    try testing.expectEqualStrings("low_position", regime.cause);
    try testing.expectApproxEqAbs(@as(f64, 7.7), regime.lag_pp, 0.05);
    try testing.expect(regime.cash_drag > 0.07);

    var buf: [max_candidates]dynamic.Params = undefined;
    const n = neighborhood(dynamic.Params{}, &buf);
    try testing.expectEqual(max_candidates, n);
    var again: [max_candidates]dynamic.Params = undefined;
    try testing.expectEqual(n, neighborhood(dynamic.Params{}, &again));
    for (buf, again) |a, b| try testing.expect(a.eql(b));
    const base = dynamic.Params{};
    for (buf) |cand| {
        const verdict = dynamic.validate(base, cand, 1, 0);
        try testing.expectEqual(dynamic.Reason.ok, verdict.reason);
        try testing.expect(cand.position_cap.eql(base.position_cap));
        try testing.expect(cand.price_shock.eql(base.price_shock));
        try testing.expect(cand.exit_reserve.eql(base.exit_reserve));
        try testing.expect(!@hasField(dynamic.Params, "max_drawdown"));
    }
}

fn boot() !struct { database: db.Db, cfg: config.Config } {
    var database = try db.Db.open(":memory:");
    errdefer database.close();
    var cfg = try config.parse(testing.allocator, "");
    errdefer cfg.deinit();
    _ = try store.ensureActive(&database, &cfg, 1_700_000_000_000);
    return .{ .database = database, .cfg = cfg };
}

fn insertFlatMarks(database: *db.Db, equity_last: []const u8) !void {
    const bar_ms: i64 = 15 * 60_000;
    const t0: i64 = @divFloor(1_700_000_000_000, bar_ms) * bar_ms;
    var i: usize = 0;
    while (i < 45) : (i += 1) {
        var ts_buf: [40]u8 = undefined;
        const ts = try clock.formatRfc3339Ms(t0 + @as(i64, @intCast(i)) * 60_000, &ts_buf);
        const equity: []const u8 = if (i + 1 == 45) equity_last else "1000";
        var stmt = try database.prepare(
            \\INSERT INTO equity_samples (ts, interval, equity, hwm, drawdown, cash, btc_value, bid_price, btc_qty, capital_flow)
            \\VALUES (?1, '1m', ?2, ?2, '0', ?2, '0', '100', '0', '')
        );
        defer stmt.finalize();
        try stmt.bindText(1, ts);
        try stmt.bindText(2, equity);
        _ = try stmt.stepCritical();
    }
}

fn activeVersion(database: *db.Db) !i64 {
    const snap = (try store.loadActive(database)).?;
    return snap.version_id;
}

fn expectStatus(database: *db.Db, want: []const u8) !void {
    var stmt = try database.prepare("SELECT status FROM strategy_reviews ORDER BY id DESC LIMIT 1");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings(want, stmt.columnText(0));
}

test "a divergent equity curve aborts and leaves the active version" {
    var env = try boot();
    defer env.database.close();
    defer env.cfg.deinit();
    try insertFlatMarks(&env.database, "1300");
    const before = try activeVersion(&env.database);
    execute(&env.database, Decimal.zero, 1_700_003_000_000, .auto, "schedule", 0.01, true);
    try testing.expectEqual(before, try activeVersion(&env.database));
    var stmt = try env.database.prepare("SELECT status, summary FROM strategy_reviews ORDER BY id DESC LIMIT 1");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("aborted", stmt.columnText(0));
    try testing.expectEqualStrings("reconcile_deviation", stmt.columnText(1));
    const list_buf = try testing.allocator.alloc(u8, 2048);
    defer testing.allocator.free(list_buf);
    const listed = try listJson(&env.database, list_buf);
    try testing.expect(std.mem.indexOf(u8, listed, "aborted") != null);
}

test "switch off and an injected exception do not change parameters" {
    var env = try boot();
    defer env.database.close();
    defer env.cfg.deinit();
    const before = try activeVersion(&env.database);
    execute(&env.database, Decimal.zero, 1_700_003_000_000, .off, "manual", 0.2, false);
    try testing.expectEqual(before, try activeVersion(&env.database));
    try expectStatus(&env.database, "skipped");

    finish(&env.database, Decimal.zero, 1_700_004_000_000, .auto, "schedule", 0.01, true, true);
    try testing.expectEqual(before, try activeVersion(&env.database));
    var stmt = try env.database.prepare(
        \\SELECT COUNT(*) FROM param_audit
        \\WHERE action = 'apply' AND instr(detail_json, '"code":"ok"') > 0
    );
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    var status = try env.database.prepare("SELECT status FROM strategy_reviews ORDER BY id DESC LIMIT 1");
    defer status.finalize();
    try testing.expect(try status.step());
    try testing.expectEqualStrings("failed", status.columnText(0));
}

test "apply opens a 72h watch and the window blocks then rolls back" {
    var env = try boot();
    defer env.database.close();
    defer env.cfg.deinit();
    const now: i64 = 1_700_000_000_000 + dynamic.day_ms;
    var cand = dynamic.Params{};
    cand.daily_trade_cap = 7;
    var params_buf: [2048]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&params_buf);
    try cand.writeJson(&pw);
    var seed = try env.database.prepare(
        \\INSERT INTO backtest_reports (
        \\  id, created_ts, as_of_ms, passed, params_json, baseline_json,
        \\  baseline_version_id, range_hash, digest, report_json
        \\) VALUES ('bt_review', '2023-11-14T22:13:20.000Z', ?1, 1, ?2, '{}', 1, 'abc', 'digest1', '{}')
    );
    defer seed.finalize();
    try seed.bindInt(1, now);
    try seed.bindText(2, pw.buffered());
    _ = try seed.stepCritical();
    var summary_buf: [256]u8 = undefined;
    const summary_text = try std.fmt.bufPrint(&summary_buf, "{{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_review\",\"passed\":true,\"digest\":\"digest1\",\"as_of_ms\":{d}}}", .{now});
    const outcome = try commitPlan(&env.database, .{
        .now_ms = now,
        .plan = .{ .phase = .applied, .reason = "auto_apply", .effect = .apply, .open_watch = true, .selected = 0 },
        .candidate = cand,
        .backtest_summary = summary_text,
        .live_drawdown = 0.01,
        .trades_per_day = 0.5,
        .active_version_id = 1,
        .previous_version_id = 1,
        .expected_drawdown = 0.02,
    });
    try testing.expectEqual(Phase.applied, outcome.phase);
    try testing.expect(outcome.watch_active);
    try testing.expectEqual(now + observe_ms, outcome.watch_until);
    try testing.expectEqual(@as(i64, 2), try activeVersion(&env.database));

    var audit = try env.database.prepare("SELECT source FROM param_audit WHERE action = 'apply' ORDER BY id DESC LIMIT 1");
    defer audit.finalize();
    try testing.expect(try audit.step());
    try testing.expectEqualStrings("review", audit.columnText(0));

    const held_at = now + 3_600_000;
    execute(&env.database, Decimal.zero, held_at, .auto, "schedule", 0.01, true);
    try testing.expectEqual(@as(i64, 2), try activeVersion(&env.database));
    try expectStatus(&env.database, "observe_hold");

    const bad_at = held_at + 3_600_000;
    execute(&env.database, Decimal.zero, bad_at, .auto, "schedule", 0.08, true);
    const restored = (try store.loadActive(&env.database)).?;
    try testing.expect(restored.params.daily_trade_cap == 6);
    try expectStatus(&env.database, "rolled_back");
    const watch = try loadWatch(&env.database);
    try testing.expect(!watch.active);
}

test "a rejected apply leaves the active version and stores a proposal outcome" {
    var env = try boot();
    defer env.database.close();
    defer env.cfg.deinit();
    var cand = dynamic.Params{};
    cand.daily_trade_cap = 7;
    const outcome = try commitPlan(&env.database, .{
        .now_ms = 1_700_000_000_000 + dynamic.day_ms,
        .plan = .{ .phase = .applied, .reason = "auto_apply", .effect = .apply, .selected = 0 },
        .candidate = cand,
        .backtest_summary = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_missing\",\"passed\":true}",
        .live_drawdown = 0.01,
        .active_version_id = 1,
        .previous_version_id = 1,
    });
    try testing.expectEqual(Phase.proposed, outcome.phase);
    try testing.expectEqualStrings("apply_rejected", outcome.reason);
    try testing.expect(!outcome.watch_active);
    try testing.expectEqual(@as(i64, 1), try activeVersion(&env.database));
}

test "get_review reads one stored report and rejects a bad id" {
    var env = try boot();
    defer env.database.close();
    defer env.cfg.deinit();
    execute(&env.database, Decimal.zero, 1_700_003_000_000, .off, "manual", 0.01, true);
    var id_stmt = try env.database.prepare("SELECT review_id FROM strategy_reviews ORDER BY id DESC LIMIT 1");
    defer id_stmt.finalize();
    try testing.expect(try id_stmt.step());
    var id_buf: [80]u8 = undefined;
    const id_raw = id_stmt.columnText(0);
    try testing.expect(id_raw.len <= id_buf.len);
    @memcpy(id_buf[0..id_raw.len], id_raw);
    const id = id_buf[0..id_raw.len];
    var buf: [8192]u8 = undefined;
    const got = try getJson(&env.database, id, &buf);
    try testing.expectEqual(ReadStatus.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"max_drawdown_locked\":\"0.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "skipped") != null);
    const bad = try getJson(&env.database, "nope id", &buf);
    try testing.expectEqual(ReadStatus.bad_id, bad.status);
}
