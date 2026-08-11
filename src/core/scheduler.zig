//! Deterministic multi-factor decision scheduler (slow loop cadence).
//!
//! Replaces the fixed `decision_interval_ms` tick with three composable
//! factors, all pure functions of loop state — no wall-clock reads inside:
//!
//! 1. Regular low-frequency cadence: `base_interval_ms` while inside the
//!    configured UTC active session, `quiet_interval_ms` outside it.
//! 2. Event triggers that pull a decision forward: price moved beyond
//!    `price_move` since the last decision, drawdown deepened by
//!    `drawdown_step`, or the risk mode changed.
//! 3. A hard cooldown floor `min_interval_ms` that bounds *every* trigger so
//!    event bursts can never spam the LLM. The risk kernel acts on its own —
//!    this only gates the advisory LLM proposal loop.
//!
//! Fail-safe: `base_interval_ms == 0` disables scheduled decisions entirely
//! (manual `--agent-once` still works, matching previous behavior).

const std = @import("std");
const dec = @import("decimal.zig");
const sm = @import("../risk/state_machine.zig");

const Decimal = dec.Decimal;

pub const TriggerReason = enum {
    none,
    first_run,
    interval_active,
    interval_quiet,
    price_move,
    drawdown_step,
    risk_mode_change,

    pub fn text(self: TriggerReason) []const u8 {
        return switch (self) {
            .none => "none",
            .first_run => "first_run",
            .interval_active => "interval_active",
            .interval_quiet => "interval_quiet",
            .price_move => "price_move",
            .drawdown_step => "drawdown_step",
            .risk_mode_change => "risk_mode_change",
        };
    }
};

pub const Verdict = struct {
    fire: bool = false,
    reason: TriggerReason = .none,
};

/// UTC hour window [start, end); start == end means always active.
/// Supports wrap-around windows like 22-4.
pub const HourRange = struct {
    start: u8 = 0,
    end: u8 = 0,

    pub fn alwaysActive(self: HourRange) bool {
        return self.start == self.end;
    }

    pub fn contains(self: HourRange, hour_utc: u8) bool {
        if (self.alwaysActive()) return true;
        if (self.start < self.end) return hour_utc >= self.start and hour_utc < self.end;
        // wrap: e.g. 22-4 → [22,24) ∪ [0,4)
        return hour_utc >= self.start or hour_utc < self.end;
    }
};

pub const ParseHoursError = error{InvalidHours};

/// Parse "13-21" style UTC hour ranges; "" → always active.
pub fn parseHours(s: []const u8) ParseHoursError!HourRange {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len == 0) return .{};
    const dash = std.mem.indexOfScalar(u8, t, '-') orelse return error.InvalidHours;
    const a = std.fmt.parseInt(u8, std.mem.trim(u8, t[0..dash], " "), 10) catch return error.InvalidHours;
    const b = std.fmt.parseInt(u8, std.mem.trim(u8, t[dash + 1 ..], " "), 10) catch return error.InvalidHours;
    if (a > 23 or b > 23) return error.InvalidHours;
    return .{ .start = a, .end = b };
}

pub fn hourUtc(now_ms: i64) u8 {
    const h = @mod(@divFloor(now_ms, 3_600_000), 24);
    return @intCast(h);
}

pub const Params = struct {
    /// Cadence inside the active session; 0 disables scheduled decisions.
    base_interval_ms: i64 = 600_000,
    /// Cadence outside the active session; 0 → same as base.
    quiet_interval_ms: i64 = 0,
    /// Hard floor between any two decisions (event triggers included).
    min_interval_ms: i64 = 120_000,
    active_hours: HourRange = .{},
    /// Early trigger when |bid − last_bid| / last_bid ≥ this fraction; 0 disables.
    price_move: Decimal = Decimal.zero,
    /// Early trigger when drawdown − last_drawdown ≥ this fraction; 0 disables.
    drawdown_step: Decimal = Decimal.zero,

    pub fn effectiveInterval(self: Params, hour: u8) i64 {
        if (self.active_hours.contains(hour)) return self.base_interval_ms;
        return if (self.quiet_interval_ms > 0) self.quiet_interval_ms else self.base_interval_ms;
    }
};

