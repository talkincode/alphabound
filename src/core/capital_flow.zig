//! External capital-flow inference from consecutive reconciled account books.
//!
//! Both books are valued at the same bid, so market movement cannot create a
//! flow. Value-balanced opposing cash/BTC legs remain below materiality as spot
//! execution, while any material residual is classified as external capital.

const std = @import("std");
const dec = @import("decimal.zig");
const equity = @import("../risk/equity.zig");
const Decimal = dec.Decimal;

pub const Direction = enum {
    deposit,
    withdrawal,

    pub fn text(self: Direction) []const u8 {
        return switch (self) {
            .deposit => "deposit",
            .withdrawal => "withdrawal",
        };
    }
};

pub const Balances = struct {
    cash_usdt: Decimal,
    btc_total: Decimal,
};

pub const Flow = struct {
    direction: Direction,
    cash_delta: Decimal,
    btc_delta: Decimal,
    quote_value: Decimal,
    equity_before: Decimal,
    equity_after: Decimal,
};

pub const DetectInput = struct {
    before: Balances,
    after: Balances,
    bid_price: Decimal,
    exit_costs: equity.ExitCostParams,
};

pub fn formatBalances(buf: []u8, balances: Balances) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(buf, "v1|{f}|{f}", .{
        balances.cash_usdt,
        balances.btc_total,
    }) catch error.BufferTooSmall;
}

pub fn parseBalances(encoded: []const u8) dec.DecimalError!Balances {
    var parts = std.mem.splitScalar(u8, encoded, '|');
    const version = parts.next() orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, version, "v1")) return error.InvalidFormat;
    const cash = parts.next() orelse return error.InvalidFormat;
    const btc = parts.next() orelse return error.InvalidFormat;
    if (parts.next() != null) return error.InvalidFormat;
    return .{
        .cash_usdt = try Decimal.parse(cash),
        .btc_total = try Decimal.parse(btc),
    };
}

pub fn detect(input: DetectInput) dec.DecimalError!?Flow {
    if (!input.bid_price.gt(Decimal.zero)) return null;

    const cash_delta = try input.after.cash_usdt.sub(input.before.cash_usdt);
    const btc_delta = try input.after.btc_total.sub(input.before.btc_total);
    const btc_quote_delta = try btc_delta.mul(input.bid_price, .down);
    const leg_floor = Decimal.fromInt(2);

    const before_eq = try equity.conservativeEquity(.{
        .cash_usdt = input.before.cash_usdt,
        .btc_total = input.before.btc_total,
        .liq_price = input.bid_price,
        .exit_costs = input.exit_costs,
    });
    const after_eq = try equity.conservativeEquity(.{
        .cash_usdt = input.after.cash_usdt,
        .btc_total = input.after.btc_total,
        .liq_price = input.bid_price,
        .exit_costs = input.exit_costs,
    });
    const quote_value = try after_eq.equity.sub(before_eq.equity);
    const opposing_legs =
        (cash_delta.gt(Decimal.zero) and btc_quote_delta.isNegative()) or
        (cash_delta.isNegative() and btc_quote_delta.gt(Decimal.zero));
    var relative_rate = Decimal.fromRaw(250_000); // 0.25%
    if (opposing_legs) {
        // A reconciliation interval containing a spot trade includes entry
        // friction plus the conservative exit haircut. Use a 2x round-trip
        // allowance so a large rebalance cannot masquerade as a withdrawal.
        const one_way_costs = try input.exit_costs.fee_rate.add(input.exit_costs.slippage_rate);
        const trade_noise_rate = try one_way_costs.mul(Decimal.fromInt(4), .up);
        relative_rate = Decimal.max(relative_rate, trade_noise_rate);
    }
    const relative_floor = try before_eq.equity.mul(relative_rate, .up);
    const materiality = Decimal.max(leg_floor, relative_floor);
    const crosses_zero = before_eq.equity.gt(Decimal.zero) != after_eq.equity.gt(Decimal.zero);
    if (!crosses_zero and quote_value.abs().lt(materiality)) return null;

    return .{
        .direction = if (quote_value.isNegative()) .withdrawal else .deposit,
        .cash_delta = cash_delta,
        .btc_delta = btc_delta,
        .quote_value = quote_value,
        .equity_before = before_eq.equity,
        .equity_after = after_eq.equity,
    };
}

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "detects a material BTC deposit at conservative quote value" {
    const flow = (try detect(.{
        .before = .{ .cash_usdt = d("100"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = d("100"), .btc_total = d("0.001") },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    })).?;

    try std.testing.expectEqual(Direction.deposit, flow.direction);
    try std.testing.expect(flow.cash_delta.eql(Decimal.zero));
    try std.testing.expect(flow.btc_delta.eql(d("0.001")));
    try std.testing.expect(flow.quote_value.eql(d("49.9")));
    try std.testing.expect(flow.equity_before.eql(d("100")));
    try std.testing.expect(flow.equity_after.eql(d("149.9")));
}

test "does not classify opposing balance legs from a spot buy as capital flow" {
    const flow = try detect(.{
        .before = .{ .cash_usdt = d("100"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = d("49.95"), .btc_total = d("0.001") },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    });

    try std.testing.expect(flow == null);
}

test "does not classify a large frictional rebalance as capital flow" {
    const flow = try detect(.{
        .before = .{ .cash_usdt = d("10000"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = Decimal.zero, .btc_total = d("0.1996") },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    });

    try std.testing.expect(flow == null);
}

test "detects transfer residual when a spot trade occurs in the same interval" {
    const flow = (try detect(.{
        .before = .{ .cash_usdt = d("100"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = d("50"), .btc_total = d("0.003") },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    })).?;

    try std.testing.expectEqual(Direction.deposit, flow.direction);
    try std.testing.expect(flow.quote_value.eql(d("99.7")));
}

test "detects a material USDT withdrawal" {
    const flow = (try detect(.{
        .before = .{ .cash_usdt = d("100"), .btc_total = d("0.001") },
        .after = .{ .cash_usdt = d("70"), .btc_total = d("0.001") },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    })).?;

    try std.testing.expectEqual(Direction.withdrawal, flow.direction);
    try std.testing.expect(flow.quote_value.eql(d("-30")));
}

test "ignores reconciliation dust below the materiality floor" {
    const flow = try detect(.{
        .before = .{ .cash_usdt = d("100"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = d("100.5"), .btc_total = Decimal.zero },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    });

    try std.testing.expect(flow == null);
}

test "detects a full withdrawal below the ordinary dust floor" {
    const flow = (try detect(.{
        .before = .{ .cash_usdt = d("1.5"), .btc_total = Decimal.zero },
        .after = .{ .cash_usdt = Decimal.zero, .btc_total = Decimal.zero },
        .bid_price = d("50000"),
        .exit_costs = .{ .fee_rate = d("0.001"), .slippage_rate = d("0.001") },
    })).?;

    try std.testing.expectEqual(Direction.withdrawal, flow.direction);
    try std.testing.expect(flow.quote_value.eql(d("-1.5")));
}

test "reconciled balance book serialization round-trips" {
    var buf: [128]u8 = undefined;
    const encoded = try formatBalances(&buf, .{
        .cash_usdt = d("12.34"),
        .btc_total = d("0.0056789"),
    });
    const decoded = try parseBalances(encoded);
    try std.testing.expect(decoded.cash_usdt.eql(d("12.34")));
    try std.testing.expect(decoded.btc_total.eql(d("0.0056789")));
    try std.testing.expectError(error.InvalidFormat, parseBalances("v2|12|0.1"));
}
