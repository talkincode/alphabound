//! Online SQLite backup, rotated snapshots, retention sweep, and the
//! read-only restore-drill verifier (AC-OPS3/4/9). Extracted from main.zig.

const std = @import("std");
const storage = @import("db.zig");
const retention = @import("retention.zig");
const config = @import("../config.zig");
const state = @import("../core/state.zig");
const dec = @import("../core/decimal.zig");
const clock = @import("../core/clock.zig");
const journal = @import("../observability/journal.zig");

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

/// AC-OPS4 restore drill: read-only verification of a backup snapshot.
/// Exit 0 = verifiable (integrity ok, schema current, projections readable).
pub fn verifyDbSnapshot(path: []const u8) u8 {
    var path_buf: [640:0]u8 = undefined;
    const zpath = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
        std.debug.print("[verify-db] path too long\n", .{});
        return 1;
    };
    var db = storage.Db.openReadOnly(zpath) catch {
        std.debug.print("[verify-db] FAIL open read-only: {s}\n", .{path});
        return 1;
    };
    defer db.close();

    var fails: u8 = 0;

    // 1. Page-level integrity.
    {
        var stmt = db.prepare("PRAGMA integrity_check") catch {
            std.debug.print("[verify-db] FAIL integrity_check prepare\n", .{});
            return 1;
        };
        defer stmt.finalize();
        const row = stmt.step() catch false;
        const verdict = if (row) stmt.columnText(0) else "no-result";
        if (!std.mem.eql(u8, verdict, "ok")) {
            std.debug.print("[verify-db] FAIL integrity_check: {s}\n", .{verdict});
            fails += 1;
        } else {
            std.debug.print("[verify-db] integrity_check ok\n", .{});
        }
    }

    // 2. Schema version matches this binary's migrations.
    {
        const uv = db.queryInt("PRAGMA user_version") catch -1;
        if (uv != storage.expected_user_version) {
            std.debug.print("[verify-db] FAIL user_version {d} != expected {d}\n", .{ uv, storage.expected_user_version });
            fails += 1;
        } else {
            std.debug.print("[verify-db] user_version {d} ok\n", .{uv});
        }
    }

    // 3. Core projections are present and readable.
    const events = db.queryInt("SELECT COUNT(*) FROM events") catch -1;
    const orders = db.queryInt("SELECT COUNT(*) FROM orders") catch -1;
    const fills = db.queryInt("SELECT COUNT(*) FROM fills") catch -1;
    const equity = db.queryInt("SELECT COUNT(*) FROM equity_samples") catch -1;
    const runs = db.queryInt("SELECT COUNT(*) FROM agent_runs") catch -1;
    const mems = db.queryInt("SELECT COUNT(*) FROM memories") catch -1;
    std.debug.print(
        "[verify-db] counts events={d} orders={d} fills={d} equity_samples={d} agent_runs={d} memories={d}\n",
        .{ events, orders, fills, equity, runs, mems },
    );
    if (events < 0 or orders < 0 or fills < 0 or equity < 0 or runs < 0 or mems < 0) {
        std.debug.print("[verify-db] FAIL missing core table(s)\n", .{});
        fails += 1;
    }

    // 4. Event sequence sane: ids unique (PK) and seq strictly positive range.
    if (events > 0) {
        const min_seq = db.queryInt("SELECT MIN(seq) FROM events") catch -1;
        const max_seq = db.queryInt("SELECT MAX(seq) FROM events") catch -1;
        if (min_seq < 1 or max_seq < min_seq) {
            std.debug.print("[verify-db] FAIL event seq range min={d} max={d}\n", .{ min_seq, max_seq });
            fails += 1;
        } else {
            std.debug.print("[verify-db] event seq {d}..{d} ok\n", .{ min_seq, max_seq });
        }
    }

    // 5. HWM restorable: latest sample parses as a non-negative decimal.
    if (equity > 0) {
        var stmt = db.prepare("SELECT hwm FROM equity_samples ORDER BY ts DESC LIMIT 1") catch {
            std.debug.print("[verify-db] FAIL hwm query\n", .{});
            return fails + 1;
        };
        defer stmt.finalize();
        if (stmt.step() catch false) {
            const hwm_text = stmt.columnText(0);
            const hwm = dec.Decimal.parse(hwm_text) catch {
                std.debug.print("[verify-db] FAIL hwm unparseable: {s}\n", .{hwm_text});
                fails += 1;
                return fails;
            };
            if (hwm.isNegative()) {
                std.debug.print("[verify-db] FAIL hwm negative\n", .{});
                fails += 1;
            } else {
                std.debug.print("[verify-db] hwm {s} restorable\n", .{hwm_text});
            }
        }
    }

    // 6. Audit chain (AC-GO5): every order traceable to its decision event
    //    (decision_id → AGENT_PROPOSAL_OK or ADMIN_TARGET_WEIGHT payload),
    //    stamped with config_hash/software_version, covered by ORDER_* events;
    //    fills must reference a known order. Operator probes use dec_op_* + ADMIN_*.
    {
        const o_no_dec = db.queryInt(
            "SELECT COUNT(*) FROM orders WHERE decision_id = ''",
        ) catch -1;
        const o_no_proposal = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
            \\  SELECT 1 FROM events e
            \\  WHERE e.type IN ('AGENT_PROPOSAL_OK','ADMIN_TARGET_WEIGHT')
            \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0)
        ) catch -1;
        const o_unstamped_dec = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE EXISTS (
            \\  SELECT 1 FROM events e
            \\  WHERE e.type IN ('AGENT_PROPOSAL_OK','ADMIN_TARGET_WEIGHT')
            \\  AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0
            \\  AND (e.config_hash = '' OR e.software_version = ''))
        ) catch -1;
        const o_no_events = db.queryInt(
            \\SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (
            \\  SELECT 1 FROM events e WHERE e.type LIKE 'ORDER_%'
            \\  AND instr(e.payload_json, o.client_order_id) > 0)
        ) catch -1;
        const orphan_fills = db.queryInt(
            \\SELECT COUNT(*) FROM fills f WHERE NOT EXISTS (
            \\  SELECT 1 FROM orders o WHERE o.client_order_id = f.order_id)
        ) catch -1;
        if (o_no_dec != 0 or o_no_proposal != 0 or o_unstamped_dec != 0 or
            o_no_events != 0 or orphan_fills != 0)
        {
            std.debug.print(
                "[verify-db] FAIL audit chain: no_decision_id={d} no_proposal_event={d} unstamped_decision={d} no_order_events={d} orphan_fills={d}\n",
                .{ o_no_dec, o_no_proposal, o_unstamped_dec, o_no_events, orphan_fills },
            );
            fails += 1;
        } else {
            std.debug.print("[verify-db] audit chain ok ({d} orders, {d} fills)\n", .{ orders, fills });
        }
    }

    if (fails == 0) {
        std.debug.print("[verify-db] PASS {s}\n", .{path});
        return 0;
    }
    std.debug.print("[verify-db] FAIL {d} check(s): {s}\n", .{ fails, path });
    return 1;
}

