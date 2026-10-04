//! End-to-end failure-injection regressions for the order chain: engine +
//! SQLite ledger + planner + admission + OKX client, against an in-process
//! fake venue. Each test names the audited defect it pins down.

const std = @import("std");
const testing = std.testing;
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const risk_sm = @import("../risk/state_machine.zig");
const demo_runner = @import("demo_runner.zig");
const operator = @import("operator.zig");
const harness = @import("../testing/harness.zig");
const fake_okx = @import("../testing/fake_okx.zig");

const Harness = harness.Harness;
const d = harness.d;

const place_path = "/api/v5/trade/order";

test "P1-1: a lost placement response is queried, never re-sent" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.fake.addFault(.{ .method = .POST, .path = "/trade/order", .nth = 1, .action = .drop_after_apply });

    _ = h.execute("dec_lost_ack", "0.5", false);

    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
    try testing.expectEqual(@as(usize, 1), h.fake.orders.items.len);
    try testing.expect(h.fake.countCalls(.GET, "/api/v5/trade/order?") >= 1);
}

test "P1-2: a business error with an empty data list never resolves an order" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.fake.addFault(.{ .method = .GET, .path = "/trade/order?", .nth = 0, .action = .api_error, .code = "50011" });

    _ = h.execute("dec_err_query", "0.5", false);

    try testing.expectEqual(@as(i64, 0), h.countOrdersWithStatus("CANCELED"));
    try testing.expect(h.engine.snapshot().unresolved_orders);
}

test "P1-2: whitespace variant of an empty list is not proof of cancellation" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.fake.addFault(.{
        .method = .GET,
        .path = "/trade/order?",
        .nth = 0,
        .action = .raw_body,
        .raw = "{\"code\": \"51603\", \"msg\": \"Order does not exist\", \"data\": [ ]}",
    });

    _ = h.execute("dec_ws_query", "0.5", false);

    try testing.expectEqual(@as(i64, 0), h.countOrdersWithStatus("CANCELED"));
    try testing.expect(h.engine.snapshot().unresolved_orders);
}

test "P1-2: an order not yet visible stays unresolved instead of canceled" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.new_order_hidden_queries = 100;

    _ = h.execute("dec_hidden", "0.5", false);

    try testing.expectEqual(@as(i64, 0), h.countOrdersWithStatus("CANCELED"));
    try testing.expect(h.engine.snapshot().unresolved_orders);
}

test "P1-3: a rejected cancel after a partial fill never opens another leg" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .fraction;
    h.fake.cancel_mode = .reject;

    _ = h.execute("dec_cancel_reject", "0.5", true);

    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
    try testing.expect(h.engine.snapshot().unresolved_orders);
}

fn crashPriceOnFirstRefresh(h: *Harness) void {
    if (h.refresh_calls == 1) {
        h.fake.bid = d("50000");
        h.fake.ask = d("50000");
    }
}

test "P1-3: every replanned leg is re-admitted on a fresh snapshot" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .fraction;
    h.before_refresh = crashPriceOnFirstRefresh;

    _ = h.execute("dec_leg_gate", "0.5", true);

    try testing.expectEqual(risk_sm.RiskMode.flattening, h.engine.snapshot().risk_mode);
    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
}

test "P1-4: a failed refresh projects the actual fill, not the order size" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .fraction;
    h.fake.fill_fraction = d("0.2");
    const account_ms_before = h.engine.snapshot().freshness.account_last_ms;
    try h.fake.addFault(.{ .method = .GET, .path = "/account/balance", .nth = 0, .action = .http_error });

    _ = h.execute("dec_projection", "0.5", false);

    const snap = h.engine.snapshot();
    // Ordered 0.005 BTC, venue filled 0.001: the book may hold at most that.
    try testing.expect(snap.btc_total.lt(d("0.002")));
    try testing.expectEqual(account_ms_before, snap.freshness.account_last_ms);
}

