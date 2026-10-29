//! Risk Kernel glue shared by the agent path and operator paths: derives the
//! admission view from an engine snapshot and flattens the verdict for
//! journaling. Pure — no I/O; verdict math lives in `admission.zig`.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const config = @import("../config.zig");
const admission = @import("admission.zig");

const Decimal = dec.Decimal;

/// Text written to `AGENT_PROPOSAL_OK` payload `admission.verdict`.
/// Periodic-review counters compare against these exact strings.
/// `REDUCE` is only the reduced bucket; it is not also counted as approved.
pub const verdict_approve: []const u8 = "APPROVE";
pub const verdict_reduce: []const u8 = "REDUCE";
pub const verdict_reject: []const u8 = "REJECT";

/// Maps a kernel verdict onto the string persisted in the event payload.
pub fn storedVerdictText(verdict: admission.Verdict) []const u8 {
    return switch (verdict) {
        .approve => verdict_approve,
        .approve_reduced => verdict_reduce,
        .reject => verdict_reject,
    };
}

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
        .unresolved_orders = snap.unresolved_orders or snap.foreign_pending,
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
    return shadowAdmitWith(snap, proposal_snapshot_version, target_btc_weight, cfg, defaultStressParams(cfg), now_ms);
}

/// Agent decision path: same kernel, with the active version's shock and reserve.
/// At the shipped defaults this is identical to `shadowAdmit`.
pub fn shadowAdmitWith(
    snap: state.PortfolioState,
    proposal_snapshot_version: u64,
    target_btc_weight: Decimal,
    cfg: *const config.Config,
    stress: admission.StressParams,
    now_ms: i64,
) ShadowAdmission {
    const view = admissionView(snap, now_ms);
    const prop = admission.ProposalView{
        .snapshot_version = proposal_snapshot_version,
        .target_btc_weight = target_btc_weight,
    };
    const result = admission.admit(view, prop, cfg.max_drawdown, stress) catch {
        return .{
            .verdict_txt = "ERROR",
            .reason_txt = "admission_math_error",
            .admitted_weight = Decimal.zero,
            .stress_equity = Decimal.zero,
            .floor = Decimal.zero,
        };
    };
    const verdict_txt = storedVerdictText(result.verdict);
    return switch (result.verdict) {
        .approve => |w| .{
            .verdict_txt = verdict_txt,
            .reason_txt = "ok",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .approve_reduced => |w| .{
            .verdict_txt = verdict_txt,
            .reason_txt = "reduced_to_boundary",
            .admitted_weight = w,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
        .reject => |r| .{
            .verdict_txt = verdict_txt,
            .reason_txt = r.text(),
            .admitted_weight = Decimal.zero,
            .stress_equity = result.stress_equity,
            .floor = result.floor,
        },
    };
}

test "stored admission verdict text is APPROVE, REDUCE, or REJECT" {
    try std.testing.expectEqualStrings("APPROVE", verdict_approve);
    try std.testing.expectEqualStrings("REDUCE", verdict_reduce);
    try std.testing.expectEqualStrings("REJECT", verdict_reject);
    try std.testing.expectEqualStrings(verdict_approve, storedVerdictText(.{ .approve = Decimal.zero }));
    try std.testing.expectEqualStrings(verdict_reduce, storedVerdictText(.{ .approve_reduced = Decimal.zero }));
    try std.testing.expectEqualStrings(verdict_reject, storedVerdictText(.{ .reject = .boundary_violated }));
}

pub fn exitView(snap: state.PortfolioState, now_ms: i64) admission.ExitView {
    return .{
        .reconciled = snap.reconciled,
        .market_fresh = snap.freshness.marketFresh(now_ms),
        .account_fresh = snap.freshness.accountFresh(now_ms) and !snap.account_projected,
        // Own ledger only: foreign resting orders cannot cause an oversell (the
        // sell is capped by free BTC) and must not stop a risk-reducing exit.
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
