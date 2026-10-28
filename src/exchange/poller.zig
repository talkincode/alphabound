//! Bounded network-only lanes. No DB handles, no state-engine writes.
//! Market, private-account and optional presentation I/O cannot block each
//! other or the owner. Shutdown cancels and joins all requests.
const std = @import("std");
const rest = @import("okx/rest.zig");
const auth = @import("okx/auth.zig");
const config = @import("../config.zig");
const lanes = @import("../core/lanes.zig");
const web = @import("../web/cache.zig");
const clock = @import("../core/clock.zig");

pub const Tick = union(enum) { ok: struct { ticker: rest.Ticker, recv_ms: i64 }, failed };
pub const Account = struct { ticket: u64, probe: rest.BalanceProbe };
pub const Poller = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: *const config.Config,
    creds: ?auth.Credentials,
    simulated: bool,
    ws: *web.WebState,
    status: *web.RuntimeStatus,
    ticks: lanes.Mailbox(Tick, 8) = .{},
    accounts: lanes.Mailbox(Account, 4) = .{},
    requests: lanes.Mailbox(u64, 4) = .{},
    workers: std.Io.Group = .init,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *Poller) !void {
        errdefer self.stop();
        try self.workers.concurrent(self.io, marketLoop, .{self});
        try self.workers.concurrent(self.io, accountLoop, .{self});
        try self.workers.concurrent(self.io, displayLoop, .{self});
    }
    /// Coalesce an owner stall instead of replaying a permanent old-tick backlog.
    pub fn takeTick(self: *Poller) ?Tick {
        var latest: ?Tick = null;
        while (self.ticks.pop()) |tick| latest = tick;
        return latest;
    }

    pub fn stop(self: *Poller) void {
        self.stopping.store(true, .release);
        self.workers.cancel(self.io);
    }
    fn client(self: *Poller) rest.Client {
        var c = rest.Client.init(self.gpa, self.io, self.cfg.rest_url, self.creds);
        c.simulated = self.simulated;
        return c;
    }
    fn marketLoop(self: *Poller) void {
        var c = self.client();
        defer c.deinit();
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v5/market/ticker?instId={s}", .{self.cfg.instrument}) catch return;
        while (!self.stopping.load(.acquire)) {
            const result: Tick = blk: {
                const body = c.getPublic(path) catch break :blk .failed;
                defer self.gpa.free(body);
                const recv_ms = clock.SystemClock.clock().wallMs();
                const ticker = rest.parseTicker(self.gpa, body) catch break :blk .failed;
                break :blk .{ .ok = .{ .ticker = ticker, .recv_ms = recv_ms } };
            };
            // Never wait for a reader; stale inputs are rejected by freshness.
            _ = self.ticks.push(result);
            self.io.sleep(.{ .nanoseconds = @as(i96, self.cfg.poll_interval_ms) * 1_000_000 }, .awake) catch return;
        }
    }
    fn accountLoop(self: *Poller) void {
        var c = self.client();
        defer c.deinit();
        while (!self.stopping.load(.acquire)) {
            if (self.requests.pop()) |ticket| {
                const probe = rest.probeBalance(&c, self.gpa, clock.SystemClock.clock().wallMs());
                // Owner permits one in-flight request; capacity is a hard bound.
                _ = self.accounts.push(.{ .ticket = ticket, .probe = probe });
            } else self.io.sleep(.{ .nanoseconds = 5_000_000 }, .awake) catch return;
        }
    }
    fn displayLoop(self: *Poller) void {
        var c = self.client();
        defer c.deinit();
        var last_slow: i64 = 0;
        while (!self.stopping.load(.acquire)) {
            web.refreshCandlesCache(self.gpa, self.ws, &c, self.cfg);
            const now = clock.SystemClock.clock().wallMs();
            if (now - last_slow >= 1_800_000) {
                last_slow = now;
                web.refreshSentimentCache(self.gpa, self.ws, &c);
                if (c.getAbsoluteUrl("https://api.ipify.org")) |body| {
                    defer self.gpa.free(body);
                    const ip = std.mem.trim(u8, body, " \t\r\n");
                    if (ip.len > 0 and ip.len < 64) self.status.setEgress(ip);
                } else |_| {}
            }
            self.io.sleep(.{ .nanoseconds = 5_000_000_000 }, .awake) catch return;
        }
    }
};
