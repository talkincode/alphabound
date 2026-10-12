//! Persist the dynamic-parameter version chain.
//!
//! Bootstrap inserts v1 when no `active` row exists. Later writes (propose,
//! apply, rollback) live in `write.zig` and append to the same tables. The
//! audit table stays append-only. Nothing here places an order.

const std = @import("std");
const db = @import("../storage/db.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const dynamic = @import("dynamic.zig");

pub const StoreError = db.DbError || dynamic.ParseError || error{Clock};

pub const Snapshot = struct {
    version_id: i64,
    created_ms: i64,
    params: dynamic.Params,
};

pub fn ensureActive(database: *db.Db, cfg: *const config.Config, now_ms: i64) StoreError!Snapshot {
    if (try loadActive(database)) |snap| return snap;
    const params = dynamic.fromConfig(cfg);
    var json_buf: [2048]u8 = undefined;
    var jw: std.Io.Writer = .fixed(&json_buf);
    params.writeJson(&jw) catch return error.Clock;
    const params_json = jw.buffered();
    var ts_buf: [40]u8 = undefined;
    const ts = clock.formatRfc3339Ms(now_ms, &ts_buf) catch return error.Clock;

    database.execAll("BEGIN IMMEDIATE") catch return error.ExecFailed;
    errdefer database.execAll("ROLLBACK") catch {};

    var insert = try database.prepare(
        \\INSERT INTO param_versions (params_json, source, parent_id, created_ts, status, backtest_summary)
        \\VALUES (?1, 'bootstrap', NULL, ?2, 'active', '')
    );
    defer insert.finalize();
    try insert.bindText(1, params_json);
    try insert.bindText(2, ts);
    _ = try insert.stepCritical();
    const id = database.lastInsertRowid();

    var detail_buf: [64]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buf, "{{\"version_id\":{d},\"action\":\"bootstrap\"}}", .{id}) catch return error.Clock;
    var audit = try database.prepare(
        \\INSERT INTO param_audit (ts, version_id, action, source, detail_json)
        \\VALUES (?1, ?2, 'bootstrap', 'bootstrap', ?3)
    );
    defer audit.finalize();
    try audit.bindText(1, ts);
    try audit.bindInt(2, id);
    try audit.bindText(3, detail);
    _ = try audit.stepCritical();
    try database.execAll("COMMIT");

    return .{
        .version_id = id,
        .created_ms = now_ms,
        .params = params,
    };
}

pub fn loadActive(database: *db.Db) StoreError!?Snapshot {
    var stmt = try database.prepare(
        \\SELECT id, created_ts, params_json FROM param_versions WHERE status = 'active' LIMIT 1
    );
    defer stmt.finalize();
    if (!try stmt.step()) return null;
    const id = stmt.columnInt(0);
    const created = stmt.columnText(1);
    const raw = stmt.columnText(2);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const params = try dynamic.parseJson(arena.allocator(), raw);
    return .{
        .version_id = id,
        .created_ms = clock.parseRfc3339Ms(created) catch return error.Clock,
        .params = params,
    };
}

pub fn writeActiveJson(database: *db.Db, out: []u8) db.DbError![]const u8 {
    var stmt = try database.prepare(
        \\SELECT id, source, parent_id, created_ts, status, backtest_summary, params_json
        \\FROM param_versions WHERE status = 'active' LIMIT 1
    );
    defer stmt.finalize();
    if (!try stmt.step()) return error.NotFound;
    var w: std.Io.Writer = .fixed(out);
    writeVersionObject(&w, &stmt, true) catch return error.StepFailed;
    return w.buffered();
}

pub fn writeVersionsJson(database: *db.Db, out: []u8) db.DbError![]const u8 {
    var stmt = try database.prepare(
        \\SELECT id, source, parent_id, created_ts, status, backtest_summary, params_json
        \\FROM param_versions ORDER BY id DESC LIMIT 20
    );
    defer stmt.finalize();
    if (out.len < 2) return error.StepFailed;
    var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]);
    w.writeAll("[") catch return error.StepFailed;
    var i: usize = 0;
    while (try stmt.step()) : (i += 1) {
        const mark = w.end;
        const wrote = blk: {
            if (i > 0) w.writeAll(",") catch break :blk false;
            writeVersionObject(&w, &stmt, false) catch break :blk false;
            break :blk true;
        };
        if (!wrote) {
            w.end = mark;
            break;
        }
    }
    out[w.end] = ']';
    return out[0 .. w.end + 1];
}

