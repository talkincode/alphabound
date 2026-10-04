//! Cross-thread behaviour of the execution lane against the fake venue:
//! the risk loop (this thread) keeps running while orders are worked.

const std = @import("std");
const testing = std.testing;
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const lanes = @import("../core/lanes.zig");
const storage = @import("../storage/db.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const demo_runner = @import("demo_runner.zig");
const exec_lane = @import("exec_lane.zig");
const planner = @import("planner.zig");
const risk_sm = @import("../risk/state_machine.zig");
const fake_okx = @import("../testing/fake_okx.zig");

const Decimal = dec.Decimal;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn wallMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

const Rig = struct {
    gpa: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    path_buf: [512]u8 = undefined,
    path: [:0]const u8 = undefined,
    fake: fake_okx.Fake,
    cfg: config.Config,
    engine: state.Engine,
    service: lanes.Service = .{},
    main_okx: okx_rest.Client,
    lane: exec_lane.ExecLane = .{},
    ticks: u64 = 0,

    fn makeClient(ctx: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io) okx_rest.Client {
        _ = gpa;
        const fake: *fake_okx.Fake = @ptrCast(@alignCast(ctx.?));
        return fake.client(io);
    }

    fn create(gpa: std.mem.Allocator) !*Rig {
        const rig = try gpa.create(Rig);
        errdefer gpa.destroy(rig);
        rig.* = .{
            .gpa = gpa,
            .tmp = std.testing.tmpDir(.{}),
            .fake = fake_okx.Fake.init(gpa),
            .cfg = try config.parse(gpa, "[exchange]\nmode = \"live\"\n"),
            .engine = undefined,
            .main_okx = undefined,
        };
        var dir_buf: [400]u8 = undefined;
        const n = try rig.tmp.dir.realPath(testing.io, &dir_buf);
        rig.path = try std.fmt.bufPrintZ(&rig.path_buf, "{s}/lane.db", .{dir_buf[0..n]});
        rig.engine = state.Engine.init(
            .{ .fee_rate = rig.cfg.taker_fee_rate, .slippage_rate = rig.cfg.slippage_rate },
            rig.cfg.max_drawdown,
        );
        rig.engine.claimOwner();
        rig.main_okx = rig.fake.client(testing.io);
        demo_runner.timing = .{ .query_retry_ms = 1, .poll_ms = 2, .absent_grace_ms = 60_000 };
        try rig.lane.start(.{
            .gpa = gpa,
            .io = testing.io,
            .cfg = &rig.cfg,
            .engine = &rig.engine,
            .instrument = .{ .tick_size = d("0.1"), .lot_size = d("0.00000001"), .min_size = d("0.00001"), .min_notional = d("1") },
            .venue_authorized = true,
            .db_path = rig.path,
            .make_client = makeClient,
            .client_ctx = &rig.fake,
            .service = &rig.service,
            .idle_poll_ms = 2,
            .reconcile_timeout_ms = 5_000,
        });
        return rig;
    }

    fn destroy(self: *Rig) void {
        _ = self.lane.shutdown(5_000);
        self.main_okx.deinit();
        self.fake.deinit();
        self.cfg.deinit();
        self.tmp.cleanup();
        self.gpa.destroy(self);
    }

    /// The risk loop's authoritative reconcile (what `refreshAccountForExecution` does).
    fn reconcile(self: *Rig) bool {
        const tick = self.main_okx.getPublic("/api/v5/market/ticker?instId=BTC-USDT") catch return false;
        defer self.gpa.free(tick);
        const t = okx_rest.parseTicker(self.gpa, tick) catch return false;
        _ = self.engine.apply(.{ .market_tick = .{ .ts_ms = t.ts_ms, .bid = t.bid, .mark = t.last } }) catch return false;
        switch (okx_rest.probeBalance(&self.main_okx, self.gpa, wallMs())) {
            .ok => |b| {
                _ = self.engine.apply(.{ .reconcile_result = .{
                    .ts_ms = wallMs(),
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

    fn reconcileThunk(raw: *anyopaque) bool {
        const self: *Rig = @ptrCast(@alignCast(raw));
        return self.reconcile();
    }

    /// One iteration of the risk loop: market tick, owner-only work for the lanes.
    fn spin(self: *Rig) void {
        const tick = self.main_okx.getPublic("/api/v5/market/ticker?instId=BTC-USDT") catch return;
        defer self.gpa.free(tick);
        if (okx_rest.parseTicker(self.gpa, tick)) |t| {
            _ = self.engine.apply(.{ .market_tick = .{ .ts_ms = t.ts_ms, .bid = t.bid, .mark = t.last } }) catch {};
        } else |_| {}
        _ = self.engine.drainInbox();
        _ = self.service.pump(self, reconcileThunk);
        self.ticks += 1;
    }

    fn seed(self: *Rig, usdt: []const u8, btc: []const u8, bid: []const u8, hwm: []const u8) void {
        self.fake.usdt = d(usdt);
        self.fake.btc = d(btc);
        self.fake.bid = d(bid);
        self.fake.ask = d(bid);
        std.debug.assert(self.reconcile());
        self.engine.restoreHwm(d(hwm));
        std.debug.assert(self.reconcile());
    }
};

const SlowThinker = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *SlowThinker) void {
        // Stand-in for an LLM call that takes far longer than any risk deadline.
        testing.io.sleep(.{ .nanoseconds = 900_000_000 }, .awake) catch {};
        self.done.store(true, .release);
    }
};

test "a flatten completes on the execution lane while the thinking lane is stuck on a slow model" {
    const rig = try Rig.create(testing.allocator);
    defer rig.destroy();
    rig.seed("0", "0.001", "89000", "100");
    try testing.expectEqual(risk_sm.RiskMode.flattening, rig.engine.snapshot().risk_mode);

    var thinker = SlowThinker{};
    const t = try std.Thread.spawn(.{}, SlowThinker.run, .{&thinker});
    defer t.join();

    const t0 = wallMs();
    try testing.expect(rig.lane.submit(.{ .flatten = .{ .force = true } }, true));
    while (wallMs() - t0 < 600 and rig.engine.snapshot().risk_mode != .halted) {
        rig.spin();
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expectEqual(risk_sm.RiskMode.halted, rig.engine.snapshot().risk_mode);
    try testing.expect(!thinker.done.load(.acquire)); // model call still hanging
    try testing.expect(rig.fake.btc.lt(d("0.00001")));
    // The risk loop kept ticking the whole time.
    try testing.expect(rig.ticks >= 3);
}

test "a resting limit order never blocks the risk loop and is canceled when execution is blocked" {
    const rig = try Rig.create(testing.allocator);
    defer rig.destroy();
    rig.seed("1000", "0", "100000", "1000");
    rig.fake.fill_mode = .none;

    var reply = exec_lane.Reply{};
    var job = exec_lane.AgentJob{
        .requested_weight = d("0.5"),
        .order_type = .limit_only,
        .urgency = d("1"),
        .max_wait_ms = 60_000, // would block a synchronous caller for a minute
        .created_ms = wallMs(),
        .reply = &reply,
    };
    job.decision_id.set("dec_lane_rest");
    try testing.expect(rig.lane.submit(.{ .agent = job }, false));

    // The order rests on the venue while this thread keeps running the loop.
    const t0 = wallMs();
    var resting = false;
    while (wallMs() - t0 < 1500 and !resting) {
        rig.spin();
        resting = rig.fake.countCalls(.POST, "/api/v5/trade/order") == 1 and
            rig.fake.lastOrder() != null and rig.fake.lastOrder().?.state == .live;
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expect(resting);
    const ticks_before = rig.ticks;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        rig.spin();
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expect(rig.ticks - ticks_before == 20);
    try testing.expect(!reply.done.load(.acquire)); // still waiting on the venue

    // Risk escalation blocks agent execution: the order is canceled and confirmed.
    rig.lane.setAgentBlocked(true);
    const t1 = wallMs();
    while (wallMs() - t1 < 2000 and !reply.done.load(.acquire)) {
        rig.spin();
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expect(reply.done.load(.acquire));
    try testing.expectEqual(fake_okx.OrderState.canceled, rig.fake.lastOrder().?.state);
    try testing.expectEqual(@as(usize, 1), rig.fake.countCalls(.POST, "/api/v5/trade/order"));
}

test "a queued agent rebalance that went stale is dropped, not executed late" {
    const rig = try Rig.create(testing.allocator);
    defer rig.destroy();
    rig.seed("1000", "0", "100000", "1000");

    var reply = exec_lane.Reply{};
    var job = exec_lane.AgentJob{
        .requested_weight = d("0.5"),
        .order_type = .limit_or_market,
        .urgency = d("1"),
        .max_wait_ms = 0,
        .created_ms = wallMs() - 2 * exec_lane.max_queue_age_ms,
        .reply = &reply,
    };
    job.decision_id.set("dec_lane_stale");
    try testing.expect(rig.lane.submit(.{ .agent = job }, false));
    const t0 = wallMs();
    while (wallMs() - t0 < 1000 and !reply.done.load(.acquire)) {
        rig.spin();
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expectEqualStrings("stale_dropped", reply.note.get());
    try testing.expectEqual(@as(usize, 0), rig.fake.countCalls(.POST, "/api/v5/trade/order"));
}

test "a fresh agent rebalance runs on the lane with an execution-time admission" {
    const rig = try Rig.create(testing.allocator);
    defer rig.destroy();
    rig.seed("1000", "0", "100000", "1000");

    var reply = exec_lane.Reply{};
    var job = exec_lane.AgentJob{
        .requested_weight = d("0.5"),
        .order_type = .limit_or_market,
        .urgency = d("1"),
        .max_wait_ms = 0,
        .created_ms = wallMs(),
        .reply = &reply,
    };
    job.decision_id.set("dec_lane_fresh");
    try testing.expect(rig.lane.submit(.{ .agent = job }, false));
    const t0 = wallMs();
    while (wallMs() - t0 < 3000 and !reply.done.load(.acquire)) {
        rig.spin();
        try testing.io.sleep(.{ .nanoseconds = 2_000_000 }, .awake);
    }
    try testing.expect(reply.done.load(.acquire));
    try testing.expectEqualStrings("filled", reply.note.get());
    try testing.expectEqualStrings("APPROVE", reply.verdict.get());
    try testing.expect(reply.exec_version > 0);
    try testing.expectEqual(@as(usize, 1), rig.fake.countCalls(.POST, "/api/v5/trade/order"));
}

test "the lane queue is bounded and tells the sender when it is full" {
    var lane = exec_lane.ExecLane{};
    var i: usize = 0;
    while (i < 8) : (i += 1) try testing.expect(lane.submit(.cancel_all, false));
    try testing.expect(!lane.submit(.cancel_all, false));
    try testing.expect(!lane.submit(.{ .flatten = .{ .force = true } }, true)); // even urgent work cannot grow it
}
