//! Shadow vs buy-and-hold baseline (§Phase 2 影子对比).
//! Pure math: given initial capital and a reference entry price, track BH
//! equity under mark/bid updates. No exchange side effects.

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
    /// shadow - bh (positive => shadow ahead)
    alpha: Decimal,
    entry_bid: Decimal,
    bh_btc: Decimal,
};

pub fn init(capital: Decimal, entry_bid: Decimal, fee_rate: Decimal) Snapshot {
    if (entry_bid.isZero() or capital.isZero()) {
        return .{
            .initial_capital = capital,
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

/// Conservative BH equity: mark-to-bid minus exit fee/slippage approx fee_rate.
pub fn evaluate(self: Snapshot, bid: Decimal, shadow_equity: Decimal) Comparison {
    if (!self.initialized or bid.isZero()) {
        return .{
            .shadow_equity = shadow_equity,
            .bh_equity = self.initial_capital,
            .alpha = shadow_equity.sub(self.initial_capital) catch Decimal.zero,
            .entry_bid = self.entry_bid,
            .bh_btc = self.bh_btc,
        };
    }
    const notional = self.bh_btc.mul(bid, .down) catch Decimal.zero;
    const one = Decimal.one;
    const keep = one.sub(self.fee_rate) catch one;
    const bh_eq = notional.mul(keep, .down) catch notional;
    const alpha = shadow_equity.sub(bh_eq) catch Decimal.zero;
    return .{
        .shadow_equity = shadow_equity,
        .bh_equity = bh_eq,
        .alpha = alpha,
        .entry_bid = self.entry_bid,
        .bh_btc = self.bh_btc,
    };
}

pub fn formatJson(buf: []u8, c: Comparison) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"shadow_equity\":\"{f}\",\"bh_equity\":\"{f}\",\"alpha\":\"{f}\",\"entry_bid\":\"{f}\",\"bh_btc\":\"{f}\"}}",
        .{ c.shadow_equity, c.bh_equity, c.alpha, c.entry_bid, c.bh_btc },
    ) catch return error.BufferTooSmall;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
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

    // Price up 10%
    const up = evaluate(s, d("55000"), d("100"));
    try testing.expect(up.bh_equity.gt(d("109")));
    // shadow still 100 → alpha negative
    try testing.expect(up.alpha.lt(Decimal.zero));
}

test "uninitialized stays at capital" {
    const s = init(d("100"), Decimal.zero, d("0.001"));
    try testing.expect(!s.initialized);
    const c = evaluate(s, d("1"), d("100"));
    try testing.expect(c.bh_equity.eql(d("100")));
}
