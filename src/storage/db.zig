//! SQLite storage layer (§6): WAL journal, single writer, migrations,
//! and typed repositories. The journal writer is the only DB writer in the
//! process; everything else reads.

const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const DbError = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    NotFound,
    Busy,
};

const migration_0001: [:0]const u8 = @embedFile("migration_0001");
const migration_0002: [:0]const u8 = @embedFile("migration_0002");
const migration_0003: [:0]const u8 = @embedFile("migration_0003");
const migration_0004: [:0]const u8 = @embedFile("migration_0004");
const migration_0005: [:0]const u8 = @embedFile("migration_0005");

/// Ordered list of migrations; user_version tracks the applied count.
const migrations = [_][:0]const u8{
    migration_0001,
    migration_0002,
    migration_0003,
    migration_0004,
    migration_0005,
};

/// Expected user_version for a fully migrated database (restore drills).
pub const expected_user_version: i64 = migrations.len;

pub const Db = struct {
    handle: *c.sqlite3,

    /// Open (creating if needed) with the §6.1 pragmas and run migrations.
    pub fn open(path: [:0]const u8) DbError!Db {
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();

        try db.execAll(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA busy_timeout = 5000;
            \\PRAGMA foreign_keys = ON;
        );
        try db.migrate();
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Open an existing database strictly read-only (no migrations, no WAL
    /// conversion). For restore drills / backup verification (AC-OPS4).
    pub fn openReadOnly(path: [:0]const u8) DbError!Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return DbError.OpenFailed;
        }
        var db = Db{ .handle = handle.? };
        errdefer db.close();
        try db.execAll("PRAGMA busy_timeout = 5000;");
        return db;
    }

    /// Execute a multi-statement SQL string (no results expected).
    pub fn execAll(self: *Db, sql: [:0]const u8) DbError!void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg != null) c.sqlite3_free(errmsg);
            return DbError.ExecFailed;
        }
    }

    fn migrate(self: *Db) DbError!void {
        const current = try self.queryInt("PRAGMA user_version");
        var v: usize = @intCast(current);
        while (v < migrations.len) : (v += 1) {
            try self.execAll("BEGIN IMMEDIATE");
            errdefer self.execAll("ROLLBACK") catch {};
            try self.execAll(migrations[v]);
            var vbuf: [64:0]u8 = undefined;
            const stmt = std.fmt.bufPrintZ(&vbuf, "PRAGMA user_version = {d}", .{v + 1}) catch return DbError.ExecFailed;
            try self.execAll(stmt);
            try self.execAll("COMMIT");
        }
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) DbError!Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return DbError.PrepareFailed;
        }
        return Stmt{ .handle = stmt.? };
    }

    /// Run a query returning a single integer (first column of first row).
    pub fn queryInt(self: *Db, comptime sql: [:0]const u8) DbError!i64 {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step()) return stmt.columnInt(0);
        return DbError.NotFound;
    }

    pub fn lastInsertRowid(self: *Db) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// 1-based index. Uses SQLITE_STATIC (null destructor): the slice must
    /// stay valid until step() completes — all repos bind-then-step within
    /// one call, so this holds. (SQLITE_TRANSIENT's -1 sentinel doesn't
    /// survive translate-c alignment checks.)
    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) DbError!void {
        const rc = c.sqlite3_bind_text(self.handle, idx, text.ptr, @intCast(text.len), null);
        if (rc != c.SQLITE_OK) return DbError.BindFailed;
    }

    pub fn bindInt(self: *Stmt, idx: c_int, v: i64) DbError!void {
        if (c.sqlite3_bind_int64(self.handle, idx, v) != c.SQLITE_OK) return DbError.BindFailed;
    }

    pub fn bindFloat(self: *Stmt, idx: c_int, v: f64) DbError!void {
        if (c.sqlite3_bind_double(self.handle, idx, v) != c.SQLITE_OK) return DbError.BindFailed;
    }

    /// Returns true if a row is available, false when done.
    pub fn step(self: *Stmt) DbError!bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            c.SQLITE_BUSY => DbError.Busy,
            else => DbError.StepFailed,
        };
    }

    /// AC-FD6: retry on SQLITE_BUSY for critical writers (events/orders/fills).
    /// Does **not** reset bindings — only re-steps after busy_timeout already waited.
    pub fn stepCritical(self: *Stmt) DbError!bool {
        const policy = @import("policy.zig");
        const max_retries: u32 = 8;
        var attempt: u32 = 0;
        while (true) {
            const rc = c.sqlite3_step(self.handle);
            switch (rc) {
                c.SQLITE_ROW => return true,
                c.SQLITE_DONE => return false,
                c.SQLITE_BUSY, c.SQLITE_LOCKED => {
                    switch (policy.onBusy(attempt, max_retries)) {
                        .retry => {
                            attempt += 1;
                            continue;
                        },
                        .degrade_telemetry => return DbError.Busy,
                    }
                },
                else => return DbError.StepFailed,
            }
        }
    }

    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    pub fn columnFloat(self: *Stmt, idx: c_int) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    /// Valid only until the next step/reset/finalize.
    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, idx));
        return ptr[0..len];
    }
};

// ---------------------------------------------------------------------------
// Repositories

pub const EventRow = struct {
    event_id: []const u8,
    ts: []const u8,
    type: []const u8,
    source: []const u8,
    severity: []const u8,
    correlation_id: []const u8 = "",
    state_version: i64 = 0,
    software_version: []const u8 = "",
    config_hash: []const u8 = "",
    payload_json: []const u8 = "{}",
    content_hash: []const u8 = "",
};

