//! Filter-parameter writes (phase 2).
//!
//! propose stores a pending version after `validate`, or a rejected version
//! when the hard gates fail. apply activates one pending version if
//! `expected_active_version` still matches, the gates still pass, and a
//! passing backtest reference is attached (unless the config switch allows
//! an unbacked manual apply). rollback copies a historical version forward.
//! It skips the 20% step and the 24h gate, and still rejects values outside
//! the absolute bounds.
//!
//! Every successful or rejected write appends `param_audit`. Nothing in this
//! file inserts an order.

const std = @import("std");
const db = @import("../storage/db.zig");
const clock = @import("../core/clock.zig");
const dynamic = @import("dynamic.zig");
const store = @import("store.zig");
const gate = @import("gate.zig");

pub const WriteError = store.StoreError || error{ResponseTooSmall};

pub const Action = enum { propose, apply, rollback };

pub const OpStatus = enum {
    ok,
    unchanged,
    rejected,
    conflict,
    not_found,
    bad_version,
    backtest_required,
    backtest_rejected,
    bad_request,

    pub fn text(self: OpStatus) []const u8 {
        return @tagName(self);
    }

    pub fn httpOk(self: OpStatus) bool {
        return self == .ok or self == .unchanged;
    }
};

pub const OpResult = struct {
    status: OpStatus,
    body: []const u8,
};

const Meta = struct {
    source: []const u8,
    operator: []const u8,
    reason: []const u8,
};

const Loaded = struct {
    id: i64,
    parent_id: i64 = 0,
    has_parent: bool = false,
    status: []const u8,
    params: dynamic.Params,
    json: []const u8,
};

const Tx = struct {
    database: *db.Db,
    open: bool = false,

    fn begin(self: *Tx) db.DbError!void {
        try self.database.execAll("BEGIN IMMEDIATE");
        self.open = true;
    }

    fn commit(self: *Tx) db.DbError!void {
        try self.database.execAll("COMMIT");
        self.open = false;
    }

    fn end(self: *Tx) void {
        if (!self.open) return;
        self.database.execAll("ROLLBACK") catch {};
        self.open = false;
    }
};

pub fn writeApi(
    database: *db.Db,
    allow_unbacked_apply: bool,
    now_ms: i64,
    action: Action,
    request_json: []const u8,
    out: []u8,
) WriteError!OpResult {
    if (dynamic.rawLocksDrawdown(request_json)) {
        return rejectLocked(database, now_ms, action, request_json, out);
    }
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{}) catch {
        return respond(out, .bad_request, action, 0, 0, .{ .field = "json" }, "[]");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return respond(out, .bad_request, action, 0, 0, .{ .field = "json" }, "[]");
    const obj = parsed.value.object;
    const meta = parseMeta(obj) orelse return respond(out, .bad_request, action, 0, 0, .{ .field = "meta" }, "[]");
    return switch (action) {
        .propose => propose(database, now_ms, meta, obj, out),
        .apply => apply(database, allow_unbacked_apply, now_ms, meta, obj, out),
        .rollback => rollback(database, now_ms, meta, obj, out),
    };
}

fn rejectLocked(
    database: *db.Db,
    now_ms: i64,
    action: Action,
    request_json: []const u8,
    out: []u8,
) WriteError!OpResult {
    var tx = Tx{ .database = database };
    try tx.begin();
    defer tx.end();
    const active = (try store.loadActive(database)) orelse {
        return respond(out, .rejected, action, 0, 0, .{ .reason = .locked, .field = "max_drawdown" }, "[]");
    };
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{}) catch null;
    defer if (parsed) |*p| p.deinit();
    const meta: Meta = if (parsed) |p| blk: {
        if (p.value == .object) {
            if (parseMeta(p.value.object)) |m| break :blk m;
        }
        break :blk .{ .source = "manual", .operator = "-", .reason = "locked_field" };
    } else .{ .source = "manual", .operator = "-", .reason = "locked_field" };
    var ts_buf: [40]u8 = undefined;
    const ts = try stamp(now_ms, &ts_buf);
    var before_buf: [2048]u8 = undefined;
    const before = try paramsJson(&before_buf, active.params);
    var detail_buf: [4096]u8 = undefined;
    const detail = try writeDetail(&detail_buf, meta, "rejected", active.version_id, 0, .{ .reason = .locked, .field = "max_drawdown" }, before, null, null);
    try insertAudit(database, ts, active.version_id, @tagName(action), meta.source, detail);
    try tx.commit();
    return respond(out, .rejected, action, 0, active.version_id, .{ .reason = .locked, .field = "max_drawdown" }, "[]");
}

