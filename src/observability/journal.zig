//! Audit journal writer: every event row carries state version, software
//! version, and config hash, with boundary redaction (§7.3 / AC-SEC3).
//! Journal append failure degrades the engine (AC-GO6) — un-auditable
//! trading must not continue increasing risk.

const std = @import("std");
const storage = @import("../storage/db.zig");
const state = @import("../core/state.zig");
const config = @import("../config.zig");
const clock = @import("../core/clock.zig");
const redaction = @import("redaction.zig");

/// Set once at boot by main (before the first event is written).
pub var software_version: []const u8 = "dev";

var event_counter = std.atomic.Value(u64).init(0);

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

pub fn logEvent(
    repo: *storage.EventsRepo,
    engine: *state.Engine,
    event_type: []const u8,
    source: []const u8,
    severity: []const u8,
    cfg: *const config.Config,
) void {
    _ = logEventPayloadChecked(repo, engine, event_type, source, severity, cfg, "{}");
}

pub fn logEventPayload(
    repo: *storage.EventsRepo,
    engine: *state.Engine,
    event_type: []const u8,
    source: []const u8,
    severity: []const u8,
    cfg: *const config.Config,
    payload_json: []const u8,
) void {
    _ = logEventPayloadChecked(repo, engine, event_type, source, severity, cfg, payload_json);
}

/// Same journal path as `logEventPayload`, but reports whether the event reached
/// durable storage. Callers with a one-shot marker can retain it for retry.
pub fn logEventPayloadChecked(
    repo: *storage.EventsRepo,
    engine: *state.Engine,
    event_type: []const u8,
    source: []const u8,
    severity: []const u8,
    cfg: *const config.Config,
    payload_json: []const u8,
) bool {
    const snap = engine.snapshot();
    const n = event_counter.fetchAdd(1, .monotonic);
    var id_buf: [64]u8 = undefined;
    const event_id = std.fmt.bufPrint(&id_buf, "evt_{d}_{d}", .{ nowMs(), n }) catch return false;
    var ts_buf: [32]u8 = undefined;
    const ts = clock.formatRfc3339Ms(nowMs(), &ts_buf) catch return false;
    // Boundary redaction (§7.3 / AC-SEC3): never persist secrets in event payloads.
    var red_buf: [4096]u8 = undefined;
    const safe_payload = if (payload_json.len + 64 <= red_buf.len)
        redaction.redact(payload_json, &red_buf)
    else
        payload_json;
    if (redaction.looksLeaky(safe_payload)) {
        std.debug.print("[journal] drop leaky payload for {s}\n", .{event_type});
        return false;
    }
    repo.append(.{
        .event_id = event_id,
        .ts = ts,
        .type = event_type,
        .source = source,
        .severity = severity,
        .state_version = @intCast(snap.version),
        .software_version = software_version,
        .config_hash = cfg.hash(),
        .payload_json = safe_payload,
    }) catch |err| {
        std.debug.print("[journal] append failed: {t} — degrading (AC-GO6)\n", .{err});
        // Un-auditable trading must not continue increasing risk.
        _ = engine.apply(.{ .journal_status = .{ .ok = false } }) catch {};
        return false;
    };
    if (!snap.journal_ok) {
        std.debug.print("[journal] append recovered — clearing degrade\n", .{});
        _ = engine.apply(.{ .journal_status = .{ .ok = true } }) catch {};
    }
    return true;
}
