//! Proposal-LLM availability only. Pure, process-local state; callers supply time.
const std = @import("std");

pub const Mode = enum { observe, enforce };
pub const State = enum { closed, open, half_open };
pub const Params = struct {
    failure_threshold: u32 = 3,
    open_ms: u32 = 720_000,
    /// Consecutive successful half-open calls needed to close. Calls are serial.
    half_open_probes: u32 = 1,
};

pub const Breaker = struct {
    params: Params = .{},
    state: State = .closed,
    failures: u32 = 0,
    opened_ms: i64 = 0,
    probe_successes: u32 = 0,

    /// Observe advances the same state machine but never suppresses a call.
    pub fn allow(self: *Breaker, now_ms: i64, mode: Mode) bool {
        if (self.state == .open and @as(i128, now_ms) - self.opened_ms >= self.params.open_ms) {
            self.state = .half_open;
            self.probe_successes = 0;
        }
        return mode == .observe or self.state != .open;
    }

    pub fn recordSuccess(self: *Breaker) void {
        self.failures = 0;
        if (self.state == .half_open) {
            self.probe_successes +|= 1;
            if (self.probe_successes < self.params.half_open_probes) return;
        }
        // Observe may see recovery before the open interval expires.
        self.state = .closed;
        self.probe_successes = 0;
    }

    /// Returns true only on a transition into open. Invalid proposals and
    /// local/parser/resource errors are not provider availability failures.
    pub fn recordFailure(self: *Breaker, tag: []const u8, now_ms: i64) bool {
        if (!countsFailure(tag)) return false;
        if (self.state == .open) return false;
        self.failures +|= 1;
        if (self.state == .half_open or self.failures >= self.params.failure_threshold) {
            self.state = .open;
            self.opened_ms = now_ms;
            self.probe_successes = 0;
            return true;
        }
        return false;
    }
};

pub fn countsFailure(tag: []const u8) bool {
    inline for (.{ "timeout", "connect", "http_failed", "api_error", "empty_content" }) |failure| {
        if (std.mem.eql(u8, tag, failure)) return true;
    }
    return false;
}

const t = std.testing;
test "threshold, exact deadline, failed probe resets interval, successful probe closes" {
    var b = Breaker{};
    try t.expect(!b.recordFailure("timeout", 0));
    try t.expect(!b.recordFailure("connect", 1));
    try t.expect(b.recordFailure("api_error", 2));
    try t.expectEqual(State.open, b.state);
    try t.expect(!b.allow(720_001, .enforce));
    try t.expect(b.allow(720_002, .enforce));
    try t.expectEqual(State.half_open, b.state);
    try t.expect(b.recordFailure("empty_content", 720_003));
    try t.expect(!b.allow(1_440_002, .enforce));
    try t.expect(b.allow(1_440_003, .enforce));
    b.recordSuccess();
    try t.expectEqual(State.closed, b.state);
    try t.expectEqual(@as(u32, 0), b.failures);
}

test "failure classification, consecutive failures, repeated open failure, backwards time" {
    inline for (.{ "timeout", "connect", "http_failed", "api_error", "empty_content" }) |tag| try t.expect(countsFailure(tag));
    var b = Breaker{ .params = .{ .failure_threshold = 1 } };
    inline for (.{ "invalid_proposal", "malformed_response", "oom", "buffer" }) |tag| {
        try t.expect(!b.recordFailure(tag, 0));
        try t.expectEqual(State.closed, b.state);
    }
    try t.expect(b.recordFailure("http_failed", 10));
    try t.expect(!b.recordFailure("timeout", 20));
    try t.expectEqual(@as(i64, 10), b.opened_ms);
    try t.expect(!b.allow(-1, .enforce));
    try t.expect(b.allow(11, .observe));
    b.recordSuccess();
    try t.expectEqual(State.closed, b.state);
    b.params.failure_threshold = 3;
    _ = b.recordFailure("timeout", 30);
    b.recordSuccess();
    _ = b.recordFailure("timeout", 31);
    try t.expectEqual(@as(u32, 1), b.failures);
}

test "multiple half-open probes require consecutive successes" {
    var b = Breaker{ .params = .{ .failure_threshold = 1, .open_ms = 10, .half_open_probes = 2 } };
    _ = b.recordFailure("timeout", 0);
    try t.expect(b.allow(10, .enforce));
    b.recordSuccess();
    try t.expectEqual(State.half_open, b.state);
    try t.expect(!b.recordFailure("invalid_proposal", 11));
    try t.expect(b.recordFailure("timeout", 12));
    try t.expect(b.allow(22, .enforce));
    b.recordSuccess();
    b.recordSuccess();
    try t.expectEqual(State.closed, b.state);
}

test "2026-10-15 outage replay 08:11 to 13:04, 15-minute failures then recovery" {
    // Synthetic relative timestamps; no network, account data or wall clock.
    const start: i64 = (8 * 60 + 11) * 60_000;
    const recovery: i64 = (13 * 60 + 4) * 60_000;
    inline for (.{ Mode.observe, Mode.enforce }) |mode| {
        var b = Breaker{};
        var at = start;
        var calls: u32 = 0;
        while (at < recovery) : (at += 15 * 60_000) {
            try t.expect(b.allow(at, mode));
            if (calls >= 3) try t.expectEqual(State.half_open, b.state);
            const opened = b.recordFailure("timeout", at);
            calls += 1;
            try t.expectEqual(calls >= 3, opened);
            try t.expectEqual(if (calls >= 3) State.open else State.closed, b.state);
            if (calls >= 3) {
                try t.expectEqual(mode == .observe, b.allow(at + 1, mode));
            }
        }
        // Final failed call was 12:56; enforce must wait until 13:08.
        try t.expectEqual(mode == .observe, b.allow(recovery, mode));
        if (mode == .enforce) {
            const next_probe = b.opened_ms + b.params.open_ms;
            try t.expect(!b.allow(next_probe - 1, mode));
            try t.expect(b.allow(next_probe, mode));
            try t.expectEqual(State.half_open, b.state);
        }
        b.recordSuccess();
        try t.expectEqual(State.closed, b.state);
        try t.expect(b.allow(at + 1, mode));
    }
}

test "observe never suppresses calls and emits one open transition per interval" {
    var b = Breaker{ .params = .{ .failure_threshold = 2, .open_ms = 10 } };
    try t.expect(b.allow(0, .observe));
    try t.expect(!b.recordFailure("timeout", 0));
    try t.expect(b.allow(1, .observe));
    try t.expect(!b.recordFailure("invalid_proposal", 1));
    try t.expectEqual(@as(u32, 1), b.failures);
    try t.expect(b.recordFailure("http_failed", 2));
    var now: i64 = 3;
    while (now < 12) : (now += 1) {
        try t.expect(b.allow(now, .observe));
        try t.expectEqual(State.open, b.state);
        try t.expect(!b.recordFailure("timeout", now));
    }
    try t.expect(b.allow(12, .observe));
    try t.expectEqual(State.half_open, b.state);
    try t.expect(b.recordFailure("api_error", 12));
    try t.expect(b.allow(13, .observe));
    b.recordSuccess();
    try t.expectEqual(State.closed, b.state);
}
