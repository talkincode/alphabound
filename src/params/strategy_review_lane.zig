//! Background schedule for the strategy review.
//!
//! Sleeps until the configured interval, or until the web thread sets the
//! kick flag. The round opens its own database connection. The trading loop
//! never calls this file and is not waited on.

const std = @import("std");
const clock = @import("../core/clock.zig");
const db = @import("../storage/db.zig");
const dec = @import("../core/decimal.zig");
const cache = @import("../web/cache.zig");
const review = @import("strategy_review.zig");

pub const Lane = struct {
    io: std.Io,
    db_path: [:0]const u8,
    mode: review.Switch,
    interval_ms: u32,
    min_notional: dec.Decimal,
    web: *cache.WebState,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    last_run_ms: i64 = 0,

    pub fn start(self: *Lane) !void {
        // The first scheduled round waits one full interval. A manual kick
        // still runs immediately.
        self.last_run_ms = clock.SystemClock.clock().wallMs();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn shutdown(self: *Lane, timeout_ms: u32) bool {
        self.stop.store(true, .release);
        var waited: u32 = 0;
        while (!self.stopped.load(.acquire)) {
            if (waited >= timeout_ms) return false;
            self.io.sleep(.{ .nanoseconds = 20_000_000 }, .awake) catch break;
            waited += 20;
        }
        if (self.thread) |t| t.join();
        self.thread = null;
        return true;
    }
};

fn run(self: *Lane) void {
    defer self.stopped.store(true, .release);
    while (!self.stop.load(.acquire)) {
        self.io.sleep(.{ .nanoseconds = 500_000_000 }, .awake) catch {};
        if (self.stop.load(.acquire)) break;
        const now = clock.SystemClock.clock().wallMs();
        const manual = self.web.strategy_review_kick.swap(false, .acq_rel);
        const due = self.interval_ms != 0 and now - self.last_run_ms >= @as(i64, self.interval_ms);
        if (!manual and !due) continue;
        if (self.web.strategy_review_running.swap(true, .acq_rel)) {
            if (manual) self.web.strategy_review_kick.store(true, .release);
            continue;
        }
        defer self.web.strategy_review_running.store(false, .release);
        const snap = cache.WebState.readSnapshot(self.web);
        var database = db.Db.open(self.db_path) catch |err| {
            std.debug.print("[strategy-review] db open failed {t}; parameters unchanged\n", .{err});
            continue;
        };
        defer database.close();
        const trigger: []const u8 = if (manual) "manual" else "schedule";
        review.execute(
            &database,
            self.min_notional,
            now,
            self.mode,
            trigger,
            snap.drawdown.toF64Lossy(),
            snap.risk_mode == .normal,
        );
        self.last_run_ms = clock.SystemClock.clock().wallMs();
    }
}