fn propose(
    database: *db.Db,
    now_ms: i64,
    meta: Meta,
    obj: std.json.ObjectMap,
    out: []u8,
) WriteError!OpResult {
    const params_v = obj.get("params") orelse return respond(out, .bad_request, .propose, 0, 0, .{ .field = "params" }, "[]");
    const proposed = dynamic.parseValue(params_v) catch return respond(out, .bad_request, .propose, 0, 0, .{ .field = "params" }, "[]");
    var tx = Tx{ .database = database };
    try tx.begin();
    defer tx.end();
    const active = (try store.loadActive(database)) orelse return respond(out, .not_found, .propose, 0, 0, .{}, "[]");
    const last = try lastApplyMs(database);
    const verdict = dynamic.validate(active.params, proposed, now_ms, last);
    var diff_buf: [2048]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&diff_buf);
    dynamic.writeDiff(&dw, active.params, proposed) catch return error.ResponseTooSmall;
    const diff = dw.buffered();
    var ts_buf: [40]u8 = undefined;
    const ts = try stamp(now_ms, &ts_buf);
    var before_buf: [2048]u8 = undefined;
    const before = try paramsJson(&before_buf, active.params);
    var after_buf: [2048]u8 = undefined;
    const after = try paramsJson(&after_buf, proposed);
    if (verdict.reason == .unchanged) {
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "unchanged", active.version_id, active.version_id, verdict, before, after, null);
        try insertAudit(database, ts, active.version_id, "propose", meta.source, detail);
        try tx.commit();
        return respond(out, .unchanged, .propose, active.version_id, active.version_id, verdict, diff);
    }
    const row_status: []const u8 = if (verdict.reason == .ok) "pending" else "rejected";
    const id = try insertVersion(database, after, meta.source, active.version_id, ts, row_status);
    var detail_buf: [8192]u8 = undefined;
    const code: []const u8 = if (verdict.reason == .ok) "ok" else "rejected";
    const detail = try writeDetail(&detail_buf, meta, code, active.version_id, id, verdict, before, after, null);
    try insertAudit(database, ts, id, "propose", meta.source, detail);
    try tx.commit();
    const status: OpStatus = if (verdict.reason == .ok) .ok else .rejected;
    return respond(out, status, .propose, id, active.version_id, verdict, diff);
}

