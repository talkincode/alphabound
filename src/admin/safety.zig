//! Durable operator/risk latch. An unclean process exit requires explicit
//! resume after reconciliation; it must never implicitly clear a pause/halt.
const std = @import("std");
const storage = @import("../storage/db.zig");
const risk = @import("../risk/state_machine.zig");
const clock = @import("../core/clock.zig");
const key = "runtime_safety_v1";

pub const State = struct {
    paused: bool = false,
    mode: risk.RiskMode = .exit_only,
    clean: bool = true,
};
fn parse(encoded: []const u8) storage.DbError!State {
    var it = std.mem.splitScalar(u8, encoded, '|');
    if (!std.mem.eql(u8, it.next() orelse "", "v1")) return error.StepFailed;
    const p = it.next() orelse return error.StepFailed;
    const m = it.next() orelse return error.StepFailed;
    const c = it.next() orelse return error.StepFailed;
    if (it.next() != null) return error.StepFailed;
    if ((!std.mem.eql(u8, p, "0") and !std.mem.eql(u8, p, "1")) or
        (!std.mem.eql(u8, c, "0") and !std.mem.eql(u8, c, "1"))) return error.StepFailed;
    var mode: ?risk.RiskMode = null;
    inline for (std.meta.fields(risk.RiskMode)) |field| {
        const candidate: risk.RiskMode = @enumFromInt(field.value);
        if (std.mem.eql(u8, m, candidate.jsonName())) mode = candidate;
    }
    return .{ .paused = std.mem.eql(u8, p, "1"), .mode = mode orelse return error.StepFailed, .clean = std.mem.eql(u8, c, "1") };
}

pub fn load(db: *storage.Db, kv: *storage.KvRepo) storage.DbError!State {
    var buf: [128]u8 = undefined;
    if (try kv.getChecked(key, &buf)) |encoded| return parse(encoded);
    // First upgrade: retain legacy explicit latches. Without a durable session
    // marker, a nonempty historical DB must be reviewed before autonomous buys.
    var out = State{ .clean = (try db.queryInt("SELECT count(*) FROM events")) == 0 };
    var pause = try db.prepare("SELECT type FROM events WHERE type IN ('ADMIN_PAUSED','ADMIN_RESUMED') ORDER BY seq DESC LIMIT 1");
    defer pause.finalize();
    if (try pause.step()) out.paused = std.mem.eql(u8, pause.columnText(0), "ADMIN_PAUSED");
    var mode = try db.prepare(
        \\SELECT CASE
        \\ WHEN type='ADMIN_OPERATOR_RESET' THEN 'EXIT_ONLY'
        \\ WHEN type='ADMIN_FLATTEN' THEN 'FLATTENING'
        \\ WHEN type='ADMIN_FLATTEN_COMPLETE' THEN 'HALTED'
        \\ ELSE upper(json_extract(payload_json,'$.to')) END
        \\FROM events WHERE type IN ('ADMIN_OPERATOR_RESET','ADMIN_FLATTEN','ADMIN_FLATTEN_COMPLETE')
        \\ OR (type='RISK_MODE_CHANGED' AND upper(json_extract(payload_json,'$.to')) IN ('HALTED','FLATTENING'))
        \\ORDER BY seq DESC LIMIT 1
    );
    defer mode.finalize();
    if (try mode.step()) {
        const text = mode.columnText(0);
        if (std.mem.eql(u8, text, "HALTED")) out.mode = .halted else if (std.mem.eql(u8, text, "FLATTENING")) out.mode = .flattening;
    }
    return out;
}

pub fn save(kv: *storage.KvRepo, value: State) storage.DbError!void {
    var buf: [64]u8 = undefined;
    const encoded = std.fmt.bufPrint(&buf, "v1|{d}|{s}|{d}", .{ @intFromBool(value.paused), value.mode.jsonName(), @intFromBool(value.clean) }) catch return error.StepFailed;
    var ts_buf: [32]u8 = undefined;
    const ts = clock.formatRfc3339Ms(clock.SystemClock.clock().wallMs(), &ts_buf) catch return error.StepFailed;
    try kv.put(key, encoded, ts);
}

pub fn checkpoint(kv: *storage.KvRepo, previous: *State, paused: bool, mode: risk.RiskMode) storage.DbError!void {
    const next = State{ .paused = paused, .mode = mode, .clean = false };
    if (previous.paused == next.paused and previous.mode == next.mode and !previous.clean) return;
    try save(kv, next);
    previous.* = next;
}

test "safety checkpoints retain halt/pause and reject malformed data" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    var kv = try storage.KvRepo.init(&db);
    defer kv.deinit();
    try std.testing.expect((try load(&db, &kv)).clean);
    try save(&kv, .{ .paused = true, .mode = .halted, .clean = false });
    const restored = try load(&db, &kv);
    try std.testing.expect(restored.paused and restored.mode == .halted and !restored.clean);
    try kv.put(key, "v1|0|UNKNOWN|1", "synthetic-time");
    try std.testing.expectError(error.StepFailed, load(&db, &kv));
}
test "legacy halt is not cleared by a later normal health event" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    var kv = try storage.KvRepo.init(&db);
    defer kv.deinit();
    var events = try storage.EventsRepo.init(&db);
    defer events.deinit();
    try events.append(.{ .event_id = "synthetic-halt", .ts = "synthetic-time", .type = "ADMIN_FLATTEN_COMPLETE", .source = "test", .severity = "CRITICAL" });
    try events.append(.{ .event_id = "synthetic-health", .ts = "synthetic-time", .type = "RISK_MODE_CHANGED", .source = "test", .severity = "INFO", .payload_json = "{\"to\":\"NORMAL\"}" });
    const restored = try load(&db, &kv);
    try std.testing.expect(restored.mode == .halted and !restored.clean);
    try events.append(.{ .event_id = "synthetic-reset", .ts = "synthetic-time", .type = "ADMIN_OPERATOR_RESET", .source = "test", .severity = "CRITICAL" });
    try std.testing.expect((try load(&db, &kv)).mode == .exit_only);
}
