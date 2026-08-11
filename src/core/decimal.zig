//! Fixed-point decimal for all money/quantity/price arithmetic.
//!
//! Design rule (§4.2): order quantities, fees and equity must be computed in
//! deterministic precision — never settled in binary floating point.
//!
//! Representation: i128 mantissa with a fixed scale of 1e-8 (one "unit" is
//! 10^-8), which covers both USDT cents and BTC satoshis with headroom.

const std = @import("std");

pub const SCALE: comptime_int = 8;
pub const ONE_RAW: i128 = 100_000_000; // 10^SCALE

pub const DecimalError = error{
    Overflow,
    DivisionByZero,
    InvalidFormat,
};

pub const Rounding = enum {
    /// Round toward zero (truncate). Default for conservative buy sizing.
    down,
    /// Round away from zero.
    up,
    /// Round half away from zero.
    nearest,
};

pub const Decimal = struct {
    raw: i128,

    pub const zero = Decimal{ .raw = 0 };
    pub const one = Decimal{ .raw = ONE_RAW };

    pub fn fromInt(v: i64) Decimal {
        return .{ .raw = @as(i128, v) * ONE_RAW };
    }

    /// Construct from integer raw units of 10^-8.
    pub fn fromRaw(raw: i128) Decimal {
        return .{ .raw = raw };
    }

    /// Parse "123", "-0.5", "0.00000001". More than 8 fraction digits is an error.
    pub fn parse(s: []const u8) DecimalError!Decimal {
        if (s.len == 0) return error.InvalidFormat;
        var i: usize = 0;
        var negative = false;
        if (s[0] == '-') {
            negative = true;
            i = 1;
        } else if (s[0] == '+') {
            i = 1;
        }
        if (i >= s.len) return error.InvalidFormat;

        var int_part: i128 = 0;
        var saw_digit = false;
        while (i < s.len and s[i] != '.') : (i += 1) {
            const c = s[i];
            if (c < '0' or c > '9') return error.InvalidFormat;
            saw_digit = true;
            int_part = std.math.mul(i128, int_part, 10) catch return error.Overflow;
            int_part = std.math.add(i128, int_part, c - '0') catch return error.Overflow;
        }
        var frac_part: i128 = 0;
        var frac_digits: usize = 0;
        if (i < s.len and s[i] == '.') {
            i += 1;
            if (i >= s.len) return error.InvalidFormat;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c < '0' or c > '9') return error.InvalidFormat;
                saw_digit = true;
                if (frac_digits == SCALE) return error.InvalidFormat; // too precise
                frac_part = frac_part * 10 + (c - '0');
                frac_digits += 1;
            }
        }
        if (!saw_digit) return error.InvalidFormat;
        var pad = frac_part;
        var d = frac_digits;
        while (d < SCALE) : (d += 1) pad *= 10;
        const scaled_int = std.math.mul(i128, int_part, ONE_RAW) catch return error.Overflow;
        var raw = std.math.add(i128, scaled_int, pad) catch return error.Overflow;
        if (negative) raw = -raw;
        return .{ .raw = raw };
    }

    pub fn add(a: Decimal, b: Decimal) DecimalError!Decimal {
        return .{ .raw = std.math.add(i128, a.raw, b.raw) catch return error.Overflow };
    }

    pub fn sub(a: Decimal, b: Decimal) DecimalError!Decimal {
        return .{ .raw = std.math.sub(i128, a.raw, b.raw) catch return error.Overflow };
    }

    /// Multiply two decimals, rounding the 10^-16 intermediate back to 10^-8.
    pub fn mul(a: Decimal, b: Decimal, rounding: Rounding) DecimalError!Decimal {
        const prod = std.math.mul(i128, a.raw, b.raw) catch return error.Overflow;
        return .{ .raw = divRound(prod, ONE_RAW, rounding) };
    }

    pub fn div(a: Decimal, b: Decimal, rounding: Rounding) DecimalError!Decimal {
        if (b.raw == 0) return error.DivisionByZero;
        const scaled = std.math.mul(i128, a.raw, ONE_RAW) catch return error.Overflow;
        return .{ .raw = divRound(scaled, b.raw, rounding) };
    }

    fn divRound(num: i128, den: i128, rounding: Rounding) i128 {
        const q = @divTrunc(num, den);
        const r = @rem(num, den);
        if (r == 0) return q;
        const positive = (num > 0) == (den > 0);
        return switch (rounding) {
            .down => q,
            .up => if (positive) q + 1 else q - 1,
            .nearest => blk: {
                const abs_r: i128 = if (r < 0) -r else r;
                const abs_den: i128 = if (den < 0) -den else den;
                if (abs_r * 2 >= abs_den) {
                    break :blk if (positive) q + 1 else q - 1;
                }
                break :blk q;
            },
        };
    }

    pub fn neg(a: Decimal) Decimal {
        return .{ .raw = -a.raw };
    }

    pub fn abs(a: Decimal) Decimal {
        return .{ .raw = if (a.raw < 0) -a.raw else a.raw };
    }

    pub fn cmp(a: Decimal, b: Decimal) std.math.Order {
        return std.math.order(a.raw, b.raw);
    }

    pub fn eql(a: Decimal, b: Decimal) bool {
        return a.raw == b.raw;
    }

    pub fn lt(a: Decimal, b: Decimal) bool {
        return a.raw < b.raw;
    }

    pub fn lte(a: Decimal, b: Decimal) bool {
        return a.raw <= b.raw;
    }

    pub fn gt(a: Decimal, b: Decimal) bool {
        return a.raw > b.raw;
    }

    pub fn gte(a: Decimal, b: Decimal) bool {
        return a.raw >= b.raw;
    }

    pub fn isZero(a: Decimal) bool {
        return a.raw == 0;
    }

    pub fn isNegative(a: Decimal) bool {
        return a.raw < 0;
    }

    pub fn max(a: Decimal, b: Decimal) Decimal {
        return if (a.raw >= b.raw) a else b;
    }

    pub fn min(a: Decimal, b: Decimal) Decimal {
        return if (a.raw <= b.raw) a else b;
    }

    /// Round down to a multiple of `step` (e.g. lot size). step must be > 0.
    pub fn floorToStep(a: Decimal, step: Decimal) DecimalError!Decimal {
        if (step.raw <= 0) return error.DivisionByZero;
        const q = @divFloor(a.raw, step.raw);
        return .{ .raw = q * step.raw };
    }

    /// Lossy conversion for display/metrics only. Never feed back into settlement.
    pub fn toF64Lossy(a: Decimal) f64 {
        return @as(f64, @floatFromInt(a.raw)) / @as(f64, @floatFromInt(ONE_RAW));
    }

    /// Format as canonical decimal string, trailing fraction zeros trimmed.
    pub fn format(a: Decimal, writer: anytype) !void {
        var raw = a.raw;
        if (raw < 0) {
            try writer.writeAll("-");
            raw = -raw;
        }
        const int_part = @divTrunc(raw, ONE_RAW);
        const frac_part = @rem(raw, ONE_RAW);
        try writer.print("{d}", .{int_part});
        if (frac_part != 0) {
            var buf: [SCALE]u8 = undefined;
            var f: i128 = frac_part;
            var idx: usize = SCALE;
            while (idx > 0) {
                idx -= 1;
                buf[idx] = @intCast('0' + @rem(f, 10));
                f = @divTrunc(f, 10);
            }
            var end: usize = SCALE;
            while (end > 0 and buf[end - 1] == '0') end -= 1;
            try writer.writeAll(".");
            try writer.writeAll(buf[0..end]);
        }
    }

    pub fn toString(a: Decimal, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try a.format(&w);
        return w.buffered();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse and format round trip" {
    const cases = [_][]const u8{ "0", "1", "-1", "0.5", "123.456", "-0.00000001", "21000000", "0.1" };
    for (cases) |s| {
        const d = try Decimal.parse(s);
        var buf: [64]u8 = undefined;
        const out = try d.toString(&buf);
        try testing.expectEqualStrings(s, out);
    }
}

