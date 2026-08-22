//! Intel ingest mailbox: web thread enqueues validated records, the core
//! loop is the only SQLite writer. Rate-limited per source_id.

const std = @import("std");
const protocol = @import("protocol.zig");

pub const EnqueueError = error{
    Full,
    DuplicatePending,
    RateLimited,
};

pub const max_queue = 8;
pub const rate_max: u32 = 30;
pub const rate_window_ms: i64 = 3_600_000;

const RateSlot = struct {
    id_buf: [protocol.max_source]u8 = undefined,
    id_len: usize = 0,
    stamps: [rate_max]i64 = @splat(0),
    n: u32 = 0,

    fn id(self: *const RateSlot) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const Inbox = struct {
    mutex: std.atomic.Mutex = .unlocked,
    queue: [max_queue]protocol.Item = undefined,
    count: usize = 0,
    rates: [8]RateSlot = @splat(.{}),

    fn lock(self: *Inbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn enqueue(self: *Inbox, rec: protocol.Item, now_ms: i64) EnqueueError!void {
        self.lock();
        defer self.mutex.unlock();
        if (self.count >= self.queue.len) return EnqueueError.Full;
        for (self.queue[0..self.count]) |*q| {
            if (std.mem.eql(u8, q.id(), rec.id()) or std.mem.eql(u8, q.dedupKey(), rec.dedupKey()))
                return EnqueueError.DuplicatePending;
        }
        if (!self.allowLocked(rec.sourceId(), now_ms)) return EnqueueError.RateLimited;
        self.queue[self.count] = rec;
        self.count += 1;
        self.noteLocked(rec.sourceId(), now_ms);
    }

    pub fn drain(self: *Inbox) ?protocol.Item {
        self.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const front = self.queue[0];
        var i: usize = 1;
        while (i < self.count) : (i += 1) self.queue[i - 1] = self.queue[i];
        self.count -= 1;
        return front;
    }

    pub fn pending(self: *Inbox) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.count;
    }

    fn allowLocked(self: *Inbox, source_id: []const u8, now_ms: i64) bool {
        const slot = self.findRate(source_id) orelse return true;
        var live: u32 = 0;
        for (slot.stamps[0..slot.n]) |ts| {
            if (now_ms - ts < rate_window_ms) live += 1;
        }
        return live < rate_max;
    }

    fn noteLocked(self: *Inbox, source_id: []const u8, now_ms: i64) void {
        const slot = self.findRate(source_id) orelse self.allocRate(source_id) orelse return;
        if (slot.n < slot.stamps.len) {
            slot.stamps[slot.n] = now_ms;
            slot.n += 1;
            return;
        }
        var oldest: usize = 0;
        var i: usize = 1;
        while (i < slot.stamps.len) : (i += 1) {
            if (slot.stamps[i] < slot.stamps[oldest]) oldest = i;
        }
        slot.stamps[oldest] = now_ms;
    }

    fn findRate(self: *Inbox, source_id: []const u8) ?*RateSlot {
        for (&self.rates) |*s| {
            if (s.id_len == 0) continue;
            if (std.mem.eql(u8, s.id(), source_id)) return s;
        }
        return null;
    }

    fn allocRate(self: *Inbox, source_id: []const u8) ?*RateSlot {
        for (&self.rates) |*s| {
            if (s.id_len == 0) {
                const n = @min(source_id.len, s.id_buf.len);
                @memcpy(s.id_buf[0..n], source_id[0..n]);
                s.id_len = n;
                return s;
            }
        }
        return &self.rates[0];
    }
};

const testing = std.testing;

fn testRec(id: []const u8, source: []const u8) protocol.Item {
    var it = protocol.Item{};
    const n = @min(id.len, it.id_buf.len);
    @memcpy(it.id_buf[0..n], id[0..n]);
    it.id_len = n;
    const sn = @min(source.len, it.source_buf.len);
    @memcpy(it.source_buf[0..sn], source[0..sn]);
    it.source_len = sn;
    const d = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    @memcpy(it.dedup_buf[0..64], d[0..64]);
    it.dedup_buf[63] = id[id.len - 1];
    return it;
}

test "inbox enqueue drain FIFO and duplicate id" {
    var box: Inbox = .{};
    try box.enqueue(testRec("intel_a1", "collector.macro"), 1);
    try box.enqueue(testRec("intel_a2", "collector.macro"), 2);
    try testing.expectEqual(@as(usize, 2), box.pending());
    try testing.expectError(EnqueueError.DuplicatePending, box.enqueue(testRec("intel_a1", "collector.macro"), 3));
    try testing.expectEqualStrings("intel_a1", box.drain().?.id());
    try testing.expectEqualStrings("intel_a2", box.drain().?.id());
    try testing.expect(box.drain() == null);
}

test "inbox rate limit per source" {
    var box: Inbox = .{};
    const t: i64 = 1_000;
    var i: u32 = 0;
    while (i < rate_max) : (i += 1) {
        var id_buf: [16]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "intel_{d}", .{i + 10}) catch unreachable;
        try box.enqueue(testRec(id, "collector.macro"), t + i);
        _ = box.drain();
    }
    try testing.expectError(EnqueueError.RateLimited, box.enqueue(testRec("intel_zz", "collector.macro"), t + rate_max));
    try box.enqueue(testRec("intel_other", "collector.news"), t + rate_max);
}