test "P1-5: a failed intent write blocks the venue request" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.db.execAll("CREATE TRIGGER fail_orders_insert BEFORE INSERT ON orders BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END;");

    const note = h.execute("dec_no_intent", "0.5", false);

    try testing.expectEqual(@as(usize, 0), h.fake.countCalls(.POST, place_path));
    try testing.expectEqualStrings("intent_persist_failed", note);
}

test "P1-5: a failed acknowledgement write keeps the order unresolved" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.db.execAll("CREATE TRIGGER fail_orders_update BEFORE UPDATE ON orders BEGIN SELECT RAISE(ABORT, 'disk I/O error'); END;");

    _ = h.execute("dec_ack_write", "0.5", false);

    try testing.expect(h.engine.snapshot().unresolved_orders);
}

fn placeRestingOrder(h: *Harness, cl_id: []const u8) !void {
    const body = try std.fmt.allocPrint(testing.allocator, "{{\"instId\":\"BTC-USDT\",\"tdMode\":\"cash\",\"side\":\"buy\",\"ordType\":\"limit\",\"sz\":\"0.001\",\"px\":\"99000\",\"clOrdId\":\"{s}\"}}", .{cl_id});
    defer testing.allocator.free(body);
    const resp = try h.okx.postPrivate("/api/v5/trade/order", body, 0);
    testing.allocator.free(resp);
}

test "P1-7: cancel-all keeps the order ambiguity when the pending list fails" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    try placeRestingOrder(h, "abresting01");
    _ = try h.engine.apply(.{ .order_ambiguity = .{ .present = true } });
    try h.fake.addFault(.{ .method = .GET, .path = "orders-pending", .nth = 0, .action = .http_error });

    _ = operator.cancelAll(h.operatorEnv());

    try testing.expect(h.engine.snapshot().unresolved_orders);
    try testing.expectEqual(fake_okx.OrderState.live, h.fake.findOrder("abresting01").?.state);
}

test "P1-7: cancel-all keeps the order ambiguity when the venue rejects the cancel" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    try placeRestingOrder(h, "abresting02");
    _ = try h.engine.apply(.{ .order_ambiguity = .{ .present = true } });
    h.fake.cancel_mode = .reject;

    _ = operator.cancelAll(h.operatorEnv());

    try testing.expect(h.engine.snapshot().unresolved_orders);
}

test "P1-8: cumulative fills accumulate across partial -> larger partial -> filled" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    const cl = "abcum000000000000000000000000001";
    try placeRestingOrder(h, cl);
    try h.orders.upsert(.{
        .client_order_id = cl,
        .decision_id = "dec_cum",
        .side = "buy",
        .qty = "0.001",
        .price = "99000",
        .status = "ACKNOWLEDGED",
        .created_ts = "2026-01-01T00:00:00.000Z",
        .updated_ts = "2026-01-01T00:00:00.000Z",
    });
    const ref = demo_runner.OrderRef{
        .cl_id = cl,
        .decision_id = "dec_cum",
        .side = "buy",
        .qty_s = "0.001",
        .price_s = "99000",
        .created_ts = "2026-01-01T00:00:00.000Z",
        .created_ms = 0,
    };
    const ctx = h.ctx();

    try h.fake.fillOrder(cl, d("0.0002"), d("99000"));
    try testing.expectEqual(demo_runner.ObsKind.partial, demo_runner.observeOnce(&ctx, ref).kind);
    try testing.expect(h.filledQty(cl).eql(d("0.0002")));

    try h.fake.fillOrder(cl, d("0.0003"), d("99000"));
    _ = demo_runner.observeOnce(&ctx, ref);
    try h.fake.fillOrder(cl, d("0.0005"), d("99000"));
    try testing.expectEqual(demo_runner.ObsKind.filled, demo_runner.observeOnce(&ctx, ref).kind);
    // A repeated query must not count anything twice.
    _ = demo_runner.observeOnce(&ctx, ref);

    try testing.expect(h.filledQty(cl).eql(d("0.001")));
}