test "parse rejects garbage" {
    try testing.expectError(error.InvalidFormat, Decimal.parse(""));
    try testing.expectError(error.InvalidFormat, Decimal.parse("."));
    try testing.expectError(error.InvalidFormat, Decimal.parse("1."));
    try testing.expectError(error.InvalidFormat, Decimal.parse("abc"));
    try testing.expectError(error.InvalidFormat, Decimal.parse("1.2.3"));
    try testing.expectError(error.InvalidFormat, Decimal.parse("0.000000001")); // 9 digits
}

test "basic arithmetic" {
    const a = try Decimal.parse("0.1");
    const b = try Decimal.parse("0.2");
    const sum = try a.add(b);
    try testing.expect(sum.eql(try Decimal.parse("0.3"))); // no float drift

    const p = try Decimal.parse("117000.5");
    const q = try Decimal.parse("0.00123");
    const cost = try p.mul(q, .nearest);
    try testing.expect(cost.eql(try Decimal.parse("143.910615")));
}

test "division rounding modes" {
    const ten = Decimal.fromInt(10);
    const three = Decimal.fromInt(3);
    const down = try ten.div(three, .down);
    const up = try ten.div(three, .up);
    try testing.expect(down.raw == 333333333);
    try testing.expect(up.raw == 333333334);
}

test "floorToStep lot size" {
    const qty = try Decimal.parse("0.00123456");
    const lot = try Decimal.parse("0.0001");
    const floored = try qty.floorToStep(lot);
    try testing.expect(floored.eql(try Decimal.parse("0.0012")));
}

test "property: add/sub inverse and mul monotonicity" {
    var prng = std.Random.DefaultPrng.init(0xa1fab0);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const a = Decimal.fromRaw(random.intRangeAtMost(i128, -1_000_000_000_000, 1_000_000_000_000));
        const b = Decimal.fromRaw(random.intRangeAtMost(i128, -1_000_000_000_000, 1_000_000_000_000));
        const s = try a.add(b);
        const back = try s.sub(b);
        try testing.expect(back.eql(a));

        // multiplying a non-negative value by a larger non-negative factor never shrinks it
        const x = Decimal.fromRaw(random.intRangeAtMost(i128, 0, 1_000_000_000_000));
        const f1 = Decimal.fromRaw(random.intRangeAtMost(i128, 0, ONE_RAW));
        const f2 = try f1.add(Decimal.fromRaw(random.intRangeAtMost(i128, 0, ONE_RAW)));
        const y1 = try x.mul(f1, .down);
        const y2 = try x.mul(f2, .down);
        try testing.expect(y2.gte(y1));
    }
}
