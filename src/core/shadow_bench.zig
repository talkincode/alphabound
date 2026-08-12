//! Shadow vs buy-and-hold baseline (§Phase 2 影子对比).
//! Pure math: given a baseline capital and a reference entry price, track BH
//! equity under mark/bid updates. No exchange side effects.
//!
//! On material capital inflows/outflows the baseline must be **rebased** to the
//! new equity at the current bid — otherwise absolute alpha is dominated by
//! deposits, not strategy skill.

const std = @import("std");
const dec = @import("decimal.zig");
const Decimal = dec.Decimal;

pub const Snapshot = struct {
    initial_capital: Decimal = Decimal.zero,
    entry_bid: Decimal = Decimal.zero,
    /// BTC amount BH would hold if fully converted at entry (after fee).
    bh_btc: Decimal = Decimal.zero,
    fee_rate: Decimal = Decimal.zero,
    initialized: bool = false,
};

pub const Comparison = struct {
    shadow_equity: Decimal,
    bh_equity: Decimal,
    /// shadow - bh (same-capital dollars; meaningful only after rebase)
    alpha: Decimal,
    entry_bid: Decimal,
    bh_btc: Decimal,
    /// Capital used when BH baseline was (re)built.
    baseline_capital: Decimal = Decimal.zero,
    /// shadow_equity / baseline - 1
    shadow_return: Decimal = Decimal.zero,
    /// bh_equity / baseline - 1
    bh_return: Decimal = Decimal.zero,
    /// shadow_return - bh_return (primary skill metric)
    alpha_return: Decimal = Decimal.zero,
};

pub fn init(capital: Decimal, entry_bid: Decimal, fee_rate: Decimal) Snapshot {
    if (entry_bid.isZero() or capital.isZero() or capital.isNegative()) {
        return .{
            .initial_capital = if (capital.isNegative()) Decimal.zero else capital,
            .entry_bid = entry_bid,
            .fee_rate = fee_rate,
            .initialized = false,
        };
    }
    // Spend all cash at bid, pay taker fee on notional.
    // btc = capital / bid * (1 - fee)
    const raw = capital.div(entry_bid, .down) catch Decimal.zero;
    const one = Decimal.one;
    const keep = one.sub(fee_rate) catch one;
    const btc = raw.mul(keep, .down) catch Decimal.zero;
    return .{
        .initial_capital = capital,
        .entry_bid = entry_bid,
        .bh_btc = btc,
        .fee_rate = fee_rate,
        .initialized = !btc.isZero(),
    };
}

/// True when live equity diverges from BH baseline by more than market noise —
/// typical of deposits/withdrawals, not a 10% BTC book marking.
///
/// Defaults: relative ≥ 8% AND absolute ≥ 15 USDT.
pub fn needsRebase(baseline_capital: Decimal, live_equity: Decimal) bool {
    return needsRebaseThresholds(baseline_capital, live_equity, dConst("0.08"), dConst("15"));
}

pub fn needsRebaseThresholds(
    baseline_capital: Decimal,
    live_equity: Decimal,
    rel: Decimal,
    abs_min: Decimal,
) bool {
    if (baseline_capital.isZero() or baseline_capital.isNegative()) return live_equity.gt(Decimal.zero);
    if (live_equity.isZero() or live_equity.isNegative()) return false;
    const diff = if (live_equity.gt(baseline_capital))
        (live_equity.sub(baseline_capital) catch Decimal.zero)
    else
        (baseline_capital.sub(live_equity) catch Decimal.zero);
    if (!diff.gte(abs_min)) return false;
    const ratio = live_equity.div(baseline_capital, .down) catch return false;
    const one = Decimal.one;
    if (ratio.gt(one)) {
        const up = ratio.sub(one) catch return false;
        return up.gte(rel);
    }
    const down = one.sub(ratio) catch return false;
    return down.gte(rel);
}

/// Conservative BH equity: mark-to-bid minus exit fee/slippage approx fee_rate.
pub fn evaluate(self: Snapshot, bid: Decimal, shadow_equity: Decimal) Comparison {
    const baseline = self.initial_capital;
    if (!self.initialized or bid.isZero()) {
        return withReturns(.{
            .shadow_equity = shadow_equity,
            .bh_equity = baseline,
            .alpha = shadow_equity.sub(baseline) catch Decimal.zero,
            .entry_bid = self.entry_bid,
            .bh_btc = self.bh_btc,
            .baseline_capital = baseline,
        });
    }
    const notional = self.bh_btc.mul(bid, .down) catch Decimal.zero;
    const one = Decimal.one;
    const keep = one.sub(self.fee_rate) catch one;
    const bh_eq = notional.mul(keep, .down) catch notional;
    const alpha = shadow_equity.sub(bh_eq) catch Decimal.zero;
    return withReturns(.{
        .shadow_equity = shadow_equity,
        .bh_equity = bh_eq,
        .alpha = alpha,
        .entry_bid = self.entry_bid,
        .bh_btc = self.bh_btc,
        .baseline_capital = baseline,
    });
}

