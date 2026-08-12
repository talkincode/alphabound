//! State Engine (§3.2, §4.2): the single owner of mutable trading state.
//! All inputs (WS ticks, REST reconciliation, order execution, agent
//! proposals) become messages processed in order; every mutation bumps the
//! snapshot version. Readers only ever see immutable snapshots.

const std = @import("std");
const dec = @import("decimal.zig");
const Decimal = dec.Decimal;
const sm = @import("../risk/state_machine.zig");
const equity_mod = @import("../risk/equity.zig");
const orders_mod = @import("../execution/orders.zig");

pub const FreshnessState = struct {
    market_last_ms: i64 = 0,
    account_last_ms: i64 = 0,
    /// Data older than this is stale (drives EXIT_ONLY, §7.2).
    market_ttl_ms: i64 = 10_000,
    account_ttl_ms: i64 = 30_000,

    pub fn marketFresh(self: FreshnessState, now_ms: i64) bool {
        return self.market_last_ms > 0 and now_ms - self.market_last_ms <= self.market_ttl_ms;
    }

    pub fn accountFresh(self: FreshnessState, now_ms: i64) bool {
        return self.account_last_ms > 0 and now_ms - self.account_last_ms <= self.account_ttl_ms;
    }
};

pub const PortfolioState = struct {
    version: u64 = 0,
    as_of_ms: i64 = 0,
    cash_usdt: Decimal = Decimal.zero,
    btc_total: Decimal = Decimal.zero,
    btc_available: Decimal = Decimal.zero,
    bid_price: Decimal = Decimal.zero, // liquidation-side price
    mark_price: Decimal = Decimal.zero,
    conservative_equity: Decimal = Decimal.zero,
    high_watermark: Decimal = Decimal.zero,
    drawdown: Decimal = Decimal.zero,
    risk_mode: sm.RiskMode = .exit_only, // fail-closed until reconciled
    reconciled: bool = false,
    unresolved_orders: bool = false,
    /// False when the DB volume is in low/critical free-space band (FD7).
    disk_ok: bool = true,
    /// False when the audit journal (events append) is failing (AC-GO6):
    /// un-auditable trading must not continue increasing risk.
    journal_ok: bool = true,
    freshness: FreshnessState = .{},
};

pub const Message = union(enum) {
    market_tick: struct {
        ts_ms: i64,
        bid: Decimal,
        mark: Decimal,
    },
    account_update: struct {
        ts_ms: i64,
        cash_usdt: Decimal,
        btc_total: Decimal,
        btc_available: Decimal,
    },
    reconcile_result: struct {
        ts_ms: i64,
        cash_usdt: Decimal,
        btc_total: Decimal,
        btc_available: Decimal,
        hwm_from_db: Decimal,
        clean: bool, // false = mismatch found, corrections were emitted
    },
    order_ambiguity: struct { present: bool },
    risk_trigger: sm.Trigger,
    /// Disk free-space health for the DB volume (FD7). `ok=false` → degraded.
    disk_status: struct { ok: bool },
    /// Audit journal write health (AC-GO6). `ok=false` → degraded.
    journal_status: struct { ok: bool },
    clock_tick: struct { ts_ms: i64 }, // periodic freshness re-evaluation
};

pub const ApplyResult = struct {
    /// Risk mode changed during this message (worth a critical event).
    mode_changed: bool = false,
    /// Drawdown boundary reached during this message.
    boundary_hit: bool = false,
};

