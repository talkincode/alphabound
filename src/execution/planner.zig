//! Execution planner: converts an admitted target weight into a concrete
//! order, respecting instrument constraints (tick size, lot size, min size,
//! min notional) loaded at startup — never hardcoded (§4.1).
//! Partial fills re-plan from the *remaining* delta (§5.5).

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;
const orders = @import("orders.zig");

pub const Instrument = struct {
    /// Price increment, e.g. 0.1 USDT.
    tick_size: Decimal,
    /// Quantity increment, e.g. 0.00000001 BTC.
    lot_size: Decimal,
    /// Minimum order quantity in base units.
    min_size: Decimal,
    /// Some venues also enforce a min notional; 0 disables.
    min_notional: Decimal = Decimal.zero,
};

pub const PlanInputs = struct {
    cash_usdt: Decimal,
    btc_total: Decimal,
    /// Basis for converting weight into value terms (conservative equity).
    equity: Decimal,
    mark_price: Decimal,
    admitted_btc_weight: Decimal,
    instrument: Instrument,
};

pub const Plan = union(enum) {
    /// Delta below instrument minimums or zero — do nothing.
    hold,
    order: PlannedOrder,
};

pub const PlannedOrder = struct {
    side: orders.Side,
    qty: Decimal, // base (BTC), rounded down to lot size
};

pub const PlanError = error{
    InvalidInstrument,
    NonPositiveEquity,
    NonPositivePrice,
} || dec.DecimalError;

pub fn plan(in: PlanInputs) PlanError!Plan {
    if (in.instrument.lot_size.raw <= 0 or in.instrument.tick_size.raw <= 0)
        return error.InvalidInstrument;
    if (!in.equity.gt(Decimal.zero)) return error.NonPositiveEquity;
    if (!in.mark_price.gt(Decimal.zero)) return error.NonPositivePrice;

    const target_value = try in.equity.mul(in.admitted_btc_weight, .down);
    const target_qty = try target_value.div(in.mark_price, .down);
    const delta = try target_qty.sub(in.btc_total);

    if (delta.isZero()) return .hold;

    const side: orders.Side = if (delta.isNegative()) .sell else .buy;
    var qty = try delta.abs().floorToStep(in.instrument.lot_size);

    if (side == .buy) {
        // Never spend more cash than available (fees eat a margin too).
        const max_affordable = try in.cash_usdt.div(in.mark_price, .down);
        qty = Decimal.min(qty, try max_affordable.floorToStep(in.instrument.lot_size));
    } else {
        qty = Decimal.min(qty, try in.btc_total.floorToStep(in.instrument.lot_size));
    }

    if (qty.lt(in.instrument.min_size) or qty.isZero()) return .hold;
    if (in.instrument.min_notional.gt(Decimal.zero)) {
        const notional = try qty.mul(in.mark_price, .down);
        if (notional.lt(in.instrument.min_notional)) return .hold;
    }
    return .{ .order = .{ .side = side, .qty = qty } };
}

/// Round a limit price onto the tick grid, biased against ourselves
/// (buy rounds down, sell rounds up) so we never cross more than intended.
pub fn snapPrice(price: Decimal, tick: Decimal, side: orders.Side) PlanError!Decimal {
    if (tick.raw <= 0) return error.InvalidInstrument;
    const floored = try price.floorToStep(tick);
    return switch (side) {
        .buy => floored,
        .sell => if (floored.eql(price)) price else try floored.add(tick),
    };
}