fn writeVersionObject(w: *std.Io.Writer, stmt: *db.Stmt, with_locked: bool) std.Io.Writer.Error!void {
    try w.print("{{\"id\":{d},\"version_id\":{d},\"source\":\"{s}\",\"parent_id\":", .{
        stmt.columnInt(0),
        stmt.columnInt(0),
        stmt.columnText(1),
    });
    if (stmt.columnIsNull(2)) {
        try w.writeAll("null");
    } else {
        try w.print("{d}", .{stmt.columnInt(2)});
    }
    try w.print(",\"created_ts\":\"{s}\",\"status\":\"{s}\",\"backtest_summary\":\"", .{
        stmt.columnText(3),
        stmt.columnText(4),
    });
    try writeEscaped(w, stmt.columnText(5));
    try w.writeAll("\",\"params\":");
    try w.writeAll(stmt.columnText(6));
    if (with_locked) {
        try w.print(",\"max_drawdown_locked\":\"{f}\"", .{dynamic.max_drawdown_locked});
    }
    try w.writeByte('}');
}

fn writeEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n', '\r' => try w.writeByte(' '),
        else => if (c >= 0x20) try w.writeByte(c),
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "bootstrap writes v1 once and the decision snapshot matches config" {
    var database = try db.Db.open(":memory:");
    defer database.close();
    var cfg = try config.parse(testing.allocator,
        \\[risk]
        \\guard_daily_trade_cap = 5
        \\min_trade_notional = 10
    );
    defer cfg.deinit();
    const now: i64 = 1_700_000_000_000;
    const first = try ensureActive(&database, &cfg, now);
    try testing.expectEqual(@as(i64, 1), first.version_id);
    try testing.expectEqual(@as(u32, 5), first.params.daily_trade_cap);
    try testing.expect(first.params.eql(dynamic.fromConfig(&cfg)));
    try testing.expect(first.params.position_cap.eql(dynamic.default_position_cap));
    try testing.expect(!@hasField(dynamic.Params, "max_drawdown"));

    const second = try ensureActive(&database, &cfg, now + 10_000);
    try testing.expectEqual(first.version_id, second.version_id);
    try testing.expectEqual(@as(u32, 5), second.params.daily_trade_cap);
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM param_versions"));
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM param_audit"));

    var active_buf: [4096]u8 = undefined;
    const active = try writeActiveJson(&database, &active_buf);
    try testing.expect(std.mem.indexOf(u8, active, "\"version_id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"source\":\"bootstrap\"") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"parent_id\":null") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"status\":\"active\"") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"daily_trade_cap\":5") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"max_drawdown_locked\":\"0.1\"") != null);
    try testing.expect(std.mem.indexOf(u8, active, "\"max_drawdown\":") == null);

    var versions_buf: [8192]u8 = undefined;
    const versions = try writeVersionsJson(&database, &versions_buf);
    try testing.expect(std.mem.startsWith(u8, versions, "["));
    try testing.expect(std.mem.indexOf(u8, versions, "\"id\":1") != null);

    try testing.expectError(error.ExecFailed, database.execAll("UPDATE param_audit SET action = 'tamper'"));
    try testing.expectError(error.ExecFailed, database.execAll("DELETE FROM param_audit"));
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM param_audit"));
}

test "a corrupt active row is not replaced" {
    var database = try db.Db.open(":memory:");
    defer database.close();
    var cfg = try config.parse(testing.allocator, "");
    defer cfg.deinit();
    try database.execAll(
        \\INSERT INTO param_versions (params_json, source, parent_id, created_ts, status, backtest_summary)
        \\VALUES ('{"max_drawdown":"0.2"}', 'bootstrap', NULL, '2026-01-01T00:00:00.000Z', 'active', '')
    );
    try testing.expectError(error.UnknownField, ensureActive(&database, &cfg, 1_700_000_000_000));
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM param_versions"));
}
