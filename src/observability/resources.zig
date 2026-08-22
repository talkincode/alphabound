//! Process and host resource occupancy for Dashboard「运行状态」.
//! Best-effort: Linux reads /proc; other OS fall back to getrusage.
//! Rates need two samples; the first snapshot fills RSS/mem and leaves
//! CPU/network at zero.

const std = @import("std");
const builtin = @import("builtin");

pub const Snapshot = struct {
    /// Process CPU, tenths of a percent of one core (12 = 1.2%).
    cpu_pct_x10: u32 = 0,
    /// Host busy CPU, tenths of a percent.
    host_cpu_pct_x10: u32 = 0,
    rss_bytes: u64 = 0,
    mem_used_bytes: u64 = 0,
    mem_total_bytes: u64 = 0,
    net_rx_bps: u64 = 0,
    net_tx_bps: u64 = 0,
    /// False until a second sample exists so rates are meaningful.
    ready: bool = false,
};

pub const Sampler = struct {
    last_ms: i64 = 0,
    last_proc_ticks: u64 = 0,
    last_host_idle: u64 = 0,
    last_host_total: u64 = 0,
    last_rx: u64 = 0,
    last_tx: u64 = 0,
    clk_tck: u64 = 100,

    pub fn init() Sampler {
        var s = Sampler{};
        if (clkTck()) |t| s.clk_tck = t;
        return s;
    }

    pub fn sample(self: *Sampler, now_ms: i64) Snapshot {
        var snap = Snapshot{};
        const proc_ticks = readProcTicks();
        const host = readHostCpu();
        const rss = readRssBytes();
        const mem = readHostMem();
        const net = readNetBytes();

        snap.rss_bytes = rss;
        snap.mem_total_bytes = mem.total;
        snap.mem_used_bytes = mem.used;
        snap.ready = self.last_ms > 0;

        if (self.last_ms > 0 and now_ms > self.last_ms) {
            const dt_ms: u64 = @intCast(now_ms - self.last_ms);
            if (proc_ticks) |ticks| {
                if (ticks >= self.last_proc_ticks and self.clk_tck > 0) {
                    snap.cpu_pct_x10 = cpuPctX10(ticks - self.last_proc_ticks, self.clk_tck, dt_ms);
                }
            }
            if (host) |h| {
                if (h.total > self.last_host_total) {
                    const d_total = h.total - self.last_host_total;
                    const d_idle = if (h.idle >= self.last_host_idle) h.idle - self.last_host_idle else 0;
                    const busy = if (d_total > d_idle) d_total - d_idle else 0;
                    snap.host_cpu_pct_x10 = @intCast(@min(1000, busy * 1000 / d_total));
                }
            }
            if (net) |n| {
                snap.net_rx_bps = bytesPerSec(self.last_rx, n.rx, dt_ms);
                snap.net_tx_bps = bytesPerSec(self.last_tx, n.tx, dt_ms);
            }
        }

        if (proc_ticks) |t| self.last_proc_ticks = t;
        if (host) |h| {
            self.last_host_idle = h.idle;
            self.last_host_total = h.total;
        }
        if (net) |n| {
            self.last_rx = n.rx;
            self.last_tx = n.tx;
        }
        self.last_ms = now_ms;
        return snap;
    }
};

fn cpuPctX10(delta_ticks: u64, clk_tck: u64, dt_ms: u64) u32 {
    if (clk_tck == 0 or dt_ms == 0) return 0;
    // tenths of a percent of one core: 1000 * (delta_ticks/clk_tck) / (dt_ms/1000)
    const num = delta_ticks * 1_000_000;
    const den = clk_tck * dt_ms;
    const x10 = num / den;
    return @intCast(@min(x10, 9999));
}

fn bytesPerSec(prev: u64, now: u64, dt_ms: u64) u64 {
    if (dt_ms == 0 or now < prev) return 0;
    return (now - prev) * 1000 / dt_ms;
}

const HostCpu = struct { idle: u64, total: u64 };
const HostMem = struct { used: u64 = 0, total: u64 = 0 };
const NetBytes = struct { rx: u64, tx: u64 };

fn clkTck() ?u64 {
    // USER_HZ is 100 on Linux x86_64; Darwin path uses getrusage microseconds.
    if (builtin.os.tag != .linux) return 1_000_000;
    return 100;
}

fn readAbs(path: []const u8, buf: []u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.c.close(fd);
    const n = std.posix.read(fd, buf) catch return null;
    if (n == 0) return null;
    return buf[0..n];
}