pub const EventsRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!EventsRepo {
        return .{ .insert = try db.prepare(
            \\INSERT INTO events (event_id, ts, type, source, severity,
            \\  correlation_id, state_version, software_version, config_hash,
            \\  payload_json, content_hash)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
        ) };
    }

    pub fn deinit(self: *EventsRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *EventsRepo, row: EventRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.event_id);
        try self.insert.bindText(2, row.ts);
        try self.insert.bindText(3, row.type);
        try self.insert.bindText(4, row.source);
        try self.insert.bindText(5, row.severity);
        try self.insert.bindText(6, row.correlation_id);
        try self.insert.bindInt(7, row.state_version);
        try self.insert.bindText(8, row.software_version);
        try self.insert.bindText(9, row.config_hash);
        try self.insert.bindText(10, row.payload_json);
        try self.insert.bindText(11, row.content_hash);
        _ = try self.insert.stepCritical();
    }

    /// Newest events as a JSON array (newest first). payload_json must already be valid JSON object.
    pub fn listRecentJson(self: *EventsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT event_id, ts, type, source, severity, state_version, payload_json
            \\FROM events ORDER BY ts DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        return writeEventRows(&stmt, out);
    }

    /// Agent decision-related events (proposal / invalid / llm fail / reflection), newest first.
    /// Scheduler wake-ups (AGENT_TRIGGER) stay in the raw events feed only.
    pub fn listAgentDecisionsJson(self: *EventsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT event_id, ts, type, source, severity, state_version, payload_json
            \\FROM events
            \\WHERE type GLOB 'AGENT_*' AND type != 'AGENT_TRIGGER'
            \\ORDER BY ts DESC
            \\LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        return writeEventRows(&stmt, out);
    }

    /// Events inside [ts_from, ts_to] (RFC3339 strings compare lexicographically),
    /// newest first. Backs the 复盘「事件流」window around a decision.
    pub fn listWindowJson(
        self: *EventsRepo,
        db: *Db,
        out: []u8,
        ts_from: []const u8,
        ts_to: []const u8,
        limit: i64,
    ) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT event_id, ts, type, source, severity, state_version, payload_json
            \\FROM events
            \\WHERE ts >= ?1 AND ts <= ?2
            \\ORDER BY ts DESC
            \\LIMIT ?3
        );
        defer stmt.finalize();
        try stmt.bindText(1, ts_from);
        try stmt.bindText(2, ts_to);
        try stmt.bindInt(3, limit);
        return writeEventRows(&stmt, out);
    }

    /// payload_json of the newest event with this type + decision_id in payload,
    /// copied into `out`. Null when absent. Feeds the review chat prompt.
    pub fn proposalPayloadByDecision(
        self: *EventsRepo,
        db: *Db,
        out: []u8,
        decision_id: []const u8,
    ) DbError!?[]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT payload_json FROM events
            \\WHERE type = 'AGENT_PROPOSAL_OK'
            \\  AND json_extract(payload_json, '$.decision_id') = ?1
            \\ORDER BY ts DESC LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindText(1, decision_id);
        if (!try stmt.step()) return null;
        const p = stmt.columnText(0);
        const n = @min(p.len, out.len);
        @memcpy(out[0..n], p[0..n]);
        return out[0..n];
    }

    /// Compact proposal lines inside [ts_from, ts_to] (oldest first) for the
    /// review tool round: ts/action/weight/conf/admission verdict only.
    pub fn writeProposalsWindowCompact(
        self: *EventsRepo,
        db: *Db,
        w: *std.Io.Writer,
        ts_from: []const u8,
        ts_to: []const u8,
        limit: i64,
    ) DbError!void {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT ts,
            \\  COALESCE(json_extract(payload_json,'$.decision_id'),''),
            \\  COALESCE(json_extract(payload_json,'$.action'),''),
            \\  COALESCE(json_extract(payload_json,'$.target_btc_weight'),''),
            \\  COALESCE(json_extract(payload_json,'$.confidence'),''),
            \\  COALESCE(json_extract(payload_json,'$.admission.verdict'),''),
            \\  COALESCE(json_extract(payload_json,'$.executed'),0)
            \\FROM (
            \\  SELECT ts, payload_json FROM events
            \\  WHERE type = 'AGENT_PROPOSAL_OK' AND ts >= ?1 AND ts <= ?2
            \\  ORDER BY ts DESC LIMIT ?3
            \\) ORDER BY ts ASC
        );
        defer stmt.finalize();
        try stmt.bindText(1, ts_from);
        try stmt.bindText(2, ts_to);
        try stmt.bindInt(3, limit);
        w.writeAll("\"rows\":[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeByte(',') catch break :blk false;
                w.print(
                    "{{\"ts\":\"{s}\",\"decision_id\":\"{s}\",\"action\":\"{s}\",\"w\":\"{s}\",\"conf\":\"{s}\",\"verdict\":\"{s}\",\"executed\":{d}}}",
                    .{
                        stmt.columnText(0),
                        stmt.columnText(1),
                        stmt.columnText(2),
                        stmt.columnText(3),
                        stmt.columnText(4),
                        stmt.columnText(5),
                        stmt.columnInt(6),
                    },
                ) catch break :blk false;
                break :blk true;
            };
            if (!wrote) {
                w.end = mark;
                break;
            }
        }
        w.writeAll("]") catch return DbError.StepFailed;
    }

    /// Serialize stepped event rows as a JSON array, keeping as many newest
    /// rows as fit: a row that overflows `out` is dropped (with every older
    /// row) instead of failing the whole listing — the dashboard must never
    /// go blank because one payload grew.
    fn writeEventRows(stmt: *Stmt, out: []u8) DbError![]const u8 {
        if (out.len < 2) return DbError.StepFailed;
        var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]); // reserve "]"
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeAll(",") catch break :blk false;
                w.print(
                    "{{\"event_id\":\"{s}\",\"ts\":\"{s}\",\"type\":\"{s}\",\"source\":\"{s}\",\"severity\":\"{s}\",\"state_version\":{d},\"payload\":{s}}}",
                    .{
                        stmt.columnText(0),
                        stmt.columnText(1),
                        stmt.columnText(2),
                        stmt.columnText(3),
                        stmt.columnText(4),
                        stmt.columnInt(5),
                        stmt.columnText(6),
                    },
                ) catch break :blk false;
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

    /// Compact event objects for agent context (oldest first). Writes into `backing`
    /// and fills `out_ptrs` with slices. Returns count written (≤ out_ptrs.len).
    pub fn listCompactForContext(
        self: *EventsRepo,
        db: *Db,
        backing: []u8,
        out_ptrs: [][]const u8,
    ) DbError!usize {
        _ = self;
        if (out_ptrs.len == 0) return 0;
        const limit: i64 = @intCast(out_ptrs.len);
        var stmt = try db.prepare(
            \\SELECT type, severity, state_version, ts
            \\FROM events
            \\WHERE severity IN ('INFO','WARN','CRITICAL')
            \\ORDER BY ts DESC
            \\LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);

        // Collect newest-first into temporary slots, then reverse.
        var tmp_ptrs: [16][]const u8 = undefined;
        var n: usize = 0;
        var off: usize = 0;
        while (try stmt.step()) {
            if (n >= out_ptrs.len) break;
            var w: std.Io.Writer = .fixed(backing[off..]);
            w.print(
                "{{\"type\":\"{s}\",\"severity\":\"{s}\",\"state_version\":{d},\"ts\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnText(1),
                    stmt.columnInt(2),
                    stmt.columnText(3),
                },
            ) catch return DbError.StepFailed;
            const piece = w.buffered();
            tmp_ptrs[n] = piece;
            off += piece.len;
            // pad 1 byte separator so slices stay distinct if needed
            if (off < backing.len) {
                backing[off] = 0;
                off += 1;
            }
            n += 1;
        }
        // Oldest first for deterministic context narrative.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out_ptrs[i] = tmp_ptrs[n - 1 - i];
        }
        return n;
    }

    /// One own past proposal row for the self-review context section.
    pub const ProposalRow = struct { ts: []const u8, payload: []const u8 };

    /// Own recent decision proposals (oldest first) with raw payload JSON.
    /// First-party audit data for the agent's self-review section.
    pub fn listProposalsForContext(
        self: *EventsRepo,
        db: *Db,
        backing: []u8,
        out: []ProposalRow,
    ) DbError!usize {
        _ = self;
        if (out.len == 0) return 0;
        const limit: i64 = @intCast(out.len);
        var stmt = try db.prepare(
            \\SELECT ts, payload_json
            \\FROM events
            \\WHERE type = 'AGENT_PROPOSAL_OK'
            \\ORDER BY ts DESC
            \\LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);

        var tmp: [16]EventsRepo.ProposalRow = undefined;
        var n: usize = 0;
        var off: usize = 0;
        while (try stmt.step()) {
            if (n >= out.len) break;
            const ts = stmt.columnText(0);
            const payload = stmt.columnText(1);
            if (off + ts.len + payload.len > backing.len) break;
            @memcpy(backing[off .. off + ts.len], ts);
            const ts_slice = backing[off .. off + ts.len];
            off += ts.len;
            @memcpy(backing[off .. off + payload.len], payload);
            const pl_slice = backing[off .. off + payload.len];
            off += payload.len;
            tmp[n] = .{ .ts = ts_slice, .payload = pl_slice };
            n += 1;
        }
        // Oldest first for deterministic context narrative.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = tmp[n - 1 - i];
        }
        return n;
    }
};

/// Online backup via SQLite Backup API (§6.1). Safe with WAL; single writer.
pub fn backupToPath(db: *Db, dest_path: [:0]const u8) DbError!void {
    var dest: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(dest_path.ptr, &dest, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) {
        if (dest) |h| _ = c.sqlite3_close(h);
        return DbError.OpenFailed;
    }
    defer _ = c.sqlite3_close(dest.?);

    const bak = c.sqlite3_backup_init(dest.?, "main", db.handle, "main");
    if (bak == null) return DbError.ExecFailed;
    defer _ = c.sqlite3_backup_finish(bak);

    // Copy all pages; retry briefly on BUSY/LOCKED (no sleep — single-writer daemon).
    var tries: u8 = 0;
    while (tries < 64) : (tries += 1) {
        const rc = c.sqlite3_backup_step(bak, -1);
        if (rc == c.SQLITE_DONE) return;
        if (rc == c.SQLITE_OK) continue;
        if (rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) continue;
        return DbError.ExecFailed;
    }
    return DbError.Busy;
}

pub const OrderRow = struct {
    client_order_id: []const u8,
    exchange_order_id: []const u8 = "",
    decision_id: []const u8,
    side: []const u8,
    qty: []const u8,
    price: []const u8,
    status: []const u8,
    created_ts: []const u8,
    updated_ts: []const u8,
};

pub const OrdersRepo = struct {
    upsert_stmt: Stmt,

    pub fn init(db: *Db) DbError!OrdersRepo {
        return .{ .upsert_stmt = try db.prepare(
            \\INSERT INTO orders (client_order_id, exchange_order_id, decision_id,
            \\  side, qty, price, status, created_ts, updated_ts)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
            \\ON CONFLICT(client_order_id) DO UPDATE SET
            \\  exchange_order_id = CASE
            \\    WHEN excluded.exchange_order_id = '' THEN orders.exchange_order_id
            \\    ELSE excluded.exchange_order_id END,
            \\  status = excluded.status,
            \\  price = excluded.price,
            \\  updated_ts = excluded.updated_ts
        ) };
    }

    pub fn deinit(self: *OrdersRepo) void {
        self.upsert_stmt.finalize();
    }

    pub fn upsert(self: *OrdersRepo, row: OrderRow) DbError!void {
        self.upsert_stmt.reset();
        try self.upsert_stmt.bindText(1, row.client_order_id);
        try self.upsert_stmt.bindText(2, row.exchange_order_id);
        try self.upsert_stmt.bindText(3, row.decision_id);
        try self.upsert_stmt.bindText(4, row.side);
        try self.upsert_stmt.bindText(5, row.qty);
        try self.upsert_stmt.bindText(6, row.price);
        try self.upsert_stmt.bindText(7, row.status);
        try self.upsert_stmt.bindText(8, row.created_ts);
        try self.upsert_stmt.bindText(9, row.updated_ts);
        _ = try self.upsert_stmt.stepCritical();
    }

    /// Newest orders as JSON array (newest first by updated_ts).
    pub fn listRecentJson(self: *OrdersRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT client_order_id, exchange_order_id, decision_id, side, qty, price,
            \\  status, created_ts, updated_ts
            \\FROM orders ORDER BY updated_ts DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return DbError.StepFailed;
            w.print(
                "{{\"client_order_id\":\"{s}\",\"exchange_order_id\":\"{s}\",\"decision_id\":\"{s}\",\"side\":\"{s}\",\"qty\":\"{s}\",\"price\":\"{s}\",\"status\":\"{s}\",\"created_ts\":\"{s}\",\"updated_ts\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnText(1),
                    stmt.columnText(2),
                    stmt.columnText(3),
                    stmt.columnText(4),
                    stmt.columnText(5),
                    stmt.columnText(6),
                    stmt.columnText(7),
                    stmt.columnText(8),
                },
            ) catch return DbError.StepFailed;
        }
        w.writeAll("]") catch return DbError.StepFailed;
        return w.buffered();
    }
};