test "P0-1: a flatten drive past the drawdown boundary can still reduce the position" {
    var h = try Harness.create(testing.allocator, "live");
    defer h.destroy();
    h.seed("0", "0.001", "89000", "100");
    try testing.expectEqual(risk_sm.RiskMode.flattening, h.engine.snapshot().risk_mode);

    var last: i64 = 0;
    operator.driveFlatten(h.operatorEnv(), &last, true);

    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
    try testing.expect(h.fake.btc.lt(d("0.00001")));
}

test "P0-1: the flatten completes into HALTED once the venue confirms the position is gone" {
    var h = try Harness.create(testing.allocator, "live");
    defer h.destroy();
    h.seed("0", "0.001", "89000", "100");
    var last: i64 = 0;
    operator.driveFlatten(h.operatorEnv(), &last, true);
    try testing.expectEqual(risk_sm.RiskMode.halted, h.engine.snapshot().risk_mode);
}

test "P0-1: a gap through the boundary where exit costs exceed the buffer still exits, and never buys" {
    var h = try Harness.create(testing.allocator, "live");
    defer h.destroy();
    h.seed("5", "0.002", "50000", "1000"); // 99% drawdown
    try testing.expectEqual(risk_sm.RiskMode.flattening, h.engine.snapshot().risk_mode);
    var last: i64 = 0;
    operator.driveFlatten(h.operatorEnv(), &last, true);
    for (h.fake.calls.items) |c| {
        if (c.method == .POST and std.mem.indexOf(u8, c.path, "/trade/order") != null) {
            try testing.expect(std.mem.indexOf(u8, c.body, "\"side\":\"sell\"") != null);
            try testing.expect(std.mem.indexOf(u8, c.body, "\"side\":\"buy\"") == null);
        }
    }
    try testing.expect(h.fake.btc.lt(d("0.00001")));
}

test "P0-1: a flatten with an unresolved order does not sell again" {
    var h = try Harness.create(testing.allocator, "live");
    defer h.destroy();
    h.seed("0", "0.001", "89000", "100");
    _ = try h.engine.apply(.{ .order_ambiguity = .{ .present = true } });
    var last: i64 = 0;
    operator.driveFlatten(h.operatorEnv(), &last, true);
    try testing.expectEqual(@as(usize, 0), h.fake.countCalls(.POST, place_path));
}

test "P0-1: a flatten cannot sell on a projected (non-authoritative) book" {
    var h = try Harness.create(testing.allocator, "live");
    defer h.destroy();
    h.seed("0", "0.001", "89000", "100");
    try h.fake.addFault(.{ .method = .GET, .path = "/account/balance", .nth = 0, .action = .http_error });
    _ = try h.engine.apply(.{ .account_projection = .{ .ts_ms = 0, .cash_usdt = d("0"), .btc_total = d("0.001"), .btc_available = d("0.001") } });
    var last: i64 = 0;
    operator.driveFlatten(h.operatorEnv(), &last, true);
    try testing.expectEqual(@as(usize, 0), h.fake.countCalls(.POST, place_path));
    try testing.expectEqual(risk_sm.RiskMode.flattening, h.engine.snapshot().risk_mode);
}

fn recordLiveOrder(h: *Harness, cl_id: []const u8, status: []const u8, created_ts: []const u8) !void {
    try h.orders.upsert(.{
        .client_order_id = cl_id,
        .decision_id = "dec_restart",
        .side = "buy",
        .qty = "0.001",
        .price = "99000",
        .status = status,
        .created_ts = created_ts,
        .updated_ts = created_ts,
    });
}

