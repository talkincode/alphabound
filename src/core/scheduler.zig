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

/// Parse a bounded ISO-8601 duration ("PT4H", "PT30M", "P1D", "PT1H30M")
/// into milliseconds. Returns null for anything malformed, negative,
/// fractional, or beyond 30 days — model output is untrusted input.
pub fn parseIsoDurationMs(s: []const u8) ?i64 {
    const max_ms: i64 = 30 * 86_400_000;
    if (s.len < 3 or (s[0] != 'P' and s[0] != 'p')) return null;
    var total: i64 = 0;
    var in_time = false;
    var i: usize = 1;
    var any = false;
    while (i < s.len) {
        const c = s[i];
        if (c == 'T' or c == 't') {
            if (in_time) return null;
            in_time = true;
            i += 1;
            continue;
        }
        const start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == start or i >= s.len) return null;
        const n = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
        const unit = s[i];
        i += 1;
        const ms: i64 = switch (unit) {
            'D', 'd' => if (in_time) return null else 86_400_000,
            'H', 'h' => if (!in_time) return null else 3_600_000,
            'M', 'm' => if (!in_time) return null else 60_000,
            'S', 's' => if (!in_time) return null else 1_000,
            else => return null,
        };
        if (n > @divTrunc(max_ms, ms)) return null;
        total += n * ms;
        if (total > max_ms) return null;
        any = true;
    }
    if (!any) return null;
    return total;
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
    /// Upper bound for honoring a HOLD proposal's `review_after` as a regular-
    /// cadence backoff; 0 disables the backoff entirely (legacy behavior).
    /// Event triggers (price_move / drawdown_step / risk_mode_change) always
    /// cut through a backoff, so risk reaction speed is unchanged.
    review_backoff_max_ms: i64 = 0,
    /// Cap for the escalating price_move cooldown after consecutive no-op
    /// decisions (HOLD / plan-held rebalances). Each consecutive no-op doubles
    /// the price_move floor starting from min_interval_ms, capped here.
    /// 0 disables escalation. Only price_move is dampened — drawdown_step and
    /// risk_mode_change keep the base cooldown, and the risk kernel is
    /// independent of this advisory loop entirely.
    noop_backoff_cap_ms: i64 = 0,

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
    /// Regular cadence is suppressed until this instant (HOLD review_after
    /// backoff). Event triggers ignore it; cleared on every fire.
    hold_until_ms: i64 = 0,
    /// Consecutive decisions that produced no order (HOLD or plan-held
    /// rebalance). Drives the escalating price_move cooldown; reset by
    /// `noteOutcome(true)` when a decision actually trades.
    consecutive_noops: u32 = 0,

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
            if (rel.gte(p.price_move) and elapsed >= self.priceMoveFloorMs())
                return .{ .fire = true, .reason = .price_move };
        }

        // Session-aware regular cadence, deferrable by a HOLD review_after backoff.
        const hour = hourUtc(now_ms);
        if (now_ms < self.hold_until_ms) return .{};
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
        self.hold_until_ms = 0;
    }

    /// Honor `review_after` on a no-op decision (HOLD, or REBALANCE that
    /// planned to HOLD because the delta was dust / below min notional) by
    /// deferring the next regular-cadence fire. Clamped into [current
    /// effective interval, review_backoff_max_ms]; returns the applied
    /// backoff in ms, or 0 when the feature is disabled. Event triggers
    /// still cut through.
    pub fn deferAfterHold(self: *Scheduler, now_ms: i64, review_after_ms: i64) i64 {
        const cap = self.params.review_backoff_max_ms;
        if (cap <= 0 or review_after_ms <= 0) return 0;
        const floor_ms = self.params.effectiveInterval(hourUtc(now_ms));
        const clamped = @min(@max(review_after_ms, floor_ms), cap);
        self.hold_until_ms = now_ms + clamped;
        return clamped;
    }

    /// Record whether the fired decision actually produced an order.
    /// Consecutive no-ops (HOLD, plan-held rebalance) escalate the
    /// price_move cooldown; any real order resets it.
    pub fn noteOutcome(self: *Scheduler, produced_order: bool) void {
        if (produced_order) {
            self.consecutive_noops = 0;
        } else {
            self.consecutive_noops +|= 1;
        }
    }

    /// Effective cooldown floor for the price_move trigger: doubles per
    /// consecutive no-op from min_interval_ms, saturating at the cap.
    fn priceMoveFloorMs(self: *const Scheduler) i64 {
        const p = self.params;
        if (p.noop_backoff_cap_ms <= 0 or self.consecutive_noops == 0)
            return p.min_interval_ms;
        const shift: u6 = @intCast(@min(self.consecutive_noops, 20));
        const scaled = p.min_interval_ms *| (@as(i64, 1) <<| shift);
        return @min(scaled, @max(p.noop_backoff_cap_ms, p.min_interval_ms));
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

test "parseIsoDurationMs accepts bounded durations, rejects junk" {
    try testing.expectEqual(@as(?i64, 4 * 3_600_000), parseIsoDurationMs("PT4H"));
    try testing.expectEqual(@as(?i64, 30 * 60_000), parseIsoDurationMs("PT30M"));
    try testing.expectEqual(@as(?i64, 86_400_000), parseIsoDurationMs("P1D"));
    try testing.expectEqual(@as(?i64, 5_400_000), parseIsoDurationMs("PT1H30M"));
    try testing.expectEqual(@as(?i64, 90_061_000), parseIsoDurationMs("P1DT1H1M1S"));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs(""));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("PT"));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("4H"));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("PT4X"));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("P4H")); // H needs T
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("PT1.5H"));
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("P99D")); // > 30d
    try testing.expectEqual(@as(?i64, null), parseIsoDurationMs("PT999999999999H"));
}

