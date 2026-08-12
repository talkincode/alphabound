//! In-process latency tracking for the critical risk path (AC-NFR01).
//!
//! Design target: market event → in-process risk computation p99 < 10 ms
//! (excluding public network). This keeps a bounded reservoir of recent
//! samples and derives percentiles on demand — no allocation, no locks
//! (single-writer daemon thread only).

const std = @import("std");

pub const CAPACITY = 2048;

pub const Histogram = struct {
    samples_us: [CAPACITY]u32 = undefined,
    len: usize = 0,
    next: usize = 0,
    total_count: u64 = 0,
    max_us: u32 = 0,

    pub fn record(self: *Histogram, us: u32) void {
        self.samples_us[self.next] = us;
        self.next = (self.next + 1) % CAPACITY;
        if (self.len < CAPACITY) self.len += 1;
        self.total_count += 1;
        if (us > self.max_us) self.max_us = us;
    }

    /// Percentile over the retained window (nearest-rank). p in [0,100].
    pub fn percentile(self: *const Histogram, p: u8) u32 {
        if (self.len == 0) return 0;
        var sorted: [CAPACITY]u32 = undefined;
        @memcpy(sorted[0..self.len], self.samples_us[0..self.len]);
        std.mem.sort(u32, sorted[0..self.len], {}, std.sort.asc(u32));
        const pc: usize = @min(@as(usize, p), 100);
        // nearest-rank: ceil(p/100 * n), 1-based
        var rank = (pc * self.len + 99) / 100;
        if (rank == 0) rank = 1;
        return sorted[rank - 1];
    }

    pub fn count(self: *const Histogram) u64 {
        return self.total_count;
    }

    pub fn maxUs(self: *const Histogram) u32 {
        return self.max_us;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "empty histogram reports zeros" {
    var h = Histogram{};
    try testing.expectEqual(@as(u32, 0), h.percentile(50));
    try testing.expectEqual(@as(u64, 0), h.count());
}

test "percentiles over a known distribution" {
    var h = Histogram{};
    // 1..100 µs
    var i: u32 = 1;
    while (i <= 100) : (i += 1) h.record(i);
    try testing.expectEqual(@as(u32, 50), h.percentile(50));
    try testing.expectEqual(@as(u32, 99), h.percentile(99));
    try testing.expectEqual(@as(u32, 100), h.percentile(100));
    try testing.expectEqual(@as(u32, 1), h.percentile(0));
    try testing.expectEqual(@as(u32, 100), h.maxUs());
    try testing.expectEqual(@as(u64, 100), h.count());
}

test "ring buffer keeps most recent window but max is lifetime" {
    var h = Histogram{};
    var i: u32 = 0;
    while (i < CAPACITY) : (i += 1) h.record(1_000_000); // old slow samples
    i = 0;
    while (i < CAPACITY) : (i += 1) h.record(5); // fully overwrite window
    try testing.expectEqual(@as(u32, 5), h.percentile(99));
    try testing.expectEqual(@as(u32, 1_000_000), h.maxUs()); // lifetime max survives
    try testing.expectEqual(@as(u64, 2 * CAPACITY), h.count());
}

test "property: percentile is monotone in p and bounded by window contents" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var h = Histogram{};
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const v = random.intRangeAtMost(u32, 0, 20_000);
        h.record(v);
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    var prev: u32 = 0;
    var p: u8 = 0;
    while (p <= 100) : (p += 10) {
        const v = h.percentile(p);
        try testing.expect(v >= prev);
        try testing.expect(v >= lo and v <= hi);
        prev = v;
        if (p == 100) break;
    }
}
