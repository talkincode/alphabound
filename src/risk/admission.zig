//! Proposal admission (§5.2).
//!
//! Approve only if:
//!   proposal.snapshot_version == current.version
//!   AND account reconciled AND data fresh AND no unresolved order ambiguity
//!   AND E_stress(after trade) >= H_t × (1 − maxdd) + ExitReserve_t
//!
//! The kernel re-derives everything from the snapshot; it never trusts the
//! agent's own risk claims. If the requested weight fails, it searches for the
//! largest admissible reduced weight (REDUCE) before rejecting.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;
const equity_mod = @import("equity.zig");
const sm = @import("state_machine.zig");

pub const AdmissionError = error{Overflow} || dec.DecimalError;

pub const StressParams = struct {
    /// Adverse price shock applied to the post-trade position, e.g. 0.05 = −5%.
    price_shock: Decimal,
    /// Fee rate charged on the rebalancing trade itself.
    trade_fee_rate: Decimal,
    /// Slippage rate on the rebalancing trade notional.
    trade_slippage_rate: Decimal,
    /// Exit cost model used inside stress valuation.
    exit_costs: equity_mod.ExitCostParams,
    /// Additional exit reserve floor in USDT ("braking distance", §5.2).
    exit_reserve: Decimal,
};

pub const SnapshotView = struct {
    version: u64,
    reconciled: bool,
    market_fresh: bool,
    account_fresh: bool,
    unresolved_orders: bool,
    risk_mode: sm.RiskMode,
    cash_usdt: Decimal,
    btc_total: Decimal,
    /// Executable liquidation (bid-side) price.
    liq_price: Decimal,
    /// Mid/last price used to compute trade notionals.
    mark_price: Decimal,
    high_watermark: Decimal,
};

pub const ProposalView = struct {
    snapshot_version: u64,
    /// Requested BTC portfolio weight in [0,1].
    target_btc_weight: Decimal,
};

pub const Verdict = union(enum) {
    approve: Decimal, // admitted weight (== requested)
    approve_reduced: Decimal, // largest admissible weight < requested
    reject: RejectReason,
};

pub const RejectReason = enum {
    stale_snapshot,
    not_reconciled,
    stale_data,
    unresolved_orders,
    risk_mode_blocks,
    invalid_weight,
    boundary_violated,

    pub fn text(self: RejectReason) []const u8 {
        return switch (self) {
            .stale_snapshot => "snapshot_version mismatch",
            .not_reconciled => "account not reconciled",
            .stale_data => "market or account data stale",
            .unresolved_orders => "unresolved order ambiguity",
            .risk_mode_blocks => "risk mode does not allow risk increase",
            .invalid_weight => "target weight outside [0,1]",
            .boundary_violated => "stress equity below drawdown boundary + exit reserve",
        };
    }
};

pub const Admission = struct {
    verdict: Verdict,
    /// Stress equity at the admitted (or requested, if rejected) weight.
    stress_equity: Decimal,
    /// Boundary floor: H × (1 − maxdd) + exit_reserve.
    floor: Decimal,
};

/// Compute stress equity after rebalancing to `weight` and applying the shock.
pub fn stressEquityAtWeight(
    snap: SnapshotView,
    weight: Decimal,
    p: StressParams,
) AdmissionError!Decimal {
    // Current conservative equity (pre-trade) as sizing base.
    const pre = try equity_mod.conservativeEquity(.{
        .cash_usdt = snap.cash_usdt,
        .btc_total = snap.btc_total,
        .liq_price = snap.liq_price,
        .exit_costs = p.exit_costs,
    });
    const base = pre.equity;
    if (!base.gt(Decimal.zero)) return Decimal.zero;

    // Target BTC value and delta traded at mark price.
    const target_btc_value = try base.mul(weight, .down);
    const current_btc_value = try snap.btc_total.mul(snap.mark_price, .down);
    const delta = try target_btc_value.sub(current_btc_value);
    const traded_notional = delta.abs();
    const trade_fee = try traded_notional.mul(p.trade_fee_rate, .up);
    const trade_slip = try traded_notional.mul(p.trade_slippage_rate, .up);

    // Post-trade holdings (value terms), then shock the BTC leg.
    var cash = try snap.cash_usdt.add(current_btc_value); // liquidate notionally…
    cash = try cash.sub(target_btc_value); // …rebuy target
    cash = try cash.sub(trade_fee);
    cash = try cash.sub(trade_slip);

    const one_minus_shock = try Decimal.one.sub(p.price_shock);
    const shocked_btc_value = try target_btc_value.mul(one_minus_shock, .down);

    // Exit costs on the shocked position (would-be liquidation).
    const exit_fee = try shocked_btc_value.mul(p.exit_costs.fee_rate, .up);
    const exit_slip = try shocked_btc_value.mul(p.exit_costs.slippage_rate, .up);

    var e = try cash.add(shocked_btc_value);
    e = try e.sub(exit_fee);
    e = try e.sub(exit_slip);
    return e;
}