test "P1-6: after a restart a resting order is canceled and verified before trading reopens" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    const cl = "abrestart00000000000000000000001";
    try placeRestingOrder(h, cl);
    try recordLiveOrder(h, cl, "ACKNOWLEDGED", "2026-01-01T00:00:00.000Z");
    h.restartProcess();
    try testing.expect(h.engine.snapshot().unresolved_orders);

    // Trading stays closed while the previous process' order is unaccounted for.
    try testing.expectEqualStrings("unresolved_orders", h.execute("dec_after_restart", "0.5", false));
    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));

    const report = h.recover();
    try testing.expect(report.complete);
    try testing.expectEqual(@as(usize, 1), report.canceled);
    try testing.expectEqual(fake_okx.OrderState.canceled, h.fake.findOrder(cl).?.state);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("CANCELED", h.orderStatus(cl, &buf).?);
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "P1-6: an order that filled while the process was down is booked, not re-traded" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    const cl = "abrestart00000000000000000000002";
    try placeRestingOrder(h, cl);
    try recordLiveOrder(h, cl, "ACKNOWLEDGED", "2026-01-01T00:00:00.000Z");
    try h.fake.fillOrder(cl, d("0.001"), d("99000"));
    h.restartProcess();

    const report = h.recover();
    try testing.expect(report.complete);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("FILLED", h.orderStatus(cl, &buf).?);
    try testing.expect(h.filledQty(cl).eql(d("0.001")));
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "P1-6: an unknown order the venue cannot see yet keeps trading closed" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    var now_buf: [32]u8 = undefined;
    const now_ts = try @import("../core/clock.zig").formatRfc3339Ms(@import("../core/clock.zig").SystemClock.clock().wallMs(), &now_buf);
    try recordLiveOrder(h, "abrestart00000000000000000000003", "UNKNOWN", now_ts);
    h.restartProcess();

    const report = h.recover();
    try testing.expect(!report.complete);
    try testing.expectEqual(@as(usize, 1), report.unresolved);
    try testing.expect(h.engine.snapshot().unresolved_orders);
    try testing.expectEqual(@as(i64, 0), h.countOrdersWithStatus("CANCELED"));
}

test "P1-6: an intent the venue never saw is resolved only after the visibility grace" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try recordLiveOrder(h, "abrestart00000000000000000000004", "PLANNED", "2026-01-01T00:00:00.000Z");
    h.restartProcess();

    const report = h.recover();
    try testing.expect(report.complete);
    try testing.expectEqual(@as(i64, 1), h.countOrdersWithStatus("CANCELED"));
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "P1-6: a venue order the ledger does not own keeps trading closed until cancel-all verifies" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    try placeRestingOrder(h, "abforeign0000000000000000000001");
    h.restartProcess();

    const report = h.recover();
    try testing.expect(!report.complete);
    try testing.expectEqual(@as(usize, 1), report.foreign);
    try testing.expect(h.engine.snapshot().unresolved_orders);

    const cancel = operator.cancelAll(h.operatorEnv());
    try testing.expect(cancel.verified_clear);
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "P1-6: an unreadable pending list is not proof of a clean venue" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try h.fake.addFault(.{ .method = .GET, .path = "orders-pending", .nth = 0, .action = .http_error });
    h.restartProcess();
    _ = try h.engine.apply(.{ .order_ambiguity = .{ .present = true } });

    const report = h.recover();
    try testing.expect(!report.complete);
    try testing.expect(h.engine.snapshot().unresolved_orders);
}

test "P1-6: kill after acceptance, restart, recover: the old order is settled before new trading" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    // The process "dies" mid-leg: nothing it asks the venue afterwards is answered.
    try h.fake.addFault(.{ .method = .GET, .path = "/trade/order?", .nth = 0, .action = .http_error });
    _ = h.execute("dec_kill", "0.5", true);
    try testing.expect(h.engine.snapshot().unresolved_orders);
    const orphan = h.fake.lastOrder().?;
    try testing.expectEqual(fake_okx.OrderState.live, orphan.state);

    h.fake.clearFaults();
    h.restartProcess();
    const report = h.recover();
    try testing.expect(report.complete);
    try testing.expectEqual(fake_okx.OrderState.canceled, h.fake.lastOrder().?.state);
    h.fake.fill_mode = .full;
    try testing.expectEqualStrings("filled", h.execute("dec_after_kill", "0.5", false));
}

