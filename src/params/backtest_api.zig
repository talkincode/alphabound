//! HTTP-facing backtest gate.
//!
//! The replay runs on its own thread. The trading loop never calls this file,
//! and nothing here inserts an order. `max_drawdown` stays 0.10.

const std = @import("std");
const db = @import("../storage/db.zig");
const dec = @import("../core/decimal.zig");
const clock = @import("../core/clock.zig");
const dynamic = @import("dynamic.zig");
const store = @import("store.zig");
const gate = @import("gate.zig");
const history = @import("history.zig");
const backtest = @import("../backtest.zig");

const Decimal = dec.Decimal;
const heap = std.heap.page_allocator;

pub const ApiStatus = enum {
    ok,
    bad_request,
    unprocessable,
    not_found,
    failed,

    pub fn http(self: ApiStatus) std.http.Status {
        return switch (self) {
            .ok => .ok,
            .bad_request => .bad_request,
            .unprocessable => .unprocessable_entity,
            .not_found => .not_found,
            .failed => .internal_server_error,
        };
    }
};

pub const ApiResult = struct {
    status: ApiStatus,
    body: []const u8,
};

const Slot = struct {
    bars: []const backtest.Bar,
    decisions: []const backtest.Decision,
    baseline: dynamic.Params,
    candidate: dynamic.Params,
    baseline_version_id: i64,
    min_notional: Decimal,
    now_ms: i64,
    meta: gate.Meta,
    out: []u8,
    report: gate.Report = .{},
    failed: bool = false,
};

fn replayWorker(slot: *Slot) void {
    slot.report = gate.evaluate(
        heap,
        slot.bars,
        slot.decisions,
        slot.baseline,
        slot.candidate,
        slot.baseline_version_id,
        slot.min_notional,
        slot.now_ms,
        slot.meta,
        slot.out,
    ) catch {
        slot.failed = true;
        return;
    };
}

