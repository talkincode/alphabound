//! Conservative equity, high-watermark and drawdown math (§5.1).
//!
//! E_t  = C_t + Q_t × P_liq,t − Fee_exit,t − Slippage_exit,t − PendingRisk_t
//! H_t  = max(H_{t−1}, E_t)
//! DD_t = max(0, (H_t − E_t) / H_t)
//! RiskBudget_t = H_t × maxdd − (H_t − E_t)
//!
//! Pure functions over Decimal — no network, no LLM, no database (§4 module table).

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

pub const ExitCostParams = struct {
    /// Taker fee rate applied on exit notional (e.g. 0.001 = 10 bps).
    fee_rate: Decimal,
    /// Modeled slippage rate on exit notional. Calibration is an open item
    /// (§9.5); conservative default until live order book data exists.
    slippage_rate: Decimal,
};

pub const EquityInputs = struct {
    cash_usdt: Decimal,
    btc_total: Decimal,
    /// Executable liquidation price (near best bid), not last trade.
    liq_price: Decimal,
    exit_costs: ExitCostParams,
    /// Risk attributed to open orders that may still fill (§5.1).
    pending_risk: Decimal = Decimal.zero,
};

pub const EquityResult = struct {
    equity: Decimal,
    exit_fee: Decimal,
    exit_slippage: Decimal,
};

/// Conservative liquidation equity.
pub fn conservativeEquity(in: EquityInputs) dec.DecimalError!EquityResult {
    const btc_value = try in.btc_total.mul(in.liq_price, .down);
    const fee = try btc_value.mul(in.exit_costs.fee_rate, .up);
    const slip = try btc_value.mul(in.exit_costs.slippage_rate, .up);
    var e = try in.cash_usdt.add(btc_value);
    e = try e.sub(fee);
    e = try e.sub(slip);
    e = try e.sub(in.pending_risk);
    return .{ .equity = e, .exit_fee = fee, .exit_slippage = slip };
}

/// High watermark is monotonically non-decreasing.
pub fn updateHighWatermark(prev_hwm: Decimal, equity: Decimal) Decimal {
    return Decimal.max(prev_hwm, equity);
}

/// Drawdown as a fraction of HWM in [0, 1]; zero when HWM is not positive.
pub fn drawdown(hwm: Decimal, equity: Decimal) dec.DecimalError!Decimal {
    if (!hwm.gt(Decimal.zero)) return Decimal.zero;
    if (equity.gte(hwm)) return Decimal.zero;
    const loss = try hwm.sub(equity);
    return try loss.div(hwm, .up); // round up: never understate drawdown
}

/// Remaining risk budget in USDT: H×maxdd − (H − E). Negative means breached.
pub fn riskBudget(hwm: Decimal, equity: Decimal, max_drawdown: Decimal) dec.DecimalError!Decimal {
    const allowance = try hwm.mul(max_drawdown, .down);
    const loss = try hwm.sub(equity);
    return try allowance.sub(loss);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "design example: 100 -> 120 -> 108 hits 10% drawdown" {
    var hwm = d("100");
    hwm = updateHighWatermark(hwm, d("120"));
    try testing.expect(hwm.eql(d("120")));
    const dd = try drawdown(hwm, d("108"));
    try testing.expect(dd.eql(d("0.1")));
    const budget = try riskBudget(hwm, d("108"), d("0.10"));
    try testing.expect(budget.eql(d("0"))); // exactly exhausted
}

test "conservative equity subtracts exit costs and pending risk" {
    const r = try conservativeEquity(.{
        .cash_usdt = d("40"),
        .btc_total = d("0.0005"),
        .liq_price = d("120000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.0005") },
        .pending_risk = d("0.05"),
    });
    // btc_value = 60; fee = 0.06; slip = 0.03; E = 40+60-0.06-0.03-0.05 = 99.86
    try testing.expect(r.equity.eql(d("99.86")));
}

test "hwm never decreases" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var hwm = Decimal.zero;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const e = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200 * dec.ONE_RAW));
        const next = updateHighWatermark(hwm, e);
        try testing.expect(next.gte(hwm));
        try testing.expect(next.gte(e));
        hwm = next;
    }
}

test "property: drawdown in [0,1] and consistent with budget sign" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const maxdd = d("0.10");
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const hwm = Decimal.fromRaw(random.intRangeAtMost(i128, 1, 1_000 * dec.ONE_RAW));
        const equity = Decimal.fromRaw(random.intRangeAtMost(i128, 0, hwm.raw));
        const dd = try drawdown(hwm, equity);
        try testing.expect(dd.gte(Decimal.zero));
        try testing.expect(dd.lte(Decimal.one));
        const budget = try riskBudget(hwm, equity, maxdd);
        // budget < 0 iff dd > maxdd (allowing 1 raw-unit rounding tolerance)
        if (budget.isNegative()) {
            try testing.expect(dd.raw >= maxdd.raw - 1);
        } else {
            try testing.expect(dd.raw <= maxdd.raw + 1);
        }
    }
}
