//! Offline, policy-fixed scheduler comparison. No daemon or account imports.
const std = @import("std");
const sched = @import("core/scheduler.zig");
const Decimal = @import("core/decimal.zig").Decimal;
const minute = 60_000;
const day_ms = 86_400_000;
const max_bytes = 64 * 1024 * 1024;
const max_samples = 2_000_000;
const reason_count = @typeInfo(sched.TriggerReason).@"enum".fields.len;

const Sample = struct { time: i64, bid: Decimal };

fn parseLine(line: []const u8, previous: i64) !Sample {
    if (line.len == 0 or line.len > 128) return error.InvalidLine;
    const comma = std.mem.indexOfScalar(u8, line, ',') orelse return error.InvalidLine;
    const ts = line[0..comma];
    const price = line[comma + 1 ..];
    if (ts.len == 0 or price.len == 0) return error.InvalidLine;
    for (ts) |c| if (!std.ascii.isDigit(c)) return error.InvalidTimestamp;
    // Restrict to plain decimal notation; Decimal enforces eight fractional digits.
    for (price) |c| if (!std.ascii.isDigit(c) and c != '.') return error.InvalidBid;
    const time = std.fmt.parseInt(i64, ts, 10) catch return error.InvalidTimestamp;
    // Leave headroom for scheduler deadline arithmetic.
    if (time <= previous or time > 253402300799999) return error.InvalidTimestamp;
    const bid = Decimal.parse(price) catch return error.InvalidBid;
    // Bound arithmetic operands as well as input memory.
    if (!bid.gt(Decimal.zero) or bid.gt(Decimal.fromInt(1_000_000_000))) return error.InvalidBid;
    return .{ .time = time, .bid = bid };
}

const Parser = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_number: usize = 0,
    previous: i64 = 0,
    count: usize = 0,

    fn init(text: []const u8) Parser {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(self: *Parser) !?Sample {
        while (self.lines.next()) |raw| {
            self.line_number += 1;
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            if (self.line_number == 1 and std.mem.eql(u8, line, "timestamp_ms,bid")) continue;
            if (line.len == 0 and self.lines.peek() == null and self.count > 0) return null;
            const sample = try parseLine(line, self.previous);
            self.count += 1;
            if (self.count > max_samples) return error.TooManySamples;
            self.previous = sample.time;
            return sample;
        }
        if (self.count == 0) return error.EmptyInput;
        return null;
    }
};

fn params(enabled: bool) sched.Params {
    return .{
        .base_interval_ms = 15 * minute,
        .min_interval_ms = 3 * minute,
        .price_move = Decimal.parse("0.005") catch unreachable,
        .price_drift = Decimal.parse("0.02") catch unreachable,
        .noop_backoff_cap_ms = 30 * minute,
        .review_backoff_max_ms = 4 * 60 * minute,
        .volatility_enter = if (enabled) Decimal.parse("0.01") catch unreachable else Decimal.zero,
        .volatility_exit = Decimal.parse("0.006") catch unreachable,
        .volatility_interval_ms = 3 * minute,
        .volatility_exit_hold_ms = 15 * minute,
    };
}

const Stats = struct {
    counts: [reason_count]u64 = @splat(0),
    min_gap: ?i64 = null,
    max_gap: ?i64 = null,

    fn record(self: *Stats, reason: sched.TriggerReason, gap: ?i64) void {
        self.counts[@intFromEnum(reason)] += 1;
        if (gap) |g| {
            self.min_gap = @min(self.min_gap orelse g, g);
            self.max_gap = @max(self.max_gap orelse g, g);
        }
    }
};

const Model = struct {
    scheduler: sched.Scheduler,
    daily: Stats = .{},
    total: Stats = .{},

    fn step(self: *Model, sample: Sample) !void {
        self.scheduler.observePrice(sample.time, sample.bid);
        const verdict = self.scheduler.evaluate(sample.time, sample.bid, Decimal.zero, .exit_only);
        if (!verdict.fire) return;
        const gap: ?i64 = if (self.scheduler.fired_once) sample.time - self.scheduler.last_fire_ms else null;
        // Runtime error, not debug-only assert: enforced in ReleaseFast too.
        if (gap) |g| if (g < 3 * minute) return error.CooldownViolation;
        self.daily.record(verdict.reason, gap);
        self.total.record(verdict.reason, gap);
        self.scheduler.noteReason(verdict.reason);
        self.scheduler.commit(sample.time, sample.bid, Decimal.zero, .exit_only);
        self.scheduler.noteOutcome(false);
        _ = self.scheduler.deferAfterHold(sample.time, 4 * 60 * minute);
    }
};

fn printStats(out: *std.Io.Writer, scope: []const u8, day: i64, name: []const u8, stats: Stats) !void {
    inline for (@typeInfo(sched.TriggerReason).@"enum".fields) |field| {
        try out.print("{s},{d},{s},{s},{d},{d},{d}\n", .{
            scope,
            day,
            name,
            field.name,
            stats.counts[field.value],
            stats.min_gap orelse 0,
            stats.max_gap orelse 0,
        });
    }
}

