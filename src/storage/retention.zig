//! Backup rotation and data-retention policy (AC-OPS3 / AC-OPS9).
//!
//! Pure decision logic, unit-testable without a filesystem or database:
//!   - hourly snapshots  <db>.hourly.YYYYMMDDHH.bak   keep 24
//!   - daily  snapshots  <db>.daily.YYYYMMDD.bak      keep 30
//!   - tool_calls rows older than 30 days are pruned
//!   - '1s' equity samples older than 7 days are pruned ('1m' kept forever)

const std = @import("std");
const clock = @import("../core/clock.zig");

pub const keep_hourly: usize = 24;
pub const keep_daily: usize = 30;
pub const tool_calls_days: i64 = 30;
pub const equity_1s_days: i64 = 7;

pub const hourly_infix = ".hourly.";
pub const daily_infix = ".daily.";
pub const backup_suffix = ".bak";

/// Format "<base>.hourly.YYYYMMDDHH.bak" from a UTC ms timestamp.
pub fn hourlyName(buf: []u8, base: []const u8, now_ms: i64) error{BufferTooSmall}![]const u8 {
    var ts: [32]u8 = undefined;
    const iso = clock.formatRfc3339Ms(now_ms, &ts) catch return error.BufferTooSmall;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}{s}{s}", .{
        base, hourly_infix, iso[0..4], iso[5..7], iso[8..10], iso[11..13], backup_suffix,
    }) catch error.BufferTooSmall;
}

/// Format "<base>.daily.YYYYMMDD.bak" from a UTC ms timestamp.
pub fn dailyName(buf: []u8, base: []const u8, now_ms: i64) error{BufferTooSmall}![]const u8 {
    var ts: [32]u8 = undefined;
    const iso = clock.formatRfc3339Ms(now_ms, &ts) catch return error.BufferTooSmall;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}{s}", .{
        base, daily_infix, iso[0..4], iso[5..7], iso[8..10], backup_suffix,
    }) catch error.BufferTooSmall;
}

/// True when `name` is a rotated backup of `base_name` with the given infix
/// (e.g. base_name="alphabound.db", infix=".hourly."). Matches file *names*,
/// not full paths.
pub fn isRotatedBackup(name: []const u8, base_name: []const u8, infix: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base_name)) return false;
    const rest = name[base_name.len..];
    if (!std.mem.startsWith(u8, rest, infix)) return false;
    const stamp = rest[infix.len..];
    if (!std.mem.endsWith(u8, stamp, backup_suffix)) return false;
    const digits = stamp[0 .. stamp.len - backup_suffix.len];
    if (digits.len < 8 or digits.len > 10) return false;
    for (digits) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Given rotated backup names (any order), select which to DELETE so only the
/// newest `keep` remain. Timestamps embed lexicographically-sortable digits,
/// so plain name ordering is age ordering. Returns slice of `out` with indexes
/// into `names`.
pub fn selectDoomed(names: []const []const u8, keep: usize, out: []usize) []const usize {
    const n = names.len;
    if (n <= keep) return out[0..0];
    const doomed_n = @min(n - keep, out.len);

    // Selection: repeatedly pick the oldest (lexicographically smallest) name.
    var used = [_]bool{false} ** 256;
    if (n > used.len) return out[0..0]; // absurd count; refuse rather than misbehave
    var k: usize = 0;
    while (k < doomed_n) : (k += 1) {
        var best: ?usize = null;
        for (names, 0..) |nm, i| {
            if (used[i]) continue;
            if (best == null or std.mem.lessThan(u8, nm, names[best.?])) best = i;
        }
        used[best.?] = true;
        out[k] = best.?;
    }
    return out[0..doomed_n];
}

/// SQL for pruning old tool_calls (RFC3339 text timestamps compare lexicographically).
pub const prune_tool_calls_sql =
    "DELETE FROM tool_calls WHERE ts < ?1";
/// SQL for pruning old 1s equity samples; '1m' rows are kept forever.
pub const prune_equity_1s_sql =
    "DELETE FROM equity_samples WHERE interval = '1s' AND ts < ?1";

