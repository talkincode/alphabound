//! Order state machine and idempotent order identity (§5.5).
//!
//! Every order state change must be reconstructable from the event log:
//! PLANNED, SUBMITTED, ACKNOWLEDGED, PARTIAL, FILLED, CANCELED, REJECTED, UNKNOWN.
//! client_order_id derives deterministically from decision_id + target version
//! + sequence — retries must never mint a different logical order.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

pub const OrderStatus = enum {
    planned,
    submitted,
    acknowledged,
    partial,
    filled,
    canceled,
    rejected,
    unknown,

    pub fn jsonName(self: OrderStatus) []const u8 {
        return switch (self) {
            .planned => "PLANNED",
            .submitted => "SUBMITTED",
            .acknowledged => "ACKNOWLEDGED",
            .partial => "PARTIAL",
            .filled => "FILLED",
            .canceled => "CANCELED",
            .rejected => "REJECTED",
            .unknown => "UNKNOWN",
        };
    }

    pub fn isTerminal(self: OrderStatus) bool {
        return switch (self) {
            .filled, .canceled, .rejected => true,
            else => false,
        };
    }
};

pub const OrderEvent = enum {
    submit, // we sent the request
    ack, // exchange acknowledged
    fill_partial,
    fill_complete,
    cancel_confirmed,
    reject_confirmed,
    timeout, // request outcome unknown — query, never blind-resend (§5.5)
    /// Post-timeout query resolved the true state.
    resolved_ack,
    resolved_filled,
    resolved_canceled,
    resolved_rejected,
    resolved_not_found, // exchange never saw it → safe to treat as canceled
};

pub const TransitionError = error{IllegalTransition};

/// Legal transitions only; anything else is a bug or an integrity violation.
pub fn next(status: OrderStatus, event: OrderEvent) TransitionError!OrderStatus {
    return switch (status) {
        .planned => switch (event) {
            .submit => .submitted,
            else => error.IllegalTransition,
        },
        .submitted => switch (event) {
            .ack => .acknowledged,
            .fill_partial => .partial, // fill can race ahead of ack
            .fill_complete => .filled,
            .reject_confirmed => .rejected,
            .cancel_confirmed => .canceled,
            .timeout => .unknown,
            else => error.IllegalTransition,
        },
        .acknowledged => switch (event) {
            .fill_partial => .partial,
            .fill_complete => .filled,
            .cancel_confirmed => .canceled,
            .reject_confirmed => .rejected,
            .timeout => .unknown,
            else => error.IllegalTransition,
        },
        .partial => switch (event) {
            .fill_partial => .partial,
            .fill_complete => .filled,
            .cancel_confirmed => .canceled, // remainder canceled
            .timeout => .unknown,
            else => error.IllegalTransition,
        },
        .unknown => switch (event) {
            .resolved_ack => .acknowledged,
            .resolved_filled => .filled,
            .resolved_canceled => .canceled,
            .resolved_rejected => .rejected,
            .resolved_not_found => .canceled,
            .fill_partial => .partial, // private WS may deliver while querying
            .fill_complete => .filled,
            .timeout => .unknown,
            else => error.IllegalTransition,
        },
        .filled, .canceled, .rejected => error.IllegalTransition, // terminal
    };
}

/// Deterministic client_order_id: "ab" + hex(decision fingerprint + version + seq).
/// OKX clOrdId allows 1–32 alphanumeric characters.
pub fn clientOrderId(buf: *[32]u8, decision_id: []const u8, target_version: u64, seq: u16) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(decision_id);
    hasher.update(std.mem.asBytes(&target_version));
    hasher.update(std.mem.asBytes(&seq));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    buf[0] = 'a';
    buf[1] = 'b';
    const hex = "0123456789abcdef";
    for (digest[0..15], 0..) |b, i| {
        buf[2 + i * 2] = hex[b >> 4];
        buf[2 + i * 2 + 1] = hex[b & 0x0f];
    }
    return buf[0..32];
}

pub const Side = enum {
    buy,
    sell,

    pub fn jsonName(self: Side) []const u8 {
        return switch (self) {
            .buy => "buy",
            .sell => "sell",
        };
    }
};

pub const Order = struct {
    client_order_id: [32]u8,
    exchange_order_id: ?[]const u8 = null,
    decision_id: []const u8,
    side: Side,
    qty: Decimal,
    filled_qty: Decimal = Decimal.zero,
    price: ?Decimal, // null = market
    status: OrderStatus = .planned,

    pub fn remaining(self: Order) dec.DecimalError!Decimal {
        return self.qty.sub(self.filled_qty);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "happy path: planned -> submitted -> ack -> partial -> filled" {
    var s = OrderStatus.planned;
    s = try next(s, .submit);
    s = try next(s, .ack);
    s = try next(s, .fill_partial);
    s = try next(s, .fill_complete);
    try testing.expectEqual(OrderStatus.filled, s);
    try testing.expect(s.isTerminal());
}

test "timeout goes to unknown, resolution required" {
    var s = OrderStatus.planned;
    s = try next(s, .submit);
    s = try next(s, .timeout);
    try testing.expectEqual(OrderStatus.unknown, s);
    // blind resubmit is not a legal event from unknown; only resolutions are
    try testing.expectError(error.IllegalTransition, next(s, .submit));
    s = try next(s, .resolved_not_found);
    try testing.expectEqual(OrderStatus.canceled, s);
}

test "terminal states accept no events" {
    inline for ([_]OrderStatus{ .filled, .canceled, .rejected }) |terminal| {
        inline for (comptime std.enums.values(OrderEvent)) |e| {
            try testing.expectError(error.IllegalTransition, next(terminal, e));
        }
    }
}

test "client order id is deterministic and 32 chars" {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const id1 = clientOrderId(&b1, "dec_01JABCDEF", 184392, 0);
    const id2 = clientOrderId(&b2, "dec_01JABCDEF", 184392, 0);
    try testing.expectEqualStrings(id1, id2);
    try testing.expectEqual(@as(usize, 32), id1.len);

    var b3: [32]u8 = undefined;
    const id3 = clientOrderId(&b3, "dec_01JABCDEF", 184392, 1);
    try testing.expect(!std.mem.eql(u8, id1, id3)); // different seq → different id
}

test "property: no event sequence resurrects a terminal order" {
    var prng = std.Random.DefaultPrng.init(1234);
    const random = prng.random();
    const events = comptime std.enums.values(OrderEvent);
    var run: usize = 0;
    while (run < 2000) : (run += 1) {
        var s = OrderStatus.planned;
        var steps: usize = 0;
        while (steps < 12) : (steps += 1) {
            const e = events[random.intRangeLessThan(usize, 0, events.len)];
            const n = next(s, e) catch continue;
            if (s.isTerminal()) {
                // must be unreachable: terminal accepted an event
                try testing.expect(false);
            }
            s = n;
        }
    }
}