pub const FillRow = struct {
    fill_id: []const u8,
    order_id: []const u8,
    price: []const u8,
    qty: []const u8,
    fee: []const u8,
    fee_ccy: []const u8 = "USDT",
    ts: []const u8,
};

pub const FillsRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!FillsRepo {
        return .{ .insert = try db.prepare(
            \\INSERT OR IGNORE INTO fills (fill_id, order_id, price, qty, fee, fee_ccy, ts)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7)
        ) };
    }

    pub fn deinit(self: *FillsRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *FillsRepo, row: FillRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.fill_id);
        try self.insert.bindText(2, row.order_id);
        try self.insert.bindText(3, row.price);
        try self.insert.bindText(4, row.qty);
        try self.insert.bindText(5, row.fee);
        try self.insert.bindText(6, row.fee_ccy);
        try self.insert.bindText(7, row.ts);
        _ = try self.insert.stepCritical();
    }

    /// Newest fills as JSON array (newest first).
    pub fn listRecentJson(self: *FillsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT fill_id, order_id, price, qty, fee, fee_ccy, ts
            \\FROM fills ORDER BY ts DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return DbError.StepFailed;
            w.print(
                "{{\"fill_id\":\"{s}\",\"order_id\":\"{s}\",\"price\":\"{s}\",\"qty\":\"{s}\",\"fee\":\"{s}\",\"fee_ccy\":\"{s}\",\"ts\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnText(1),
                    stmt.columnText(2),
                    stmt.columnText(3),
                    stmt.columnText(4),
                    stmt.columnText(5),
                    stmt.columnText(6),
                },
            ) catch return DbError.StepFailed;
        }
        w.writeAll("]") catch return DbError.StepFailed;
        return w.buffered();
    }

    /// Compact own executions (oldest first) for the agent self-review section:
    /// fill joined to its order for side and decision linkage.
    pub fn listCompactForContext(
        self: *FillsRepo,
        db: *Db,
        backing: []u8,
        out_ptrs: [][]const u8,
    ) DbError!usize {
        _ = self;
        if (out_ptrs.len == 0) return 0;
        const limit: i64 = @intCast(out_ptrs.len);
        var stmt = try db.prepare(
            \\SELECT f.ts, COALESCE(o.side,''), f.qty, f.price, f.fee, COALESCE(o.decision_id,'')
            \\FROM fills f LEFT JOIN orders o ON o.client_order_id = f.order_id
            \\ORDER BY f.ts DESC
            \\LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);

        var tmp_ptrs: [16][]const u8 = undefined;
        var n: usize = 0;
        var off: usize = 0;
        while (try stmt.step()) {
            if (n >= out_ptrs.len) break;
            var w: std.Io.Writer = .fixed(backing[off..]);
            w.print(
                "{{\"ts\":\"{s}\",\"side\":\"{s}\",\"qty\":\"{s}\",\"price\":\"{s}\",\"fee\":\"{s}\",\"decision_id\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnText(1),
                    stmt.columnText(2),
                    stmt.columnText(3),
                    stmt.columnText(4),
                    stmt.columnText(5),
                },
            ) catch return DbError.StepFailed;
            const piece = w.buffered();
            tmp_ptrs[n] = piece;
            off += piece.len;
            if (off < backing.len) {
                backing[off] = 0;
                off += 1;
            }
            n += 1;
        }
        // Oldest first for deterministic context narrative.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out_ptrs[i] = tmp_ptrs[n - 1 - i];
        }
        return n;
    }
};

pub const EquitySampleRow = struct {
    ts: []const u8,
    interval: []const u8, // "1s" | "1m"
    equity: []const u8,
    hwm: []const u8,
    drawdown: []const u8,
    cash: []const u8,
    btc_value: []const u8,
};

pub const EquityRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!EquityRepo {
        return .{ .insert = try db.prepare(
            \\INSERT OR REPLACE INTO equity_samples (ts, interval, equity, hwm, drawdown, cash, btc_value)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7)
        ) };
    }

    pub fn deinit(self: *EquityRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *EquityRepo, row: EquitySampleRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.ts);
        try self.insert.bindText(2, row.interval);
        try self.insert.bindText(3, row.equity);
        try self.insert.bindText(4, row.hwm);
        try self.insert.bindText(5, row.drawdown);
        try self.insert.bindText(6, row.cash);
        try self.insert.bindText(7, row.btc_value);
        _ = try self.insert.stepCritical();
    }

    /// Latest HWM recorded (for BOOTING restore). Zero string when empty.
    pub fn latestHwm(self: *EquityRepo, db: *Db, buf: []u8) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare("SELECT hwm FROM equity_samples ORDER BY ts DESC LIMIT 1");
        defer stmt.finalize();
        if (try stmt.step()) {
            const text = stmt.columnText(0);
            if (text.len > buf.len) return DbError.StepFailed;
            @memcpy(buf[0..text.len], text);
            return buf[0..text.len];
        }
        return DbError.NotFound;
    }

    /// Render newest equity samples as a JSON array into `out` (newest first).
    pub fn listRecentJson(self: *EquityRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT ts, interval, equity, hwm, drawdown, cash, btc_value
            \\FROM equity_samples ORDER BY ts DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return DbError.StepFailed;
            w.print(
                "{{\"ts\":\"{s}\",\"interval\":\"{s}\",\"equity\":\"{s}\",\"hwm\":\"{s}\",\"drawdown\":\"{s}\",\"cash\":\"{s}\",\"btc_value\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnText(1),
                    stmt.columnText(2),
                    stmt.columnText(3),
                    stmt.columnText(4),
                    stmt.columnText(5),
                    stmt.columnText(6),
                },
            ) catch return DbError.StepFailed;
        }
        w.writeAll("]") catch return DbError.StepFailed;
        return w.buffered();
    }

    /// Latest equity sample at or before `cutoff_ts` (RFC3339, lexicographically
    /// comparable), rendered as one labelled JSON mark for the self-review
    /// section: `{"ago":"24h","ts":"...","equity":"..."}`.
    pub fn equityMarkJson(
        self: *EquityRepo,
        db: *Db,
        label: []const u8,
        cutoff_ts: []const u8,
        out: []u8,
    ) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT ts, equity FROM equity_samples
            \\WHERE ts <= ?1 ORDER BY ts DESC LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindText(1, cutoff_ts);
        if (try stmt.step()) {
            var w: std.Io.Writer = .fixed(out);
            w.print(
                "{{\"ago\":\"{s}\",\"ts\":\"{s}\",\"equity\":\"{s}\"}}",
                .{ label, stmt.columnText(0), stmt.columnText(1) },
            ) catch return DbError.StepFailed;
            return w.buffered();
        }
        return DbError.NotFound;
    }

    /// Hourly-bucketed equity trail inside [ts_from, ts_to] (oldest first)
    /// for the review tool round: last sample of each hour.
    pub fn writeTrailCompact(
        self: *EquityRepo,
        db: *Db,
        w: *std.Io.Writer,
        ts_from: []const u8,
        ts_to: []const u8,
        limit: i64,
    ) DbError!void {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT ts, equity, drawdown FROM equity_samples
            \\WHERE ts >= ?1 AND ts <= ?2
            \\GROUP BY substr(ts, 1, 13)
            \\HAVING ts = MAX(ts)
            \\ORDER BY ts ASC LIMIT ?3
        );
        defer stmt.finalize();
        try stmt.bindText(1, ts_from);
        try stmt.bindText(2, ts_to);
        try stmt.bindInt(3, limit);
        w.writeAll("\"rows\":[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeByte(',') catch break :blk false;
                w.print(
                    "{{\"ts\":\"{s}\",\"equity\":\"{s}\",\"dd\":\"{s}\"}}",
                    .{ stmt.columnText(0), stmt.columnText(1), stmt.columnText(2) },
                ) catch break :blk false;
                break :blk true;
            };
            if (!wrote) {
                w.end = mark;
                break;
            }
        }
        w.writeAll("]") catch return DbError.StepFailed;
    }
};