fn apply(
    database: *db.Db,
    allow_unbacked_apply: bool,
    now_ms: i64,
    meta: Meta,
    obj: std.json.ObjectMap,
    out: []u8,
) WriteError!OpResult {
    const version_id = jsonInt(obj, "version_id") orelse return respond(out, .bad_request, .apply, 0, 0, .{ .field = "version_id" }, "[]");
    const expected = jsonInt(obj, "expected_active_version") orelse return respond(out, .bad_request, .apply, 0, 0, .{ .field = "expected_active_version" }, "[]");
    const backtest = jsonString(obj, "backtest_summary") orelse "";
    var tx = Tx{ .database = database };
    try tx.begin();
    defer tx.end();
    const active = (try store.loadActive(database)) orelse return respond(out, .not_found, .apply, version_id, 0, .{}, "[]");
    var ts_buf: [40]u8 = undefined;
    const ts = try stamp(now_ms, &ts_buf);
    var before_buf: [2048]u8 = undefined;
    const before = try paramsJson(&before_buf, active.params);
    if (active.version_id != expected) {
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "conflict", active.version_id, version_id, .{ .field = "expected_active_version" }, before, null, null);
        try insertAudit(database, ts, active.version_id, "apply", meta.source, detail);
        try tx.commit();
        return respond(out, .conflict, .apply, version_id, active.version_id, .{ .field = "expected_active_version" }, "[]");
    }
    var status_buf: [16]u8 = undefined;
    var json_buf: [2048]u8 = undefined;
    const row = (try loadVersion(database, version_id, &status_buf, &json_buf)) orelse {
        return respond(out, .not_found, .apply, version_id, active.version_id, .{}, "[]");
    };
    if (!std.mem.eql(u8, row.status, "pending")) {
        return respond(out, .bad_version, .apply, version_id, active.version_id, .{ .field = "status" }, "[]");
    }
    if (backtest.len == 0) {
        if (!allow_unbacked_apply) {
            var detail_buf: [8192]u8 = undefined;
            const detail = try writeDetail(&detail_buf, meta, "backtest_required", active.version_id, version_id, .{ .field = "backtest_summary" }, before, row.json, null);
            try insertAudit(database, ts, version_id, "apply", meta.source, detail);
            try tx.commit();
            return respond(out, .backtest_required, .apply, version_id, active.version_id, .{ .field = "backtest_summary" }, "[]");
        }
    } else {
        gate.validateStoredRef(database, backtest, row.json, active.version_id, now_ms) catch |err| {
            switch (err) {
                error.PrepareFailed => return error.PrepareFailed,
                error.BindFailed => return error.BindFailed,
                error.StepFailed => return error.StepFailed,
                error.Busy => return error.Busy,
                error.OpenFailed => return error.OpenFailed,
                error.ExecFailed => return error.ExecFailed,
                error.NotFound => return error.NotFound,
                else => {},
            }
            var detail_buf: [8192]u8 = undefined;
            const detail = try writeDetail(&detail_buf, meta, "backtest_rejected", active.version_id, version_id, .{ .field = gate.refField(err) }, before, row.json, null);
            try insertAudit(database, ts, version_id, "apply", meta.source, detail);
            try tx.commit();
            return respond(out, .backtest_rejected, .apply, version_id, active.version_id, .{ .field = gate.refField(err) }, "[]");
        };
    }
    const last = try lastApplyMs(database);
    const verdict = dynamic.validate(active.params, row.params, now_ms, last);
    var diff_buf: [2048]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&diff_buf);
    dynamic.writeDiff(&dw, active.params, row.params) catch return error.ResponseTooSmall;
    const diff = dw.buffered();
    if (verdict.reason == .unchanged) {
        if (try setStatusWhere(database, version_id, "rejected", "pending") != 1) return error.StepFailed;
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "unchanged", active.version_id, version_id, verdict, before, row.json, null);
        try insertAudit(database, ts, version_id, "apply", meta.source, detail);
        try tx.commit();
        return respond(out, .unchanged, .apply, version_id, active.version_id, verdict, diff);
    }
    if (verdict.reason != .ok) {
        if (verdict.reason != .too_soon) {
            if (try setStatusWhere(database, version_id, "rejected", "pending") != 1) return error.StepFailed;
        }
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "rejected", active.version_id, version_id, verdict, before, row.json, null);
        try insertAudit(database, ts, version_id, "apply", meta.source, detail);
        try tx.commit();
        return respond(out, .rejected, .apply, version_id, active.version_id, verdict, diff);
    }
    if (try setStatusWhere(database, active.version_id, "superseded", "active") != 1) return error.StepFailed;
    if (try activate(database, version_id, backtest) != 1) return error.StepFailed;
    var detail_buf: [8192]u8 = undefined;
    const detail = try writeDetail(&detail_buf, meta, "ok", active.version_id, version_id, verdict, before, row.json, null);
    try insertAudit(database, ts, version_id, "apply", meta.source, detail);
    try tx.commit();
    return respond(out, .ok, .apply, version_id, version_id, verdict, diff);
}

