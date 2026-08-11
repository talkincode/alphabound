//! OKX trade request builders + response helpers for Demo execution (§5.5).
//! Pure / offline-testable — no network. Live mode must never call these
//! from the daemon until Gate 4 explicitly unlocks it.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;
const orders = @import("orders.zig");

pub const PlaceMarket = struct {
    inst_id: []const u8,
    side: orders.Side,
    qty: Decimal,
    client_order_id: []const u8,
};

/// Build POST /api/v5/trade/order body for a spot cash market order.
/// Uses tgtCcy=base_ccy so `sz` is always BTC quantity for both buy and sell.
pub fn formatPlaceMarketBody(buf: []u8, req: PlaceMarket) error{BufferTooSmall}![]const u8 {
    var qty_buf: [48]u8 = undefined;
    const qty_s = req.qty.toString(&qty_buf) catch return error.BufferTooSmall;
    return std.fmt.bufPrint(
        buf,
        "{{\"instId\":\"{s}\",\"tdMode\":\"cash\",\"side\":\"{s}\",\"ordType\":\"market\",\"sz\":\"{s}\",\"clOrdId\":\"{s}\",\"tgtCcy\":\"base_ccy\"}}",
        .{ req.inst_id, req.side.jsonName(), qty_s, req.client_order_id },
    ) catch return error.BufferTooSmall;
}

pub const CancelByClOrdId = struct {
    inst_id: []const u8,
    client_order_id: []const u8,
};

pub fn formatCancelBody(buf: []u8, req: CancelByClOrdId) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"instId\":\"{s}\",\"clOrdId\":\"{s}\"}}",
        .{ req.inst_id, req.client_order_id },
    ) catch return error.BufferTooSmall;
}

/// GET path for order query by client order id (includes leading path + query).
pub fn formatQueryPath(buf: []u8, inst_id: []const u8, client_order_id: []const u8) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/api/v5/trade/order?instId={s}&clOrdId={s}",
        .{ inst_id, client_order_id },
    ) catch return error.BufferTooSmall;
}

/// GET path for pending orders (spot).
pub fn formatPendingPath(buf: []u8, inst_id: []const u8) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "/api/v5/trade/orders-pending?instType=SPOT&instId={s}",
        .{inst_id},
    ) catch return error.BufferTooSmall;
}

/// Map OKX order `state` string → local status (best effort).
pub fn mapOkxState(state: []const u8) orders.OrderStatus {
    if (std.mem.eql(u8, state, "live")) return .acknowledged;
    if (std.mem.eql(u8, state, "partially_filled")) return .partial;
    if (std.mem.eql(u8, state, "filled")) return .filled;
    if (std.mem.eql(u8, state, "canceled") or std.mem.eql(u8, state, "cancelled")) return .canceled;
    if (std.mem.eql(u8, state, "mmp_canceled")) return .canceled;
    return .unknown;
}

/// Whether demo execution is allowed for this process configuration.
/// Live is never allowed here; demo requires simulated trading header path.
pub fn executionAllowed(mode_demo: bool, simulated: bool) bool {
    return mode_demo and simulated;
}

/// After a leg resolves, should we refresh portfolio and try another plan?
/// `partial` always; `filled` too (fees/rounding may leave residual delta).
pub fn wantsResidualPlan(resolve_note: []const u8) bool {
    return std.mem.eql(u8, resolve_note, "partial") or std.mem.eql(u8, resolve_note, "filled");
}

/// Hard cap on market legs per decision (anti-runaway replan).
pub const max_replan_legs: u16 = 3;

/// Whether another leg is still allowed (`leg_index` is 0-based, already placed).
pub fn canPlaceAnotherLeg(leg_index: u16) bool {
    return leg_index + 1 < max_replan_legs;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "place market body uses base_ccy and clOrdId" {
    var buf: [256]u8 = undefined;
    const body = try formatPlaceMarketBody(&buf, .{
        .inst_id = "BTC-USDT",
        .side = .buy,
        .qty = d("0.0001"),
        .client_order_id = "ab00112233445566778899aabbccddee",
    });
    try testing.expect(std.mem.indexOf(u8, body, "\"ordType\":\"market\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tgtCcy\":\"base_ccy\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"side\":\"buy\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"sz\":\"0.0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "ab00112233445566778899aabbccddee") != null);
}

test "cancel and query path builders" {
    var buf: [128]u8 = undefined;
    const c = try formatCancelBody(&buf, .{ .inst_id = "BTC-USDT", .client_order_id = "abdeadbeef" });
    try testing.expect(std.mem.indexOf(u8, c, "clOrdId") != null);
    var pbuf: [160]u8 = undefined;
    const path = try formatQueryPath(&pbuf, "BTC-USDT", "abdeadbeef");
    try testing.expect(std.mem.startsWith(u8, path, "/api/v5/trade/order?"));
    try testing.expect(std.mem.indexOf(u8, path, "clOrdId=abdeadbeef") != null);
}

test "okx state mapping" {
    try testing.expectEqual(orders.OrderStatus.filled, mapOkxState("filled"));
    try testing.expectEqual(orders.OrderStatus.partial, mapOkxState("partially_filled"));
    try testing.expectEqual(orders.OrderStatus.canceled, mapOkxState("canceled"));
    try testing.expectEqual(orders.OrderStatus.acknowledged, mapOkxState("live"));
    try testing.expectEqual(orders.OrderStatus.unknown, mapOkxState("something_else"));
}

test "executionAllowed is demo+simulated only" {
    try testing.expect(executionAllowed(true, true));
    try testing.expect(!executionAllowed(true, false));
    try testing.expect(!executionAllowed(false, true));
}

test "residual plan policy and leg cap" {
    try testing.expect(wantsResidualPlan("partial"));
    try testing.expect(wantsResidualPlan("filled"));
    try testing.expect(!wantsResidualPlan("rejected"));
    try testing.expect(!wantsResidualPlan("unknown_http"));
    try testing.expect(canPlaceAnotherLeg(0));
    try testing.expect(canPlaceAnotherLeg(1));
    try testing.expect(!canPlaceAnotherLeg(2));
    try testing.expectEqual(@as(u16, 3), max_replan_legs);

    try testing.expect(!executionAllowed(false, false));
}