/// Derive a limit price from mark + urgency in [0,1].
/// urgency=1 → at mark (still tick-snapped, side-adversarial).
/// urgency=0 → up to `max_passive_frac` away from mark (more passive).
pub fn limitPriceFromMark(
    mark: Decimal,
    tick: Decimal,
    side: orders.Side,
    urgency: Decimal,
    max_passive_frac: Decimal,
) PlanError!Decimal {
    if (!mark.gt(Decimal.zero)) return error.NonPositivePrice;
    var u = urgency;
    if (u.isNegative()) u = Decimal.zero;
    if (u.gt(Decimal.one)) u = Decimal.one;
    const one_minus = try Decimal.one.sub(u);
    const passive = try max_passive_frac.mul(one_minus, .down);
    const raw = switch (side) {
        .buy => try mark.mul(try Decimal.one.sub(passive), .down),
        .sell => try mark.mul(try Decimal.one.add(passive), .up),
    };
    return snapPrice(raw, tick, side);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

const btc_usdt = Instrument{
    .tick_size = d("0.1"),
    .lot_size = d("0.00000001"),
    .min_size = d("0.00001"),
    .min_notional = d("1"),
};

test "buy plan from all-cash to 50% weight" {
    const p = try plan(.{
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .equity = d("100"),
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0.5"),
        .instrument = btc_usdt,
    });
    try testing.expect(p == .order);
    try testing.expectEqual(orders.Side.buy, p.order.side);
    try testing.expect(p.order.qty.eql(d("0.0005")));
}

test "sell plan when overweight" {
    const p = try plan(.{
        .cash_usdt = d("20"),
        .btc_total = d("0.001"),
        .equity = d("119"),
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0.4"),
        .instrument = btc_usdt,
    });
    try testing.expect(p == .order);
    try testing.expectEqual(orders.Side.sell, p.order.side);
    // target qty = 119*0.4/100000 = 0.000476 → sell 0.000524
    try testing.expect(p.order.qty.eql(d("0.000524")));
}

test "dust delta holds" {
    const p = try plan(.{
        .cash_usdt = d("50"),
        .btc_total = d("0.0005"),
        .equity = d("100"),
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0.500001"), // sub-min delta
        .instrument = btc_usdt,
    });
    try testing.expect(p == .hold);
}

test "buy below min_notional holds even with leftover cash" {
    // Near-full BTC book: 98.15% → 99% is ~3.75 USDT, under a 10 USDT floor.
    const floor10 = Instrument{
        .tick_size = d("0.1"),
        .lot_size = d("0.00000001"),
        .min_size = d("0.00001"),
        .min_notional = d("10"),
    };
    const p = try plan(.{
        .cash_usdt = d("8.82"),
        .btc_total = d("0.00574788"),
        .equity = d("442.37"),
        .mark_price = d("75540.9"),
        .admitted_btc_weight = d("0.99"),
        .instrument = floor10,
    });
    try testing.expect(p == .hold);
}

test "all remaining cash below min_notional cannot buy" {
    const floor10 = Instrument{
        .tick_size = d("0.1"),
        .lot_size = d("0.00000001"),
        .min_size = d("0.00001"),
        .min_notional = d("10"),
    };
    const p = try plan(.{
        .cash_usdt = d("8.82"),
        .btc_total = d("0.00574788"),
        .equity = d("442.37"),
        .mark_price = d("75540.9"),
        .admitted_btc_weight = d("1"),
        .instrument = floor10,
    });
    try testing.expect(p == .hold);
}

test "buy capped by available cash" {
    const p = try plan(.{
        .cash_usdt = d("10"),
        .btc_total = d("0"),
        .equity = d("100"), // equity says 50 target but only 10 cash
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0.5"),
        .instrument = btc_usdt,
    });
    try testing.expect(p == .order);
    try testing.expect(p.order.qty.eql(d("0.0001"))); // 10/100000
}

test "sell capped by holdings" {
    const p = try plan(.{
        .cash_usdt = d("0"),
        .btc_total = d("0.0002"),
        .equity = d("20"),
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0"),
        .instrument = btc_usdt,
    });
    try testing.expect(p == .order);
    try testing.expect(p.order.qty.eql(d("0.0002")));
}

test "partial fill re-plan shrinks remaining delta" {
    // After buying 0.0003 of a planned 0.0005, re-plan targets only the rest.
    const p = try plan(.{
        .cash_usdt = d("70"),
        .btc_total = d("0.0003"),
        .equity = d("100"),
        .mark_price = d("100000"),
        .admitted_btc_weight = d("0.5"),
        .instrument = btc_usdt,
    });
    try testing.expect(p == .order);
    try testing.expect(p.order.qty.eql(d("0.0002")));
}

test "price snapping is side-adversarial" {
    const buy = try snapPrice(d("100000.15"), d("0.1"), .buy);
    try testing.expect(buy.eql(d("100000.1")));
    const sell = try snapPrice(d("100000.15"), d("0.1"), .sell);
    try testing.expect(sell.eql(d("100000.2")));
    const exact = try snapPrice(d("100000.1"), d("0.1"), .sell);
    try testing.expect(exact.eql(d("100000.1")));
}

test "limitPriceFromMark urgency pulls toward mark" {
    const tick = d("0.1");
    const mark = d("100000");
    const max_passive = d("0.001"); // 10 bps
    const buy_passive = try limitPriceFromMark(mark, tick, .buy, d("0"), max_passive);
    try testing.expect(buy_passive.lt(mark));
    const buy_urgent = try limitPriceFromMark(mark, tick, .buy, d("1"), max_passive);
    try testing.expect(buy_urgent.eql(try snapPrice(mark, tick, .buy)));
    const sell_passive = try limitPriceFromMark(mark, tick, .sell, d("0"), max_passive);
    try testing.expect(sell_passive.gt(mark));
}

test "property: planned qty always on lot grid and within caps" {
    var prng = std.Random.DefaultPrng.init(555);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const cash = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200 * dec.ONE_RAW));
        const btc = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 300_000));
        const price = Decimal.fromRaw(random.intRangeAtMost(i128, 50_000 * dec.ONE_RAW, 150_000 * dec.ONE_RAW));
        const btc_value = try btc.mul(price, .down);
        const equity = try cash.add(btc_value);
        if (!equity.gt(Decimal.zero)) continue;
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const p = plan(.{
            .cash_usdt = cash,
            .btc_total = btc,
            .equity = equity,
            .mark_price = price,
            .admitted_btc_weight = w,
            .instrument = btc_usdt,
        }) catch continue;
        switch (p) {
            .hold => {},
            .order => |o| {
                try testing.expect(o.qty.gte(btc_usdt.min_size));
                try testing.expect(@rem(o.qty.raw, btc_usdt.lot_size.raw) == 0);
                if (o.side == .sell) try testing.expect(o.qty.lte(btc));
                if (o.side == .buy) {
                    const cost = try o.qty.mul(price, .down);
                    try testing.expect(cost.lte(cash));
                }
            },
        }
    }
}