pub const Engine = struct {
    state: PortfolioState = .{},
    exit_costs: equity_mod.ExitCostParams,
    max_drawdown: Decimal,

    pub fn init(exit_costs: equity_mod.ExitCostParams, max_drawdown: Decimal) Engine {
        return .{ .exit_costs = exit_costs, .max_drawdown = max_drawdown };
    }

    /// Restore high watermark from storage at boot (§7.1 BOOTING).
    pub fn restoreHwm(self: *Engine, hwm: Decimal) void {
        self.state.high_watermark = hwm;
        self.state.version += 1;
    }

    /// Sequentially apply one message. This is the only place state mutates.
    pub fn apply(self: *Engine, msg: Message) dec.DecimalError!ApplyResult {
        var result = ApplyResult{};
        const prev_mode = self.state.risk_mode;

        switch (msg) {
            .market_tick => |t| {
                self.state.bid_price = t.bid;
                self.state.mark_price = t.mark;
                self.state.freshness.market_last_ms = t.ts_ms;
                self.state.as_of_ms = t.ts_ms;
                try self.revalue(t.ts_ms);
            },
            .account_update => |u| {
                self.state.cash_usdt = u.cash_usdt;
                self.state.btc_total = u.btc_total;
                self.state.btc_available = u.btc_available;
                self.state.freshness.account_last_ms = u.ts_ms;
                self.state.as_of_ms = u.ts_ms;
                try self.revalue(u.ts_ms);
            },
            .reconcile_result => |r| {
                self.state.cash_usdt = r.cash_usdt;
                self.state.btc_total = r.btc_total;
                self.state.btc_available = r.btc_available;
                self.state.high_watermark = Decimal.max(self.state.high_watermark, r.hwm_from_db);
                self.state.freshness.account_last_ms = r.ts_ms;
                self.state.reconciled = r.clean;
                self.state.as_of_ms = r.ts_ms;
                try self.revalue(r.ts_ms);
            },
            .order_ambiguity => |o| {
                self.state.unresolved_orders = o.present;
                self.evaluateHealth(self.state.as_of_ms);
            },
            .risk_trigger => |t| {
                self.state.risk_mode = sm.next(self.state.risk_mode, t);
            },
            .disk_status => |dsk| {
                self.state.disk_ok = dsk.ok;
                self.evaluateHealth(self.state.as_of_ms);
            },
            .journal_status => |j| {
                self.state.journal_ok = j.ok;
                self.evaluateHealth(self.state.as_of_ms);
            },
            .clock_tick => |c| {
                self.state.as_of_ms = c.ts_ms;
                self.evaluateHealth(c.ts_ms);
            },
        }

        self.state.version += 1;
        result.mode_changed = self.state.risk_mode != prev_mode;
        result.boundary_hit = self.state.drawdown.gte(self.max_drawdown) and
            self.state.high_watermark.gt(Decimal.zero);
        return result;
    }

    /// Immutable snapshot for readers (agent, dashboard, risk worker).
    pub fn snapshot(self: *const Engine) PortfolioState {
        return self.state;
    }

    fn revalue(self: *Engine, now_ms: i64) dec.DecimalError!void {
        if (self.state.bid_price.gt(Decimal.zero)) {
            const r = try equity_mod.conservativeEquity(.{
                .cash_usdt = self.state.cash_usdt,
                .btc_total = self.state.btc_total,
                .liq_price = self.state.bid_price,
                .exit_costs = self.exit_costs,
            });
            self.state.conservative_equity = r.equity;
            if (self.state.reconciled) {
                // HWM only advances on reconciled data — unconfirmed balances
                // must not raise the boundary reference (§5.1 conservatism).
                self.state.high_watermark = equity_mod.updateHighWatermark(self.state.high_watermark, r.equity);
            }
            self.state.drawdown = try equity_mod.drawdown(self.state.high_watermark, r.equity);
        }
        self.evaluateHealth(now_ms);

        // Boundary breach forces flattening (§5.3), regardless of health.
        if (self.state.high_watermark.gt(Decimal.zero) and
            self.state.drawdown.gte(self.max_drawdown) and
            (self.state.risk_mode == .normal or self.state.risk_mode == .exit_only))
        {
            self.state.risk_mode = sm.next(self.state.risk_mode, .exit_trigger);
        }
    }

    fn evaluateHealth(self: *Engine, now_ms: i64) void {
        const healthy = self.state.reconciled and
            !self.state.unresolved_orders and
            self.state.disk_ok and
            self.state.journal_ok and
            self.state.freshness.marketFresh(now_ms) and
            self.state.freshness.accountFresh(now_ms);
        const trigger: sm.Trigger = if (healthy) .conditions_ok else .degraded;
        self.state.risk_mode = sm.next(self.state.risk_mode, trigger);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn testEngine() Engine {
    return Engine.init(
        .{ .fee_rate = d("0.001"), .slippage_rate = d("0.0005") },
        d("0.10"),
    );
}

test "starts exit_only until reconciled and fresh" {
    var e = testEngine();
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);

    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100050") } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode); // account still unknown

    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1500,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
    try testing.expect(e.snapshot().reconciled);
}

test "versions increase monotonically per message" {
    var e = testEngine();
    const v0 = e.snapshot().version;
    _ = try e.apply(.{ .clock_tick = .{ .ts_ms = 1 } });
    _ = try e.apply(.{ .clock_tick = .{ .ts_ms = 2 } });
    try testing.expectEqual(v0 + 2, e.snapshot().version);
}

test "disk not ok degrades to exit_only until cleared" {
    var e = testEngine();
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100000") } });
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);

    _ = try e.apply(.{ .disk_status = .{ .ok = false } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);
    try testing.expect(!e.snapshot().disk_ok);

    // Fresh market tick must not clear disk pressure by itself.
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 2000, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);

    _ = try e.apply(.{ .disk_status = .{ .ok = true } });
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 3000, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
}