test "hold backoff defers regular cadence but not event triggers" {
    var s = Scheduler.init(.{
        .base_interval_ms = 900_000,
        .min_interval_ms = 180_000,
        .price_move = d("0.005"),
        .review_backoff_max_ms = 4 * 3_600_000,
    });
    s.commit(0, d("64000"), Decimal.zero, .normal);

    // HOLD with PT4H → backoff applied at the cap.
    const applied = s.deferAfterHold(0, parseIsoDurationMs("PT4H").?);
    try testing.expectEqual(@as(i64, 4 * 3_600_000), applied);

    // Regular cadence suppressed at base interval and well beyond.
    try testing.expect(!s.evaluate(900_000, d("64000"), Decimal.zero, .normal).fire);
    try testing.expect(!s.evaluate(3 * 3_600_000, d("64000"), Decimal.zero, .normal).fire);

    // Price event still cuts through during the backoff.
    const v = s.evaluate(900_000, d("63616"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.price_move, v.reason);

    // Risk mode change also cuts through.
    try testing.expect(s.evaluate(900_000, d("64000"), Decimal.zero, .exit_only).fire);

    // After the backoff expires, regular cadence resumes.
    const v2 = s.evaluate(4 * 3_600_000 + 1, d("64000"), Decimal.zero, .normal);
    try testing.expect(v2.fire);
    try testing.expectEqual(TriggerReason.interval_active, v2.reason);

    // commit clears the backoff.
    _ = s.deferAfterHold(0, 3_600_000);
    s.commit(10, d("64000"), Decimal.zero, .normal);
    try testing.expectEqual(@as(i64, 0), s.hold_until_ms);
}

test "hold backoff clamps below to interval and disabled cap is a no-op" {
    var s = Scheduler.init(.{
        .base_interval_ms = 900_000,
        .min_interval_ms = 0,
        .review_backoff_max_ms = 4 * 3_600_000,
    });
    // PT1M below the base interval → clamped up to base.
    try testing.expectEqual(@as(i64, 900_000), s.deferAfterHold(0, 60_000));

    var off = Scheduler.init(.{ .base_interval_ms = 900_000 });
    try testing.expectEqual(@as(i64, 0), off.deferAfterHold(0, 3_600_000));
    try testing.expectEqual(@as(i64, 0), off.hold_until_ms);
}

test "no-op escalation dampens price_move only; order resets" {
    var s = Scheduler.init(.{
        .base_interval_ms = 900_000,
        .min_interval_ms = 180_000,
        .price_move = d("0.005"),
        .noop_backoff_cap_ms = 3_600_000,
    });
    s.commit(0, d("100"), Decimal.zero, .normal);

    // Baseline: 1% move fires at the 180s floor.
    var v = s.evaluate(180_000, d("101"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.price_move, v.reason);
    s.commit(180_000, d("101"), Decimal.zero, .normal);

    // One no-op → price_move floor doubles to 360s.
    s.noteOutcome(false);
    try testing.expect(!s.evaluate(180_000 + 180_000, d("102.1"), Decimal.zero, .normal).fire);
    v = s.evaluate(180_000 + 360_000, d("102.1"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.price_move, v.reason);
    s.commit(540_000, d("102.1"), Decimal.zero, .normal);

    // Three more no-ops (4 total) → floor 16×=2880s; still blocked at 720s...
    s.noteOutcome(false);
    s.noteOutcome(false);
    s.noteOutcome(false);
    try testing.expect(!s.evaluate(540_000 + 720_000, d("104"), Decimal.zero, .normal).fire);
    // ...but a risk-mode change still cuts through at the base 180s floor.
    const vr = s.evaluate(540_000 + 180_000, d("104"), Decimal.zero, .exit_only);
    try testing.expect(vr.fire);
    try testing.expectEqual(TriggerReason.risk_mode_change, vr.reason);
    // Regular cadence also unaffected (fires at base interval).
    const vc = s.evaluate(540_000 + 900_000, d("102.2"), Decimal.zero, .normal);
    try testing.expect(vc.fire);
    try testing.expectEqual(TriggerReason.interval_active, vc.reason);

    // A real order resets escalation back to the base floor.
    s.noteOutcome(true);
    const v2 = s.evaluate(540_000 + 180_000, d("104"), Decimal.zero, .normal);
    try testing.expect(v2.fire);
    try testing.expectEqual(TriggerReason.price_move, v2.reason);
}

test "no-op escalation saturates at cap and disabled cap keeps legacy behavior" {
    var s = Scheduler.init(.{
        .base_interval_ms = 7_200_000,
        .min_interval_ms = 180_000,
        .price_move = d("0.005"),
        .noop_backoff_cap_ms = 3_600_000,
    });
    s.commit(0, d("100"), Decimal.zero, .normal);
    var i: u32 = 0;
    while (i < 40) : (i += 1) s.noteOutcome(false); // way past any shift width
    // Blocked below the 1h cap, fires at the cap.
    try testing.expect(!s.evaluate(3_599_999, d("110"), Decimal.zero, .normal).fire);
    const v = s.evaluate(3_600_000, d("110"), Decimal.zero, .normal);
    try testing.expect(v.fire);
    try testing.expectEqual(TriggerReason.price_move, v.reason);

    // cap=0 → legacy: no-ops never dampen price_move.
    var legacy = Scheduler.init(.{
        .base_interval_ms = 900_000,
        .min_interval_ms = 180_000,
        .price_move = d("0.005"),
    });
    legacy.commit(0, d("100"), Decimal.zero, .normal);
    legacy.noteOutcome(false);
    legacy.noteOutcome(false);
    const lv = legacy.evaluate(180_000, d("101"), Decimal.zero, .normal);
    try testing.expect(lv.fire);
    try testing.expectEqual(TriggerReason.price_move, lv.reason);
}
