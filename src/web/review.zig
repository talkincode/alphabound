//! Review (复盘) mailbox: the web thread enqueues human review requests,
//! the core loop drains them (single writer keeps DB + LLM off the web
//! thread). Analysis-only channel — nothing here can reach the trading
//! path: no engine, no orders, no risk state.

const std = @import("std");

/// `periodic` runs an on-demand 定期复盘 cycle; the cycle name ("short" /
/// "long") travels in `decision_id` so the queue stays allocation-free.
pub const Kind = enum { context, chat, summarize, periodic };

pub const max_decision_id = 96;
pub const max_anchor_ts = 40;
pub const max_message = 1500;

/// One queued review request (fixed-size copies; no allocation).
pub const Request = struct {
    kind: Kind = .context,
    decision_id_buf: [max_decision_id]u8 = undefined,
    decision_id_len: usize = 0,
    anchor_ts_buf: [max_anchor_ts]u8 = undefined,
    anchor_ts_len: usize = 0,
    message_buf: [max_message]u8 = undefined,
    message_len: usize = 0,

    pub fn decisionId(self: *const Request) []const u8 {
        return self.decision_id_buf[0..self.decision_id_len];
    }
    pub fn anchorTs(self: *const Request) []const u8 {
        return self.anchor_ts_buf[0..self.anchor_ts_len];
    }
    pub fn message(self: *const Request) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

pub const EnqueueError = error{ Full, BadInput, DuplicatePending };

/// Small spin-guarded FIFO (std.atomic.Mutex; critical sections are tiny
/// memcpys). Web accept loop is single-threaded; the core loop drains at
/// most one request per tick, so depth stays tiny.
pub const Inbox = struct {
    mutex: std.atomic.Mutex = .unlocked,
    queue: [4]Request = undefined,
    count: usize = 0,

    fn lock(self: *Inbox) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn enqueue(
        self: *Inbox,
        kind: Kind,
        decision_id: []const u8,
        anchor_ts: []const u8,
        message: []const u8,
    ) EnqueueError!void {
        if (decision_id.len == 0 or decision_id.len > max_decision_id) return EnqueueError.BadInput;
        if (anchor_ts.len > max_anchor_ts) return EnqueueError.BadInput;
        if (message.len > max_message) return EnqueueError.BadInput;
        if (kind == .chat and message.len == 0) return EnqueueError.BadInput;
        if (kind == .periodic and
            !std.mem.eql(u8, decision_id, "short") and
            !std.mem.eql(u8, decision_id, "long")) return EnqueueError.BadInput;

        self.lock();
        defer self.mutex.unlock();
        if (self.count >= self.queue.len) return EnqueueError.Full;
        // One in-flight chat/summarize per decision: keeps the LLM path serial
        // and stops double-submit from the UI.
        if (kind != .context) {
            for (self.queue[0..self.count]) |*r| {
                if (r.kind == kind and std.mem.eql(u8, r.decisionId(), decision_id))
                    return EnqueueError.DuplicatePending;
            }
        }
        var req: Request = .{ .kind = kind };
        @memcpy(req.decision_id_buf[0..decision_id.len], decision_id);
        req.decision_id_len = decision_id.len;
        @memcpy(req.anchor_ts_buf[0..anchor_ts.len], anchor_ts);
        req.anchor_ts_len = anchor_ts.len;
        @memcpy(req.message_buf[0..message.len], message);
        req.message_len = message.len;
        self.queue[self.count] = req;
        self.count += 1;
    }

    /// Pop the oldest request. Null when empty.
    pub fn drain(self: *Inbox) ?Request {
        self.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const req = self.queue[0];
        var i: usize = 1;
        while (i < self.count) : (i += 1) self.queue[i - 1] = self.queue[i];
        self.count -= 1;
        return req;
    }

    /// Number of queued requests (for /review status hints).
    pub fn pending(self: *Inbox) usize {
        self.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "inbox enqueue/drain FIFO with copies" {
    var box: Inbox = .{};
    try box.enqueue(.chat, "dec_1", "2026-08-14T03:26:41.212Z", "为什么当时选择 HOLD？");
    try box.enqueue(.context, "dec_2", "", "");
    try testing.expectEqual(@as(usize, 2), box.pending());

    const a = box.drain().?;
    try testing.expectEqual(Kind.chat, a.kind);
    try testing.expectEqualStrings("dec_1", a.decisionId());
    try testing.expectEqualStrings("2026-08-14T03:26:41.212Z", a.anchorTs());
    try testing.expectEqualStrings("为什么当时选择 HOLD？", a.message());

    const b = box.drain().?;
    try testing.expectEqual(Kind.context, b.kind);
    try testing.expectEqualStrings("dec_2", b.decisionId());
    try testing.expect(box.drain() == null);
}

test "periodic requests carry the cycle and dedupe per cycle" {
    var box: Inbox = .{};
    try testing.expectError(EnqueueError.BadInput, box.enqueue(.periodic, "yearly", "", ""));
    try testing.expectError(EnqueueError.BadInput, box.enqueue(.periodic, "", "", ""));

    try box.enqueue(.periodic, "short", "", "");
    try testing.expectError(EnqueueError.DuplicatePending, box.enqueue(.periodic, "short", "", ""));
    try box.enqueue(.periodic, "long", "", "");

    const a = box.drain().?;
    try testing.expectEqual(Kind.periodic, a.kind);
    try testing.expectEqualStrings("short", a.decisionId());
    try testing.expectEqualStrings("long", box.drain().?.decisionId());
}

test "inbox rejects bad input, duplicates and overflow" {
    var box: Inbox = .{};
    try testing.expectError(EnqueueError.BadInput, box.enqueue(.chat, "", "", "hi"));
    try testing.expectError(EnqueueError.BadInput, box.enqueue(.chat, "dec", "", ""));
    const long = [_]u8{'x'} ** (max_message + 1);
    try testing.expectError(EnqueueError.BadInput, box.enqueue(.chat, "dec", "", &long));

    try box.enqueue(.chat, "dec_1", "", "q1");
    try testing.expectError(EnqueueError.DuplicatePending, box.enqueue(.chat, "dec_1", "", "q2"));
    // context requests may repeat
    try box.enqueue(.context, "dec_1", "", "");
    try box.enqueue(.context, "dec_1", "", "");
    try box.enqueue(.context, "dec_1", "", "");
    try testing.expectError(EnqueueError.Full, box.enqueue(.context, "dec_1", "", ""));
}