test "journal failure degrades to exit_only until writes recover (AC-GO6)" {
    var e = testEngine();
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100000") } });
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);

    _ = try e.apply(.{ .journal_status = .{ .ok = false } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);
    try testing.expect(!e.snapshot().journal_ok);

    // Fresh market data must not clear a broken audit journal by itself.
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 2000, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);

    _ = try e.apply(.{ .journal_status = .{ .ok = true } });
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 3000, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
}

test "stale market data degrades to exit_only" {
    var e = testEngine();
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100000") } });
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);

    // 60 seconds later with no market data → stale → EXIT_ONLY
    _ = try e.apply(.{ .clock_tick = .{ .ts_ms = 61_000 } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);

    // fresh tick + fresh account restores NORMAL
    _ = try e.apply(.{ .account_update = .{ .ts_ms = 61_500, .cash_usdt = d("100"), .btc_total = d("0"), .btc_available = d("0") } });
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 62_000, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
}

test "operator exit_trigger moves normal to flattening" {
    var e = testEngine();
    // Reach NORMAL via clean reconcile + fresh market tick.
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1100, .bid = d("100000"), .mark = d("100000") } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
    _ = try e.apply(.{ .risk_trigger = .exit_trigger });
    try testing.expectEqual(sm.RiskMode.flattening, e.snapshot().risk_mode);
}

test "drawdown breach forces flattening and HWM only rises reconciled" {
    var e = testEngine();
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("0"),
        .btc_total = d("0.001"),
        .btc_available = d("0.001"),
        .hwm_from_db = d("0"),
        .clean = true,
    } });
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1100, .bid = d("120000"), .mark = d("120000") } });
    const hwm_at_peak = e.snapshot().high_watermark;
    try testing.expect(hwm_at_peak.gt(d("119"))); // ~119.82 after exit costs

    // price collapses 15% → drawdown > 10% → flattening
    const r = try e.apply(.{ .market_tick = .{ .ts_ms = 1200, .bid = d("102000"), .mark = d("102000") } });
    try testing.expectEqual(sm.RiskMode.flattening, e.snapshot().risk_mode);
    try testing.expect(r.boundary_hit);
    try testing.expect(e.snapshot().high_watermark.eql(hwm_at_peak)); // HWM did not fall
}

test "order ambiguity blocks normal mode" {
    var e = testEngine();
    _ = try e.apply(.{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100000") } });
    _ = try e.apply(.{ .reconcile_result = .{
        .ts_ms = 1000,
        .cash_usdt = d("100"),
        .btc_total = d("0"),
        .btc_available = d("0"),
        .hwm_from_db = d("100"),
        .clean = true,
    } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
    _ = try e.apply(.{ .order_ambiguity = .{ .present = true } });
    try testing.expectEqual(sm.RiskMode.exit_only, e.snapshot().risk_mode);
    _ = try e.apply(.{ .order_ambiguity = .{ .present = false } });
    try testing.expectEqual(sm.RiskMode.normal, e.snapshot().risk_mode);
}

test "replay determinism: same messages, same final state" {
    const msgs = [_]Message{
        .{ .market_tick = .{ .ts_ms = 1000, .bid = d("100000"), .mark = d("100050") } },
        .{ .reconcile_result = .{ .ts_ms = 1100, .cash_usdt = d("100"), .btc_total = d("0"), .btc_available = d("0"), .hwm_from_db = d("100"), .clean = true } },
        .{ .market_tick = .{ .ts_ms = 1200, .bid = d("101000"), .mark = d("101020") } },
        .{ .account_update = .{ .ts_ms = 1300, .cash_usdt = d("50"), .btc_total = d("0.0005"), .btc_available = d("0.0005") } },
        .{ .market_tick = .{ .ts_ms = 1400, .bid = d("99000"), .mark = d("99010") } },
        .{ .clock_tick = .{ .ts_ms = 5000 } },
    };
    var e1 = testEngine();
    var e2 = testEngine();
    for (msgs) |m| {
        _ = try e1.apply(m);
        _ = try e2.apply(m);
    }
    const s1 = e1.snapshot();
    const s2 = e2.snapshot();
    try testing.expectEqual(s1.version, s2.version);
    try testing.expect(s1.conservative_equity.eql(s2.conservative_equity));
    try testing.expect(s1.high_watermark.eql(s2.high_watermark));
    try testing.expect(s1.drawdown.eql(s2.drawdown));
    try testing.expectEqual(s1.risk_mode, s2.risk_mode);
}