fn readProcTicks() ?u64 {
    if (builtin.os.tag == .linux) {
        var buf: [1024]u8 = undefined;
        const body = readAbs("/proc/self/stat", &buf) orelse return null;
        return parseProcSelfStatTicks(body);
    }
    return readRusageUsec();
}

fn readHostCpu() ?HostCpu {
    if (builtin.os.tag != .linux) return null;
    var buf: [1024]u8 = undefined;
    const body = readAbs("/proc/stat", &buf) orelse return null;
    return parseProcStatCpu(body);
}

fn readRssBytes() u64 {
    if (builtin.os.tag == .linux) {
        var buf: [256]u8 = undefined;
        const body = readAbs("/proc/self/statm", &buf) orelse return readRusageRss();
        return parseProcSelfStatmRss(body, 4096) orelse readRusageRss();
    }
    return readRusageRss();
}

fn readHostMem() HostMem {
    if (builtin.os.tag == .linux) {
        var buf: [2048]u8 = undefined;
        const body = readAbs("/proc/meminfo", &buf) orelse return .{};
        return parseMeminfo(body) orelse .{};
    }
    return readDarwinMem();
}

fn readNetBytes() ?NetBytes {
    if (builtin.os.tag != .linux) return null;
    var buf: [8192]u8 = undefined;
    const body = readAbs("/proc/net/dev", &buf) orelse return null;
    return parseNetDev(body);
}

const TimeUsec = if (builtin.os.tag == .linux) i64 else i32;
const timeval = extern struct {
    tv_sec: i64,
    tv_usec: TimeUsec,
};

const rusage = extern struct {
    utime: timeval,
    stime: timeval,
    maxrss: isize,
    ixrss: isize = 0,
    idrss: isize = 0,
    isrss: isize = 0,
    minflt: isize = 0,
    majflt: isize = 0,
    nswap: isize = 0,
    inblock: isize = 0,
    oublock: isize = 0,
    msgsnd: isize = 0,
    msgrcv: isize = 0,
    nsignals: isize = 0,
    nvcsw: isize = 0,
    nivcsw: isize = 0,
};

extern "c" fn getrusage(who: c_int, usage: *rusage) c_int;
const RUSAGE_SELF: c_int = 0;

fn readRusageUsec() ?u64 {
    if (builtin.os.tag == .linux) return null;
    var ru = std.mem.zeroes(rusage);
    if (getrusage(RUSAGE_SELF, &ru) != 0) return null;
    const u = usec(ru.utime) + usec(ru.stime);
    return u;
}

fn usec(t: timeval) u64 {
    const sec: i128 = t.tv_sec;
    const us: i128 = t.tv_usec;
    if (sec < 0 or us < 0) return 0;
    return @intCast(sec * 1_000_000 + us);
}

fn readRusageRss() u64 {
    if (builtin.os.tag == .linux) return 0;
    var ru = std.mem.zeroes(rusage);
    if (getrusage(RUSAGE_SELF, &ru) != 0) return 0;
    if (ru.maxrss <= 0) return 0;
    return @intCast(ru.maxrss);
}

fn readDarwinMem() HostMem {
    if (builtin.os.tag != .macos) return .{};
    const total = sysctlU64("hw.memsize") orelse return .{};
    return .{ .total = total, .used = 0 };
}

extern "c" fn sysctlbyname(
    name: [*:0]const u8,
    oldp: ?*anyopaque,
    oldlenp: ?*usize,
    newp: ?*anyopaque,
    newlen: usize,
) c_int;

fn sysctlU64(name: [*:0]const u8) ?u64 {
    var val: u64 = 0;
    var len: usize = @sizeOf(u64);
    if (sysctlbyname(name, &val, &len, null, 0) != 0) return null;
    return val;
}

/// utime+stime clock ticks from /proc/self/stat.
pub fn parseProcSelfStatTicks(body: []const u8) ?u64 {
    const rp = std.mem.lastIndexOfScalar(u8, body, ')') orelse return null;
    if (rp + 2 >= body.len) return null;
    var it = std.mem.tokenizeAny(u8, body[rp + 2 ..], " \t\n");
    var i: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (it.next()) |tok| : (i += 1) {
        // After ')': 0=state ... 11=utime 12=stime
        if (i == 11) utime = std.fmt.parseInt(u64, tok, 10) catch return null;
        if (i == 12) {
            stime = std.fmt.parseInt(u64, tok, 10) catch return null;
            return utime + stime;
        }
    }
    return null;
}

