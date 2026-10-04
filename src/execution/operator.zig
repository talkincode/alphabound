//! Operator-driven execution entry points (flatten drive, target-weight probe)
//! and the pre-admission refresh shared with the agent path. Extracted from
//! main.zig so the full chain (admission → planner → venue) is testable.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const storage = @import("../storage/db.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const okx_trade = @import("okx_trade.zig");
const demo_runner = @import("demo_runner.zig");
const planner = @import("planner.zig");
const proposal = @import("../agent/proposal.zig");
const gate = @import("../risk/gate.zig");
const journal = @import("../observability/journal.zig");

const Decimal = dec.Decimal;
const logEventPayload = journal.logEventPayload;

/// Everything an execution entry point needs. Borrowed; owned by the caller.
pub const Env = struct {
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    db: *storage.Db,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    refresher: demo_runner.PortfolioRefresher,
    instrument: planner.Instrument,
    /// OKX_SIMULATED=1 (demo) or OKX_REAL_MONEY_OK=1 (live).
    venue_authorized: bool,
};

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

fn decFmt(buf: []u8, v: Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

/// Pull fresh ticker (+ demo private balances) into the engine immediately before
/// admission/execution. LLM calls routinely exceed market_ttl_ms (10s).
pub fn refreshBeforeAdmission(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    portfolio_refresher: demo_runner.PortfolioRefresher,
) void {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/api/v5/market/ticker?instId={s}", .{cfg.instrument}) catch return;
    if (okx.getPublic(path)) |body| {
        defer gpa.free(body);
        if (okx_rest.parseTicker(gpa, body)) |ticker| {
            _ = engine.apply(.{ .market_tick = .{
                .ts_ms = ticker.ts_ms,
                .bid = ticker.bid,
                .mark = ticker.last,
            } }) catch {};
        } else |_| {}
    } else |_| {}
    if (cfg.mode.isTrading()) {
        _ = portfolio_refresher.run();
    }
}

fn isDust(snap: state.PortfolioState, instrument: planner.Instrument) bool {
    const dust = if (instrument.min_size.gt(Decimal.zero)) instrument.min_size else (Decimal.parse("0.00001") catch Decimal.zero);
    return snap.btc_total.isZero() or snap.btc_total.lt(dust);
}

/// The book is a statement about the venue only if it is a fresh venue balance.
fn authoritative(snap: state.PortfolioState) bool {
    return snap.reconciled and !snap.account_projected and snap.freshness.accountFresh(nowMs());
}

fn completeFlatten(env: Env, snap: state.PortfolioState) void {
    const prev = snap.risk_mode;
    _ = env.engine.apply(.{ .risk_trigger = .flatten_complete }) catch {};
    const now_mode = env.engine.snapshot().risk_mode;
    std.debug.print("[admin] flatten-complete {t} -> {t} (btc dust)\n", .{ prev, now_mode });
    var fb: [192]u8 = undefined;
    const fp = std.fmt.bufPrint(
        &fb,
        "{{\"from\":\"{t}\",\"to\":\"{t}\",\"trigger\":\"flatten_complete\"}}",
        .{ prev, now_mode },
    ) catch "{\"trigger\":\"flatten_complete\"}";
    logEventPayload(env.events_repo, env.engine, "ADMIN_FLATTEN_COMPLETE", "admin", "CRITICAL", env.cfg, fp);
}

/// While risk_mode=FLATTENING: sell toward cash through the strictly
/// risk-reducing exit path; when the venue confirms dust, flatten_complete →
/// HALTED. Never gated on the drawdown boundary (it has already been crossed).
pub fn driveFlatten(env: Env, last_exec_ms: *i64, force: bool) void {
    const engine = env.engine;
    const cfg = env.cfg;
    const events_repo = env.events_repo;
    const snap0 = engine.snapshot();
    if (snap0.risk_mode != .flattening) return;

    // A projected or stale book cannot prove the position is gone.
    if (isDust(snap0, env.instrument) and authoritative(snap0)) {
        completeFlatten(env, snap0);
        return;
    }

    const tnow = nowMs();
    const cooldown_ms: i64 = 15_000;
    if (!force and last_exec_ms.* != 0 and tnow - last_exec_ms.* < cooldown_ms) return;
    last_exec_ms.* = tnow;

    const out = runExit(env);
    std.debug.print("[admin] flatten-drive btc={f} exec={s}\n", .{ snap0.btc_total, out.note });
    var pb: [256]u8 = undefined;
    var btc_buf: [48]u8 = undefined;
    const bs = decFmt(&btc_buf, snap0.btc_total);
    const payload = std.fmt.bufPrint(
        &pb,
        "{{\"btc_total\":\"{s}\",\"exec\":\"{s}\",\"source\":\"flatten_drive\"}}",
        .{ bs, out.note },
    ) catch "{\"source\":\"flatten_drive\"}";
    logEventPayload(events_repo, engine, "ADMIN_FLATTEN_DRIVE", "admin", "CRITICAL", cfg, payload);

    const snap1 = engine.snapshot();
    if (snap1.risk_mode == .flattening and isDust(snap1, env.instrument) and authoritative(snap1)) {
        completeFlatten(env, snap1);
    }
}

/// Emergency exit: refresh, then sell-only execution under `exitAdmit`.
pub fn runExit(env: Env) TargetOutcome {
    const engine = env.engine;
    const cfg = env.cfg;
    if (!okx_trade.executionAllowed(cfg.mode.isTrading(), env.venue_authorized)) {
        logEventPayload(env.events_repo, engine, "ADMIN_FLATTEN_EXIT", "admin", "WARN", cfg, "{\"error\":\"execution_not_allowed\"}");
        return .{ .note = "exec_off" };
    }
    refreshBeforeAdmission(env.gpa, env.okx, cfg, engine, env.refresher);
    const snap = engine.snapshot();
    const now = nowMs();
    var id_buf: [48]u8 = undefined;
    const decision_id = std.fmt.bufPrint(&id_buf, "dec_exit_{d}", .{now}) catch "dec_exit";
    const verdict = gate.exitAdmit(snap, now);
    const verdict_txt: []const u8 = switch (verdict) {
        .approve => "APPROVE",
        .reject => |r| r.text(),
    };
    const policy = proposal.OrderPolicy{
        .type = .market_only,
        .urgency = Decimal.one,
        .max_wait_ms = 0,
    };
    const exec_note = demo_runner.tryDemoExecute(
        env.gpa,
        env.okx,
        cfg,
        engine,
        env.db,
        env.orders_repo,
        env.fills_repo,
        env.events_repo,
        env.refresher,
        decision_id,
        "APPROVE",
        Decimal.zero,
        env.instrument,
        snap,
        policy,
        .{ .requested_weight = Decimal.zero, .intent = .emergency_exit },
    );
    var pbuf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &pbuf,
        "{{\"decision_id\":\"{s}\",\"exit_admission\":\"{s}\",\"exec\":\"{s}\",\"source\":\"flatten\"}}",
        .{ decision_id, verdict_txt, exec_note },
    ) catch "{\"source\":\"flatten\"}";
    logEventPayload(env.events_repo, engine, "ADMIN_FLATTEN_EXIT", "admin", "CRITICAL", cfg, payload);
    var out = TargetOutcome{ .note = exec_note };
    const line = std.fmt.bufPrint(&out.status_buf, "EXIT {s} admit={s} exec={s}", .{ decision_id, verdict_txt, exec_note }) catch "EXIT";
    out.status_len = line.len;
    return out;
}