fn rollback(
    database: *db.Db,
    now_ms: i64,
    meta: Meta,
    obj: std.json.ObjectMap,
    out: []u8,
) WriteError!OpResult {
    const version_id = jsonInt(obj, "version_id") orelse return respond(out, .bad_request, .rollback, 0, 0, .{ .field = "version_id" }, "[]");
    const expected = jsonInt(obj, "expected_active_version") orelse return respond(out, .bad_request, .rollback, 0, 0, .{ .field = "expected_active_version" }, "[]");
    var tx = Tx{ .database = database };
    try tx.begin();
    defer tx.end();
    const active = (try store.loadActive(database)) orelse return respond(out, .not_found, .rollback, version_id, 0, .{}, "[]");
    var ts_buf: [40]u8 = undefined;
    const ts = try stamp(now_ms, &ts_buf);
    var before_buf: [2048]u8 = undefined;
    const before = try paramsJson(&before_buf, active.params);
    if (active.version_id != expected) {
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "conflict", active.version_id, version_id, .{ .field = "expected_active_version" }, before, null, version_id);
        try insertAudit(database, ts, active.version_id, "rollback", meta.source, detail);
        try tx.commit();
        return respond(out, .conflict, .rollback, version_id, active.version_id, .{ .field = "expected_active_version" }, "[]");
    }
    if (version_id == active.version_id) {
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "unchanged", active.version_id, active.version_id, .{ .reason = .unchanged }, before, before, version_id);
        try insertAudit(database, ts, active.version_id, "rollback", meta.source, detail);
        try tx.commit();
        return respond(out, .unchanged, .rollback, active.version_id, active.version_id, .{ .reason = .unchanged }, "[]");
    }
    var status_buf: [16]u8 = undefined;
    var json_buf: [2048]u8 = undefined;
    const row = (try loadVersion(database, version_id, &status_buf, &json_buf)) orelse {
        return respond(out, .not_found, .rollback, version_id, active.version_id, .{}, "[]");
    };
    const historical = std.mem.eql(u8, row.status, "superseded") or std.mem.eql(u8, row.status, "rolled_back");
    if (!historical) {
        return respond(out, .bad_version, .rollback, version_id, active.version_id, .{ .field = "status" }, "[]");
    }
    const verdict = dynamic.validateAbsolute(row.params);
    var diff_buf: [2048]u8 = undefined;
    var dw: std.Io.Writer = .fixed(&diff_buf);
    dynamic.writeDiff(&dw, active.params, row.params) catch return error.ResponseTooSmall;
    const diff = dw.buffered();
    if (verdict.reason != .ok) {
        var detail_buf: [8192]u8 = undefined;
        const detail = try writeDetail(&detail_buf, meta, "rejected", active.version_id, version_id, verdict, before, row.json, version_id);
        try insertAudit(database, ts, active.version_id, "rollback", meta.source, detail);
        try tx.commit();
        return respond(out, .rejected, .rollback, version_id, active.version_id, verdict, diff);
    }
    if (try setStatusWhere(database, active.version_id, "rolled_back", "active") != 1) return error.StepFailed;
    const id = try insertVersion(database, row.json, meta.source, active.version_id, ts, "active");
    var detail_buf: [8192]u8 = undefined;
    const detail = try writeDetail(&detail_buf, meta, "ok", active.version_id, id, .{ .reason = .ok }, before, row.json, version_id);
    try insertAudit(database, ts, id, "rollback", meta.source, detail);
    try tx.commit();
    return respond(out, .ok, .rollback, id, id, .{ .reason = .ok }, diff);
}

fn respond(
    out: []u8,
    status: OpStatus,
    action: Action,
    version_id: i64,
    active_id: i64,
    verdict: dynamic.Verdict,
    diff: []const u8,
) WriteError!OpResult {
    var w: std.Io.Writer = .fixed(out);
    w.print(
        "{{\"ok\":{},\"action\":\"{s}\",\"code\":\"{s}\",\"version_id\":{d},\"active_version_id\":{d},\"verdict\":\"{s}\",\"field\":\"{s}\",\"diff\":{s}}}",
        .{
            status.httpOk(),
            @tagName(action),
            status.text(),
            version_id,
            active_id,
            verdict.reason.text(),
            verdict.field,
            if (diff.len == 0) "[]" else diff,
        },
    ) catch return error.ResponseTooSmall;
    return .{ .status = status, .body = w.buffered() };
}

fn parseMeta(obj: std.json.ObjectMap) ?Meta {
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

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer or v.integer <= 0) return null;
    return v.integer;
}

fn stamp(now_ms: i64, buf: []u8) WriteError![]const u8 {
    return clock.formatRfc3339Ms(now_ms, buf) catch error.Clock;
}

fn paramsJson(buf: []u8, params: dynamic.Params) WriteError![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    params.writeJson(&w) catch return error.ResponseTooSmall;
    return w.buffered();
}

fn loadVersion(database: *db.Db, id: i64, status_buf: []u8, json_buf: []u8) WriteError!?Loaded {
    var stmt = try database.prepare(
        \\SELECT id, parent_id, status, params_json FROM param_versions WHERE id = ?1
    );
    defer stmt.finalize();
    try stmt.bindInt(1, id);
    if (!try stmt.step()) return null;
    const st = stmt.columnText(2);
    if (st.len > status_buf.len or st.len == 0) return error.Clock;
    @memcpy(status_buf[0..st.len], st);
    const raw = stmt.columnText(3);
    if (raw.len > json_buf.len) return error.Clock;
    @memcpy(json_buf[0..raw.len], raw);
    const params = dynamic.parseJson(std.heap.page_allocator, json_buf[0..raw.len]) catch return error.Clock;
    return .{
        .id = stmt.columnInt(0),
        .parent_id = if (stmt.columnIsNull(1)) 0 else stmt.columnInt(1),
        .has_parent = !stmt.columnIsNull(1),
        .status = status_buf[0..st.len],
        .params = params,
        .json = json_buf[0..raw.len],
    };
}