pub fn parseProcStatCpu(body: []const u8) ?HostCpu {
    const line_end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    const line = body[0..line_end];
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    var it = std.mem.tokenizeAny(u8, line[4..], " \t");
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        const v = std.fmt.parseInt(u64, tok, 10) catch continue;
        total += v;
        // user nice system idle iowait irq softirq steal ...
        if (i == 3 or i == 4) idle += v;
    }
    if (total == 0) return null;
    return .{ .idle = idle, .total = total };
}

pub fn parseProcSelfStatmRss(body: []const u8, page_size: u64) ?u64 {
    var it = std.mem.tokenizeAny(u8, body, " \t\n");
    _ = it.next() orelse return null; // size
    const res = it.next() orelse return null;
    const pages = std.fmt.parseInt(u64, res, 10) catch return null;
    return pages *% page_size;
}

pub fn parseMeminfo(body: []const u8) ?HostMem {
    var total_kb: ?u64 = null;
    var avail_kb: ?u64 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = firstInt(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            avail_kb = firstInt(line);
        }
        if (total_kb != null and avail_kb != null) break;
    }
    const total = (total_kb orelse return null) *% 1024;
    const avail = (avail_kb orelse 0) *% 1024;
    const used = if (total > avail) total - avail else 0;
    return .{ .used = used, .total = total };
}

pub fn parseNetDev(body: []const u8) ?NetBytes {
    var rx: u64 = 0;
    var tx: u64 = 0;
    var saw = false;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0 or std.mem.eql(u8, name, "lo")) continue;
        var nums = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var idx: usize = 0;
        var line_rx: u64 = 0;
        var line_tx: u64 = 0;
        while (nums.next()) |tok| : (idx += 1) {
            const v = std.fmt.parseInt(u64, tok, 10) catch continue;
            if (idx == 0) line_rx = v;
            if (idx == 8) {
                line_tx = v;
                break;
            }
        }
        if (idx < 8) continue;
        rx +%= line_rx;
        tx +%= line_tx;
        saw = true;
    }
    if (!saw) return null;
    return .{ .rx = rx, .tx = tx };
}

fn firstInt(line: []const u8) ?u64 {
    var i: usize = 0;
    while (i < line.len and (line[i] < '0' or line[i] > '9')) : (i += 1) {}
    if (i >= line.len) return null;
    var j = i;
    while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {}
    return std.fmt.parseInt(u64, line[i..j], 10) catch null;
}

const testing = std.testing;

test "parse /proc/self/stat ticks after comm" {
    const body = "1234 (alphabound) S 1 1 1 0 -1 0 0 0 0 0 40 10 0 0 20 0 3 0 0 0 0\n";
    const ticks = parseProcSelfStatTicks(body).?;
    try testing.expectEqual(@as(u64, 50), ticks);
}

test "parse /proc/stat idle+iowait" {
    const body = "cpu  10 0 10 70 10 0 0 0 0 0\ncpu0 5 0 5 35 5 0 0 0 0 0\n";
    const h = parseProcStatCpu(body).?;
    try testing.expectEqual(@as(u64, 80), h.idle);
    try testing.expectEqual(@as(u64, 100), h.total);
}

test "parse statm rss pages" {
    const rss = parseProcSelfStatmRss("100 20 10 1 0 50 0\n", 4096).?;
    try testing.expectEqual(@as(u64, 20 * 4096), rss);
}

test "parse meminfo used = total - available" {
    const body =
        \\MemTotal:        2000 kB
        \\MemFree:          200 kB
        \\MemAvailable:     500 kB
        \\
    ;
    const m = parseMeminfo(body).?;
    try testing.expectEqual(@as(u64, 2000 * 1024), m.total);
    try testing.expectEqual(@as(u64, 1500 * 1024), m.used);
}

test "parse netdev skips lo and sums nics" {
    const body =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo: 999 0 0 0 0 0 0 0 999 0 0 0 0 0 0 0
        \\  eth0: 100 1 0 0 0 0 0 0 40 1 0 0 0 0 0 0
        \\  ens5: 50 1 0 0 0 0 0 0 10 1 0 0 0 0 0 0
        \\
    ;
    const n = parseNetDev(body).?;
    try testing.expectEqual(@as(u64, 150), n.rx);
    try testing.expectEqual(@as(u64, 50), n.tx);
}

test "cpuPctX10 is 0.2% for one tick in 5s at 100 Hz" {
    try testing.expectEqual(@as(u32, 2), cpuPctX10(1, 100, 5000));
}

test "sample returns rss on this process" {
    var s = Sampler.init();
    const a = s.sample(1_000);
    try testing.expect(a.rss_bytes > 0);
    const b = s.sample(6_000);
    try testing.expect(b.rss_bytes > 0);
}
