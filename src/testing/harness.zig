//! Test harness wiring the real execution chain (engine, SQLite ledger,
//! planner, admission) to the in-process fake venue. No sockets, no secrets.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const storage = @import("../storage/db.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const planner = @import("../execution/planner.zig");
const demo_runner = @import("../execution/demo_runner.zig");
const operator = @import("../execution/operator.zig");
const fake_okx = @import("fake_okx.zig");

const Decimal = dec.Decimal;

pub fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

pub const Harness = struct {
    gpa: std.mem.Allocator,
    fake: fake_okx.Fake,
    okx: okx_rest.Client,
    db: storage.Db,
    engine: state.Engine,
    orders: storage.OrdersRepo,
    fills: storage.FillsRepo,
    events: storage.EventsRepo,
    cfg: config.Config,
    instrument: planner.Instrument,
    refresh_calls: u32 = 0,
    /// Lets a test mutate the venue/engine right before the next refresh.
    before_refresh: ?*const fn (*Harness) void = null,

    pub fn create(gpa: std.mem.Allocator, mode_text: []const u8) !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.fake = fake_okx.Fake.init(gpa);
        errdefer self.fake.deinit();
        self.okx = self.fake.client(std.testing.io);
        errdefer self.okx.deinit();
        self.db = try storage.Db.open(":memory:");
        errdefer self.db.close();
        var text_buf: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "[exchange]\nmode = \"{s}\"\n", .{mode_text});
        self.cfg = try config.parse(gpa, text);
        errdefer self.cfg.deinit();
        self.engine = state.Engine.init(
            .{ .fee_rate = self.cfg.taker_fee_rate, .slippage_rate = self.cfg.slippage_rate },
            self.cfg.max_drawdown,
        );
        self.orders = try storage.OrdersRepo.init(&self.db);
        self.fills = try storage.FillsRepo.init(&self.db);
        self.events = try storage.EventsRepo.init(&self.db);
        self.instrument = .{
            .tick_size = d("0.1"),
            .lot_size = d("0.00000001"),
            .min_size = d("0.00001"),
            .min_notional = d("1"),
        };
        self.refresh_calls = 0;
        self.before_refresh = null;
        demo_runner.timing = .{ .query_retry_ms = 1, .poll_ms = 1, .absent_grace_ms = 60_000 };
        return self;
    }

    pub fn destroy(self: *Harness) void {
        self.events.deinit();
        self.fills.deinit();
        self.orders.deinit();
        self.cfg.deinit();
        self.db.close();
        self.okx.deinit();
        self.fake.deinit();
        self.gpa.destroy(self);
    }

    pub fn refresher(self: *Harness) demo_runner.PortfolioRefresher {
        return .{ .context = self, .run_fn = refreshThunk };
    }

    fn refreshThunk(raw: *anyopaque) bool {
        const self: *Harness = @ptrCast(@alignCast(raw));
        return self.refresh();
    }

    /// Mirrors the daemon's authoritative private reconcile (balance + ticker).
    pub fn refresh(self: *Harness) bool {
        self.refresh_calls += 1;
        if (self.before_refresh) |f| f(self);
        const tick_body = self.okx.getPublic("/api/v5/market/ticker?instId=BTC-USDT") catch return false;
        defer self.gpa.free(tick_body);
        const ticker = okx_rest.parseTicker(self.gpa, tick_body) catch return false;
        _ = self.engine.apply(.{ .market_tick = .{
            .ts_ms = ticker.ts_ms,
            .bid = ticker.bid,
            .mark = ticker.last,
        } }) catch return false;
        const now = clock.SystemClock.clock().wallMs();
        switch (okx_rest.probeBalance(&self.okx, self.gpa, now)) {
            .ok => |b| {
                _ = self.engine.apply(.{ .reconcile_result = .{
                    .ts_ms = clock.SystemClock.clock().wallMs(),
                    .cash_usdt = b.usdt_cash,
                    .btc_total = b.btc_cash,
                    .btc_available = b.btc_avail,
                    .hwm_from_db = self.engine.snapshot().high_watermark,
                    .clean = true,
                } }) catch return false;
                return true;
            },
            .err => return false,
        }
    }

    /// Put the venue and engine in a reconciled state with the given book.
    pub fn seed(self: *Harness, usdt: []const u8, btc: []const u8, bid: []const u8, hwm: []const u8) void {
        self.fake.usdt = d(usdt);
        self.fake.btc = d(btc);
        self.fake.bid = d(bid);
        self.fake.ask = d(bid);
        self.engine.restoreHwm(d(hwm));
        std.debug.assert(self.refresh());
        self.refresh_calls = 0;
    }

    pub fn orderStatus(self: *Harness, cl_id: []const u8, out: []u8) ?[]const u8 {
        var stmt = self.db.prepare("SELECT status FROM orders WHERE client_order_id = ?1") catch return null;
        defer stmt.finalize();
        stmt.bindText(1, cl_id) catch return null;
        const has = stmt.step() catch return null;
        if (!has) return null;
        const txt = stmt.columnText(0);
        @memcpy(out[0..txt.len], txt);
        return out[0..txt.len];
    }

    pub fn countOrdersWithStatus(self: *Harness, status: []const u8) i64 {
        var stmt = self.db.prepare("SELECT COUNT(*) FROM orders WHERE status = ?1") catch return -1;
        defer stmt.finalize();
        stmt.bindText(1, status) catch return -1;
        _ = stmt.step() catch return -1;
        return stmt.columnInt(0);
    }

    pub fn countOrders(self: *Harness) i64 {
        return self.db.queryInt("SELECT COUNT(*) FROM orders") catch -1;
    }

    /// Sum of all projected fill quantities for one order.
    pub fn filledQty(self: *Harness, order_id: []const u8) Decimal {
        var stmt = self.db.prepare("SELECT qty FROM fills WHERE order_id = ?1") catch return Decimal.zero;
        defer stmt.finalize();
        stmt.bindText(1, order_id) catch return Decimal.zero;
        var total = Decimal.zero;
        while (stmt.step() catch false) {
            const q = Decimal.parse(stmt.columnText(0)) catch continue;
            total = total.add(q) catch total;
        }
        return total;
    }

    pub fn ctx(self: *Harness) demo_runner.Ctx {
        return .{
            .gpa = self.gpa,
            .okx = &self.okx,
            .cfg = &self.cfg,
            .engine = &self.engine,
            .db = &self.db,
            .orders_repo = &self.orders,
            .fills_repo = &self.fills,
            .events_repo = &self.events,
        };
    }

    pub fn operatorEnv(self: *Harness) operator.Env {
        return .{
            .gpa = self.gpa,
            .okx = &self.okx,
            .cfg = &self.cfg,
            .engine = &self.engine,
            .db = &self.db,
            .orders_repo = &self.orders,
            .fills_repo = &self.fills,
            .events_repo = &self.events,
            .refresher = self.refresher(),
            .instrument = self.instrument,
            .venue_authorized = true,
        };
    }

    /// Run the agent-style execution entry with an already admitted weight.
    pub fn execute(self: *Harness, decision_id: []const u8, weight: []const u8, policy_limit_only: bool) []const u8 {
        const snap = self.engine.snapshot();
        return demo_runner.tryDemoExecute(
            self.gpa,
            &self.okx,
            &self.cfg,
            &self.engine,
            &self.db,
            &self.orders,
            &self.fills,
            &self.events,
            self.refresher(),
            decision_id,
            "APPROVE",
            d(weight),
            self.instrument,
            snap,
            .{
                .type = if (policy_limit_only) .limit_only else .limit_or_market,
                .urgency = d("1"),
                .max_wait_ms = 1_000,
            },
            .{},
        );
    }
};
