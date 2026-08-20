//! Event envelope (§6.3): top-level type / correlation_id / state_version /
//! software_version / config_hash are first-class fields so the Dashboard
//! never has to mine JSON payloads to filter.

const std = @import("std");
const clock_mod = @import("clock.zig");

pub const SOFTWARE_VERSION = "0.1.0-dev";

pub const Severity = enum {
    debug,
    info,
    warn,
    @"error",
    critical,

    pub fn jsonName(self: Severity) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
            .critical => "CRITICAL",
        };
    }
};

pub const EventType = enum {
    system_boot,
    system_mode_change,
    market_tick,
    market_stale,
    account_snapshot,
    reconcile_start,
    reconcile_done,
    reconcile_mismatch,
    agent_run_start,
    agent_run_done,
    agent_run_failed,
    tool_call,
    proposal_received,
    proposal_voided,
    risk_decision,
    risk_mode_change,
    order_planned,
    order_submitted,
    order_update,
    order_unknown,
    fill,
    equity_sample,
    reflection,
    memory_op,
    config_applied,
    system_maintenance,
    backup_done,
    fault,

    pub fn jsonName(self: EventType) []const u8 {
        // Stable wire names, SCREAMING_SNAKE.
        return switch (self) {
            .system_boot => "SYSTEM_BOOT",
            .system_mode_change => "SYSTEM_MODE_CHANGE",
            .market_tick => "MARKET_TICK",
            .market_stale => "MARKET_STALE",
            .account_snapshot => "ACCOUNT_SNAPSHOT",
            .reconcile_start => "RECONCILE_START",
            .reconcile_done => "RECONCILE_DONE",
            .reconcile_mismatch => "RECONCILE_MISMATCH",
            .agent_run_start => "AGENT_RUN_START",
            .agent_run_done => "AGENT_RUN_DONE",
            .agent_run_failed => "AGENT_RUN_FAILED",
            .tool_call => "TOOL_CALL",
            .proposal_received => "PROPOSAL_RECEIVED",
            .proposal_voided => "PROPOSAL_VOIDED",
            .risk_decision => "RISK_DECISION",
            .risk_mode_change => "RISK_MODE_CHANGE",
            .order_planned => "ORDER_PLANNED",
            .order_submitted => "ORDER_SUBMITTED",
            .order_update => "ORDER_UPDATE",
            .order_unknown => "ORDER_UNKNOWN",
            .fill => "FILL",
            .equity_sample => "EQUITY_SAMPLE",
            .reflection => "REFLECTION",
            .memory_op => "MEMORY_OP",
            .config_applied => "CONFIG_APPLIED",
            .system_maintenance => "SYSTEM_MAINTENANCE",
            .backup_done => "BACKUP_DONE",
            .fault => "FAULT",
        };
    }

    /// Critical events must be committed to storage within the write deadline;
    /// ordinary telemetry may be batched (§6.1).
    pub fn isCritical(self: EventType) bool {
        return switch (self) {
            .order_planned,
            .order_submitted,
            .order_update,
            .order_unknown,
            .fill,
            .risk_decision,
            .risk_mode_change,
            .system_mode_change,
            .reconcile_mismatch,
            .config_applied,
            .system_maintenance,
            .fault,
            => true,
            else => false,
        };
    }
};

pub const Event = struct {
    seq: u64 = 0, // assigned by the journal writer
    ts_ms: i64,
    type: EventType,
    source: []const u8,
    severity: Severity = .info,
    correlation_id: ?[]const u8 = null,
    state_version: u64,
    config_hash: []const u8,
    /// Pre-serialized JSON payload (owned by producer until journaled).
    payload_json: []const u8,

    /// Serialize the full envelope to JSON.
    pub fn writeJson(self: Event, w: *std.Io.Writer) !void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("seq");
        try s.write(self.seq);
        try s.objectField("ts");
        var tsbuf: [32]u8 = undefined;
        const ts = clock_mod.formatRfc3339Ms(self.ts_ms, &tsbuf) catch "1970-01-01T00:00:00.000Z";
        try s.write(ts);
        try s.objectField("type");
        try s.write(self.type.jsonName());
        try s.objectField("source");
        try s.write(self.source);
        try s.objectField("severity");
        try s.write(self.severity.jsonName());
        if (self.correlation_id) |cid| {
            try s.objectField("correlation_id");
            try s.write(cid);
        }
        try s.objectField("state_version");
        try s.write(self.state_version);
        try s.objectField("software_version");
        try s.write(SOFTWARE_VERSION);
        try s.objectField("config_hash");
        try s.write(self.config_hash);
        try s.objectField("payload");
        try s.beginWriteRaw();
        try w.writeAll(if (self.payload_json.len > 0) self.payload_json else "{}");
        s.endWriteRaw();
        try s.endObject();
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "envelope serializes with mandatory top-level fields" {
    const e = Event{
        .seq = 92841,
        .ts_ms = 1_786_264_264_482,
        .type = .risk_decision,
        .source = "risk-kernel",
        .severity = .info,
        .correlation_id = "dec_01JX",
        .state_version = 184395,
        .config_hash = "sha256:abc",
        .payload_json =
        \\{"decision":"APPROVE_REDUCED"}
        ,
    };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try e.writeJson(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"RISK_DECISION\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"correlation_id\":\"dec_01JX\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"state_version\":184395") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"config_hash\":\"sha256:abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"payload\":{\"decision\":\"APPROVE_REDUCED\"}") != null);
    // envelope itself must be valid JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    parsed.deinit();
}

test "critical classification covers order and risk events" {
    try testing.expect(EventType.order_submitted.isCritical());
    try testing.expect(EventType.risk_decision.isCritical());
    try testing.expect(EventType.config_applied.isCritical());
    try testing.expect(EventType.system_maintenance.isCritical());
    try testing.expect(!EventType.market_tick.isCritical());
    try testing.expect(!EventType.equity_sample.isCritical());
}
