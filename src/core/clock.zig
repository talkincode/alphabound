//! Clock abstraction: separates wall time (for exchange signatures, event
//! timestamps) from monotonic time (for timeouts, freshness windows).
//! Deterministic TestClock enables replay-stable tests (§9.2 Replay).

const std = @import("std");

pub const Clock = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        wallMs: *const fn (ctx: *anyopaque) i64,
        monotonicNs: *const fn (ctx: *anyopaque) u64,
    };

    /// Milliseconds since Unix epoch.
    pub fn wallMs(self: Clock) i64 {
        return self.vtable.wallMs(self.ctx);
    }

    /// Monotonic nanoseconds; only differences are meaningful.
    pub fn monotonicNs(self: Clock) u64 {
        return self.vtable.monotonicNs(self.ctx);
    }
};

pub const SystemClock = struct {
    var instance = SystemClock{};

    pub fn clock() Clock {
        return .{ .ctx = @ptrCast(&instance), .vtable = &vtable };
    }

    const vtable = Clock.VTable{
        .wallMs = wallMsImpl,
        .monotonicNs = monotonicNsImpl,
    };

    fn wallMsImpl(_: *anyopaque) i64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
    }

    fn monotonicNsImpl(_: *anyopaque) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
};

pub const TestClock = struct {
    wall_ms: i64 = 1_700_000_000_000,
    mono_ns: u64 = 0,

    pub fn clock(self: *TestClock) Clock {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    pub fn advance(self: *TestClock, ms: i64) void {
        self.wall_ms += ms;
        self.mono_ns += @as(u64, @intCast(ms)) * std.time.ns_per_ms;
    }

    const vtable = Clock.VTable{
        .wallMs = wallMsImpl,
        .monotonicNs = monotonicNsImpl,
    };

    fn wallMsImpl(ctx: *anyopaque) i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        return self.wall_ms;
    }

    fn monotonicNsImpl(ctx: *anyopaque) u64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        return self.mono_ns;
    }
};

/// Format a wall timestamp (ms) as RFC3339 UTC with millisecond precision,
/// e.g. "2026-08-09T08:31:04.482Z". Used in event envelopes and OKX signing.
pub fn formatRfc3339Ms(wall_ms: i64, buf: []u8) ![]const u8 {
    if (buf.len < 24) return error.NoSpaceLeft;
    const secs = @divFloor(wall_ms, 1000);
    const ms: u64 = @intCast(@mod(wall_ms, 1000));
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    const out = try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms,
    });
    return out;
}

/// Best-effort parse of RFC3339 UTC with optional fractional seconds
/// ("2026-08-09T08:31:04.482Z" or "2026-08-09T08:31:04Z"). Returns wall ms.
pub fn parseRfc3339Ms(s: []const u8) error{InvalidTimestamp}!i64 {
    if (s.len < 20) return error.InvalidTimestamp;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':')
        return error.InvalidTimestamp;
    const year = std.fmt.parseInt(i32, s[0..4], 10) catch return error.InvalidTimestamp;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return error.InvalidTimestamp;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return error.InvalidTimestamp;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return error.InvalidTimestamp;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return error.InvalidTimestamp;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return error.InvalidTimestamp;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60)
        return error.InvalidTimestamp;

    var ms: i64 = 0;
    if (s.len > 20 and s[19] == '.') {
        var i: usize = 20;
        var digits: i64 = 0;
        var n: usize = 0;
        while (i < s.len and s[i] >= '0' and s[i] <= '9' and n < 3) : ({
            i += 1;
            n += 1;
        }) {
            digits = digits * 10 + (s[i] - '0');
        }
        while (n < 3) : (n += 1) digits *= 10;
        ms = digits;
    }

    // Days from civil date (Howard Hinnant algorithm) → Unix seconds.
    const y: i64 = if (month <= 2) year - 1 else year;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy: i64 = @divTrunc(153 * mp + 2, 5) + day - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return secs * 1000 + ms;
}

const testing = std.testing;

test "rfc3339 roundtrip parse" {
    var buf: [32]u8 = undefined;
    const s = try formatRfc3339Ms(1_786_264_264_482, &buf);
    try testing.expectEqual(@as(i64, 1_786_264_264_482), try parseRfc3339Ms(s));
    try testing.expectEqual(@as(i64, 1_700_000_000_000), try parseRfc3339Ms("2023-11-14T22:13:20.000Z"));
    try testing.expectEqual(@as(i64, 1_700_000_000_000), try parseRfc3339Ms("2023-11-14T22:13:20Z"));
}

test "test clock advances deterministically" {
    var tc = TestClock{};
    const c = tc.clock();
    const w0 = c.wallMs();
    const m0 = c.monotonicNs();
    tc.advance(1500);
    try testing.expectEqual(w0 + 1500, c.wallMs());
    try testing.expectEqual(m0 + 1_500_000_000, c.monotonicNs());
}

test "rfc3339 formatting" {
    var buf: [32]u8 = undefined;
    const s = try formatRfc3339Ms(1_700_000_000_000, &buf);
    try testing.expectEqualStrings("2023-11-14T22:13:20.000Z", s);
    const s2 = try formatRfc3339Ms(1_786_264_264_482, &buf);
    try testing.expectEqualStrings("2026-08-09T08:31:04.482Z", s2);
}