pub fn runSqliteBackup(
    io: std.Io,
    db: *storage.Db,
    cfg: *const config.Config,
    engine: *state.Engine,
    events_repo: *storage.EventsRepo,
) void {
    // Latest pointer: <db_path>.bak (same directory); online Backup API.
    var dest_buf: [640:0]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&dest_buf, "{s}.bak", .{cfg.db_path}) catch {
        std.debug.print("[backup] path too long\n", .{});
        return;
    };
    storage.backupToPath(db, dest) catch |err| {
        std.debug.print("[backup] failed: {t}\n", .{err});
        var err_buf: [160]u8 = undefined;
        const payload = std.fmt.bufPrint(&err_buf, "{{\"dest\":\"{s}\",\"ok\":false}}", .{dest}) catch "{\"ok\":false}";
        journal.logEventPayload(events_repo, engine, "BACKUP_FAILED", "storage", "WARN", cfg, payload);
        return;
    };
    std.debug.print("[backup] ok {s}\n", .{dest});
    var ok_buf: [200]u8 = undefined;
    const payload = std.fmt.bufPrint(&ok_buf, "{{\"dest\":\"{s}\",\"ok\":true}}", .{dest}) catch "{\"ok\":true}";
    journal.logEventPayload(events_repo, engine, "BACKUP_DONE", "storage", "INFO", cfg, payload);

    // AC-OPS3/OPS9: rotated snapshots + retention sweep.
    const now_ms = nowMs();
    rotateBackups(io, db, cfg, now_ms);
    runRetentionSweep(db, now_ms);
}

