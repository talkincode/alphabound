//! Proposal validity (README: "state changed ⇒ the old proposal is void").
//!
//! The model decides on one snapshot; by the time the proposal reaches
//! admission, the world has moved (a slow model call routinely spans many
//! ticks). Engine versions churn on every tick, so strict version equality can
//! never hold; the old shortcut rebound a proposal to the *current* snapshot
//! whenever it matched the decision-start version, which let a reasoning about
//! a stale book be checked against fresh balances.
//!
//! Instead the decision keeps an immutable `Anchor` (what the model saw) and
//! admission is only attempted when the execution snapshot is still materially
//! the same situation. Otherwise the proposal is void and the decision is
//! redone on fresh context. Both snapshots are recorded with the proposal.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const sm = @import("../risk/state_machine.zig");

const Decimal = dec.Decimal;

pub const Anchor = struct {
    version: u64,
    ts_ms: i64,
    bid: Decimal,
    btc_total: Decimal,
    cash_usdt: Decimal,
    equity: Decimal,
    risk_mode: sm.RiskMode,
    flow_epoch: u32,
};

pub fn anchorOf(snap: state.PortfolioState, ts_ms: i64) Anchor {
    return .{
        .version = snap.version,
        .ts_ms = ts_ms,
        .bid = snap.bid_price,
        .btc_total = snap.btc_total,
        .cash_usdt = snap.cash_usdt,
        .equity = snap.conservative_equity,
        .risk_mode = snap.risk_mode,
        .flow_epoch = snap.flow_epoch,
    };
}

pub const Limits = struct {
    max_age_ms: i64,
    /// |bid − anchor bid| / anchor bid.
    max_price_drift: Decimal,
    /// |Δcash| / anchor equity and |ΔBTC value| / anchor equity.
    max_book_drift: Decimal,
};

pub const Staleness = enum {
    too_old,
    price_drift,
    book_changed,
    risk_mode_changed,
    capital_flow,
    unresolved_orders,
    unusable_anchor,

    pub fn text(self: Staleness) []const u8 {
        return @tagName(self);
    }
};

pub const Verdict = union(enum) {
    valid,
    stale: Staleness,
};

fn driftExceeds(a: Decimal, b: Decimal, base: Decimal, limit: Decimal) bool {
    const diff = (a.sub(b) catch return true).abs();
    const ratio = diff.div(base, .up) catch return true;
    return ratio.gt(limit);
}

pub fn check(anchor: Anchor, now: state.PortfolioState, now_ms: i64, limits: Limits) Verdict {
    if (!anchor.bid.gt(Decimal.zero) or !anchor.equity.gt(Decimal.zero)) return .{ .stale = .unusable_anchor };
    if (now_ms - anchor.ts_ms > limits.max_age_ms) return .{ .stale = .too_old };
    if (now.risk_mode != anchor.risk_mode) return .{ .stale = .risk_mode_changed };
    if (now.flow_epoch != anchor.flow_epoch) return .{ .stale = .capital_flow };
    if (now.unresolved_orders) return .{ .stale = .unresolved_orders };
    if (!now.bid_price.gt(Decimal.zero)) return .{ .stale = .price_drift };
    if (driftExceeds(now.bid_price, anchor.bid, anchor.bid, limits.max_price_drift)) return .{ .stale = .price_drift };
    if (driftExceeds(now.cash_usdt, anchor.cash_usdt, anchor.equity, limits.max_book_drift)) return .{ .stale = .book_changed };
    const mark = if (now.mark_price.gt(Decimal.zero)) now.mark_price else now.bid_price;
    const held_then = anchor.btc_total.mul(mark, .down) catch return .{ .stale = .book_changed };
    const held_now = now.btc_total.mul(mark, .down) catch return .{ .stale = .book_changed };
    if (driftExceeds(held_now, held_then, anchor.equity, limits.max_book_drift)) return .{ .stale = .book_changed };
    return .valid;
}

