//! Gate 3 fault-degradation matrix (design §7.2 / AC-FD*).
//!
//! Pure, offline checks that compose Risk Kernel + tools + order SM so the
//! fail-closed story is regression-tested in one place. Live/network injection
//! and soak remain manual (see docs/GATE3_CHECKLIST.md).

const std = @import("std");
const testing = std.testing;

const sm = @import("../risk/state_machine.zig");
const admission = @import("../risk/admission.zig");
const equity = @import("../risk/equity.zig");
const state_mod = @import("../core/state.zig");
const orders = @import("../execution/orders.zig");
const okx_trade = @import("../execution/okx_trade.zig");
const market = @import("../tools/market.zig");
const tools = @import("../tools/registry.zig");
const openai = @import("../agent/openai.zig");
const proposal = @import("../agent/proposal.zig");
const Decimal = @import("../core/decimal.zig").Decimal;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn baseSnap() admission.SnapshotView {
    return .{
        .version = 10,
        .reconciled = true,
        .market_fresh = true,
        .account_fresh = true,
        .unresolved_orders = false,
        .risk_mode = .normal,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .liq_price = d("100000"),
        .mark_price = d("100000"),
        .high_watermark = d("100"),
    };
}

fn stress() admission.StressParams {
    return .{
        .price_shock = d("0.05"),
        .trade_fee_rate = d("0.001"),
        .trade_slippage_rate = d("0.0005"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.0005") },
        .exit_reserve = d("0.5"),
    };
}

// --- AC-FD1: LLM failure → safe HOLD semantics (no executable increase) ------

test "AC-FD1 llm failure classification and invalid proposal is not executable" {
    try testing.expectEqualStrings("rate_limit", openai.classifyApiErrorBody("{\"error\":{\"code\":\"rate_limit_exceeded\"}}"));
    try testing.expectEqualStrings("unauthorized", openai.classifyApiErrorBody("HTTP 401 unauthorized"));
    try testing.expectEqualStrings("http_or_network", openai.classifyApiErrorBody("totally broken"));

    // Incomplete model JSON must not become a Proposal value.
    try testing.expectError(error.MissingField, proposal.parse(testing.allocator,
        \\{"action":"REBALANCE","target":{"type":"portfolio_weight","btc":"0.9"},"confidence":0.5}
    ));
}

// --- AC-FD2: tool unavailable must not invent zero market data --------------

test "AC-FD2 tool UNAVAILABLE keeps null data not zero quotes" {
    const r = market.unavailableResult("okx", 1_700_000_000_000);
    try testing.expectEqual(tools.ResultStatus.unavailable, r.status);
    try testing.expectEqualStrings("null", r.data_json);

    const err = market.errResult("okx", 1_700_000_000_000, 12, "http_failed");
    try testing.expectEqual(tools.ResultStatus.err, err.status);
    try testing.expect(std.mem.indexOf(u8, err.data_json, "\"bid\":0") == null);
    try testing.expect(std.mem.indexOf(u8, err.data_json, "fetch_failed") != null);
}

// --- AC-FD3: stale public market → EXIT_ONLY + no risk increase -------------

test "AC-FD3 stale market forces EXIT_ONLY and admission rejects increase" {
    var eng = state_mod.Engine.init(.{
        .fee_rate = d("0.001"),
        .slippage_rate = d("0.0005"),
    }, d("0.10"));
    _ = try eng.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100000") } });
    _ = try eng.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, eng.snapshot().risk_mode);

    _ = try eng.apply(.{ .clock_tick = .{ .ts_ms = 61_000 } });
    try testing.expectEqual(sm.RiskMode.exit_only, eng.snapshot().risk_mode);
    try testing.expect(!sm.allowsRiskIncrease(eng.snapshot().risk_mode));

    var snap = baseSnap();
    snap.version = eng.snapshot().version;
    snap.risk_mode = .exit_only;
    snap.market_fresh = false;
    const res = try admission.admit(snap, .{
        .snapshot_version = snap.version,
        .target_btc_weight = d("0.5"),
    }, d("0.10"), stress());
    try testing.expect(res.verdict == .reject);
}

// --- AC-FD4: private uncertainty → unresolved/stale account blocks increase -

test "AC-FD4 unresolved orders and stale account reject risk increase" {
    var snap = baseSnap();
    snap.unresolved_orders = true;
    const r1 = try admission.admit(snap, .{
        .snapshot_version = 10,
        .target_btc_weight = d("0.4"),
    }, d("0.10"), stress());
    try testing.expect(r1.verdict == .reject);

    snap.unresolved_orders = false;
    snap.account_fresh = false;
    const r2 = try admission.admit(snap, .{
        .snapshot_version = 10,
        .target_btc_weight = d("0.4"),
    }, d("0.10"), stress());
    try testing.expect(r2.verdict == .reject);
}

// --- AC-FD5: order timeout → UNKNOWN; never blind resubmit ------------------

test "AC-FD5 timeout to UNKNOWN forbids blind resubmit" {
    var s = orders.OrderStatus.planned;
    s = try orders.next(s, .submit);
    s = try orders.next(s, .timeout);
    try testing.expectEqual(orders.OrderStatus.unknown, s);
    try testing.expectError(error.IllegalTransition, orders.next(s, .submit));
    s = try orders.next(s, .resolved_filled);
    try testing.expectEqual(orders.OrderStatus.filled, s);

    try testing.expect(!okx_trade.executionAllowed(false, true));
    try testing.expect(!okx_trade.executionAllowed(true, false));
}

// --- AC-FD9: boundary breach path into FLATTENING / HALTED ------------------

test "AC-FD9 exit trigger flattens then halts; HALTED needs operator" {
    var m = sm.next(.normal, .exit_trigger);
    try testing.expectEqual(sm.RiskMode.flattening, m);
    try testing.expect(!sm.allowsRiskIncrease(m));
    try testing.expect(sm.allowsRiskReduction(m));

    m = sm.next(m, .flatten_complete);
    try testing.expectEqual(sm.RiskMode.halted, m);
    try testing.expect(!sm.allowsRiskIncrease(m));
    try testing.expect(!sm.allowsRiskReduction(m));

    try testing.expectEqual(sm.RiskMode.halted, sm.next(m, .conditions_ok));
    try testing.expectEqual(sm.RiskMode.exit_only, sm.next(m, .operator_reset));
}

// --- Cross-cutting: demo replan stays bounded --------------------------------

test "AC-FR06 residual replan leg cap is hard" {
    try testing.expect(okx_trade.wantsResidualPlan("partial"));
    try testing.expect(okx_trade.canPlaceAnotherLeg(0));
    try testing.expect(okx_trade.canPlaceAnotherLeg(1));
    try testing.expect(!okx_trade.canPlaceAnotherLeg(2));
    try testing.expectEqual(@as(u16, 3), okx_trade.max_replan_legs);
}

// --- Equity floor still holds under stressed params (FD9 support) ------------

test "AC-RK1 conservative equity never ignores exit costs" {
    const e = try equity.conservativeEquity(.{
        .cash_usdt = d("50"),
        .btc_total = d("0.001"),
        .liq_price = d("100000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.0005") },
    });
    // 0.001 BTC @ 100k = 100 notional + 50 cash; exit costs pull below 150.
    try testing.expect(e.equity.lt(d("150")));
    try testing.expect(e.equity.gt(d("50")));
}
