//! Deployment-maintenance marker: the installer writes it immediately before a
//! controlled restart; the next daemon consumes it into the durable event stream.

const std = @import("std");
const clock = @import("../core/clock.zig");

pub const Marker = struct {
    deployment_id: []const u8,
    started_at: []const u8,
};

pub const ParseError = error{
    Malformed,
    DuplicateField,
    UnsupportedVersion,
    UnsupportedKind,
    MissingField,
    InvalidDeploymentId,
    InvalidTimestamp,
};

/// Fallback location for local/manual deployments when the service does not
/// supply ALPHABOUND_MAINTENANCE_MARKER.
pub fn pathFromDb(db_path: []const u8, out: []u8) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(out, "{s}.maintenance", .{db_path}) catch return error.BufferTooSmall;
}

/// Parse the small line-oriented marker without accepting arbitrary JSON or
/// arbitrary deployment identifiers into the event payload.
pub fn parse(raw: []const u8) ParseError!Marker {
    var version: ?[]const u8 = null;
    var kind: ?[]const u8 = null;
    var deployment_id: ?[]const u8 = null;
    var started_at: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "version")) {
            if (version != null) return error.DuplicateField;
            version = value;
        } else if (std.mem.eql(u8, key, "kind")) {
            if (kind != null) return error.DuplicateField;
            kind = value;
        } else if (std.mem.eql(u8, key, "deployment_id")) {
            if (deployment_id != null) return error.DuplicateField;
            deployment_id = value;
        } else if (std.mem.eql(u8, key, "started_at")) {
            if (started_at != null) return error.DuplicateField;
            started_at = value;
        } else {
            return error.Malformed;
        }
    }

    if (!std.mem.eql(u8, version orelse return error.MissingField, "1"))
        return error.UnsupportedVersion;
    if (!std.mem.eql(u8, kind orelse return error.MissingField, "deployment"))
        return error.UnsupportedKind;

    const id = deployment_id orelse return error.MissingField;
    if (!validDeploymentId(id)) return error.InvalidDeploymentId;
    const ts = started_at orelse return error.MissingField;
    _ = clock.parseRfc3339Ms(ts) catch return error.InvalidTimestamp;
    return .{ .deployment_id = id, .started_at = ts };
}

pub fn writeEventPayload(w: *std.Io.Writer, marker: Marker) std.Io.Writer.Error!void {
    try w.print(
        "{{\"kind\":\"deployment\",\"deployment_id\":\"{s}\",\"started_at\":\"{s}\",\"expected_health_check_gap\":true}}",
        .{ marker.deployment_id, marker.started_at },
    );
}

fn validDeploymentId(id: []const u8) bool {
    if (std.mem.eql(u8, id, "unknown")) return true;
    if (id.len < 7 or id.len > 64) return false;
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!hex) return false;
    }
    return true;
}

const testing = std.testing;

test "parses a deployment marker and writes a safe event payload" {
    const marker = try parse(
        \\version=1
        \\kind=deployment
        \\deployment_id=0123abcd
        \\started_at=2026-08-20T12:00:00Z
        \\
    );
    try testing.expectEqualStrings("0123abcd", marker.deployment_id);
    try testing.expectEqualStrings("2026-08-20T12:00:00Z", marker.started_at);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEventPayload(&w, marker);
    try testing.expectEqualStrings(
        "{\"kind\":\"deployment\",\"deployment_id\":\"0123abcd\",\"started_at\":\"2026-08-20T12:00:00Z\",\"expected_health_check_gap\":true}",
        w.buffered(),
    );
}

test "maintenance marker rejects malformed or untrusted fields" {
    try testing.expectError(error.InvalidDeploymentId, parse(
        \\version=1
        \\kind=deployment
        \\deployment_id=../../not-a-release
        \\started_at=2026-08-20T12:00:00Z
        \\
    ));
    try testing.expectError(error.UnsupportedKind, parse(
        \\version=1
        \\kind=restart
        \\deployment_id=0123abcd
        \\started_at=2026-08-20T12:00:00Z
        \\
    ));
}

test "maintenance marker fallback path follows the database" {
    var buf: [128]u8 = undefined;
    const path = try pathFromDb("var/trading.db", &buf);
    try testing.expectEqualStrings("var/trading.db.maintenance", path);
}