pub const AgentRunRow = struct {
    run_id: []const u8,
    snapshot_version: i64,
    model: []const u8,
    prompt_hash: []const u8,
    input_digest: []const u8 = "",
    output_digest: []const u8 = "",
    status: []const u8,
    started_ts: []const u8,
    finished_ts: []const u8 = "",
};

pub const AgentRunsRepo = struct {
    insert: Stmt,
    finish: Stmt,

    pub fn init(db: *Db) DbError!AgentRunsRepo {
        return .{
            .insert = try db.prepare(
                \\INSERT INTO agent_runs (run_id, snapshot_version, model, prompt_hash,
                \\  input_digest, output_digest, status, started_ts, finished_ts)
                \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
            ),
            .finish = try db.prepare(
                \\UPDATE agent_runs SET status = ?2, output_digest = ?3, finished_ts = ?4,
                \\  input_digest = CASE WHEN length(?5) > 0 THEN ?5 ELSE input_digest END
                \\WHERE run_id = ?1
            ),
        };
    }

    pub fn deinit(self: *AgentRunsRepo) void {
        self.insert.finalize();
        self.finish.finalize();
    }

    pub fn start(self: *AgentRunsRepo, row: AgentRunRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.run_id);
        try self.insert.bindInt(2, row.snapshot_version);
        try self.insert.bindText(3, row.model);
        try self.insert.bindText(4, row.prompt_hash);
        try self.insert.bindText(5, row.input_digest);
        try self.insert.bindText(6, row.output_digest);
        try self.insert.bindText(7, row.status);
        try self.insert.bindText(8, row.started_ts);
        try self.insert.bindText(9, row.finished_ts);
        _ = try self.insert.stepCritical();
    }

    pub fn complete(
        self: *AgentRunsRepo,
        run_id: []const u8,
        status: []const u8,
        output_digest: []const u8,
        finished_ts: []const u8,
    ) DbError!void {
        try self.completeWithInput(run_id, status, output_digest, "", finished_ts);
    }

    pub fn completeWithInput(
        self: *AgentRunsRepo,
        run_id: []const u8,
        status: []const u8,
        output_digest: []const u8,
        input_digest: []const u8,
        finished_ts: []const u8,
    ) DbError!void {
        self.finish.reset();
        try self.finish.bindText(1, run_id);
        try self.finish.bindText(2, status);
        try self.finish.bindText(3, output_digest);
        try self.finish.bindText(4, finished_ts);
        try self.finish.bindText(5, input_digest);
        _ = try self.finish.stepCritical();
    }

    /// Newest agent runs as JSON array (newest first).
    pub fn listRecentJson(self: *AgentRunsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT run_id, snapshot_version, model, status, started_ts, finished_ts,
            \\  input_digest, output_digest, prompt_hash
            \\FROM agent_runs ORDER BY started_ts DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        var w: std.Io.Writer = .fixed(out);
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            if (i > 0) w.writeAll(",") catch return DbError.StepFailed;
            w.print(
                "{{\"run_id\":\"{s}\",\"snapshot_version\":{d},\"model\":\"{s}\",\"status\":\"{s}\",\"started_ts\":\"{s}\",\"finished_ts\":\"{s}\",\"input_digest\":\"{s}\",\"output_digest\":\"{s}\",\"prompt_hash\":\"{s}\"}}",
                .{
                    stmt.columnText(0),
                    stmt.columnInt(1),
                    stmt.columnText(2),
                    stmt.columnText(3),
                    stmt.columnText(4),
                    stmt.columnText(5),
                    stmt.columnText(6),
                    stmt.columnText(7),
                    stmt.columnText(8),
                },
            ) catch return DbError.StepFailed;
        }
        w.writeAll("]") catch return DbError.StepFailed;
        return w.buffered();
    }
};

pub const ToolCallRow = struct {
    run_id: []const u8,
    tool: []const u8,
    source: []const u8 = "",
    as_of: []const u8 = "",
    latency_ms: i64 = 0,
    cost: []const u8 = "0",
    result_digest: []const u8 = "",
    ts: []const u8,
};

pub const ToolCallsRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!ToolCallsRepo {
        return .{ .insert = try db.prepare(
            \\INSERT INTO tool_calls (run_id, tool, source, as_of, latency_ms, cost, result_digest, ts)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
        ) };
    }

    pub fn deinit(self: *ToolCallsRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *ToolCallsRepo, row: ToolCallRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.run_id);
        try self.insert.bindText(2, row.tool);
        try self.insert.bindText(3, row.source);
        try self.insert.bindText(4, row.as_of);
        try self.insert.bindInt(5, row.latency_ms);
        try self.insert.bindText(6, row.cost);
        try self.insert.bindText(7, row.result_digest);
        try self.insert.bindText(8, row.ts);
        _ = try self.insert.stepCritical();
    }
};

pub const MemoryRow = struct {
    memory_id: []const u8,
    version: i64,
    kind: []const u8,
    status: []const u8 = "active",
    confidence: f64 = 0,
    evidence_count: i64 = 0,
    content_json: []const u8,
    created_ts: []const u8,
};

pub const MemoriesRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!MemoriesRepo {
        return .{ .insert = try db.prepare(
            \\INSERT INTO memories (memory_id, version, kind, status, confidence,
            \\  evidence_count, content_json, created_ts)
            \\VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
        ) };
    }

    pub fn deinit(self: *MemoriesRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *MemoriesRepo, row: MemoryRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.memory_id);
        try self.insert.bindInt(2, row.version);
        try self.insert.bindText(3, row.kind);
        try self.insert.bindText(4, row.status);
        try self.insert.bindFloat(5, row.confidence);
        try self.insert.bindInt(6, row.evidence_count);
        try self.insert.bindText(7, row.content_json);
        try self.insert.bindText(8, row.created_ts);
        _ = try self.insert.stepCritical();
    }

    /// Latest version per memory_id as a JSON array (newest first).
    pub fn listLatestJson(self: *MemoriesRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT memory_id, version, kind, status, confidence, evidence_count,
            \\  content_json, created_ts
            \\FROM memories m
            \\WHERE version = (
            \\  SELECT MAX(version) FROM memories m2 WHERE m2.memory_id = m.memory_id
            \\)
            \\ORDER BY created_ts DESC
            \\LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        if (out.len < 2) return DbError.StepFailed;
        var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]); // reserve "]"
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeAll(",") catch break :blk false;
                // confidence is REAL in SQLite; print as decimal string without scientific notation.
                const conf = stmt.columnFloat(4);
                w.print(
                    "{{\"memory_id\":\"{s}\",\"version\":{d},\"kind\":\"{s}\",\"status\":\"{s}\",\"confidence\":\"{d:.6}\",\"evidence_count\":{d},\"content\":{s},\"created_ts\":\"{s}\"}}",
                    .{
                        stmt.columnText(0),
                        stmt.columnInt(1),
                        stmt.columnText(2),
                        stmt.columnText(3),
                        conf,
                        stmt.columnInt(5),
                        stmt.columnText(6),
                        stmt.columnText(7),
                    },
                ) catch break :blk false;
                break :blk true;
            };
            // Keep as many newest rows as fit; drop the overflowing row and
            // older ones instead of blanking the whole memories API.
            if (!wrote) {
                w.end = mark;
                break;
            }
        }
        out[w.end] = ']';
        return out[0 .. w.end + 1];
    }

    /// Callback for each latest-version row (boot rebuild of in-memory store).
    /// Terminal rows (invalidated/merged) are skipped — retrieval never
    /// surfaces them and they would only consume index slots; full history
    /// stays in the table. Newest first so the freshest memories survive if
    /// the row count ever exceeds the in-process index capacity.
    pub fn forEachLatest(
        self: *MemoriesRepo,
        db: *Db,
        ctx: *anyopaque,
        cb: *const fn (ctx: *anyopaque, row: MemoryRow) void,
    ) DbError!void {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT memory_id, version, kind, status, confidence, evidence_count,
            \\  content_json, created_ts
            \\FROM memories m
            \\WHERE version = (
            \\  SELECT MAX(version) FROM memories m2 WHERE m2.memory_id = m.memory_id
            \\)
            \\  AND status NOT IN ('invalidated','merged')
            \\ORDER BY created_ts DESC
        );
        defer stmt.finalize();
        while (try stmt.step()) {
            cb(ctx, .{
                .memory_id = stmt.columnText(0),
                .version = stmt.columnInt(1),
                .kind = stmt.columnText(2),
                .status = stmt.columnText(3),
                .confidence = stmt.columnFloat(4),
                .evidence_count = stmt.columnInt(5),
                .content_json = stmt.columnText(6),
                .created_ts = stmt.columnText(7),
            });
        }
    }
};