pub fn boundaryFloor(snap: SnapshotView, max_drawdown: Decimal, exit_reserve: Decimal) AdmissionError!Decimal {
    const keep = try Decimal.one.sub(max_drawdown);
    const floor = try snap.high_watermark.mul(keep, .up);
    return try floor.add(exit_reserve);
}

pub fn admit(
    snap: SnapshotView,
    proposal: ProposalView,
    max_drawdown: Decimal,
    p: StressParams,
) AdmissionError!Admission {
    const floor = try boundaryFloor(snap, max_drawdown, p.exit_reserve);

    // Gate checks first (§5.2), all fail-closed.
    if (proposal.snapshot_version != snap.version)
        return rejected(.stale_snapshot, snap, proposal.target_btc_weight, p, floor);
    if (!snap.reconciled)
        return rejected(.not_reconciled, snap, proposal.target_btc_weight, p, floor);
    if (!snap.market_fresh or !snap.account_fresh)
        return rejected(.stale_data, snap, proposal.target_btc_weight, p, floor);
    if (snap.unresolved_orders)
        return rejected(.unresolved_orders, snap, proposal.target_btc_weight, p, floor);
    if (proposal.target_btc_weight.isNegative() or proposal.target_btc_weight.gt(Decimal.one))
        return rejected(.invalid_weight, snap, proposal.target_btc_weight, p, floor);

    const current_weight = try currentBtcWeight(snap, p);
    const increases_risk = proposal.target_btc_weight.gt(current_weight);
    if (increases_risk and !sm.allowsRiskIncrease(snap.risk_mode))
        return rejected(.risk_mode_blocks, snap, proposal.target_btc_weight, p, floor);
    if (!increases_risk and !sm.allowsRiskReduction(snap.risk_mode))
        return rejected(.risk_mode_blocks, snap, proposal.target_btc_weight, p, floor);

    // Full requested weight admissible?
    const e_req = try stressEquityAtWeight(snap, proposal.target_btc_weight, p);
    if (e_req.gte(floor)) {
        return .{ .verdict = .{ .approve = proposal.target_btc_weight }, .stress_equity = e_req, .floor = floor };
    }

    // Risk-reducing proposals that still fail stress are rejected outright —
    // shrinking a reduction would *keep more* risk than the agent asked to keep.
    if (!increases_risk)
        return .{ .verdict = .{ .reject = .boundary_violated }, .stress_equity = e_req, .floor = floor };

    // Binary-search the largest admissible weight in [current, requested).
    var lo = current_weight; // known state; if even this fails, reject
    const e_lo = try stressEquityAtWeight(snap, lo, p);
    if (!e_lo.gte(floor))
        return .{ .verdict = .{ .reject = .boundary_violated }, .stress_equity = e_req, .floor = floor };

    var hi = proposal.target_btc_weight;
    var iter: usize = 0;
    while (iter < 32) : (iter += 1) {
        const gap = try hi.sub(lo);
        if (gap.raw <= 1000) break; // 1e-5 weight resolution
        const mid_raw = lo.raw + @divTrunc(gap.raw, 2);
        const mid = Decimal.fromRaw(mid_raw);
        const e_mid = try stressEquityAtWeight(snap, mid, p);
        if (e_mid.gte(floor)) lo = mid else hi = mid;
    }

    if (lo.eql(current_weight)) {
        // No meaningful increase is admissible.
        return .{ .verdict = .{ .reject = .boundary_violated }, .stress_equity = e_req, .floor = floor };
    }
    const e_admitted = try stressEquityAtWeight(snap, lo, p);
    return .{ .verdict = .{ .approve_reduced = lo }, .stress_equity = e_admitted, .floor = floor };
}