fn lastApplyMs(database: *db.Db) WriteError!i64 {
    // Only a successful apply consumes the 24h slot. A rejected, conflicted,
    // or unchanged attempt stays in the audit and must not move the clock.
    // Rollback and bootstrap are different actions and are ignored here.
    var stmt = try database.prepare(
        \\SELECT ts FROM param_audit
        \\WHERE action = 'apply' AND instr(detail_json, '"code":"ok"') > 0
        \\ORDER BY id DESC LIMIT 1
    );
    defer stmt.finalize();
    if (!try stmt.step()) return 0;
    return clock.parseRfc3339Ms(stmt.columnText(0)) catch error.Clock;
}

fn insertVersion(
    database: *db.Db,
    params_json: []const u8,
    source: []const u8,
    parent_id: i64,
    ts: []const u8,
    status: []const u8,
) db.DbError!i64 {
    var stmt = try database.prepare(
        \\INSERT INTO param_versions (params_json, source, parent_id, created_ts, status, backtest_summary)
        \\VALUES (?1, ?2, ?3, ?4, ?5, '')
    );
    defer stmt.finalize();
    try stmt.bindText(1, params_json);
    try stmt.bindText(2, source);
    try stmt.bindInt(3, parent_id);
    try stmt.bindText(4, ts);
    try stmt.bindText(5, status);
    _ = try stmt.stepCritical();
    return database.lastInsertRowid();
}

fn setStatusWhere(database: *db.Db, id: i64, new_status: [:0]const u8, old_status: [:0]const u8) db.DbError!i64 {
    var stmt = try database.prepare(
        \\UPDATE param_versions SET status = ?1 WHERE id = ?2 AND status = ?3
    );
    defer stmt.finalize();
    try stmt.bindText(1, new_status);
    try stmt.bindInt(2, id);
    try stmt.bindText(3, old_status);
    _ = try stmt.stepCritical();
    return database.changes();
}

fn activate(database: *db.Db, id: i64, backtest: []const u8) db.DbError!i64 {
    var stmt = try database.prepare(
        \\UPDATE param_versions SET status = 'active', backtest_summary = ?1
        \\WHERE id = ?2 AND status = 'pending'
    );
    defer stmt.finalize();
    try stmt.bindText(1, backtest);
    try stmt.bindInt(2, id);
    _ = try stmt.stepCritical();
    return database.changes();
}

fn insertAudit(
    database: *db.Db,
    ts: []const u8,
    version_id: i64,
    action: []const u8,
    source: []const u8,
    detail: []const u8,
) db.DbError!void {
    var stmt = try database.prepare(
        \\INSERT INTO param_audit (ts, version_id, action, source, detail_json)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
    );
    defer stmt.finalize();
    try stmt.bindText(1, ts);
    try stmt.bindInt(2, version_id);
    try stmt.bindText(3, action);
    try stmt.bindText(4, source);
    try stmt.bindText(5, detail);
    _ = try stmt.stepCritical();
}

fn writeDetail(
    buf: []u8,
    meta: Meta,
    code: []const u8,
    before_id: i64,
    after_id: i64,
    verdict: dynamic.Verdict,
    before_json: ?[]const u8,
    after_json: ?[]const u8,
    target_id: ?i64,
) WriteError![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("{\"operator\":\"") catch return error.ResponseTooSmall;
    writeEscaped(&w, meta.operator) catch return error.ResponseTooSmall;
    w.writeAll("\",\"reason\":\"") catch return error.ResponseTooSmall;
    writeEscaped(&w, meta.reason) catch return error.ResponseTooSmall;
    w.print(
        "\",\"code\":\"{s}\",\"before_version_id\":{d},\"after_version_id\":{d},\"verdict\":\"{s}\",\"field\":\"{s}\",\"before\":",
        .{ code, before_id, after_id, verdict.reason.text(), verdict.field },
    ) catch return error.ResponseTooSmall;
    w.writeAll(before_json orelse "null") catch return error.ResponseTooSmall;
    w.writeAll(",\"after\":") catch return error.ResponseTooSmall;
    w.writeAll(after_json orelse "null") catch return error.ResponseTooSmall;
    if (target_id) |id| {
        w.print(",\"target_version_id\":{d}", .{id}) catch return error.ResponseTooSmall;
    }
    w.writeByte('}') catch return error.ResponseTooSmall;
    return w.buffered();
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
const config = @import("../config.zig");

const t0: i64 = 1_700_000_000_000;
const day_ms = dynamic.day_ms;
const backtest_ok = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true}";