pub const ReviewChatRow = struct {
    decision_id: []const u8,
    anchor_ts: []const u8 = "",
    role: []const u8, // 'user' | 'assistant' | 'summary'
    content: []const u8,
    model: []const u8 = "",
    created_ts: []const u8,
};

/// 复盘对话 transcripts. Analysis-only side channel: rows never feed the
/// trading loop; an explicit summarize step may distill them into a memory.
pub const ReviewChatsRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!ReviewChatsRepo {
        return .{ .insert = try db.prepare(
            \\INSERT INTO review_chats (decision_id, anchor_ts, role, content, model, created_ts)
            \\VALUES (?1,?2,?3,?4,?5,?6)
        ) };
    }

    pub fn deinit(self: *ReviewChatsRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *ReviewChatsRepo, row: ReviewChatRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.decision_id);
        try self.insert.bindText(2, row.anchor_ts);
        try self.insert.bindText(3, row.role);
        try self.insert.bindText(4, row.content);
        try self.insert.bindText(5, row.model);
        try self.insert.bindText(6, row.created_ts);
        _ = try self.insert.stepCritical();
    }

    pub fn countForDecision(self: *ReviewChatsRepo, db: *Db, decision_id: []const u8) DbError!i64 {
        _ = self;
        var stmt = try db.prepare("SELECT COUNT(*) FROM review_chats WHERE decision_id = ?1");
        defer stmt.finalize();
        try stmt.bindText(1, decision_id);
        if (!try stmt.step()) return 0;
        return stmt.columnInt(0);
    }

    /// Newest turns as a JSON array (newest first; client re-sorts by id).
    /// Content is raw text → JSON-escaped here. Rows that overflow `out`
    /// are dropped (with all older rows) instead of failing the listing.
    pub fn listRecentJson(self: *ReviewChatsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT id, decision_id, anchor_ts, role, content, model, created_ts
            \\FROM review_chats ORDER BY id DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        if (out.len < 2) return DbError.StepFailed;
        var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]); // reserve "]"
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeAll(",") catch break :blk false;
                w.print(
                    "{{\"id\":{d},\"decision_id\":\"{s}\",\"anchor_ts\":\"{s}\",\"role\":\"{s}\",\"content\":\"",
                    .{ stmt.columnInt(0), stmt.columnText(1), stmt.columnText(2), stmt.columnText(3) },
                ) catch break :blk false;
                writeJsonEscaped(&w, stmt.columnText(4)) catch break :blk false;
                w.print(
                    "\",\"model\":\"{s}\",\"created_ts\":\"{s}\"}}",
                    .{ stmt.columnText(5), stmt.columnText(6) },
                ) catch break :blk false;
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

    /// Plain-text transcript tail (oldest→newest of the last `max_turns`),
    /// "role: content" lines. Feeds the review LLM prompt.
    pub fn transcriptTail(
        self: *ReviewChatsRepo,
        db: *Db,
        out: []u8,
        decision_id: []const u8,
        max_turns: i64,
    ) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT role, content FROM (
            \\  SELECT id, role, content FROM review_chats
            \\  WHERE decision_id = ?1 AND role != 'summary'
            \\  ORDER BY id DESC LIMIT ?2
            \\) ORDER BY id ASC
        );
        defer stmt.finalize();
        try stmt.bindText(1, decision_id);
        try stmt.bindInt(2, max_turns);
        var w: std.Io.Writer = .fixed(out);
        while (try stmt.step()) {
            const mark = w.end;
            const wrote = blk: {
                w.print("{s}: {s}\n", .{ stmt.columnText(0), stmt.columnText(1) }) catch break :blk false;
                break :blk true;
            };
            if (!wrote) {
                w.end = mark;
                break;
            }
        }
        return w.buffered();
    }
};

pub const AuditReportRow = struct {
    audit_id: []const u8,
    ts: []const u8,
    status: []const u8, // 'ok' | 'warn' | 'alert'
    findings: i64,
    report_json: []const u8,
};