/// Hourly/daily rotated snapshots next to the DB, pruned to the newest
/// retention.keep_hourly / keep_daily. Best-effort: failures only log.
fn rotateBackups(io: std.Io, db: *storage.Db, cfg: *const config.Config, now_ms: i64) void {
    var name_buf: [600]u8 = undefined;
    var z_buf: [640:0]u8 = undefined;

    // Hourly snapshot (same stamp within the hour → cheap overwrite skip).
    if (retention.hourlyName(&name_buf, cfg.db_path, now_ms)) |hourly| {
        if (std.fmt.bufPrintZ(&z_buf, "{s}", .{hourly})) |zdest| {
            if (!fileExists(io, zdest)) {
                storage.backupToPath(db, zdest) catch |err|
                    std.debug.print("[backup] hourly failed: {t}\n", .{err});
            }
        } else |_| {}
    } else |_| {}

    // Daily snapshot: write once per UTC day.
    if (retention.dailyName(&name_buf, cfg.db_path, now_ms)) |daily| {
        if (std.fmt.bufPrintZ(&z_buf, "{s}", .{daily})) |zdest| {
            if (!fileExists(io, zdest)) {
                storage.backupToPath(db, zdest) catch |err|
                    std.debug.print("[backup] daily failed: {t}\n", .{err});
            }
        } else |_| {}
    } else |_| {}

    pruneRotated(io, cfg.db_path, retention.hourly_infix, retention.keep_hourly);
    pruneRotated(io, cfg.db_path, retention.daily_infix, retention.keep_daily);
}

fn fileExists(io: std.Io, path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Delete rotated backups beyond the newest `keep` for the given infix.
fn pruneRotated(io: std.Io, db_path: []const u8, infix: []const u8, keep: usize) void {
    const dir_path = std.fs.path.dirname(db_path) orelse ".";
    const base_name = std.fs.path.basename(db_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    const max_names = 64;
    var name_storage: [max_names][320]u8 = undefined;
    var names: [max_names][]const u8 = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!retention.isRotatedBackup(entry.name, base_name, infix)) continue;
        if (n >= max_names or entry.name.len > name_storage[n].len) continue;
        @memcpy(name_storage[n][0..entry.name.len], entry.name);
        names[n] = name_storage[n][0..entry.name.len];
        n += 1;
    }

    var out: [max_names]usize = undefined;
    const doomed = retention.selectDoomed(names[0..n], keep, &out);
    for (doomed) |idx| {
        dir.deleteFile(io, names[idx]) catch |err|
            std.debug.print("[backup] prune {s} failed: {t}\n", .{ names[idx], err });
    }
}

/// AC-OPS9: prune old tool_calls rows and '1s' equity samples.
fn runRetentionSweep(db: *storage.Db, now_ms: i64) void {
    var cut_buf: [40]u8 = undefined;

    if (retention.cutoffRfc3339(&cut_buf, now_ms, retention.tool_calls_days)) |cutoff| {
        var stmt = db.prepare(retention.prune_tool_calls_sql) catch return;
        defer stmt.finalize();
        stmt.bindText(1, cutoff) catch return;
        _ = stmt.step() catch |err|
            std.debug.print("[retention] tool_calls prune failed: {t}\n", .{err});
    } else |_| {}

    if (retention.cutoffRfc3339(&cut_buf, now_ms, retention.equity_1s_days)) |cutoff| {
        var stmt = db.prepare(retention.prune_equity_1s_sql) catch return;
        defer stmt.finalize();
        stmt.bindText(1, cutoff) catch return;
        _ = stmt.step() catch |err|
            std.debug.print("[retention] equity_1s prune failed: {t}\n", .{err});
    } else |_| {}
}

