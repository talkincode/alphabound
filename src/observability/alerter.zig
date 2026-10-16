//! Best-effort, single-flight webhook delivery. No caller waits for network I/O.
//! Only deterministic audit findings belong here; never provider responses.
const std = @import("std");
const builtin = @import("builtin");
const redaction = @import("redaction.zig");

pub const Payload = struct {
    severity: []const u8,
    check: []const u8,
    detail: []const u8,
    instance_id: []const u8,
    ts: []const u8,
};

/// Escape JSON and redact every string before it crosses the process boundary.
pub fn buildPayload(buf: []u8, payload: Payload) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte('{');
    inline for (std.meta.fields(Payload), 0..) |field, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{field.name});
        const value = @field(payload, field.name);
        if (value.len > 1024) return error.PayloadTooLarge;
        var clean: [2048]u8 = undefined;
        try std.json.Stringify.value(redaction.redact(value, &clean), .{}, &w);
    }
    try w.writeByte('}');
    return w.buffered();
}

var busy = std.atomic.Value(bool).init(false);
const Work = struct {
    url: []u8,
    body: []u8,
    timeout_ms: u32,

    fn run(self: *Work) void {
        const gpa = std.heap.page_allocator;
        defer busy.store(false, .release);
        defer gpa.destroy(self);
        defer gpa.free(self.url);
        defer gpa.free(self.body);
        // Own the I/O runtime: no detached access to daemon allocator/io/env.
        var threaded = std.Io.Threaded.init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const Result = union(enum) { sent: bool, timeout: void };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(io, &results);
        defer select.cancelDiscard();
        select.concurrent(.sent, post, .{ io, self.url, self.body }) catch {
            std.debug.print("[alert] webhook worker unavailable\n", .{});
            return;
        };
        select.concurrent(.timeout, wait, .{ io, self.timeout_ms }) catch {
            std.debug.print("[alert] webhook timer unavailable\n", .{});
            return;
        };
        const result = select.await() catch return;
        switch (result) {
            .sent => |ok| if (!ok) {
                std.debug.print("[alert] webhook delivery failed\n", .{});
            },
            .timeout => std.debug.print("[alert] webhook timeout\n", .{}),
        }
    }

    fn wait(io: std.Io, timeout_ms: u32) void {
        io.sleep(.fromMilliseconds(timeout_ms), .awake) catch {};
    }

    fn post(io: std.Io, url: []const u8, body: []const u8) bool {
        var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
        defer client.deinit();
        var response: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&response);
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &writer,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
        }) catch return false;
        const code = @intFromEnum(result.status);
        return code >= 200 and code < 300;
    }
};

/// URL comes exclusively from the environment. Do not log it (may hold tokens).
/// Drop on saturation rather than queueing or delaying a decision.
pub fn send(enabled: bool, url: ?[]const u8, timeout_ms: u32, payload: Payload) void {
    if (builtin.is_test or !enabled) return;
    const target = url orelse return;
    if (target.len == 0) return;
    if (!std.mem.startsWith(u8, target, "https://")) {
        std.debug.print("[alert] webhook requires HTTPS\n", .{});
        return;
    }
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        std.debug.print("[alert] webhook busy; notification dropped\n", .{});
        return;
    }
    const gpa = std.heap.page_allocator;
    var buf: [8192]u8 = undefined;
    const body = buildPayload(&buf, payload) catch {
        busy.store(false, .release);
        std.debug.print("[alert] webhook payload rejected\n", .{});
        return;
    };
    const work = gpa.create(Work) catch {
        busy.store(false, .release);
        return;
    };
    const owned_url = gpa.dupe(u8, target) catch {
        gpa.destroy(work);
        busy.store(false, .release);
        return;
    };
    const owned_body = gpa.dupe(u8, body) catch {
        gpa.free(owned_url);
        gpa.destroy(work);
        busy.store(false, .release);
        return;
    };
    work.* = .{ .url = owned_url, .body = owned_body, .timeout_ms = timeout_ms };
    const thread = std.Thread.spawn(.{}, Work.run, .{work}) catch {
        gpa.free(owned_body);
        gpa.free(owned_url);
        gpa.destroy(work);
        busy.store(false, .release);
        std.debug.print("[alert] webhook worker unavailable\n", .{});
        return;
    };
    thread.detach();
}

test "payload is escaped, redacted JSON with exactly the public schema" {
    var buf: [8192]u8 = undefined;
    const json = try buildPayload(&buf, .{
        .severity = "alert",
        .check = "llm.error_llm_window",
        .detail = "synthetic \"finding\"\napi_key=FAKE_SECRET",
        .instance_id = "test-instance",
        .ts = "2026-01-01T00:00:00.000Z",
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.count());
    try std.testing.expectEqualStrings("alert", parsed.value.object.get("severity").?.string);
    try std.testing.expectEqualStrings("llm.error_llm_window", parsed.value.object.get("check").?.string);
    try std.testing.expectEqualStrings("test-instance", parsed.value.object.get("instance_id").?.string);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00.000Z", parsed.value.object.get("ts").?.string);
    try std.testing.expect(std.mem.indexOf(u8, json, "FAKE_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, redaction.MASK) != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.object.get("detail").?.string, "\"finding\"\n") != null);
}