/// Scheduled audit reports (定时审计): full findings JSON kept for replay.
pub const AuditReportsRepo = struct {
    insert: Stmt,

    pub fn init(db: *Db) DbError!AuditReportsRepo {
        return .{ .insert = try db.prepare(
            \\INSERT INTO audit_reports (audit_id, ts, status, findings, report_json)
            \\VALUES (?1,?2,?3,?4,?5)
        ) };
    }

    pub fn deinit(self: *AuditReportsRepo) void {
        self.insert.finalize();
    }

    pub fn append(self: *AuditReportsRepo, row: AuditReportRow) DbError!void {
        self.insert.reset();
        try self.insert.bindText(1, row.audit_id);
        try self.insert.bindText(2, row.ts);
        try self.insert.bindText(3, row.status);
        try self.insert.bindInt(4, row.findings);
        try self.insert.bindText(5, row.report_json);
        _ = try self.insert.stepCritical();
    }

    /// ms timestamp of the newest report (parsed from RFC3339 ts), or null.
    pub fn latestTs(self: *AuditReportsRepo, db: *Db, out: []u8) DbError!?[]const u8 {
        _ = self;
        var stmt = try db.prepare("SELECT ts FROM audit_reports ORDER BY id DESC LIMIT 1");
        defer stmt.finalize();
        if (!try stmt.step()) return null;
        const t = stmt.columnText(0);
        const n = @min(t.len, out.len);
        @memcpy(out[0..n], t[0..n]);
        return out[0..n];
    }

    /// Newest reports as a JSON array (newest first); report_json embedded raw.
    /// Overflowing rows are dropped (with older ones) instead of failing.
    pub fn listRecentJson(self: *AuditReportsRepo, db: *Db, out: []u8, limit: i64) DbError![]const u8 {
        _ = self;
        var stmt = try db.prepare(
            \\SELECT audit_id, ts, status, findings, report_json
            \\FROM audit_reports ORDER BY id DESC LIMIT ?1
        );
        defer stmt.finalize();
        try stmt.bindInt(1, limit);
        if (out.len < 2) return DbError.StepFailed;
        var w: std.Io.Writer = .fixed(out[0 .. out.len - 1]);
        w.writeAll("[") catch return DbError.StepFailed;
        var i: usize = 0;
        while (try stmt.step()) : (i += 1) {
            const mark = w.end;
            const wrote = blk: {
                if (i > 0) w.writeAll(",") catch break :blk false;
                w.print("{s}", .{stmt.columnText(4)}) catch break :blk false;
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
};

/// Small runtime key/value store for persisted baselines (e.g. the shadow
/// buy-and-hold benchmark). Single writer like every other repo.
pub const KvRepo = struct {
    put_stmt: Stmt,
    get_stmt: Stmt,

    pub fn init(db: *Db) DbError!KvRepo {
        return .{
            .put_stmt = try db.prepare(
                \\INSERT INTO runtime_kv (key, value, updated_ts) VALUES (?1,?2,?3)
                \\ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_ts=excluded.updated_ts
            ),
            .get_stmt = try db.prepare("SELECT value FROM runtime_kv WHERE key = ?1"),
        };
    }

    pub fn deinit(self: *KvRepo) void {
        self.put_stmt.finalize();
        self.get_stmt.finalize();
    }

    pub fn put(self: *KvRepo, key: []const u8, value: []const u8, ts: []const u8) DbError!void {
        self.put_stmt.reset();
        try self.put_stmt.bindText(1, key);
        try self.put_stmt.bindText(2, value);
        try self.put_stmt.bindText(3, ts);
        _ = try self.put_stmt.stepCritical();
    }

    /// Copy the value for `key` into `out`; null when missing or too large.
    pub fn get(self: *KvRepo, key: []const u8, out: []u8) ?[]const u8 {
        self.get_stmt.reset();
        self.get_stmt.bindText(1, key) catch return null;
        const has = self.get_stmt.step() catch return null;
        if (!has) return null;
        const v = self.get_stmt.columnText(0);
        if (v.len > out.len) return null;
        @memcpy(out[0..v.len], v);
        return out[0..v.len];
    }
};

/// Escape raw text into a JSON string value (no surrounding quotes).
fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) error{WriteFailed}!void {
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn tmpDbPath(tmp: *std.testing.TmpDir, buf: []u8) ![:0]const u8 {
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    return std.fmt.bufPrintZ(buf, "{s}/test.db", .{dir_buf[0..n]});
}

test "open runs migrations and sets WAL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);

    var db = try Db.open(path);
    defer db.close();

    try testing.expectEqual(@as(i64, @intCast(migrations.len)), try db.queryInt("PRAGMA user_version"));

    var stmt = try db.prepare("PRAGMA journal_mode");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("wal", stmt.columnText(0));

    // Re-open: migrations must be idempotent.
    var db2 = try Db.open(path);
    db2.close();
}

test "events append and read back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var repo = try EventsRepo.init(&db);
    defer repo.deinit();

    try repo.append(.{
        .event_id = "evt_001",
        .ts = "2026-08-09T08:31:04.482Z",
        .type = "RISK_DECISION",
        .source = "risk-kernel",
        .severity = "INFO",
        .correlation_id = "dec_001",
        .state_version = 42,
        .payload_json = "{\"decision\":\"APPROVE\"}",
    });
    try repo.append(.{
        .event_id = "evt_002",
        .ts = "2026-08-09T08:31:05.000Z",
        .type = "ORDER_SUBMITTED",
        .source = "execution",
        .severity = "INFO",
    });

    try testing.expectEqual(@as(i64, 2), try db.queryInt("SELECT COUNT(*) FROM events"));

    // seq is monotonic append order
    var stmt = try db.prepare("SELECT seq, event_id FROM events ORDER BY seq");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    try testing.expectEqualStrings("evt_001", stmt.columnText(1));
    try testing.expect(try stmt.step());
    try testing.expectEqual(@as(i64, 2), stmt.columnInt(0));

    // duplicate event_id rejected (audit log integrity)
    try testing.expectError(DbError.StepFailed, repo.append(.{
        .event_id = "evt_001",
        .ts = "2026-08-09T08:31:06.000Z",
        .type = "X",
        .source = "x",
        .severity = "INFO",
    }));

    // Full listing fits.
    var big: [2048]u8 = undefined;
    const all = try repo.listRecentJson(&db, &big, 40);
    try testing.expect(std.mem.indexOf(u8, all, "evt_001") != null);
    try testing.expect(std.mem.indexOf(u8, all, "evt_002") != null);

    // Undersized buffer truncates to the newest rows that fit — still valid
    // JSON, never a hard failure that would blank the dashboard feed.
    var small: [180]u8 = undefined;
    const truncated = try repo.listRecentJson(&db, &small, 40);
    try testing.expect(truncated.len >= 2);
    try testing.expectEqual(@as(u8, '['), truncated[0]);
    try testing.expectEqual(@as(u8, ']'), truncated[truncated.len - 1]);
    try testing.expect(std.mem.indexOf(u8, truncated, "evt_002") != null); // newest kept
    try testing.expect(std.mem.indexOf(u8, truncated, "evt_001") == null); // oldest dropped

    // Scheduler wake-ups are excluded from the decisions listing.
    try repo.append(.{
        .event_id = "evt_003",
        .ts = "2026-08-09T08:31:07.000Z",
        .type = "AGENT_TRIGGER",
        .source = "agent",
        .severity = "INFO",
        .payload_json = "{\"reason\":\"interval_active\"}",
    });
    try repo.append(.{
        .event_id = "evt_004",
        .ts = "2026-08-09T08:31:08.000Z",
        .type = "AGENT_PROPOSAL_OK",
        .source = "agent",
        .severity = "INFO",
    });
    const decisions = try repo.listAgentDecisionsJson(&db, &big, 40);
    try testing.expect(std.mem.indexOf(u8, decisions, "AGENT_PROPOSAL_OK") != null);
    try testing.expect(std.mem.indexOf(u8, decisions, "AGENT_TRIGGER") == null);
    const feed = try repo.listRecentJson(&db, &big, 40);
    try testing.expect(std.mem.indexOf(u8, feed, "AGENT_TRIGGER") != null);
}

test "audit chain queries trace orders to stamped decision events (AC-GO5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var events = try EventsRepo.init(&db);
    defer events.deinit();
    var orders = try OrdersRepo.init(&db);
    defer orders.deinit();
    var fills = try FillsRepo.init(&db);
    defer fills.deinit();

    // Fully traceable order: stamped proposal event + ORDER_* event + fill.
    try events.append(.{
        .event_id = "evt_p1",
        .ts = "t1",
        .type = "AGENT_PROPOSAL_OK",
        .source = "agent",
        .severity = "INFO",
        .software_version = "0.1.0",
        .config_hash = "sha256:abc",
        .payload_json = "{\"decision_id\":\"dec_ok\",\"snapshot_version\":5,\"admission\":{\"verdict\":\"APPROVE\"}}",
    });
    try events.append(.{
        .event_id = "evt_o1",
        .ts = "t2",
        .type = "ORDER_ACK",
        .source = "execution",
        .severity = "INFO",
        .software_version = "0.1.0",
        .config_hash = "sha256:abc",
        .payload_json = "{\"client_order_id\":\"ab_good\",\"decision_id\":\"dec_ok\"}",
    });
    try orders.upsert(.{
        .client_order_id = "ab_good",
        .decision_id = "dec_ok",
        .side = "buy",
        .qty = "0.001",
        .price = "100",
        .status = "FILLED",
        .created_ts = "t2",
        .updated_ts = "t3",
    });
    try fills.append(.{ .fill_id = "f_good", .order_id = "ab_good", .price = "100", .qty = "0.001", .fee = "0", .ts = "t3" });

    const q_no_dec = "SELECT COUNT(*) FROM orders WHERE decision_id = ''";
    const q_no_proposal =
        \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
        \\  SELECT 1 FROM events e
        \\  WHERE e.type IN ('AGENT_PROPOSAL_OK','ADMIN_TARGET_WEIGHT')
        \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0)
    ;
    const q_unstamped =
        \\SELECT COUNT(*) FROM orders o WHERE EXISTS (
        \\  SELECT 1 FROM events e
        \\  WHERE e.type IN ('AGENT_PROPOSAL_OK','ADMIN_TARGET_WEIGHT')
        \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0
        \\  AND (e.config_hash = '' OR e.software_version = ''))
    ;
    const q_no_events =
        \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
        \\  SELECT 1 FROM events e WHERE e.type LIKE 'ORDER_%'
        \\  AND instr(e.payload_json, o.client_order_id) > 0)
    ;
    const q_orphan_fills =
        \\SELECT COUNT(*) FROM fills f WHERE NOT EXISTS (
        \\  SELECT 1 FROM orders o WHERE o.client_order_id = f.order_id)
    ;

    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_no_dec));
    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_no_proposal));
    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_unstamped));
    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_no_events));
    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_orphan_fills));

    // Operator probe path: ADMIN_TARGET_WEIGHT is a valid decision anchor.
    try events.append(.{
        .event_id = "evt_op",
        .ts = "t2b",
        .type = "ADMIN_TARGET_WEIGHT",
        .source = "admin",
        .severity = "CRITICAL",
        .software_version = "0.1.0",
        .config_hash = "sha256:abc",
        .payload_json = "{\"decision_id\":\"dec_op_tw_1\",\"source\":\"operator\",\"admission\":\"APPROVE\"}",
    });
    try events.append(.{
        .event_id = "evt_op_ack",
        .ts = "t2c",
        .type = "ORDER_ACK",
        .source = "execution",
        .severity = "INFO",
        .software_version = "0.1.0",
        .config_hash = "sha256:abc",
        .payload_json = "{\"clOrdId\":\"ab_op\",\"decision_id\":\"dec_op_tw_1\"}",
    });
    try orders.upsert(.{
        .client_order_id = "ab_op",
        .decision_id = "dec_op_tw_1",
        .side = "buy",
        .qty = "0.001",
        .price = "market",
        .status = "FILLED",
        .created_ts = "t2b",
        .updated_ts = "t2c",
    });
    try testing.expectEqual(@as(i64, 0), try db.queryInt(q_no_proposal));

    // Broken chain: order with no proposal event, no ORDER_* event; orphan fill;
    // plus an unstamped proposal for a second order.
    try events.append(.{
        .event_id = "evt_p2",
        .ts = "t4",
        .type = "AGENT_PROPOSAL_OK",
        .source = "agent",
        .severity = "INFO",
        .payload_json = "{\"decision_id\":\"dec_unstamped\"}",
    });
    try orders.upsert(.{
        .client_order_id = "ab_orphan",
        .decision_id = "dec_missing",
        .side = "sell",
        .qty = "1",
        .price = "1",
        .status = "LIVE",
        .created_ts = "t4",
        .updated_ts = "t4",
    });
    try orders.upsert(.{
        .client_order_id = "ab_unstamped",
        .decision_id = "dec_unstamped",
        .side = "sell",
        .qty = "1",
        .price = "1",
        .status = "LIVE",
        .created_ts = "t4",
        .updated_ts = "t4",
    });
    // Orphan fill: FK is ON in normal operation, so simulate a damaged
    // restore snapshot by inserting with FK off.
    try db.execAll("PRAGMA foreign_keys = OFF;");
    try fills.append(.{ .fill_id = "f_orphan", .order_id = "ab_ghost", .price = "1", .qty = "1", .fee = "0", .ts = "t5" });
    try db.execAll("PRAGMA foreign_keys = ON;");

    try testing.expectEqual(@as(i64, 1), try db.queryInt(q_no_proposal)); // dec_missing
    try testing.expectEqual(@as(i64, 1), try db.queryInt(q_unstamped)); // dec_unstamped
    try testing.expectEqual(@as(i64, 2), try db.queryInt(q_no_events)); // both new orders
    try testing.expectEqual(@as(i64, 1), try db.queryInt(q_orphan_fills)); // f_orphan
}

