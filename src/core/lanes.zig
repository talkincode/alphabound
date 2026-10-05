//! Message-passing primitives between the fast risk loop and the slow lanes
//! (LLM thinking, order execution).
//!
//! The risk loop owns the state engine and never waits on a lane. Lanes get
//! work through bounded mailboxes, may be asked to stop through level-triggered
//! flags, and ask the risk loop to do owner-only work through a `Service`.

const std = @import("std");

/// Bounded FIFO with a spin lock; critical sections are a few copies.
/// `push` never blocks: a full mailbox is reported so the sender can drop or
/// defer instead of building an unbounded backlog of stale work.
pub fn Mailbox(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        mutex: std.atomic.Mutex = .unlocked,
        buf: [cap]T = undefined,
        head: usize = 0,
        len: usize = 0,

        fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        pub fn push(self: *Self, item: T) bool {
            self.lock();
            defer self.mutex.unlock();
            if (self.len >= cap) return false;
            self.buf[(self.head + self.len) % cap] = item;
            self.len += 1;
            return true;
        }

        /// Jump the queue (emergency work such as a flatten).
        pub fn pushFront(self: *Self, item: T) bool {
            self.lock();
            defer self.mutex.unlock();
            if (self.len >= cap) return false;
            self.head = (self.head + cap - 1) % cap;
            self.buf[self.head] = item;
            self.len += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            self.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % cap;
            self.len -= 1;
            return item;
        }

        pub fn depth(self: *Self) usize {
            self.lock();
            defer self.mutex.unlock();
            return self.len;
        }
    };
}

/// Owner-only work a lane needs from the risk loop (e.g. an authoritative
/// account reconcile, which mutates engine state and the main DB connection).
/// The lane calls `call` and waits; the risk loop runs `pump` every iteration.
pub const Service = struct {
    requested: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Lane side. Returns the work's result, or false on timeout (the risk
    /// loop may still run it later; the lane must treat the answer as "unknown").
    pub fn call(self: *Service, io: std.Io, timeout_ms: u32) bool {
        const ticket = self.requested.fetchAdd(1, .acq_rel) + 1;
        var waited: u32 = 0;
        while (self.completed.load(.acquire) < ticket) {
            if (waited >= timeout_ms) return false;
            io.sleep(.{ .nanoseconds = 5_000_000 }, .awake) catch return false;
            waited += 5;
        }
        return self.ok.load(.acquire);
    }

    /// Risk-loop side: run `work` once if anything is waiting.
    pub fn pump(self: *Service, context: *anyopaque, work: *const fn (context: *anyopaque) bool) bool {
        const requested = self.requested.load(.acquire);
        if (self.completed.load(.acquire) >= requested) return false;
        const ok = work(context);
        self.ok.store(ok, .release);
        self.completed.store(requested, .release);
        return true;
    }
};

const testing = std.testing;

test "mailbox is bounded FIFO and supports queue jumping" {
    var m = Mailbox(u32, 3){};
    try testing.expect(m.push(1));
    try testing.expect(m.push(2));
    try testing.expect(m.push(3));
    try testing.expect(!m.push(4)); // full: sender must drop, never block
    try testing.expectEqual(@as(?u32, 1), m.pop());
    try testing.expect(m.pushFront(9));
    try testing.expectEqual(@as(?u32, 9), m.pop());
    try testing.expectEqual(@as(?u32, 2), m.pop());
    try testing.expectEqual(@as(?u32, 3), m.pop());
    try testing.expectEqual(@as(?u32, null), m.pop());
    // Wrap-around keeps order.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(m.push(i));
        try testing.expectEqual(@as(?u32, i), m.pop());
    }
}

const ServiceWorker = struct {
    service: *Service,
    result: bool = false,

    fn run(self: *ServiceWorker) void {
        self.result = self.service.call(testing.io, 2_000);
    }
};

fn serviceWork(raw: *anyopaque) bool {
    const n: *u32 = @ptrCast(@alignCast(raw));
    n.* += 1;
    return true;
}

test "service runs owner work for a waiting lane and reports its result" {
    var service = Service{};
    var runs: u32 = 0;
    var worker = ServiceWorker{ .service = &service };
    const t = try std.Thread.spawn(.{}, ServiceWorker.run, .{&worker});
    var spins: usize = 0;
    while (spins < 2000 and !service.pump(&runs, serviceWork)) : (spins += 1) {
        try testing.io.sleep(.{ .nanoseconds = 1_000_000 }, .awake);
    }
    t.join();
    try testing.expect(worker.result);
    try testing.expectEqual(@as(u32, 1), runs);
}

test "service call times out instead of waiting forever on a stalled loop" {
    var service = Service{};
    try testing.expect(!service.call(testing.io, 20));
}
