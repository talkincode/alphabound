//! Risk mode state machine (§5.3).
//!
//! NORMAL      — consistent state, fresh data, ample remaining budget.
//! EXIT_ONLY   — insufficient exit buffer, stale data or uncertain state;
//!               risk-reducing actions only.
//! FLATTENING  — dynamic exit trigger hit or operator flatten; drive BTC to zero.
//! HALTED      — boundary breach, reconcile failure, or severe storage fault;
//!               no trading; manual intervention required to leave.

const std = @import("std");

pub const RiskMode = enum {
    normal,
    exit_only,
    flattening,
    halted,

    pub fn jsonName(self: RiskMode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .exit_only => "EXIT_ONLY",
            .flattening => "FLATTENING",
            .halted => "HALTED",
        };
    }
};

pub const Trigger = enum {
    /// All health conditions satisfied (fresh data, reconciled, budget ok).
    conditions_ok,
    /// Exit buffer insufficient / stale data / uncertain account state.
    degraded,
    /// Dynamic exit trigger line reached, or operator issued flatten.
    exit_trigger,
    /// Drawdown boundary breached, reconcile failed, or storage fault.
    fatal,
    /// Flattening finished (BTC available ≈ 0, no risk-increasing orders).
    flatten_complete,
    /// Explicit operator acknowledgement after HALTED (manual only).
    operator_reset,
};

/// Pure transition function. Fail-closed: unknown combinations keep or
/// escalate the current mode, never relax it.
pub fn next(mode: RiskMode, trigger: Trigger) RiskMode {
    return switch (mode) {
        .normal => switch (trigger) {
            .conditions_ok => .normal,
            .degraded => .exit_only,
            .exit_trigger => .flattening,
            .fatal => .halted,
            .flatten_complete => .normal,
            .operator_reset => .normal,
        },
        .exit_only => switch (trigger) {
            .conditions_ok => .normal, // recovery allowed once healthy again
            .degraded => .exit_only,
            .exit_trigger => .flattening,
            .fatal => .halted,
            .flatten_complete => .exit_only,
            .operator_reset => .exit_only,
        },
        .flattening => switch (trigger) {
            // Flattening must finish or escalate; healthy signals do not abort it.
            .conditions_ok, .degraded, .exit_trigger => .flattening,
            .fatal => .halted,
            .flatten_complete => .halted, // boundary-driven flatten parks in HALTED for review
            .operator_reset => .flattening,
        },
        .halted => switch (trigger) {
            // Only a manual operator reset leaves HALTED.
            .operator_reset => .exit_only, // resume cautiously, never straight to NORMAL
            else => .halted,
        },
    };
}

/// Whether a risk-increasing proposal may even be evaluated in this mode.
pub fn allowsRiskIncrease(mode: RiskMode) bool {
    return mode == .normal;
}

/// Whether risk-reducing orders (cancel, reduce, flatten) are permitted.
pub fn allowsRiskReduction(mode: RiskMode) bool {
    return switch (mode) {
        .normal, .exit_only, .flattening => true,
        .halted => false, // monitoring + manual handling only
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "halted is sticky without operator reset" {
    inline for ([_]Trigger{ .conditions_ok, .degraded, .exit_trigger, .fatal, .flatten_complete }) |t| {
        try testing.expectEqual(RiskMode.halted, next(.halted, t));
    }
    try testing.expectEqual(RiskMode.exit_only, next(.halted, .operator_reset));
}

test "flattening cannot be aborted by healthy signals" {
    try testing.expectEqual(RiskMode.flattening, next(.flattening, .conditions_ok));
    try testing.expectEqual(RiskMode.halted, next(.flattening, .flatten_complete));
    try testing.expectEqual(RiskMode.halted, next(.flattening, .fatal));
}

test "degraded blocks risk increase, recovery restores it" {
    var m = next(.normal, .degraded);
    try testing.expectEqual(RiskMode.exit_only, m);
    try testing.expect(!allowsRiskIncrease(m));
    try testing.expect(allowsRiskReduction(m));
    m = next(m, .conditions_ok);
    try testing.expectEqual(RiskMode.normal, m);
    try testing.expect(allowsRiskIncrease(m));
}

test "property: fatal always lands in halted; no transition relaxes past rules" {
    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    const modes = [_]RiskMode{ .normal, .exit_only, .flattening, .halted };
    const triggers = [_]Trigger{ .conditions_ok, .degraded, .exit_trigger, .fatal, .flatten_complete, .operator_reset };
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const m = modes[random.intRangeLessThan(usize, 0, modes.len)];
        const t = triggers[random.intRangeLessThan(usize, 0, triggers.len)];
        const n = next(m, t);
        if (t == .fatal) try testing.expectEqual(RiskMode.halted, n);
        // risk increase is only ever allowed in NORMAL
        if (allowsRiskIncrease(n)) try testing.expectEqual(RiskMode.normal, n);
    }
}