fn seedReport(database: *db.Db, params_json: []const u8, as_of_ms: i64, baseline_version: i64) !void {
    var stmt = try database.prepare(
        \\INSERT INTO backtest_reports (
        \\  id, created_ts, as_of_ms, passed, params_json, baseline_json,
        \\  baseline_version_id, range_hash, digest, report_json
        \\) VALUES ('bt_ok', '2023-11-14T22:13:20.000Z', ?1, 1, ?2, '{}', ?3, 'abc', 'abc', '{}')
    );
    defer stmt.finalize();
    try stmt.bindInt(1, as_of_ms);
    try stmt.bindText(2, params_json);
    try stmt.bindInt(3, baseline_version);
    _ = try stmt.stepCritical();
}

fn bootDb() !struct { db: db.Db, cfg: config.Config } {
    var database = try db.Db.open(":memory:");
    errdefer database.close();
    var cfg = try config.parse(testing.allocator, "");
    errdefer cfg.deinit();
    _ = try store.ensureActive(&database, &cfg, t0);
    return .{ .db = database, .cfg = cfg };
}

fn paramsOf(p: dynamic.Params, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try p.writeJson(&w);
    return w.buffered();
}

fn proposeBody(buf: []u8, params_json: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"tighten filter\",\"params\":{s}}}", .{params_json});
}

fn applyBody(buf: []u8, version_id: i64, expected: i64, summary: ?[]const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("{{\"source\":\"mcp\",\"operator\":\"ops\",\"reason\":\"apply pending\",\"version_id\":{d},\"expected_active_version\":{d}", .{ version_id, expected });
    if (summary) |s| {
        try w.writeAll(",\"backtest_summary\":\"");
        try writeEscaped(&w, s);
        try w.writeByte('"');
    }
    try w.writeByte('}');
    return w.buffered();
}

fn rollbackBody(buf: []u8, version_id: i64, expected: i64) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"source\":\"review\",\"operator\":\"ops\",\"reason\":\"restore prior\",\"version_id\":{d},\"expected_active_version\":{d}}}", .{ version_id, expected });
}

fn call(database: *db.Db, allow: bool, now_ms: i64, action: Action, body: []const u8, out: []u8) !OpResult {
    return writeApi(database, allow, now_ms, action, body, out);
}

test "propose rejects bounds, step, direction, 24h and a locked drawdown field" {
    var env = try bootDb();
    defer env.db.close();
    defer env.cfg.deinit();

    var pbuf: [1024]u8 = undefined;
    var body: [2048]u8 = undefined;
    var out: [4096]u8 = undefined;

    var big = dynamic.Params{};
    big.daily_trade_cap = 8;
    const big_json = try paramsOf(big, &pbuf);
    const big_body = try proposeBody(&body, big_json);
    const stepped = try call(&env.db, false, t0 + day_ms, .propose, big_body, &out);
    try testing.expectEqual(OpStatus.rejected, stepped.status);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"verdict\":\"step_too_large\"") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"field\":\"daily_trade_cap\"") != null);
    try testing.expectEqual(@as(i64, 1), try env.db.queryInt("SELECT COUNT(*) FROM param_versions WHERE status = 'active'"));
    try testing.expectEqual(@as(i64, 1), try env.db.queryInt("SELECT COUNT(*) FROM param_versions WHERE status = 'rejected'"));

    var loose = dynamic.Params{};
    loose.price_shock = d("0.04");
    const loose_json = try paramsOf(loose, &pbuf);
    const loose_body = try proposeBody(&body, loose_json);
    const bounded = try call(&env.db, false, t0 + day_ms, .propose, loose_body, &out);
    try testing.expectEqual(OpStatus.rejected, bounded.status);
    try testing.expect(std.mem.indexOf(u8, bounded.body, "\"out_of_bounds\"") != null);

    var raised = dynamic.Params{};
    raised.position_cap = d("0.8");
    const down_json = try paramsOf(raised, &pbuf);
    const down_body = try proposeBody(&body, down_json);
    const pending = try call(&env.db, false, t0 + day_ms, .propose, down_body, &out);
    try testing.expectEqual(OpStatus.ok, pending.status);
    try testing.expect(std.mem.indexOf(u8, pending.body, "\"position_cap\"") != null);
    const pending_id = try env.db.queryInt("SELECT id FROM param_versions WHERE status = 'pending'");
    var up = raised;
    up.position_cap = d("0.9");
    // Apply the lower cap first so a later raise is a real loosening.
    try seedReport(&env.db, down_json, t0 + day_ms, 1);
    var abuf: [1024]u8 = undefined;
    const apply_down = try applyBody(&abuf, pending_id, 1, backtest_ok);
    const applied = try call(&env.db, false, t0 + day_ms, .apply, apply_down, &out);
    try testing.expectEqual(OpStatus.ok, applied.status);

    const up_json = try paramsOf(up, &pbuf);
    const up_body = try proposeBody(&body, up_json);
    const direction = try call(&env.db, false, t0 + day_ms * 2, .propose, up_body, &out);
    try testing.expectEqual(OpStatus.rejected, direction.status);
    try testing.expect(std.mem.indexOf(u8, direction.body, "\"not_tighter\"") != null);

    const locked_body = "{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"no\",\"params\":{\"max_drawdown\":\"0.20\"}}";
    const locked = try call(&env.db, false, t0 + day_ms * 2, .propose, locked_body, &out);
    try testing.expectEqual(OpStatus.rejected, locked.status);
    try testing.expect(std.mem.indexOf(u8, locked.body, "\"verdict\":\"locked\"") != null);
    try testing.expect(std.mem.indexOf(u8, locked.body, "\"field\":\"max_drawdown\"") != null);
    try testing.expectEqual(@as(i64, 0), try env.db.queryInt("SELECT COUNT(*) FROM param_versions WHERE params_json LIKE '%max_drawdown%'"));
}