/// RFC3339 cutoff string for "now − days".
pub fn cutoffRfc3339(buf: []u8, now_ms: i64, days: i64) error{BufferTooSmall}![]const u8 {
    const cutoff_ms = now_ms - days * 86_400_000;
    return clock.formatRfc3339Ms(cutoff_ms, buf) catch error.BufferTooSmall;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "backup names embed sortable UTC stamps" {
    var buf: [128]u8 = undefined;
    // 2026-08-12T03:37:21.787Z
    const ms: i64 = 1786505841787;
    const h = try hourlyName(&buf, "/var/lib/ab/alphabound.db", ms);
    try testing.expectEqualStrings("/var/lib/ab/alphabound.db.hourly.2026081203.bak", h);
    var buf2: [128]u8 = undefined;
    const d = try dailyName(&buf2, "/var/lib/ab/alphabound.db", ms);
    try testing.expectEqualStrings("/var/lib/ab/alphabound.db.daily.20260812.bak", d);
}

test "isRotatedBackup matches only well-formed rotated names" {
    try testing.expect(isRotatedBackup("alphabound.db.hourly.2026081203.bak", "alphabound.db", hourly_infix));
    try testing.expect(isRotatedBackup("alphabound.db.daily.20260812.bak", "alphabound.db", daily_infix));
    try testing.expect(!isRotatedBackup("alphabound.db.bak", "alphabound.db", hourly_infix));
    try testing.expect(!isRotatedBackup("alphabound.db.hourly.20260812xx.bak", "alphabound.db", hourly_infix));
    try testing.expect(!isRotatedBackup("other.db.hourly.2026081203.bak", "alphabound.db", hourly_infix));
    try testing.expect(!isRotatedBackup("alphabound.db.hourly.2026081203.bak.tmp", "alphabound.db", hourly_infix));
    // daily stamp used with hourly infix check must fail (8 digits ok for daily only)
    try testing.expect(!isRotatedBackup("alphabound.db.hourly.202608.bak", "alphabound.db", hourly_infix));
}

test "selectDoomed keeps the newest N" {
    const names = [_][]const u8{
        "db.hourly.2026081201.bak",
        "db.hourly.2026081123.bak", // oldest
        "db.hourly.2026081203.bak", // newest
        "db.hourly.2026081200.bak",
        "db.hourly.2026081202.bak",
    };
    var out: [16]usize = undefined;
    const doomed = selectDoomed(&names, 3, &out);
    try testing.expectEqual(@as(usize, 2), doomed.len);
    // Doomed = two oldest: 2026081123, 2026081200
    try testing.expectEqualStrings("db.hourly.2026081123.bak", names[doomed[0]]);
    try testing.expectEqualStrings("db.hourly.2026081200.bak", names[doomed[1]]);

    const none = selectDoomed(names[0..2], 24, &out);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "cutoff formatting and lexicographic comparability" {
    var buf: [40]u8 = undefined;
    const ms: i64 = 1786505841787; // 2026-08-12T03:37:21.787Z
    const cut7 = try cutoffRfc3339(&buf, ms, 7);
    try testing.expectEqualStrings("2026-08-05T03:37:21.787Z", cut7);
    // Text comparison works for retention: older < cutoff < newer.
    try testing.expect(std.mem.lessThan(u8, "2026-08-01T00:00:00.000Z", cut7));
    try testing.expect(std.mem.lessThan(u8, cut7, "2026-08-12T00:00:00.000Z"));
}

test "property: selectDoomed never deletes any of the newest keep names" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var storage: [40][24]u8 = undefined;
    var names: [40][]const u8 = undefined;
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        const n = random.intRangeAtMost(usize, 0, 40);
        for (0..n) |i| {
            const stamp = random.intRangeAtMost(u64, 2020010100, 2030123123);
            names[i] = std.fmt.bufPrint(&storage[i], "db.hourly.{d}.bak", .{stamp}) catch unreachable;
        }
        const keep = random.intRangeAtMost(usize, 0, 30);
        var out: [40]usize = undefined;
        const doomed = selectDoomed(names[0..n], keep, &out);
        if (n <= keep) {
            try testing.expectEqual(@as(usize, 0), doomed.len);
            continue;
        }
        try testing.expectEqual(n - keep, doomed.len);
        // Every doomed name must be ≤ every survivor (i.e. strictly not newer).
        var is_doomed = [_]bool{false} ** 40;
        for (doomed) |di| is_doomed[di] = true;
        for (doomed) |di| {
            for (0..n) |si| {
                if (is_doomed[si]) continue;
                try testing.expect(!std.mem.lessThan(u8, names[si], names[di]));
            }
        }
    }
}