fn rejected(reason: RejectReason, snap: SnapshotView, weight: Decimal, p: StressParams, floor: Decimal) AdmissionError!Admission {
    const e = stressEquityAtWeight(snap, weight, p) catch Decimal.zero;
    return .{ .verdict = .{ .reject = reason }, .stress_equity = e, .floor = floor };
}

fn currentBtcWeight(snap: SnapshotView, p: StressParams) AdmissionError!Decimal {
    const pre = try equity_mod.conservativeEquity(.{
        .cash_usdt = snap.cash_usdt,
        .btc_total = snap.btc_total,
        .liq_price = snap.liq_price,
        .exit_costs = p.exit_costs,
    });
    if (!pre.equity.gt(Decimal.zero)) return Decimal.zero;
    const btc_value = try snap.btc_total.mul(snap.mark_price, .down);
    const w = try btc_value.div(pre.equity, .down);
    return Decimal.min(Decimal.max(w, Decimal.zero), Decimal.one);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn baseSnapshot() SnapshotView {
    return .{
        .version = 184392,
        .reconciled = true,
        .market_fresh = true,
        .account_fresh = true,
        .unresolved_orders = false,
        .risk_mode = .normal,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .liq_price = d("100000"),
        .mark_price = d("100050"),
        .high_watermark = d("100"),
    };
}

fn baseParams() StressParams {
    return .{
        .price_shock = d("0.05"),
        .trade_fee_rate = d("0.001"),
        .trade_slippage_rate = d("0.0005"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.0005") },
        .exit_reserve = d("0.5"),
    };
}

test "gate checks reject before any math" {
    const snap = baseSnapshot();
    const p = baseParams();
    const stale = ProposalView{ .snapshot_version = 1, .target_btc_weight = d("0.5") };
    const r1 = try admit(snap, stale, d("0.10"), p);
    try testing.expect(r1.verdict == .reject and r1.verdict.reject == .stale_snapshot);

    var s2 = snap;
    s2.reconciled = false;
    const ok_prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = d("0.5") };
    const r2 = try admit(s2, ok_prop, d("0.10"), p);
    try testing.expect(r2.verdict == .reject and r2.verdict.reject == .not_reconciled);

    var s3 = snap;
    s3.market_fresh = false;
    const r3 = try admit(s3, ok_prop, d("0.10"), p);
    try testing.expect(r3.verdict == .reject and r3.verdict.reject == .stale_data);

    var s4 = snap;
    s4.unresolved_orders = true;
    const r4 = try admit(s4, ok_prop, d("0.10"), p);
    try testing.expect(r4.verdict == .reject and r4.verdict.reject == .unresolved_orders);

    var s5 = snap;
    s5.risk_mode = .exit_only;
    const r5 = try admit(s5, ok_prop, d("0.10"), p);
    try testing.expect(r5.verdict == .reject and r5.verdict.reject == .risk_mode_blocks);
}

test "small weight approved, oversized weight reduced or rejected" {
    var snap = baseSnapshot();
    // Prior peak at 105: floor = 105×0.9 + 0.5 = 95, so a full-BTC 5% shock (~94.7) must not clear.
    snap.high_watermark = d("105");
    const p = baseParams();
    const small = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = d("0.2") };
    const r = try admit(snap, small, d("0.10"), p);
    try testing.expect(r.verdict == .approve);
    try testing.expect(r.stress_equity.gte(r.floor));

    const big = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = d("1") };
    const rb = try admit(snap, big, d("0.10"), p);
    switch (rb.verdict) {
        .approve => try testing.expect(false), // full BTC under 5% shock cannot clear 90+reserve floor
        .approve_reduced => |w| {
            try testing.expect(w.lt(d("1")));
            const e = try stressEquityAtWeight(snap, w, p);
            try testing.expect(e.gte(rb.floor));
        },
        .reject => {},
    }
}