test "orders upsert projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var repo = try OrdersRepo.init(&db);
    defer repo.deinit();

    try repo.upsert(.{
        .client_order_id = "ab0011223344556677889900aabbccdd",
        .decision_id = "dec_001",
        .side = "buy",
        .qty = "0.00100000",
        .price = "100000.00000000",
        .status = "SUBMITTED",
        .created_ts = "t1",
        .updated_ts = "t1",
    });
    try repo.upsert(.{
        .client_order_id = "ab0011223344556677889900aabbccdd",
        .exchange_order_id = "okx-777",
        .decision_id = "dec_001",
        .side = "buy",
        .qty = "0.00100000",
        .price = "100000.00000000",
        .status = "FILLED",
        .created_ts = "t1",
        .updated_ts = "t2",
    });

    try testing.expectEqual(@as(i64, 1), try db.queryInt("SELECT COUNT(*) FROM orders"));
    var stmt = try db.prepare("SELECT status, exchange_order_id, created_ts FROM orders");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("FILLED", stmt.columnText(0));
    try testing.expectEqualStrings("okx-777", stmt.columnText(1));
    try testing.expectEqualStrings("t1", stmt.columnText(2)); // created preserved

    var json_buf: [1024]u8 = undefined;
    const json = try repo.listRecentJson(&db, &json_buf, 10);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"FILLED\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "okx-777") != null);

    // Query-path upsert with empty exchange_order_id must not wipe ACK ordId.
    try repo.upsert(.{
        .client_order_id = "ab0011223344556677889900aabbccdd",
        .exchange_order_id = "",
        .decision_id = "dec_001",
        .side = "buy",
        .qty = "0.00100000",
        .price = "100001.5",
        .status = "FILLED",
        .created_ts = "t1",
        .updated_ts = "t3",
    });
    var stmt2 = try db.prepare("SELECT exchange_order_id, price FROM orders WHERE client_order_id = ?1");
    defer stmt2.finalize();
    try stmt2.bindText(1, "ab0011223344556677889900aabbccdd");
    try testing.expect(try stmt2.step());
    try testing.expectEqualStrings("okx-777", stmt2.columnText(0));
    try testing.expectEqualStrings("100001.5", stmt2.columnText(1));
}

test "fills idempotent, equity samples, agent runs and tool calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var orders = try OrdersRepo.init(&db);
    defer orders.deinit();
    try orders.upsert(.{
        .client_order_id = "abff",
        .decision_id = "dec_9",
        .side = "sell",
        .qty = "1",
        .price = "1",
        .status = "LIVE",
        .created_ts = "t",
        .updated_ts = "t",
    });

    var fills = try FillsRepo.init(&db);
    defer fills.deinit();
    const fill = FillRow{
        .fill_id = "f1",
        .order_id = "abff",
        .price = "100000",
        .qty = "0.0005",
        .fee = "0.05",
        .ts = "t2",
    };
    try fills.append(fill);
    try fills.append(fill); // duplicate push from WS + REST poll → ignored
    try testing.expectEqual(@as(i64, 1), try db.queryInt("SELECT COUNT(*) FROM fills"));
    var fills_json_buf: [512]u8 = undefined;
    const fills_json = try fills.listRecentJson(&db, &fills_json_buf, 10);
    try testing.expect(std.mem.indexOf(u8, fills_json, "\"fill_id\":\"f1\"") != null);
    try testing.expect(std.mem.indexOf(u8, fills_json, "abff") != null);

    var equity = try EquityRepo.init(&db);
    defer equity.deinit();
    try equity.append(.{
        .ts = "2026-08-09T08:31:04.000Z",
        .interval = "1s",
        .equity = "99.5",
        .hwm = "100",
        .drawdown = "0.005",
        .cash = "50",
        .btc_value = "49.5",
    });
    var hwm_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("100", try equity.latestHwm(&db, &hwm_buf));

    var runs = try AgentRunsRepo.init(&db);
    defer runs.deinit();
    try runs.start(.{
        .run_id = "run_1",
        .snapshot_version = 7,
        .model = "gpt-x",
        .prompt_hash = "sha256:p",
        .status = "running",
        .started_ts = "t3",
    });
    try runs.complete("run_1", "ok", "sha256:o", "t4");
    var stmt = try db.prepare("SELECT status, output_digest FROM agent_runs WHERE run_id='run_1'");
    defer stmt.finalize();
    try testing.expect(try stmt.step());
    try testing.expectEqualStrings("ok", stmt.columnText(0));

    var tools = try ToolCallsRepo.init(&db);
    defer tools.deinit();
    try tools.append(.{ .run_id = "run_1", .tool = "get_market_snapshot", .latency_ms = 12, .ts = "t3" });
    // FK enforced: unknown run rejected
    try testing.expectError(DbError.StepFailed, tools.append(.{ .run_id = "nope", .tool = "x", .ts = "t" }));

    var mems = try MemoriesRepo.init(&db);
    defer mems.deinit();
    try mems.append(.{
        .memory_id = "m1",
        .version = 1,
        .kind = "strategy",
        .status = "unverified",
        .confidence = 0.6,
        .evidence_count = 3,
        .content_json = "{\"text\":\"spread widens near funding\",\"tags\":[\"BTC\"]}",
        .created_ts = "t5",
    });
    try mems.append(.{
        .memory_id = "m1",
        .version = 2,
        .kind = "strategy",
        .status = "active",
        .confidence = 0.7,
        .evidence_count = 4,
        .content_json = "{\"text\":\"updated\",\"tags\":[\"BTC\"]}",
        .created_ts = "t6",
    });
    try testing.expectEqual(@as(i64, 2), try db.queryInt("SELECT COUNT(*) FROM memories"));
    var mem_json_buf: [1024]u8 = undefined;
    const mem_json = try mems.listLatestJson(&db, &mem_json_buf, 10);
    // Latest version only — one object, version 2.
    try testing.expect(std.mem.indexOf(u8, mem_json, "\"memory_id\":\"m1\"") != null);
    try testing.expect(std.mem.indexOf(u8, mem_json, "\"version\":2") != null);
    try testing.expect(std.mem.indexOf(u8, mem_json, "\"version\":1") == null);
}

test "events compact context order and sqlite backup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var events = try EventsRepo.init(&db);
    defer events.deinit();
    try events.append(.{ .event_id = "e1", .ts = "t1", .type = "A", .source = "core", .severity = "INFO", .state_version = 1, .payload_json = "{}" });
    try events.append(.{ .event_id = "e2", .ts = "t2", .type = "B", .source = "core", .severity = "WARN", .state_version = 2, .payload_json = "{}" });
    try events.append(.{ .event_id = "e3", .ts = "t3", .type = "C", .source = "core", .severity = "DEBUG", .state_version = 3, .payload_json = "{}" });

    var backing: [1024]u8 = undefined;
    var ptrs: [8][]const u8 = undefined;
    const n = try events.listCompactForContext(&db, &backing, &ptrs);
    // DEBUG filtered out; oldest-first among INFO/WARN
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(std.mem.indexOf(u8, ptrs[0], "\"type\":\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, ptrs[1], "\"type\":\"B\"") != null);

    var bak_buf: [512:0]u8 = undefined;
    const bak = try std.fmt.bufPrintZ(&bak_buf, "{s}.bak", .{path});
    try backupToPath(&db, bak);
    var bak_db = try Db.open(bak);
    defer bak_db.close();
    try testing.expectEqual(@as(i64, 3), try bak_db.queryInt("SELECT COUNT(*) FROM events"));
}