/// Snapshot version the execution-time admission is checked against.
///
/// Only a still-valid proposal that cites the snapshot the model actually saw
/// is bound to the execution snapshot (explicitly; both versions are recorded
/// with the decision). A proposal citing any other version keeps it and fails
/// admission; a void proposal is never bound.
pub fn bindExecutionVersion(proposal_version: u64, anchor: Anchor, exec_version: u64, verdict: Verdict) ?u64 {
    if (verdict != .valid) return null;
    if (proposal_version != anchor.version) return proposal_version;
    return exec_version;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

const test_limits = Limits{ .max_age_ms = 300_000, .max_price_drift = d("0.01"), .max_book_drift = d("0.01") };

fn baseSnap() state.PortfolioState {
    return .{
        .version = 10,
        .as_of_ms = 1_000,
        .cash_usdt = d("500"),
        .btc_total = d("0.005"),
        .btc_available = d("0.005"),
        .bid_price = d("100000"),
        .mark_price = d("100000"),
        .conservative_equity = d("998"),
        .high_watermark = d("1000"),
        .risk_mode = .normal,
        .reconciled = true,
    };
}

test "unchanged situation stays valid across many engine versions" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    var later = snap;
    later.version = 410; // hundreds of ticks later
    later.bid_price = d("100200"); // +0.2%
    try testing.expect(check(anchor, later, 61_000, test_limits) == .valid);
}

test "a proposal older than its validity window is void" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    const v = check(anchor, snap, 1_000 + test_limits.max_age_ms + 1, test_limits);
    try testing.expect(v == .stale and v.stale == .too_old);
    try testing.expect(check(anchor, snap, 1_000 + test_limits.max_age_ms, test_limits) == .valid);
}

test "price drift in either direction beyond the limit voids the proposal" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    var up = snap;
    up.bid_price = d("101500");
    var down = snap;
    down.bid_price = d("98500");
    try testing.expect(check(anchor, up, 2_000, test_limits).stale == .price_drift);
    try testing.expect(check(anchor, down, 2_000, test_limits).stale == .price_drift);
    var gone = snap;
    gone.bid_price = Decimal.zero;
    try testing.expect(check(anchor, gone, 2_000, test_limits).stale == .price_drift);
}

test "a changed position or cash balance voids the proposal" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    var bought = snap;
    bought.btc_total = d("0.0070"); // +0.002 BTC ≈ 200 USDT ≈ 20% of equity
    try testing.expect(check(anchor, bought, 2_000, test_limits).stale == .book_changed);
    var deposit = snap;
    deposit.cash_usdt = d("700");
    try testing.expect(check(anchor, deposit, 2_000, test_limits).stale == .book_changed);
    var fee_dust = snap;
    fee_dust.cash_usdt = d("499.2"); // 0.08% of equity: fees, not a new situation
    try testing.expect(check(anchor, fee_dust, 2_000, test_limits) == .valid);
}

test "risk mode change, capital flow and unresolved orders void the proposal" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    var mode = snap;
    mode.risk_mode = .exit_only;
    try testing.expect(check(anchor, mode, 2_000, test_limits).stale == .risk_mode_changed);
    var flow = snap;
    flow.flow_epoch = 1;
    try testing.expect(check(anchor, flow, 2_000, test_limits).stale == .capital_flow);
    var orders = snap;
    orders.unresolved_orders = true;
    try testing.expect(check(anchor, orders, 2_000, test_limits).stale == .unresolved_orders);
}

test "an anchor without a price or equity can never validate a proposal" {
    var snap = baseSnap();
    snap.conservative_equity = Decimal.zero;
    try testing.expect(check(anchorOf(snap, 1_000), snap, 2_000, test_limits).stale == .unusable_anchor);
}

test "binding to the execution snapshot needs a valid proposal about the snapshot the model saw" {
    const snap = baseSnap();
    const anchor = anchorOf(snap, 1_000);
    // Valid and about the decision snapshot: explicitly bound to execution.
    try testing.expectEqual(@as(?u64, 777), bindExecutionVersion(10, anchor, 777, .valid));
    // The model cited some other version: left as is, so admission rejects it.
    try testing.expectEqual(@as(?u64, 3), bindExecutionVersion(3, anchor, 777, .valid));
    // Void proposals are never bound to anything.
    try testing.expectEqual(@as(?u64, null), bindExecutionVersion(10, anchor, 777, .{ .stale = .price_drift }));
}