fn withReturns(c: Comparison) Comparison {
    var out = c;
    if (c.baseline_capital.gt(Decimal.zero)) {
        const s_ratio = c.shadow_equity.div(c.baseline_capital, .down) catch Decimal.one;
        const b_ratio = c.bh_equity.div(c.baseline_capital, .down) catch Decimal.one;
        out.shadow_return = s_ratio.sub(Decimal.one) catch Decimal.zero;
        out.bh_return = b_ratio.sub(Decimal.one) catch Decimal.zero;
        out.alpha_return = out.shadow_return.sub(out.bh_return) catch Decimal.zero;
    }
    return out;
}

pub fn formatJson(buf: []u8, c: Comparison) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"shadow_equity\":\"{f}\",\"bh_equity\":\"{f}\",\"alpha\":\"{f}\",\"entry_bid\":\"{f}\",\"bh_btc\":\"{f}\",\"baseline_capital\":\"{f}\",\"shadow_return\":\"{f}\",\"bh_return\":\"{f}\",\"alpha_return\":\"{f}\"}}",
        .{
            c.shadow_equity,
            c.bh_equity,
            c.alpha,
            c.entry_bid,
            c.bh_btc,
            c.baseline_capital,
            c.shadow_return,
            c.bh_return,
            c.alpha_return,
        },
    ) catch return error.BufferTooSmall;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn dConst(s: []const u8) Decimal {
    return Decimal.parse(s) catch Decimal.zero;
}

test "buy-and-hold init and evaluate" {
    const s = init(d("100"), d("50000"), d("0.001"));
    try testing.expect(s.initialized);
    // 100/50000 * 0.999 = 0.001998
    try testing.expect(s.bh_btc.gt(d("0.0019")));
    try testing.expect(s.bh_btc.lt(d("0.0021")));

    // Price flat → BH ~ 100 * 0.999^2 (entry+exit fee)
    const flat = evaluate(s, d("50000"), d("100"));
    try testing.expect(flat.bh_equity.lt(d("100")));
    try testing.expect(flat.bh_equity.gt(d("99")));
    try testing.expect(flat.baseline_capital.eql(d("100")));

    // Price up 10%
    const up = evaluate(s, d("55000"), d("100"));
    try testing.expect(up.bh_equity.gt(d("109")));
    // shadow still 100 → alpha negative
    try testing.expect(up.alpha.lt(Decimal.zero));
    try testing.expect(up.bh_return.gt(Decimal.zero));
    try testing.expect(up.alpha_return.lt(Decimal.zero));
}

test "uninitialized stays at capital" {
    const s = init(d("100"), Decimal.zero, d("0.001"));
    try testing.expect(!s.initialized);
    const c = evaluate(s, d("1"), d("100"));
    try testing.expect(c.bh_equity.eql(d("100")));
}

test "needsRebase on deposit-like jump" {
    try testing.expect(!needsRebase(d("200"), d("201"))); // noise
    try testing.expect(!needsRebase(d("200"), d("210"))); // 5% < 8%
    try testing.expect(needsRebase(d("200"), d("300"))); // +100 deposit
    try testing.expect(needsRebase(d("100"), d("200")));
    try testing.expect(needsRebase(d("400"), d("200"))); // large withdrawal
    try testing.expect(!needsRebase(d("400"), d("390"))); // small mark move
}

test "rebase restores comparable alpha" {
    var s = init(d("100"), d("50000"), d("0.001"));
    // Pretend deposit to 300 while price flat-ish
    try testing.expect(needsRebase(s.initial_capital, d("300")));
    s = init(d("300"), d("50000"), d("0.001"));
    const c = evaluate(s, d("50000"), d("300"));
    // Same start → alpha near 0 (fees only on BH)
    try testing.expect(c.alpha.abs().lt(d("2")));
    try testing.expect(c.alpha_return.abs().lt(d("0.01")));
}