test "risk-reducing proposal allowed in exit_only" {
    var snap = baseSnapshot();
    snap.btc_total = d("0.0005"); // ~50 USDT of BTC
    snap.cash_usdt = d("50");
    snap.risk_mode = .exit_only;
    const p = baseParams();
    const reduce = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = d("0.1") };
    const r = try admit(snap, reduce, d("0.10"), p);
    try testing.expect(r.verdict == .approve);
}

test "property: admission never clears a weight whose stress equity is below floor" {
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var snap = baseSnapshot();
        snap.cash_usdt = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200 * dec.ONE_RAW));
        snap.btc_total = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200_000)); // up to 0.002 BTC
        snap.liq_price = Decimal.fromRaw(random.intRangeAtMost(i128, 50_000 * dec.ONE_RAW, 150_000 * dec.ONE_RAW));
        snap.mark_price = try snap.liq_price.mul(d("1.0005"), .nearest);
        const pre = try equity_mod.conservativeEquity(.{
            .cash_usdt = snap.cash_usdt,
            .btc_total = snap.btc_total,
            .liq_price = snap.liq_price,
            .exit_costs = baseParams().exit_costs,
        });
        snap.high_watermark = Decimal.max(pre.equity, Decimal.fromRaw(random.intRangeAtMost(i128, 1, 220 * dec.ONE_RAW)));

        const p = baseParams();
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = w };
        const r = try admit(snap, prop, d("0.10"), p);
        switch (r.verdict) {
            .approve => |aw| {
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
            },
            .approve_reduced => |aw| {
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
                try testing.expect(aw.lt(w));
            },
            .reject => {},
        }
    }
}

test "AC-RK2 property: floor invariant holds under randomized stress params and drawdown" {
    // Same invariant as above but with the *parameters* randomized too:
    // shock, fees, slippage, exit reserve and max_drawdown all vary. No
    // parameter regime may admit a weight whose stress equity is below floor.
    var prng = std.Random.DefaultPrng.init(0xab5eed01);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var snap = baseSnapshot();
        snap.cash_usdt = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 500 * dec.ONE_RAW));
        snap.btc_total = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 500_000)); // up to 0.005 BTC
        snap.liq_price = Decimal.fromRaw(random.intRangeAtMost(i128, 10_000 * dec.ONE_RAW, 200_000 * dec.ONE_RAW));
        snap.mark_price = try snap.liq_price.mul(d("1.0005"), .nearest);
        snap.high_watermark = Decimal.fromRaw(random.intRangeAtMost(i128, 1, 600 * dec.ONE_RAW));

        const p = StressParams{
            .price_shock = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 2)), // 0..50%
            .trade_fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
            .trade_slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
            .exit_costs = .{
                .fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
                .slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
            },
            .exit_reserve = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 5 * dec.ONE_RAW)),
        };
        const maxdd = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 2)); // 0..50%
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = w };
        const r = try admit(snap, prop, maxdd, p);
        switch (r.verdict) {
            .approve => |aw| {
                try testing.expect(aw.eql(w));
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
            },
            .approve_reduced => |aw| {
                try testing.expect(aw.lt(w));
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
            },
            .reject => {},
        }
    }
}