test "apply enforces optimistic concurrency, 24h, backtest ref and audit" {
    var env = try bootDb();
    defer env.db.close();
    defer env.cfg.deinit();
    var pbuf: [1024]u8 = undefined;
    var body: [2048]u8 = undefined;
    var abuf: [1024]u8 = undefined;
    var out: [4096]u8 = undefined;

    var cap = dynamic.Params{};
    cap.daily_trade_cap = 7;
    const cap_json = try paramsOf(cap, &pbuf);
    const cap_body = try proposeBody(&body, cap_json);
    const proposed = try call(&env.db, false, t0 + day_ms, .propose, cap_body, &out);
    try testing.expectEqual(OpStatus.ok, proposed.status);
    const id = try env.db.queryInt("SELECT MIN(id) FROM param_versions WHERE status = 'pending'");

    var cool = cap;
    cool.reverse_cooldown_ms = 17_280_000;
    const cool_json = try paramsOf(cool, &pbuf);
    const cool_body = try proposeBody(&body, cool_json);
    const second = try call(&env.db, false, t0 + day_ms, .propose, cool_body, &out);
    try testing.expectEqual(OpStatus.ok, second.status);
    const id2 = try env.db.queryInt("SELECT MAX(id) FROM param_versions WHERE status = 'pending'");

    var missing_buf: [1024]u8 = undefined;
    const missing = try applyBody(&missing_buf, id, 1, null);
    const need = try call(&env.db, false, t0 + day_ms, .apply, missing, &out);
    try testing.expectEqual(OpStatus.backtest_required, need.status);
    try testing.expectEqual(@as(i64, 1), try env.db.queryInt("SELECT id FROM param_versions WHERE status = 'active'"));

    const bad_ref = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_no\",\"passed\":false}";
    const bad_body = try applyBody(&abuf, id, 1, bad_ref);
    const bad = try call(&env.db, false, t0 + day_ms, .apply, bad_body, &out);
    try testing.expectEqual(OpStatus.backtest_rejected, bad.status);

    const unbacked = try call(&env.db, true, t0 + day_ms, .apply, missing, &out);
    try testing.expectEqual(OpStatus.ok, unbacked.status);
    try testing.expectEqual(id, try env.db.queryInt("SELECT id FROM param_versions WHERE status = 'active'"));

    const stale = try applyBody(&abuf, id2, 1, backtest_ok);
    const conflict = try call(&env.db, false, t0 + day_ms + 10, .apply, stale, &out);
    try testing.expectEqual(OpStatus.conflict, conflict.status);
    try testing.expect(std.mem.indexOf(u8, conflict.body, "\"code\":\"conflict\"") != null);

    const soon = try applyBody(&abuf, id2, id, backtest_ok);
    try seedReport(&env.db, cool_json, t0 + day_ms, id);
    const too_soon = try call(&env.db, false, t0 + day_ms + 10, .apply, soon, &out);
    try testing.expectEqual(OpStatus.rejected, too_soon.status);
    try testing.expect(std.mem.indexOf(u8, too_soon.body, "\"too_soon\"") != null);
    try testing.expectEqual(@as(i64, 1), try env.db.queryInt("SELECT COUNT(*) FROM param_versions WHERE status = 'pending'"));

    const later = try call(&env.db, false, t0 + day_ms * 2, .apply, soon, &out);
    try testing.expectEqual(OpStatus.ok, later.status);

    const audit = try env.db.queryInt("SELECT COUNT(*) FROM param_audit WHERE action = 'apply' AND source = 'mcp' AND detail_json LIKE '%\"operator\":\"ops\"%' AND detail_json LIKE '%\"reason\":\"apply pending\"%' AND detail_json LIKE '%\"before\":{%' AND detail_json LIKE '%\"after\":{%'");
    try testing.expect(audit >= 1);
    try testing.expectError(error.ExecFailed, env.db.execAll("UPDATE param_audit SET action = 'tamper'"));
    try testing.expectEqual(@as(i64, 0), try env.db.queryInt("SELECT COUNT(*) FROM orders"));
}

