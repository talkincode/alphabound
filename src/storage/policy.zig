//! Storage fault policies for Gate 3 (AC-FD6 / FD7 / FD8).
//! Pure decision helpers — no I/O. Daemon maps outcomes to risk mode / logging.

const std = @import("std");
const sm = @import("../risk/state_machine.zig");

/// How the writer should treat a SQLITE_BUSY after the configured busy_timeout.
pub const BusyAction = enum {
    /// Brief retry still allowed (under max attempts).
    retry,
    /// Drop/downsample non-critical telemetry; keep critical event writes.
    degrade_telemetry,
};

pub fn onBusy(attempt: u32, max_retries: u32) BusyAction {
    if (attempt < max_retries) return .retry;
    return .degrade_telemetry;
}

/// Disk free-space bands (bytes free on the volume holding the DB).
pub const DiskBand = enum {
    ok,
    /// Stop opening risk-increasing trades; allow flatten/cancel.
    low,
    /// Severe — force HALTED.
    critical,
};

pub fn classifyDiskFree(free_bytes: u64, low_threshold: u64, critical_threshold: u64) DiskBand {
    if (free_bytes <= critical_threshold) return .critical;
    if (free_bytes <= low_threshold) return .low;
    return .ok;
}

/// Risk mode reaction to disk pressure (never relaxes an existing HALTED).
pub fn riskModeForDisk(current: sm.RiskMode, band: DiskBand) sm.RiskMode {
    return switch (band) {
        .ok => current,
        .low => switch (current) {
            .normal => .exit_only,
            .exit_only, .flattening, .halted => current,
        },
        .critical => .halted,
    };
}

/// Whether risk-increasing proposals may be evaluated under this disk band.
pub fn allowsRiskIncreaseOnDisk(band: DiskBand) bool {
    return band == .ok;
}

/// On open/migrate failure that looks like corruption: never silently create a
/// fresh empty trading DB and continue as if nothing happened.
pub const CorruptOpenAction = enum {
    /// Refuse boot / stay halted with emergency logging only.
    refuse_and_halt,
};

pub fn onCorruptOpen() CorruptOpenAction {
    return .refuse_and_halt;
}

/// True when an open error should be treated as possible corruption rather than
/// "file missing" (missing is OK to create once at first boot).
pub fn looksLikeCorruption(path_exists: bool, open_ok: bool) bool {
    return path_exists and !open_ok;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "AC-FD6 busy retries then degrades telemetry" {
    try testing.expectEqual(BusyAction.retry, onBusy(0, 3));
    try testing.expectEqual(BusyAction.retry, onBusy(2, 3));
    try testing.expectEqual(BusyAction.degrade_telemetry, onBusy(3, 3));
}

test "AC-FD7 disk bands stop risk increase and can halt" {
    try testing.expectEqual(DiskBand.ok, classifyDiskFree(10_000_000_000, 1_000_000_000, 100_000_000));
    try testing.expectEqual(DiskBand.low, classifyDiskFree(500_000_000, 1_000_000_000, 100_000_000));
    try testing.expectEqual(DiskBand.critical, classifyDiskFree(50_000_000, 1_000_000_000, 100_000_000));

    try testing.expect(allowsRiskIncreaseOnDisk(.ok));
    try testing.expect(!allowsRiskIncreaseOnDisk(.low));
    try testing.expect(!allowsRiskIncreaseOnDisk(.critical));

    try testing.expectEqual(sm.RiskMode.exit_only, riskModeForDisk(.normal, .low));
    try testing.expectEqual(sm.RiskMode.halted, riskModeForDisk(.normal, .critical));
    try testing.expectEqual(sm.RiskMode.halted, riskModeForDisk(.halted, .ok)); // do not auto-unhalt
    try testing.expectEqual(sm.RiskMode.flattening, riskModeForDisk(.flattening, .low));
}

test "AC-FD8 corrupt open refuses silent empty recreate" {
    try testing.expect(looksLikeCorruption(true, false));
    try testing.expect(!looksLikeCorruption(false, false)); // first boot path
    try testing.expect(!looksLikeCorruption(true, true));
    try testing.expectEqual(CorruptOpenAction.refuse_and_halt, onCorruptOpen());
}