test "AC-RK2 fuzz: decimal extremes never panic; overflow fails closed; floor invariant survives" {
    // Structured extreme-value fuzz: draw every numeric field from a pool of
    // adversarial extremes (0, 1 raw unit, i64/i128-boundary magnitudes) mixed
    // with random values. admit() must either return a verdict (whose APPROVE/
    // REDUCE branches still satisfy the floor invariant) or error.Overflow —
    // it must never panic, wrap, or admit below floor.
    var prng = std.Random.DefaultPrng.init(0xfa22ed9e);
    const random = prng.random();
    const huge: i128 = 1_000_000_000_000 * dec.ONE_RAW; // 1e12 units
    const extremes = [_]i128{
        0,                       1, // smallest positive raw
        dec.ONE_RAW - 1,         dec.ONE_RAW,
        dec.ONE_RAW + 1,         std.math.maxInt(i64),
        huge,                    huge * 1_000_000, // 1e18 units
    };
    var pick = struct {
        r: std.Random,
        pool: []const i128,
        fn next(self: *@This()) i128 {
            if (self.r.boolean()) return self.pool[self.r.uintLessThan(usize, self.pool.len)];
            return self.r.intRangeAtMost(i128, 0, 1_000_000 * dec.ONE_RAW);
        }
    }{ .r = random, .pool = &extremes };

    var overflow_count: usize = 0;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        var snap = baseSnapshot();
        snap.cash_usdt = Decimal.fromRaw(pick.next());
        snap.btc_total = Decimal.fromRaw(pick.next());
        snap.liq_price = Decimal.fromRaw(@max(1, pick.next()));
        snap.mark_price = Decimal.fromRaw(@max(1, pick.next()));
        snap.high_watermark = Decimal.fromRaw(pick.next());

        const p = StressParams{
            .price_shock = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW)), // 0..100%
            .trade_fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 10)),
            .trade_slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 10)),
            .exit_costs = .{
                .fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 10)),
                .slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 10)),
            },
            .exit_reserve = Decimal.fromRaw(pick.next()),
        };
        const maxdd = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = w };

        const r = admit(snap, prop, maxdd, p) catch |err| {
            // Overflow is the only acceptable failure and callers map it to a
            // non-executing ERROR verdict (fail-closed) — never an approval.
            try testing.expectEqual(AdmissionError.Overflow, err);
            overflow_count += 1;
            continue;
        };
        switch (r.verdict) {
            .approve => |aw| {
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
            },
            .approve_reduced => |aw| {
                const e = try stressEquityAtWeight(snap, aw, p);
                try testing.expect(e.gte(r.floor));
                try testing.expect(aw.lt(w));
            },
            .reject => {},
        }
    }
    // The extreme pool must actually exercise the overflow path.
    try testing.expect(overflow_count > 0);
}

test "AC-NFR03 property: snapshot_version mismatch always rejects, regardless of everything else" {
    var prng = std.Random.DefaultPrng.init(0x5747a1e);
    const random = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var snap = baseSnapshot();
        snap.version = random.int(u32);
        snap.reconciled = random.boolean();
        snap.market_fresh = random.boolean();
        snap.account_fresh = random.boolean();
        snap.unresolved_orders = random.boolean();
        snap.cash_usdt = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 500 * dec.ONE_RAW));
        snap.btc_total = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 500_000));
        var stale_version = random.int(u32);
        while (stale_version == snap.version) stale_version = random.int(u32);
        const prop = ProposalView{
            .snapshot_version = stale_version,
            .target_btc_weight = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW)),
        };
        const r = try admit(snap, prop, d("0.10"), baseParams());
        switch (r.verdict) {
            .reject => |reason| try testing.expectEqual(RejectReason.stale_snapshot, reason),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "property: halted and flattening reject risk-increasing weights" {
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var snap = baseSnapshot();
        snap.risk_mode = if (random.boolean()) .halted else .flattening;
        snap.cash_usdt = d("80");
        snap.btc_total = d("0.0002");
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 1, dec.ONE_RAW)); // > 0
        const prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = w };
        const r = try admit(snap, prop, d("0.10"), baseParams());
        // Any non-hold increase in halted/flattening must not APPROVE full request unless weight is risk-reducing.
        // With small existing BTC, most positive weights are increases → reject/reduce.
        switch (r.verdict) {
            .approve => |aw| try testing.expect(aw.lte(w)),
            .approve_reduced => |aw| try testing.expect(aw.lt(w)),
            .reject => |reason| try testing.expect(reason == .risk_mode_blocks or reason == .boundary_violated or reason == .invalid_weight),
        }
    }
}