pub const Scheduler = struct {
    params: Params,
    fired_once: bool = false,
    last_fire_ms: i64 = 0,
    last_bid: Decimal = Decimal.zero,
    last_drawdown: Decimal = Decimal.zero,
    last_risk_mode: sm.RiskMode = .exit_only,

    pub fn init(params: Params) Scheduler {
        return .{ .params = params };
    }

    /// Pure check — does not mutate state. Call `commit` after actually firing.
    pub fn evaluate(
        self: *const Scheduler,
        now_ms: i64,
        bid: Decimal,
        drawdown: Decimal,
        risk_mode: sm.RiskMode,
    ) Verdict {
        const p = self.params;
        if (p.base_interval_ms <= 0) return .{};
        if (!self.fired_once) return .{ .fire = true, .reason = .first_run };

        const elapsed = now_ms - self.last_fire_ms;
        if (elapsed < p.min_interval_ms) return .{};

        // Event triggers (advisory-only; risk kernel already acted on its own).
        if (risk_mode != self.last_risk_mode)
            return .{ .fire = true, .reason = .risk_mode_change };

        if (!p.drawdown_step.isZero() and !p.drawdown_step.isNegative()) {
            const dd_delta = drawdown.sub(self.last_drawdown) catch Decimal.zero;
            if (!dd_delta.isNegative() and dd_delta.gte(p.drawdown_step))
                return .{ .fire = true, .reason = .drawdown_step };
        }

        if (!p.price_move.isZero() and !p.price_move.isNegative() and
            self.last_bid.gt(Decimal.zero) and bid.gt(Decimal.zero))
        {
            const diff = bid.sub(self.last_bid) catch Decimal.zero;
            const rel = diff.abs().div(self.last_bid, .down) catch Decimal.zero;
            if (rel.gte(p.price_move))
                return .{ .fire = true, .reason = .price_move };
        }

        // Session-aware regular cadence.
        const hour = hourUtc(now_ms);
        const interval = p.effectiveInterval(hour);
        if (interval > 0 and elapsed >= interval) {
            const reason: TriggerReason = if (p.active_hours.contains(hour)) .interval_active else .interval_quiet;
            return .{ .fire = true, .reason = reason };
        }
        return .{};
    }

    /// Record that a decision fired now with the given market observations.
    pub fn commit(
        self: *Scheduler,
        now_ms: i64,
        bid: Decimal,
        drawdown: Decimal,
        risk_mode: sm.RiskMode,
    ) void {
        self.fired_once = true;
        self.last_fire_ms = now_ms;
        self.last_bid = bid;
        self.last_drawdown = drawdown;
        self.last_risk_mode = risk_mode;
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "parseHours accepts empty, plain, and wrap ranges" {
    const always = try parseHours("");
    try testing.expect(always.alwaysActive());
    const day = try parseHours("13-21");
    try testing.expect(day.contains(13));
    try testing.expect(day.contains(20));
    try testing.expect(!day.contains(21));
    try testing.expect(!day.contains(5));
    const wrap = try parseHours("22-4");
    try testing.expect(wrap.contains(23));
    try testing.expect(wrap.contains(0));
    try testing.expect(wrap.contains(3));
    try testing.expect(!wrap.contains(4));
    try testing.expect(!wrap.contains(12));
    try testing.expectError(error.InvalidHours, parseHours("25-3"));
    try testing.expectError(error.InvalidHours, parseHours("abc"));
    try testing.expectError(error.InvalidHours, parseHours("13"));
}

test "first run fires immediately; base interval 0 disables" {
    var s = Scheduler.init(.{ .base_interval_ms = 600_000 });
    const v = s.evaluate(1_000, d("100"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.first_run, v.reason);

    const off = Scheduler.init(.{ .base_interval_ms = 0 });
    try testing.expect(!off.evaluate(1_000, d("100"), Decimal.zero, .normal).fire);
}

test "cooldown floor blocks all triggers including risk mode change" {
    var s = Scheduler.init(.{ .base_interval_ms = 600_000, .min_interval_ms = 120_000 });
    s.commit(0, d("100"), Decimal.zero, .normal);
    // 60s later: risk mode changed but cooldown not yet elapsed.
    try testing.expect(!s.evaluate(60_000, d("100"), Decimal.zero, .exit_only).fire);
    // 120s later: fires with risk_mode_change.
    const v = s.evaluate(120_000, d("100"), Decimal.zero, .exit_only);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.risk_mode_change, v.reason);
}

test "session cadence: active vs quiet interval" {
    const params = Params{
        .base_interval_ms = 600_000, // 10 min active
        .quiet_interval_ms = 3_600_000, // 60 min quiet
        .min_interval_ms = 0,
        .active_hours = try parseHours("13-21"),
    };
    var s = Scheduler.init(params);
    // Fire at 13:00 UTC on day 0 → epoch 13h.
    const t13 = @as(i64, 13) * 3_600_000;
    s.commit(t13, d("100"), Decimal.zero, .normal);
    // 13:10 active → fires with interval_active.
    var v = s.evaluate(t13 + 600_000, d("100"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.interval_active, v.reason);

    // Fire at 22:00 (quiet). 10 min later must NOT fire; 60 min later fires quiet.
    const t22 = @as(i64, 22) * 3_600_000;
    s.commit(t22, d("100"), Decimal.zero, .normal);
    try testing.expect(!s.evaluate(t22 + 600_000, d("100"), Decimal.zero, .normal).fire);
    v = s.evaluate(t22 + 3_600_000, d("100"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.interval_quiet, v.reason);
}

test "price move triggers early after cooldown" {
    var s = Scheduler.init(.{
        .base_interval_ms = 3_600_000,
        .min_interval_ms = 120_000,
        .price_move = d("0.005"),
    });
    s.commit(0, d("64000"), Decimal.zero, .normal);
    // +0.3% after cooldown → no trigger.
    try testing.expect(!s.evaluate(200_000, d("64192"), Decimal.zero, .normal).fire);
    // −0.6% → triggers.
    const v = s.evaluate(200_000, d("63616"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.price_move, v.reason);
}

test "drawdown deepening triggers; recovery does not" {
    var s = Scheduler.init(.{
        .base_interval_ms = 3_600_000,
        .min_interval_ms = 0,
        .drawdown_step = d("0.01"),
    });
    s.commit(0, d("100"), d("0.02"), .normal);
    // Drawdown recovered → no event trigger.
    try testing.expect(!s.evaluate(60_000, d("100"), d("0.005"), .normal).fire);
    // Deepened by exactly 1% → triggers.
    const v = s.evaluate(60_000, d("100"), d("0.03"), .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.drawdown_step, v.reason);
}

test "quiet interval 0 falls back to base" {
    const params = Params{
        .base_interval_ms = 600_000,
        .quiet_interval_ms = 0,
        .min_interval_ms = 0,
        .active_hours = try parseHours("13-21"),
    };
    try testing.expectEqual(@as(i64, 600_000), params.effectiveInterval(2));
    try testing.expectEqual(@as(i64, 600_000), params.effectiveInterval(15));
}
