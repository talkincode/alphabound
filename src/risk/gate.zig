//! Risk Kernel glue shared by the agent path and operator paths: derives the
//! admission view from an engine snapshot and flattens the verdict for
//! journaling. Pure — no I/O; verdict math lives in `admission.zig`.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const config = @import("../config.zig");
const admission = @import("admission.zig");

const Decimal = dec.Decimal;

/// Shadow-path Risk Kernel admission (audit only — never places orders).
pub const ShadowAdmission = struct {
    verdict_txt: []const u8,
    reason_txt: []const u8,
    admitted_weight: Decimal,
    stress_equity: Decimal,
    floor: Decimal,
};

pub fn defaultStressParams(cfg: *const config.Config) admission.StressParams {
    return .{
        .price_shock = Decimal.parse("0.05") catch Decimal.zero,
        .trade_fee_rate = cfg.taker_fee_rate,
        .trade_slippage_rate = cfg.slippage_rate,
        .exit_costs = .{ .fee_rate = cfg.taker_fee_rate, .slippage_rate = cfg.slippage_rate },
        // Small absolute reserve so tiny shadow books still exercise the floor path.
        .exit_reserve = Decimal.parse("0.50") catch Decimal.zero,
    };
}

pub fn admissionView(
    snap: state.PortfolioState,
    now_ms: i64,
) admission.SnapshotView {
    return .{
        .version = snap.version,
        .reconciled = snap.reconciled,
        .market_fresh = snap.freshness.marketFresh(now_ms),
        .account_fresh = snap.freshness.accountFresh(now_ms) and !snap.account_projected,
        .unresolved_orders = snap.unresolved_orders,
        .risk_mode = snap.risk_mode,
        .cash_usdt = snap.cash_usdt,
        .btc_total = snap.btc_total,
        .liq_price = snap.bid_price,
        .mark_price = if (snap.mark_price.gt(Decimal.zero)) snap.mark_price else snap.bid_price,
        .high_watermark = snap.high_watermark,
    };
}

pub fn shadowAdmit(
    snap: state.PortfolioState,
    proposal_snapshot_version: u64,
    target_btc_weight: Decimal,
    cfg: *const config.Config,
    now_ms: i64,
) ShadowAdmission {
    const view = admissionView(snap, now_ms);
    const prop = admission.ProposalView{
        .snapshot_version = proposal_snapshot_version,
        .target_btc_weight = target_btc_weight,
    };
    const result = admission.admit(view, prop, cfg.max_drawdown, defaultStressParams(cfg)) catch {
        return .{
            .verdict_txt = "ERROR",
            .reason_txt = "admission_math_error",
            .admitted_weight = Decimal.zero,
            .stress_equity = Decimal.zero,
            .floor = Decimal.zero,
        };
    };
    return switch (result.verdict) {
        .approve => |w| .{
            .verdict_txt = "APPROVE",
            .reason_txt = "ok",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .approve_reduced => |w| .{
            .verdict_txt = "REDUCE",
            .reason_txt = "reduced_to_boundary",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .reject => |r| .{
            .verdict_txt = "REJECT",
            .reason_txt = r.text(),
            .admitted_weight = Decimal.zero,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
    };
}

pub fn exitView(snap: state.PortfolioState, now_ms: i64) admission.ExitView {
    return .{
        .reconciled = snap.reconciled,
        .market_fresh = snap.freshness.marketFresh(now_ms),
        .account_fresh = snap.freshness.accountFresh(now_ms) and !snap.account_projected,
        .unresolved_orders = snap.unresolved_orders,
        .risk_mode = snap.risk_mode,
        .btc_total = snap.btc_total,
        .btc_available = snap.btc_available,
    };
}

/// Emergency-exit admission for FLATTENING / EXIT_ONLY books (see `admitExit`).
pub fn exitAdmit(snap: state.PortfolioState, now_ms: i64) admission.ExitVerdict {
    return admission.admitExit(exitView(snap, now_ms));
}