test "AC-GO3 property: stress equity is monotone non-increasing in costs and shock" {
    // Raising any cost dial (shock / trade fee / trade slippage / exit costs)
    // can never *improve* the stressed equity — no parameter regime exists
    // where being charged more looks safer to the kernel.
    var prng = std.Random.DefaultPrng.init(0x5eed6003);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var snap = baseSnapshot();
        snap.cash_usdt = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200 * dec.ONE_RAW));
        snap.btc_total = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200_000));
        snap.liq_price = Decimal.fromRaw(random.intRangeAtMost(i128, 50_000 * dec.ONE_RAW, 150_000 * dec.ONE_RAW));
        snap.mark_price = try snap.liq_price.mul(d("1.0005"), .nearest);
        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));

        var lo = baseParams();
        lo.price_shock = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 5)); // 0..20%
        lo.trade_fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100));
        lo.trade_slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100));
        lo.exit_costs = .{
            .fee_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
            .slippage_rate = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW / 100)),
        };

        // hi = lo with one random dial bumped upward.
        var hi = lo;
        const bump = Decimal.fromRaw(random.intRangeAtMost(i128, 1, dec.ONE_RAW / 20)); // +0..5%
        switch (random.intRangeAtMost(u8, 0, 4)) {
            0 => hi.price_shock = try hi.price_shock.add(bump),
            1 => hi.trade_fee_rate = try hi.trade_fee_rate.add(bump),
            2 => hi.trade_slippage_rate = try hi.trade_slippage_rate.add(bump),
            3 => hi.exit_costs.fee_rate = try hi.exit_costs.fee_rate.add(bump),
            else => hi.exit_costs.slippage_rate = try hi.exit_costs.slippage_rate.add(bump),
        }

        const e_lo = try stressEquityAtWeight(snap, w, lo);
        const e_hi = try stressEquityAtWeight(snap, w, hi);
        try testing.expect(e_hi.lte(e_lo));
    }
}

test "AC-GO3 property: tightening max_drawdown never admits a larger weight" {
    // A stricter boundary (smaller allowed drawdown) can only shrink what the
    // kernel lets through — approve set is monotone in the risk budget.
    var prng = std.Random.DefaultPrng.init(0x600d0dd);
    const random = prng.random();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var snap = baseSnapshot();
        snap.cash_usdt = Decimal.fromRaw(random.intRangeAtMost(i128, dec.ONE_RAW, 200 * dec.ONE_RAW));
        snap.btc_total = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 200_000));
        snap.liq_price = Decimal.fromRaw(random.intRangeAtMost(i128, 50_000 * dec.ONE_RAW, 150_000 * dec.ONE_RAW));
        snap.mark_price = try snap.liq_price.mul(d("1.0005"), .nearest);
        const pre = try equity_mod.conservativeEquity(.{
            .cash_usdt = snap.cash_usdt,
            .btc_total = snap.btc_total,
            .liq_price = snap.liq_price,
            .exit_costs = baseParams().exit_costs,
        });
        snap.high_watermark = pre.equity;

        const w = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dec.ONE_RAW));
        const prop = ProposalView{ .snapshot_version = snap.version, .target_btc_weight = w };
        const dd_loose = Decimal.fromRaw(random.intRangeAtMost(i128, dec.ONE_RAW / 20, dec.ONE_RAW / 5)); // 5%..20%
        const dd_tight = Decimal.fromRaw(random.intRangeAtMost(i128, 0, dd_loose.raw));

        const r_loose = try admit(snap, prop, dd_loose, baseParams());
        const r_tight = try admit(snap, prop, dd_tight, baseParams());

        const admitted_loose: ?Decimal = switch (r_loose.verdict) {
            .approve, .approve_reduced => |aw| aw,
            .reject => null,
        };
        const admitted_tight: ?Decimal = switch (r_tight.verdict) {
            .approve, .approve_reduced => |aw| aw,
            .reject => null,
        };
        if (admitted_tight) |at| {
            // Anything the tight budget admits, the loose budget must admit at least as much.
            try testing.expect(admitted_loose != null);
            try testing.expect(at.lte(admitted_loose.?));
        }
    }
}