test "rollback ignores step and 24h, keeps absolute bounds, and the next decision sees it" {
    var env = try bootDb();
    defer env.db.close();
    defer env.cfg.deinit();
    var pbuf: [1024]u8 = undefined;
    var body: [2048]u8 = undefined;
    var abuf: [1024]u8 = undefined;
    var rbuf: [512]u8 = undefined;
    var out: [4096]u8 = undefined;

    const held = (try store.loadActive(&env.db)).?;
    var cap = dynamic.Params{};
    cap.daily_trade_cap = 7;
    cap.position_cap = d("0.8");
    cap.price_shock = d("0.06");
    const cap_json = try paramsOf(cap, &pbuf);
    const cap_body = try proposeBody(&body, cap_json);
    _ = try call(&env.db, false, t0 + day_ms, .propose, cap_body, &out);
    const pending_id = try env.db.queryInt("SELECT id FROM param_versions WHERE status = 'pending'");
    try seedReport(&env.db, cap_json, t0 + day_ms, held.version_id);
    const apply_body = try applyBody(&abuf, pending_id, held.version_id, backtest_ok);
    const applied = try call(&env.db, false, t0 + day_ms, .apply, apply_body, &out);
    try testing.expectEqual(OpStatus.ok, applied.status);

    // Still inside the 24h window, and the jump back exceeds 20% on the cap
    // direction. Rollback must still restore the bootstrap values.
    const back = try rollbackBody(&rbuf, held.version_id, pending_id);
    const restored = try call(&env.db, false, t0 + day_ms + 1_000, .rollback, back, &out);
    try testing.expectEqual(OpStatus.ok, restored.status);
    const now_active = (try store.loadActive(&env.db)).?;
    try testing.expect(now_active.params.eql(held.params));
    try testing.expect(now_active.version_id != held.version_id);
    try testing.expect(now_active.version_id != pending_id);
    // The snapshot a decision already loaded is unchanged.
    try testing.expectEqual(@as(u32, 6), held.params.daily_trade_cap);
    try testing.expect(held.params.position_cap.eql(dynamic.default_position_cap));

    var illegal = dynamic.Params{};
    illegal.exit_reserve = d("0.10");
    var ibuf: [1024]u8 = undefined;
    const illegal_json = try paramsOf(illegal, &ibuf);
    try env.db.execAll("BEGIN IMMEDIATE");
    var ins = try env.db.prepare(
        \\INSERT INTO param_versions (params_json, source, parent_id, created_ts, status, backtest_summary)
        \\VALUES (?1, 'manual', 1, '2023-11-14T22:13:20.000Z', 'superseded', '')
    );
    defer ins.finalize();
    try ins.bindText(1, illegal_json);
    _ = try ins.stepCritical();
    const bad_id = env.db.lastInsertRowid();
    try env.db.execAll("COMMIT");
    const bad_body = try rollbackBody(&rbuf, bad_id, now_active.version_id);
    const refused = try call(&env.db, false, t0 + day_ms + 2_000, .rollback, bad_body, &out);
    try testing.expectEqual(OpStatus.rejected, refused.status);
    try testing.expect(std.mem.indexOf(u8, refused.body, "\"out_of_bounds\"") != null);
    try testing.expect((try store.loadActive(&env.db)).?.version_id == now_active.version_id);

    const audit = try env.db.queryInt("SELECT COUNT(*) FROM param_audit WHERE action = 'rollback' AND source = 'review' AND detail_json LIKE '%\"operator\":\"ops\"%' AND detail_json LIKE '%\"target_version_id\":%' AND detail_json LIKE '%\"before\":{%' AND detail_json LIKE '%\"after\":{%'");
    try testing.expect(audit >= 1);
}

fn d(s: []const u8) @import("../core/decimal.zig").Decimal {
    return @import("../core/decimal.zig").Decimal.parse(s) catch unreachable;
}