pub fn main(init: std.process.Init) !u8 {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: zig build replay-scheduler -- <public-marks.csv>\n", .{});
        return 2;
    };
    if (args.next() != null) return error.UnexpectedArgument;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_bytes));
    defer init.gpa.free(text);
    // Validate the complete bounded input before emitting any comparison.
    var validation = Parser.init(text);
    while (validation.next() catch |err| {
        std.debug.print("invalid CSV at line {d}: {s}\n", .{ validation.line_number, @errorName(err) });
        return 2;
    }) |_| {}
    var buffer: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &file_writer.interface;
    try out.writeAll("scope,utc_epoch_day,model,reason,count,min_decision_gap_ms,max_decision_gap_ms\n");
    var models = [_]Model{ .{ .scheduler = sched.Scheduler.init(params(false)) }, .{ .scheduler = sched.Scheduler.init(params(true)) } };
    const names = [_][]const u8{ "old", "volatility" };
    var parser = Parser.init(text);
    var current_day: ?i64 = null;
    var last_sample: ?Sample = null;
    var ready_ms: i64 = 0;
    var active_ms: i64 = 0;
    var unknown_ms: i64 = 0;
    var ready = false;
    var active = false;
    var min_sample_gap: ?i64 = null;
    var max_sample_gap: i64 = 0;
    while (try parser.next()) |sample| {
        const day = @divFloor(sample.time, day_ms);
        if (current_day != null and current_day.? != day) {
            for (&models, names) |*model, name| {
                try printStats(out, "day", current_day.?, name, model.daily);
                model.daily = .{};
            }
        }
        current_day = day;
        if (last_sample) |last| {
            const gap = sample.time - last.time;
            min_sample_gap = @min(min_sample_gap orelse gap, gap);
            max_sample_gap = @max(max_sample_gap, gap);
            // Only integrate observed intervals with acceptable sampling continuity.
            if (gap <= sched.volatility_max_gap_ms) {
                if (ready) ready_ms += gap;
                if (active) active_ms += gap;
            } else unknown_ms += gap;
        }
        for (&models) |*model| try model.step(sample);
        const status = models[1].scheduler.volatilityStatus(sample.time);
        ready = status.ready;
        active = status.ready and status.active;
        last_sample = sample;
    }
    for (&models, names) |*model, name| {
        try printStats(out, "day", current_day.?, name, model.daily);
        try printStats(out, "total", -1, name, model.total);
    }
    try out.flush();
    std.debug.print("samples={d} sample_gap_ms_min={d} sample_gap_ms_max={d}\nready_minutes={d:.3} high_vol_minutes={d:.3} unknown_gap_minutes={d:.3}\n", .{
        parser.count,
        min_sample_gap orelse 0,
        max_sample_gap,
        @as(f64, @floatFromInt(ready_ms)) / minute,
        @as(f64, @floatFromInt(active_ms)) / minute,
        @as(f64, @floatFromInt(unknown_ms)) / minute,
    });
    return 0;
}

test "strict CSV parser accepts optional header CRLF and rejects malformed input" {
    var good = Parser.init("timestamp_ms,bid\r\n1,100\r\n60001,100.25\r\n");
    try std.testing.expectEqual(@as(i64, 1), (try good.next()).?.time);
    try std.testing.expectEqual(@as(i64, 60001), (try good.next()).?.time);
    try std.testing.expectEqual(@as(?Sample, null), try good.next());
    for ([_][]const u8{ "", "timestamp_ms,bid\n", "0,1", "1,0", "1,-1", "1,NaN", "1,1e2", "1,1,2", "1,1\n\n2,2", "1,1\n1,2", "2,1\n1,2", "1,0.000000001", " 1,1" }) |bad| {
        var parser = Parser.init(bad);
        var rejected = false;
        while (true) {
            const sample = parser.next() catch {
                rejected = true;
                break;
            };
            if (sample == null) break;
        }
        try std.testing.expect(rejected);
    }
}

test "flat synthetic market produces identical four-hour HOLD cadence" {
    var old = Model{ .scheduler = sched.Scheduler.init(params(false)) };
    var new = Model{ .scheduler = sched.Scheduler.init(params(true)) };
    for (0..481) |i| {
        const sample = Sample{ .time = 1 + @as(i64, @intCast(i)) * minute, .bid = Decimal.fromInt(100) };
        try old.step(sample);
        try new.step(sample);
    }
    try std.testing.expectEqual(old.total.counts, new.total.counts);
    try std.testing.expectEqual(@as(u64, 1), old.total.counts[@intFromEnum(sched.TriggerReason.first_run)]);
    try std.testing.expectEqual(@as(u64, 2), old.total.counts[@intFromEnum(sched.TriggerReason.interval_active)]);
    try std.testing.expectEqual(@as(?i64, 4 * 60 * minute), new.total.min_gap);
}

test "oscillating synthetic market exercises volatility without bypassing cooldown" {
    var old = Model{ .scheduler = sched.Scheduler.init(params(false)) };
    var new = Model{ .scheduler = sched.Scheduler.init(params(true)) };
    for (0..121) |i| {
        const sample = Sample{
            .time = 1 + @as(i64, @intCast(i)) * minute,
            .bid = Decimal.parse(if (i % 2 == 0) "100" else "101.5") catch unreachable,
        };
        try old.step(sample);
        try new.step(sample);
    }
    try std.testing.expectEqual(@as(u64, 0), old.total.counts[@intFromEnum(sched.TriggerReason.volatility)]);
    try std.testing.expect(new.total.counts[@intFromEnum(sched.TriggerReason.volatility)] > 0);
    try std.testing.expect(new.total.min_gap.? >= 3 * minute);
    try std.testing.expect(new.scheduler.volatilityStatus(120 * minute + 1).ready);
}