pub const TargetOutcome = struct {
    note: []const u8,
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,

    pub fn status(self: *const TargetOutcome) []const u8 {
        return self.status_buf[0..self.status_len];
    }
};

/// Operator path probe: same admission + trading execution stack as agent REBALANCE.
pub fn runTargetWeight(env: Env, weight_s: []const u8) TargetOutcome {
    const engine = env.engine;
    const cfg = env.cfg;
    const events_repo = env.events_repo;
    const target = Decimal.parse(weight_s) catch {
        logEventPayload(events_repo, engine, "ADMIN_TARGET_WEIGHT", "admin", "WARN", cfg, "{\"error\":\"bad_weight\"}");
        return .{ .note = "bad_weight" };
    };
    if (target.isNegative() or target.gt(Decimal.one)) {
        logEventPayload(events_repo, engine, "ADMIN_TARGET_WEIGHT", "admin", "WARN", cfg, "{\"error\":\"weight_out_of_range\"}");
        return .{ .note = "bad_weight" };
    }
    if (!okx_trade.executionAllowed(cfg.mode.isTrading(), env.venue_authorized)) {
        logEventPayload(events_repo, engine, "ADMIN_TARGET_WEIGHT", "admin", "WARN", cfg, "{\"error\":\"execution_not_allowed\"}");
        return .{ .note = "exec_off" };
    }

    refreshBeforeAdmission(env.gpa, env.okx, cfg, engine, env.refresher);
    const snap = engine.snapshot();
    const admit_now = nowMs();
    const admission = gate.shadowAdmit(snap, snap.version, target, cfg, admit_now);

    var id_buf: [48]u8 = undefined;
    const decision_id = std.fmt.bufPrint(&id_buf, "dec_op_tw_{d}", .{admit_now}) catch "dec_op_tw";
    const policy = proposal.OrderPolicy{
        .type = .limit_or_market,
        .urgency = Decimal.parse("0.5") catch Decimal.zero,
        .max_wait_ms = 120_000,
    };
    const exec_note = demo_runner.tryDemoExecute(
        env.gpa,
        env.okx,
        cfg,
        engine,
        env.db,
        env.orders_repo,
        env.fills_repo,
        events_repo,
        env.refresher,
        decision_id,
        admission.verdict_txt,
        admission.admitted_weight,
        env.instrument,
        snap,
        policy,
        .{ .requested_weight = target },
    );

    var wbuf: [48]u8 = undefined;
    var awbuf: [48]u8 = undefined;
    const ws = decFmt(&wbuf, target);
    const aws = decFmt(&awbuf, admission.admitted_weight);
    var pbuf: [384]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &pbuf,
        "{{\"decision_id\":\"{s}\",\"target_btc_weight\":\"{s}\",\"admission\":\"{s}\",\"reason\":\"{s}\",\"admitted_weight\":\"{s}\",\"exec\":\"{s}\",\"source\":\"operator\"}}",
        .{ decision_id, ws, admission.verdict_txt, admission.reason_txt, aws, exec_note },
    ) catch "{\"source\":\"operator\"}";
    logEventPayload(events_repo, engine, "ADMIN_TARGET_WEIGHT", "admin", "CRITICAL", cfg, payload);
    logEventPayload(events_repo, engine, "RISK_ADMISSION", "risk", "INFO", cfg, payload);
    var out = TargetOutcome{ .note = exec_note };
    const line = std.fmt.bufPrint(&out.status_buf, "OP_TW {s} conf=1 admit={s} exec={s}", .{ decision_id, admission.verdict_txt, exec_note }) catch "OP_TW";
    out.status_len = line.len;
    return out;
}

/// Operator cancel-all: cancel every working order and verify the venue and
/// ledger are clear. The order ambiguity is only released on a verified result.
pub fn cancelAll(env: Env) demo_runner.CancelAllReport {
    const report = demo_runner.cancelAllVerified(
        env.gpa,
        env.okx,
        env.cfg,
        env.engine,
        env.db,
        env.orders_repo,
        env.fills_repo,
        env.events_repo,
        okx_trade.executionAllowed(env.cfg.mode.isTrading(), env.venue_authorized),
    );
    var cab: [224]u8 = undefined;
    const cap = std.fmt.bufPrint(
        &cab,
        "{{\"mode\":\"{t}\",\"listed\":{},\"canceled\":{d},\"remaining\":{d},\"verified_clear\":{}}}",
        .{ env.cfg.mode, report.listed, report.canceled, report.remaining, report.verified_clear },
    ) catch "{\"canceled\":0}";
    logEventPayload(env.events_repo, env.engine, "ADMIN_CANCEL_ALL", "admin", "CRITICAL", env.cfg, cap);
    return report;
}