test "AC-GO3 property: partial-fill replan converges without flipping side" {
    // Simulate the residual-replan loop: plan → random partial fill →
    // update holdings → replan. Remaining qty must shrink monotonically,
    // the side must never flip, and the loop must reach HOLD.
    var prng = std.Random.DefaultPrng.init(0xf111ed);
    const random = prng.random();
    var round: usize = 0;
    while (round < 500) : (round += 1) {
        var cash = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200 * dec.ONE_RAW));
        var btc = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 300_000));
        const price = Decimal.fromRaw(random.intRangeAtMost(i128, 50_000 * dec.ONE_RAW, 150_000 * dec.ONE_RAW));
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));

        var first_side: ?orders.Side = null;
        var prev_qty: ?Decimal = null;
        var steps: usize = 0;
        while (steps < 200) : (steps += 1) {
            const btc_value = try btc.mul(price, .down);
            const equity = try cash.add(btc_value);
            if (!equity.gt(Decimal.zero)) break;
            const p = try plan(.{
                .cash_usdt = cash,
                .btc_total = btc,
                .equity = equity,
                .mark_price = price,
                .admitted_btc_weight = w,
                .instrument = btc_usdt,
            });
            const o = switch (p) {
                .hold => break, // converged
                .order => |o| o,
            };
            if (first_side) |fs| {
                try testing.expectEqual(fs, o.side); // never flips direction
            } else first_side = o.side;
            if (prev_qty) |pq| try testing.expect(o.qty.lte(pq)); // monotone shrink
            prev_qty = o.qty;

            // Fill 25%..100% of the order, snapped to lot grid; guarantee
            // at least one lot so the loop always makes progress.
            const frac = Decimal.fromRaw(random.intRangeAtMost(i128, dec.ONE_RAW / 4, dec.ONE_RAW));
            var fill = try (try o.qty.mul(frac, .down)).floorToStep(btc_usdt.lot_size);
            if (fill.isZero()) fill = btc_usdt.lot_size;
            fill = Decimal.min(fill, o.qty);
            const notional = try fill.mul(price, .down);
            switch (o.side) {
                .buy => {
                    cash = try cash.sub(notional);
                    btc = try btc.add(fill);
                },
                .sell => {
                    cash = try cash.add(notional);
                    btc = try btc.sub(fill);
                },
            }
        }
        try testing.expect(steps < 200); // always converges to HOLD
    }
}