test "self-review queries: proposals, fills join, equity marks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var events = try EventsRepo.init(&db);
    defer events.deinit();
    try events.append(.{ .event_id = "e1", .ts = "2026-08-13T10:00:00.000Z", .type = "AGENT_PROPOSAL_OK", .source = "agent", .severity = "INFO", .state_version = 1, .payload_json = "{\"decision_id\":\"dec_a\",\"action\":\"HOLD\"}" });
    try events.append(.{ .event_id = "e2", .ts = "2026-08-13T11:00:00.000Z", .type = "AGENT_TRIGGER", .source = "core", .severity = "DEBUG", .state_version = 2, .payload_json = "{}" });
    try events.append(.{ .event_id = "e3", .ts = "2026-08-13T12:00:00.000Z", .type = "AGENT_PROPOSAL_OK", .source = "agent", .severity = "INFO", .state_version = 3, .payload_json = "{\"decision_id\":\"dec_b\",\"action\":\"REBALANCE\"}" });

    var prop_backing: [2048]u8 = undefined;
    var prop_rows: [4]EventsRepo.ProposalRow = undefined;
    const pn = try events.listProposalsForContext(&db, &prop_backing, &prop_rows);
    // Only AGENT_PROPOSAL_OK rows, oldest first.
    try testing.expectEqual(@as(usize, 2), pn);
    try testing.expect(std.mem.indexOf(u8, prop_rows[0].payload, "dec_a") != null);
    try testing.expect(std.mem.indexOf(u8, prop_rows[1].payload, "dec_b") != null);
    try testing.expectEqualStrings("2026-08-13T10:00:00.000Z", prop_rows[0].ts);

    var orders = try OrdersRepo.init(&db);
    defer orders.deinit();
    try orders.upsert(.{
        .client_order_id = "ab01",
        .decision_id = "dec_b",
        .side = "buy",
        .qty = "0.0001",
        .price = "64000",
        .status = "FILLED",
        .created_ts = "2026-08-13T12:01:00.000Z",
        .updated_ts = "2026-08-13T12:01:05.000Z",
    });
    var fills = try FillsRepo.init(&db);
    defer fills.deinit();
    try fills.append(.{ .fill_id = "f1", .order_id = "ab01", .price = "64000", .qty = "0.0001", .fee = "0.006", .ts = "2026-08-13T12:01:05.000Z" });
    try orders.upsert(.{
        .client_order_id = "ab00",
        .decision_id = "dec_a",
        .side = "sell",
        .qty = "0.0002",
        .price = "63000",
        .status = "FILLED",
        .created_ts = "2026-08-13T09:00:00.000Z",
        .updated_ts = "2026-08-13T09:00:05.000Z",
    });
    try fills.append(.{ .fill_id = "f0", .order_id = "ab00", .price = "63000", .qty = "0.0002", .fee = "0.01", .ts = "2026-08-13T09:00:00.000Z" });

    var fill_backing: [1024]u8 = undefined;
    var fill_ptrs: [4][]const u8 = undefined;
    const fn_ = try fills.listCompactForContext(&db, &fill_backing, &fill_ptrs);
    try testing.expectEqual(@as(usize, 2), fn_);
    // Oldest first; each row carries side + decision_id from the joined order.
    try testing.expect(std.mem.indexOf(u8, fill_ptrs[0], "\"side\":\"sell\"") != null);
    try testing.expect(std.mem.indexOf(u8, fill_ptrs[0], "\"decision_id\":\"dec_a\"") != null);
    try testing.expect(std.mem.indexOf(u8, fill_ptrs[1], "\"side\":\"buy\"") != null);
    try testing.expect(std.mem.indexOf(u8, fill_ptrs[1], "\"decision_id\":\"dec_b\"") != null);

    var equity = try EquityRepo.init(&db);
    defer equity.deinit();
    try equity.append(.{ .ts = "2026-08-13T08:00:00.000Z", .interval = "1m", .equity = "99.0", .hwm = "100", .drawdown = "0.01", .cash = "50", .btc_value = "49" });
    try equity.append(.{ .ts = "2026-08-13T11:30:00.000Z", .interval = "1m", .equity = "99.7", .hwm = "100", .drawdown = "0.003", .cash = "50", .btc_value = "49.7" });

    var mark_buf: [128]u8 = undefined;
    const mark = try equity.equityMarkJson(&db, "1h", "2026-08-13T11:45:00.000Z", &mark_buf);
    try testing.expect(std.mem.indexOf(u8, mark, "\"ago\":\"1h\"") != null);
    try testing.expect(std.mem.indexOf(u8, mark, "\"equity\":\"99.7\"") != null);
    // Cutoff before any sample → NotFound.
    var mark_buf2: [128]u8 = undefined;
    try testing.expectError(DbError.NotFound, equity.equityMarkJson(&db, "7d", "2026-08-13T07:00:00.000Z", &mark_buf2));
}

test "review chats append, list, transcript and count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var repo = try ReviewChatsRepo.init(&db);
    defer repo.deinit();

    try repo.append(.{
        .decision_id = "dec_1",
        .anchor_ts = "2026-08-14T03:26:41.212Z",
        .role = "user",
        .content = "当时为什么 HOLD？\n有\"引号\"",
        .created_ts = "2026-08-14T04:00:00.000Z",
    });
    try repo.append(.{
        .decision_id = "dec_1",
        .anchor_ts = "2026-08-14T03:26:41.212Z",
        .role = "assistant",
        .content = "基于负基差与卖压占优。",
        .model = "test-model",
        .created_ts = "2026-08-14T04:00:10.000Z",
    });
    try repo.append(.{
        .decision_id = "dec_2",
        .role = "user",
        .content = "另一个决策",
        .created_ts = "2026-08-14T05:00:00.000Z",
    });

    try testing.expectEqual(@as(i64, 2), try repo.countForDecision(&db, "dec_1"));
    try testing.expectEqual(@as(i64, 0), try repo.countForDecision(&db, "dec_x"));

    var out: [4096]u8 = undefined;
    const j = try repo.listRecentJson(&db, &out, 10);
    // Newest first; quotes and newlines escaped.
    try testing.expect(std.mem.indexOf(u8, j, "\"decision_id\":\"dec_2\"") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\\\"引号\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"model\":\"test-model\"") != null);
    // Valid JSON array
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, j, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);

    var tr_buf: [1024]u8 = undefined;
    const tr = try repo.transcriptTail(&db, &tr_buf, "dec_1", 8);
    // Oldest first, role-prefixed lines.
    try testing.expect(std.mem.startsWith(u8, tr, "user: "));
    try testing.expect(std.mem.indexOf(u8, tr, "assistant: 基于负基差") != null);
}

test "events window query filters by ts range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);
    var db = try Db.open(path);
    defer db.close();

    var repo = try EventsRepo.init(&db);
    defer repo.deinit();
    try repo.append(.{ .event_id = "e1", .ts = "2026-08-14T02:00:00.000Z", .type = "MARKET_TICK", .source = "t", .severity = "INFO" });
    try repo.append(.{ .event_id = "e2", .ts = "2026-08-14T03:00:00.000Z", .type = "AGENT_PROPOSAL_OK", .source = "agent", .severity = "INFO", .payload_json = "{\"decision_id\":\"dec_9\",\"action\":\"HOLD\"}" });
    try repo.append(.{ .event_id = "e3", .ts = "2026-08-14T04:00:00.000Z", .type = "MARKET_TICK", .source = "t", .severity = "INFO" });

    var out: [2048]u8 = undefined;
    const j = try repo.listWindowJson(&db, &out, "2026-08-14T02:30:00.000Z", "2026-08-14T03:30:00.000Z", 10);
    try testing.expect(std.mem.indexOf(u8, j, "\"event_id\":\"e2\"") != null);
    try testing.expect(std.mem.indexOf(u8, j, "\"event_id\":\"e1\"") == null);
    try testing.expect(std.mem.indexOf(u8, j, "\"event_id\":\"e3\"") == null);

    var pl_buf: [512]u8 = undefined;
    const pl = try repo.proposalPayloadByDecision(&db, &pl_buf, "dec_9");
    try testing.expect(pl != null);
    try testing.expect(std.mem.indexOf(u8, pl.?, "\"action\":\"HOLD\"") != null);
    try testing.expect((try repo.proposalPayloadByDecision(&db, &pl_buf, "dec_none")) == null);
}

test "runtime_kv put/get round-trip and overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [512]u8 = undefined;
    const path = try tmpDbPath(&tmp, &buf);

    var db = try Db.open(path);
    defer db.close();
    var kv = try KvRepo.init(&db);
    defer kv.deinit();

    var out: [128]u8 = undefined;
    try testing.expect(kv.get("shadow_bh", &out) == null);

    try kv.put("shadow_bh", "v1|403.2|68624.9|0.00586|0.001", "2026-08-19T16:00:00.000Z");
    const v = kv.get("shadow_bh", &out).?;
    try testing.expectEqualStrings("v1|403.2|68624.9|0.00586|0.001", v);

    // Overwrite wins; unrelated key stays missing.
    try kv.put("shadow_bh", "v1|500|70000|0.007|0.001", "2026-08-19T17:00:00.000Z");
    const v2 = kv.get("shadow_bh", &out).?;
    try testing.expectEqualStrings("v1|500|70000|0.007|0.001", v2);
    try testing.expect(kv.get("other", &out) == null);

    // Value larger than out buffer fails closed.
    var tiny: [4]u8 = undefined;
    try testing.expect(kv.get("shadow_bh", &tiny) == null);
}
