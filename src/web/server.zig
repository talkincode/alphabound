//! Local dashboard/ops HTTP API (§6.4). Binds 127.0.0.1 only — access from
//! outside the VM goes through an SSH tunnel; the daemon itself never
//! exposes a public port.
//!
//! Routing and JSON rendering are pure functions over a state snapshot so
//! they test offline; the socket loop is a thin adapter.

const std = @import("std");
const state_mod = @import("../core/state.zig");
const sm = @import("../risk/state_machine.zig");
const clock = @import("../core/clock.zig");

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
};

/// Everything the router may read. Immutable per request.
pub const Context = struct {
    snapshot: state_mod.PortfolioState,
    /// Process phase: true once RECONCILING completed (§7.1).
    ready: bool,
    software_version: []const u8,
    config_hash: []const u8,
    /// Most recent event lines (JSON objects), newest last. May be empty.
    recent_events: []const []const u8 = &.{},
    /// Pre-rendered JSON arrays/objects filled by the core loop (no DB on web thread).
    agent_runs_json: []const u8 = "[]",
    equity_json: []const u8 = "[]",
    shadow_json: []const u8 = "{}",
    events_json: []const u8 = "[]",
    candles_json: []const u8 = "[]",
    memories_json: []const u8 = "[]",
    system_json: []const u8 = "{}",
    decisions_json: []const u8 = "[]",
    /// Orders projection + recent fills: `{"orders":[...],"fills":[...]}`.
    orders_json: []const u8 = "{\"orders\":[],\"fills\":[]}",
    /// Dashboard HTML served at "/". Embedded at comptime; empty = 404.
    index_html: []const u8 = "",
};

fn riskModeText(mode: sm.RiskMode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .exit_only => "EXIT_ONLY",
        .flattening => "FLATTENING",
        .halted => "HALTED",
    };
}