pub fn run(
    database: *db.Db,
    min_notional: Decimal,
    now_ms: i64,
    request_json: []const u8,
    out: []u8,
) !ApiResult {
    var parsed = std.json.parseFromSlice(std.json.Value, heap, request_json, .{}) catch {
        return errBody(out, .bad_request, "bad_json", "");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return errBody(out, .bad_request, "bad_json", "");
    const obj = parsed.value.object;
    if (obj.get("max_drawdown") != null) return errBody(out, .unprocessable, "locked", "max_drawdown");
    var it = obj.iterator();
    while (it.next()) |entry| {
        const known = std.mem.eql(u8, entry.key_ptr.*, "source") or
            std.mem.eql(u8, entry.key_ptr.*, "operator") or
            std.mem.eql(u8, entry.key_ptr.*, "reason") or
            std.mem.eql(u8, entry.key_ptr.*, "params") or
            std.mem.eql(u8, entry.key_ptr.*, "version_id") or
            std.mem.eql(u8, entry.key_ptr.*, "candles") or
            std.mem.eql(u8, entry.key_ptr.*, "decisions");
        if (!known) return errBody(out, .bad_request, "unknown_field", "");
    }
    const meta = parseMeta(obj) orelse return errBody(out, .bad_request, "meta", "");
    const params_v = obj.get("params");
    const version_v = obj.get("version_id");
    if ((params_v == null) == (version_v == null)) return errBody(out, .bad_request, "params", "");
    const candles = jsonString(obj, "candles");
    const decisions = jsonString(obj, "decisions");
    if ((candles == null) != (decisions == null)) return errBody(out, .bad_request, "csv_pair", "");
    if (candles) |c| if (c.len == 0 or decisions.?.len == 0) return errBody(out, .bad_request, "csv_pair", "");

    const candidate: dynamic.Params = if (params_v) |pv| blk: {
        if (pv == .object) {
            if (pv.object.get("max_drawdown") != null) return errBody(out, .unprocessable, "locked", "max_drawdown");
        }
        break :blk dynamic.parseValue(pv) catch return errBody(out, .bad_request, "params", "");
    } else blk: {
        const version_id: i64 = switch (version_v.?) {
            .integer => |n| n,
            else => return errBody(out, .bad_request, "version_id", ""),
        };
        if (version_id <= 0) return errBody(out, .bad_request, "version_id", "");
        break :blk loadVersionParams(database, version_id) catch |err| switch (err) {
            error.NotFound => return errBody(out, .not_found, "not_found", "version_id"),
            else => |e| return e,
        };
    };
    const verdict = dynamic.validateAbsolute(candidate);
    if (verdict.reason != .ok) return errBody(out, .bad_request, verdict.reason.text(), verdict.field);

    const active = (try store.loadActive(database)) orelse return errBody(out, .not_found, "no_active_params", "");
    var series = if (candles) |c|
        history.fromCsv(heap, c, decisions.?) catch return errBody(out, .bad_request, "bad_csv", "")
    else
        try history.fromDb(heap, database);
    defer series.deinit(heap);

    var slot = Slot{
        .bars = series.bars.items,
        .decisions = series.decisions.items,
        .baseline = active.params,
        .candidate = candidate,
        .baseline_version_id = active.version_id,
        .min_notional = min_notional,
        .now_ms = now_ms,
        .meta = meta,
        .out = out,
    };
    if (std.Thread.spawn(.{}, replayWorker, .{&slot})) |thread| {
        thread.join();
    } else |_| {
        replayWorker(&slot);
    }
    if (slot.failed) return errBody(out, .failed, "replay_failed", "");
    try storeReport(database, now_ms, &slot.report);
    return .{ .status = .ok, .body = slot.report.body };
}

pub fn get(database: *db.Db, id: []const u8, out: []u8) !ApiResult {
    if (!idOk(id)) return errBody(out, .bad_request, "bad_id", "");
    var stmt = try database.prepare("SELECT report_json FROM backtest_reports WHERE id = ?1");
    defer stmt.finalize();
    try stmt.bindText(1, id);
    if (!try stmt.step()) return errBody(out, .not_found, "not_found", "");
    const raw = stmt.columnText(0);
    if (raw.len > out.len) return error.ResponseTooSmall;
    @memcpy(out[0..raw.len], raw);
    return .{ .status = .ok, .body = out[0..raw.len] };
}

fn loadVersionParams(database: *db.Db, id: i64) !dynamic.Params {
    if (id <= 0) return error.NotFound;
    var stmt = try database.prepare("SELECT params_json FROM param_versions WHERE id = ?1");
    defer stmt.finalize();
    try stmt.bindInt(1, id);
    if (!try stmt.step()) return error.NotFound;
    const raw = stmt.columnText(0);
    var buf: [2048]u8 = undefined;
    if (raw.len > buf.len) return error.NotFound;
    @memcpy(buf[0..raw.len], raw);
    return dynamic.parseJson(heap, buf[0..raw.len]) catch return error.NotFound;
}

fn storeReport(database: *db.Db, now_ms: i64, report: *const gate.Report) !void {
    var ts_buf: [40]u8 = undefined;
    const ts = clock.formatRfc3339Ms(now_ms, &ts_buf) catch return error.Clock;
    var stmt = try database.prepare(
        \\INSERT INTO backtest_reports (
        \\  id, created_ts, as_of_ms, passed, params_json, baseline_json,
        \\  baseline_version_id, range_hash, digest, report_json
        \\) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
        \\ON CONFLICT(id) DO NOTHING
    );
    defer stmt.finalize();
    try stmt.bindText(1, report.idText());
    try stmt.bindText(2, ts);
    try stmt.bindInt(3, report.as_of_ms);
    try stmt.bindInt(4, if (report.passed) 1 else 0);
    try stmt.bindText(5, report.paramsText());
    try stmt.bindText(6, report.baselineText());
    try stmt.bindInt(7, report.baseline_version_id);
    try stmt.bindText(8, report.rangeHashText());
    try stmt.bindText(9, report.digestText());
    try stmt.bindText(10, report.body);
    _ = try stmt.stepCritical();
}

fn parseMeta(obj: std.json.ObjectMap) ?gate.Meta {
    const source = jsonString(obj, "source") orelse return null;
    if (!std.mem.eql(u8, source, "manual") and !std.mem.eql(u8, source, "mcp") and !std.mem.eql(u8, source, "review")) return null;
    const operator = jsonString(obj, "operator") orelse return null;
    if (!printable(operator, 64)) return null;
    const reason = jsonString(obj, "reason") orelse return null;
    if (!printable(reason, 400)) return null;
    return .{ .source = source, .operator = operator, .reason = reason };
}

fn printable(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    for (s) |c| if (c < 0x20) return false;
    return true;
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn idOk(id: []const u8) bool {
    if (id.len < 4 or id.len > 80) return false;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn errBody(out: []u8, status: ApiStatus, code: []const u8, field: []const u8) !ApiResult {
    var w: std.Io.Writer = .fixed(out);
    w.print("{{\"ok\":false,\"error\":\"{s}\",\"field\":\"{s}\"}}", .{ code, field }) catch return error.ResponseTooSmall;
    return .{ .status = status, .body = w.buffered() };
}

const testing = std.testing;
const config = @import("../config.zig");

test "run_backtest stores a report off the caller and get_backtest reads it" {
    var database = try db.Db.open(":memory:");
    defer database.close();
    var cfg = try config.parse(testing.allocator, "");
    defer cfg.deinit();
    _ = try store.ensureActive(&database, &cfg, 1_700_000_000_000);

    var params_buf: [1024]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&params_buf);
    try (dynamic.Params{}).writeJson(&pw);
    var body_buf: [4096]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf, "{{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"gate\",\"params\":{s},\"candles\":\"ts_ms,close\\n0,100\\n900000,100\\n\",\"decisions\":\"ts_ms,target_weight\\n0,0.4\\n\"}}", .{pw.buffered()});
    var out: [16384]u8 = undefined;
    const ran = try run(&database, Decimal.zero, 1_700_000_000_000, body, &out);
    try testing.expectEqual(ApiStatus.ok, ran.status);
    try testing.expect(std.mem.indexOf(u8, ran.body, "\"passed\":false") != null);
    try testing.expect(std.mem.indexOf(u8, ran.body, "insufficient_bars") != null);
    try testing.expect(std.mem.indexOf(u8, ran.body, "bt_") != null);
    try testing.expectEqual(@as(i64, 0), try database.queryInt("SELECT COUNT(*) FROM orders"));
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM backtest_reports"));

    const key = "\"id\":\"";
    const at = std.mem.indexOf(u8, ran.body, key) orelse return error.TestUnexpectedResult;
    const rest = ran.body[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;
    const id = rest[0..end];
    var got_buf: [16384]u8 = undefined;
    const got = try get(&database, id, &got_buf);
    try testing.expectEqual(ApiStatus.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, id) != null);
    const missing = try get(&database, "bt_missing", &got_buf);
    try testing.expectEqual(ApiStatus.not_found, missing.status);

    const locked = try run(&database, Decimal.zero, 1_700_000_000_000, "{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"no\",\"params\":{\"max_drawdown\":\"0.2\"}}", &out);
    try testing.expectEqual(ApiStatus.unprocessable, locked.status);
    try testing.expectEqual(@as(i64, 0), try database.queryInt("SELECT COUNT(*) FROM orders"));
}