test "P1-7: cancel-all clears the ambiguity only after a verified clean venue and ledger" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    try placeRestingOrder(h, "abresting03");
    _ = try h.engine.apply(.{ .order_ambiguity = .{ .present = true } });

    const report = operator.cancelAll(h.operatorEnv());

    try testing.expect(report.verified_clear);
    try testing.expectEqual(@as(usize, 1), report.canceled);
    try testing.expectEqual(fake_okx.OrderState.canceled, h.fake.findOrder("abresting03").?.state);
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "P1-7: an order that fills during cancel-all is observed, not assumed canceled" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    const cl = "abfillcancel000000000000000000001";
    try placeRestingOrder(h, cl);
    try recordLiveOrder(h, cl, "ACKNOWLEDGED", "2026-01-01T00:00:00.000Z");
    try h.fake.fillOrder(cl, d("0.001"), d("99000")); // filled before the cancel lands

    const report = operator.cancelAll(h.operatorEnv());
    _ = report;
    var buf: [16]u8 = undefined;
    // Not pending any more, so cancel-all had nothing to cancel; the ledger
    // still lists it as open until recovery observes the fill.
    try testing.expect(h.engine.snapshot().unresolved_orders);
    const rec = h.recover();
    try testing.expect(rec.complete);
    try testing.expectEqualStrings("FILLED", h.orderStatus(cl, &buf).?);
}

test "control: a clean market rebalance fills in one leg and leaves nothing open" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    try testing.expectEqualStrings("filled", h.execute("dec_clean", "0.5", false));
    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
    try testing.expectEqual(@as(i64, 0), h.countOrders() - h.countOrdersWithStatus("FILLED"));
    try testing.expect(!h.engine.snapshot().unresolved_orders);
    try testing.expect(h.filledQty(h.fake.lastOrder().?.cl_id).eql(h.fake.lastOrder().?.acc_fill));
}

test "limit wait expires: the resting order is canceled and confirmed, never left working" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    h.max_wait_ms = 30;
    try testing.expectEqualStrings("limit_timeout", h.execute("dec_timeout", "0.5", true));
    try testing.expectEqual(fake_okx.OrderState.canceled, h.fake.lastOrder().?.state);
    try testing.expectEqual(@as(usize, 1), h.fake.countCalls(.POST, place_path));
    try testing.expect(!h.engine.snapshot().unresolved_orders);
}

test "partial fills across legs never exceed the admitted exposure" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .fraction;
    _ = h.execute("dec_legs", "0.5", true);
    // Target is 0.5 of ~1000 USDT at 100k: 0.005 BTC. Fees and rounding aside,
    // the venue must never end up holding more than that.
    try testing.expect(h.fake.btc.lte(d("0.00501")));
    try testing.expect(h.fake.countCalls(.POST, place_path) <= 3);
    // Every order the venue holds is terminal (canceled remainder / filled).
    for (h.fake.orders.items) |o| {
        try testing.expect(o.state == .canceled or o.state == .filled);
    }
}

test "an abort request cancels the resting order and stops before another leg" {
    var h = try Harness.create(testing.allocator, "demo");
    defer h.destroy();
    h.seed("1000", "0", "100000", "1000");
    h.fake.fill_mode = .none;
    h.max_wait_ms = 60_000;
    var abort = std.atomic.Value(bool).init(true);
    const snap = h.engine.snapshot();
    const note = demo_runner.tryDemoExecute(
        h.gpa,
        &h.okx,
        &h.cfg,
        &h.engine,
        &h.db,
        &h.orders,
        &h.fills,
        &h.events,
        h.refresher(),
        "dec_abort",
        "APPROVE",
        d("0.5"),
        h.instrument,
        snap,
        .{ .type = .limit_only, .urgency = d("1"), .max_wait_ms = 60_000 },
        .{ .abort = &abort },
    );
    try testing.expectEqualStrings("aborted", note);
    try testing.expectEqual(@as(usize, 0), h.fake.countCalls(.POST, place_path));
}