/// Route a request. `buf` backs the response body; must outlive the response.
pub fn handle(buf: []u8, method: std.http.Method, target: []const u8, ctx: Context) Response {
    if (method != .GET) {
        return .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
    }
    // Strip query string for matching.
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

    if (std.mem.eql(u8, path, "/health/live")) {
        return .{ .status = .ok, .body = "{\"status\":\"ok\"}" };
    }
    if (std.mem.eql(u8, path, "/health/ready")) {
        if (ctx.ready) {
            return .{ .status = .ok, .body = "{\"status\":\"ready\"}" };
        }
        return .{ .status = .service_unavailable, .body = "{\"status\":\"not_ready\"}" };
    }
    if (std.mem.eql(u8, path, "/api/v1/state")) {
        return renderState(buf, ctx);
    }
    if (std.mem.eql(u8, path, "/api/v1/events")) {
        // Prefer line list when present (tests / injectors); else DB snapshot JSON.
        if (ctx.recent_events.len > 0) {
            return renderEvents(buf, ctx);
        }
        return copyBody(buf, ctx.events_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/agent-runs")) {
        return copyBody(buf, ctx.agent_runs_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/equity")) {
        return copyBody(buf, ctx.equity_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/shadow")) {
        return copyBody(buf, ctx.shadow_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/candles")) {
        return copyBody(buf, ctx.candles_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/memories")) {
        return copyBody(buf, ctx.memories_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/system")) {
        return copyBody(buf, ctx.system_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/decisions")) {
        return copyBody(buf, ctx.decisions_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/orders")) {
        return copyBody(buf, ctx.orders_json);
    }
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        if (ctx.index_html.len > 0) {
            return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = ctx.index_html };
        }
    }
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

fn renderState(buf: []u8, ctx: Context) Response {
    var w: std.Io.Writer = .fixed(buf);
    var s: std.json.Stringify = .{ .writer = &w };
    const snap = ctx.snapshot;

    var num_buf: [dec_str_len]u8 = undefined;

    render: {
        s.beginObject() catch break :render;
        s.objectField("version") catch break :render;
        s.write(snap.version) catch break :render;
        s.objectField("as_of_ms") catch break :render;
        s.write(snap.as_of_ms) catch break :render;
        s.objectField("risk_mode") catch break :render;
        s.write(riskModeText(snap.risk_mode)) catch break :render;
        s.objectField("reconciled") catch break :render;
        s.write(snap.reconciled) catch break :render;

        s.objectField("cash_usdt") catch break :render;
        s.write(decStr(&num_buf, snap.cash_usdt)) catch break :render;
        s.objectField("btc_total") catch break :render;
        s.write(decStr(&num_buf, snap.btc_total)) catch break :render;
        s.objectField("bid_price") catch break :render;
        s.write(decStr(&num_buf, snap.bid_price)) catch break :render;
        s.objectField("conservative_equity") catch break :render;
        s.write(decStr(&num_buf, snap.conservative_equity)) catch break :render;
        s.objectField("high_watermark") catch break :render;
        s.write(decStr(&num_buf, snap.high_watermark)) catch break :render;
        s.objectField("drawdown") catch break :render;
        s.write(decStr(&num_buf, snap.drawdown)) catch break :render;

        s.objectField("software_version") catch break :render;
        s.write(ctx.software_version) catch break :render;
        s.objectField("config_hash") catch break :render;
        s.write(ctx.config_hash) catch break :render;
        s.endObject() catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

fn renderEvents(buf: []u8, ctx: Context) Response {
    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.writeAll("[") catch break :render;
        for (ctx.recent_events, 0..) |line, i| {
            if (i > 0) w.writeAll(",") catch break :render;
            w.writeAll(line) catch break :render;
        }
        w.writeAll("]") catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

/// Copy a pre-rendered JSON blob into the per-request body buffer so the
/// seqlock snapshot need not remain valid across the full socket write.
fn copyBody(buf: []u8, src: []const u8) Response {
    if (src.len > buf.len) {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"payload_too_large\"}" };
    }
    @memcpy(buf[0..src.len], src);
    return .{ .status = .ok, .body = buf[0..src.len] };
}

const dec_str_len = 48;

fn decStr(buf: *[dec_str_len]u8, v: @import("../core/decimal.zig").Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

// -- Socket loop (thin adapter) ----------------------------------------------

pub const ServerOptions = struct {
    /// Host to bind. Config allows only `127.0.0.1` (default) or `0.0.0.0`
    /// (container / compose behind host-loopback publish).
    host: []const u8 = "127.0.0.1",
    port: u16 = 8722,
};

/// Provider callback: fills a Context for each request.
pub const ContextFn = *const fn (userdata: ?*anyopaque) Context;

/// Blocking accept loop. Each connection handles one request batch.
/// Runs until the stream listener fails; caller owns thread/lifecycle.
pub fn serve(
    io: std.Io,
    opts: ServerOptions,
    ctx_fn: ContextFn,
    userdata: ?*anyopaque,
) !void {
    const addr = try std.Io.net.IpAddress.parse(opts.host, opts.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(io, stream, ctx_fn, userdata) catch {};
    }
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, ctx_fn: ContextFn, userdata: ?*anyopaque) !void {
    defer stream.close(io);
    var in_buf: [8192]u8 = undefined;
    // Large enough for multi-timeframe candles JSON + headers (and dashboard HTML path).
    var out_buf: [196608]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = server.receiveHead() catch return;
    var body_buf: [196608]u8 = undefined;
    const resp = handle(&body_buf, req.head.method, req.head.target, ctx_fn(userdata));
    try req.respond(resp.body, .{
        .status = resp.status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = resp.content_type },
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Decimal = @import("../core/decimal.zig").Decimal;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn testCtx() Context {
    var snap = state_mod.PortfolioState{};
    snap.version = 42;
    snap.as_of_ms = 1_786_264_264_482;
    snap.cash_usdt = d("87.5");
    snap.btc_total = d("0.0001");
    snap.bid_price = d("99123.3");
    snap.conservative_equity = d("97.33");
    snap.high_watermark = d("100");
    snap.drawdown = d("0.0267");
    snap.risk_mode = .normal;
    snap.reconciled = true;
    return .{
        .snapshot = snap,
        .ready = true,
        .software_version = "0.1.0+test",
        .config_hash = "sha256:abc",
    };
}

test "health endpoints" {
    var buf: [1024]u8 = undefined;
    const live = handle(&buf, .GET, "/health/live", testCtx());
    try testing.expectEqual(std.http.Status.ok, live.status);

    var ctx = testCtx();
    ctx.ready = false;
    const ready = handle(&buf, .GET, "/health/ready", ctx);
    try testing.expectEqual(std.http.Status.service_unavailable, ready.status);

    ctx.ready = true;
    const ready2 = handle(&buf, .GET, "/health/ready", ctx);
    try testing.expectEqual(std.http.Status.ok, ready2.status);
}

test "state endpoint renders decimals as strings" {
    var buf: [4096]u8 = undefined;
    const resp = handle(&buf, .GET, "/api/v1/state", testCtx());
    try testing.expectEqual(std.http.Status.ok, resp.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 42), obj.get("version").?.integer);
    try testing.expectEqualStrings("NORMAL", obj.get("risk_mode").?.string);
    try testing.expectEqualStrings("87.5", obj.get("cash_usdt").?.string);
    try testing.expectEqualStrings("0.0267", obj.get("drawdown").?.string);
    try testing.expectEqualStrings("sha256:abc", obj.get("config_hash").?.string);
}

test "events endpoint concatenates recent lines" {
    var buf: [4096]u8 = undefined;
    var ctx = testCtx();
    const lines = [_][]const u8{
        "{\"type\":\"ORDER_SUBMITTED\"}",
        "{\"type\":\"ORDER_FILLED\"}",
    };
    ctx.recent_events = &lines;
    const resp = handle(&buf, .GET, "/api/v1/events", ctx);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectEqualStrings("[{\"type\":\"ORDER_SUBMITTED\"},{\"type\":\"ORDER_FILLED\"}]", resp.body);
}

test "unknown route 404, non-GET 405, query string stripped" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqual(std.http.Status.not_found, handle(&buf, .GET, "/nope", testCtx()).status);
    try testing.expectEqual(std.http.Status.method_not_allowed, handle(&buf, .POST, "/api/v1/state", testCtx()).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/health/live?x=1", testCtx()).status);
}

test "agent-runs equity shadow endpoints serve context blobs" {
    var buf: [1024]u8 = undefined;
    var ctx = testCtx();
    ctx.agent_runs_json = "[{\"run_id\":\"r1\"}]";
    ctx.equity_json = "[{\"equity\":\"100\"}]";
    ctx.shadow_json = "{\"alpha\":\"0\"}";
    ctx.candles_json = "[{\"c\":\"1\"}]";
    ctx.memories_json = "[{\"memory_id\":\"m1\"}]";
    ctx.system_json = "{\"ready\":true}";
    ctx.decisions_json = "[{\"type\":\"AGENT_PROPOSAL_OK\"}]";
    ctx.orders_json = "{\"orders\":[{\"status\":\"FILLED\"}],\"fills\":[]}";
    try testing.expectEqualStrings("[{\"run_id\":\"r1\"}]", handle(&buf, .GET, "/api/v1/agent-runs", ctx).body);
    try testing.expectEqualStrings("[{\"equity\":\"100\"}]", handle(&buf, .GET, "/api/v1/equity", ctx).body);
    try testing.expectEqualStrings("{\"alpha\":\"0\"}", handle(&buf, .GET, "/api/v1/shadow", ctx).body);
    try testing.expectEqualStrings("[{\"c\":\"1\"}]", handle(&buf, .GET, "/api/v1/candles", ctx).body);
    try testing.expectEqualStrings("[{\"memory_id\":\"m1\"}]", handle(&buf, .GET, "/api/v1/memories", ctx).body);
    try testing.expectEqualStrings("{\"ready\":true}", handle(&buf, .GET, "/api/v1/system", ctx).body);
    try testing.expectEqualStrings("[{\"type\":\"AGENT_PROPOSAL_OK\"}]", handle(&buf, .GET, "/api/v1/decisions", ctx).body);
    try testing.expectEqualStrings("{\"orders\":[{\"status\":\"FILLED\"}],\"fills\":[]}", handle(&buf, .GET, "/api/v1/orders", ctx).body);
}
