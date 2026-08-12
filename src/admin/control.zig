//! Local admin control via a small JSON file next to the DB (§ FR-10).
//! Commands are written by `alphabound --control …` and consumed by the daemon
//! loop. No network surface — path is local filesystem only.

const std = @import("std");

pub const Cmd = enum {
    none,
    pause,
    /// CLI accepts "resume"; enum avoids Zig keyword `resume`.
    unpause,
    reconcile,
    /// Cancel open orders (demo/live). Shadow: audit-only, no exchange calls.
    cancel_all,
    /// Force risk mode toward FLATTENING (operator exit).
    flatten,
    /// Operator path probe: admit+execute toward a target BTC weight (demo/live).
    target_weight,
    shutdown,

    pub fn fromString(s: []const u8) ?Cmd {
        if (std.mem.eql(u8, s, "pause")) return .pause;
        if (std.mem.eql(u8, s, "resume") or std.mem.eql(u8, s, "unpause")) return .unpause;
        if (std.mem.eql(u8, s, "reconcile")) return .reconcile;
        if (std.mem.eql(u8, s, "cancel-all") or std.mem.eql(u8, s, "cancel_all")) return .cancel_all;
        if (std.mem.eql(u8, s, "flatten")) return .flatten;
        if (std.mem.eql(u8, s, "target-weight") or std.mem.eql(u8, s, "target_weight")) return .target_weight;
        if (std.mem.eql(u8, s, "shutdown") or std.mem.eql(u8, s, "safe-shutdown")) return .shutdown;
        if (std.mem.eql(u8, s, "status")) return .none;
        return null;
    }

    pub fn text(self: Cmd) []const u8 {
        return switch (self) {
            .none => "none",
            .pause => "pause",
            .unpause => "resume",
            .reconcile => "reconcile",
            .cancel_all => "cancel-all",
            .flatten => "flatten",
            .target_weight => "target-weight",
            .shutdown => "shutdown",
        };
    }
};

pub const Request = struct {
    cmd: Cmd = .none,
    ts_ms: i64 = 0,
    /// Optional weight string for target-weight (e.g. "0.05"). Empty = absent.
    weight_buf: [32]u8 = undefined,
    weight_len: usize = 0,

    pub fn weight(self: *const Request) ?[]const u8 {
        if (self.weight_len == 0) return null;
        return self.weight_buf[0..self.weight_len];
    }
};

pub fn pathFromDb(db_path: []const u8, out: []u8) error{BufferTooSmall}![]const u8 {
    if (std.mem.endsWith(u8, db_path, ".db")) {
        const base = db_path[0 .. db_path.len - 3];
        return std.fmt.bufPrint(out, "{s}.control", .{base}) catch return error.BufferTooSmall;
    }
    return std.fmt.bufPrint(out, "{s}.control", .{db_path}) catch return error.BufferTooSmall;
}

pub fn pathStateFromDb(db_path: []const u8, out: []u8) error{BufferTooSmall}![]const u8 {
    if (std.mem.endsWith(u8, db_path, ".db")) {
        const base = db_path[0 .. db_path.len - 3];
        return std.fmt.bufPrint(out, "{s}.control.state", .{base}) catch return error.BufferTooSmall;
    }
    return std.fmt.bufPrint(out, "{s}.control.state", .{db_path}) catch return error.BufferTooSmall;
}

pub fn formatRequest(buf: []u8, cmd: Cmd, ts_ms: i64) error{BufferTooSmall}![]const u8 {
    return formatRequestWeight(buf, cmd, ts_ms, null);
}

pub fn formatRequestWeight(buf: []u8, cmd: Cmd, ts_ms: i64, weight: ?[]const u8) error{BufferTooSmall}![]const u8 {
    if (weight) |w| {
        return std.fmt.bufPrint(
            buf,
            "{{\"cmd\":\"{s}\",\"weight\":\"{s}\",\"ts_ms\":{d}}}\n",
            .{ cmd.text(), w, ts_ms },
        ) catch return error.BufferTooSmall;
    }
    return std.fmt.bufPrint(buf, "{{\"cmd\":\"{s}\",\"ts_ms\":{d}}}\n", .{ cmd.text(), ts_ms }) catch return error.BufferTooSmall;
}

/// Parse CLI tokens like `target-weight=0.05` / `target-weight:0.05` / bare `pause`.
pub fn parseControlArg(arg: []const u8) struct { cmd: ?Cmd, weight: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        const name = arg[0..eq];
        const w = arg[eq + 1 ..];
        return .{ .cmd = Cmd.fromString(name), .weight = if (w.len > 0) w else null };
    }
    if (std.mem.indexOfScalar(u8, arg, ':')) |col| {
        // Only split on ':' for target-weight forms; bare cmds never contain ':'.
        const name = arg[0..col];
        if (Cmd.fromString(name) == .target_weight) {
            const w = arg[col + 1 ..];
            return .{ .cmd = .target_weight, .weight = if (w.len > 0) w else null };
        }
    }
    return .{ .cmd = Cmd.fromString(arg), .weight = null };
}

pub fn parseRequest(raw: []const u8) Request {
    var req: Request = .{};
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return req;

    if (std.mem.indexOf(u8, trimmed, "\"cmd\"")) |ci| {
        const after = trimmed[ci + 5 ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            const rest = after[q1 + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |q2| {
                const name = rest[0..q2];
                req.cmd = Cmd.fromString(name) orelse .none;
            }
        }
    }
    if (std.mem.indexOf(u8, trimmed, "\"ts_ms\"")) |ti| {
        const after = trimmed[ti + 7 ..];
        var i: usize = 0;
        while (i < after.len and (after[i] == ' ' or after[i] == ':' or after[i] == '\t')) : (i += 1) {}
        var j = i;
        while (j < after.len and after[j] >= '0' and after[j] <= '9') : (j += 1) {}
        if (j > i) {
            req.ts_ms = std.fmt.parseInt(i64, after[i..j], 10) catch 0;
        }
    }
    if (std.mem.indexOf(u8, trimmed, "\"weight\"")) |wi| {
        const after = trimmed[wi + 8 ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            const rest = after[q1 + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |q2| {
                const w = rest[0..q2];
                const n = @min(w.len, req.weight_buf.len);
                @memcpy(req.weight_buf[0..n], w[0..n]);
                req.weight_len = n;
            }
        }
    }
    return req;
}

pub const State = struct {
    paused: bool = false,
    last_cmd: Cmd = .none,
    last_ts_ms: i64 = 0,
    ready: bool = false,
};

pub fn formatState(buf: []u8, s: State) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"paused\":{},\"last_cmd\":\"{s}\",\"last_ts_ms\":{d},\"ready\":{}}}\n",
        .{ s.paused, s.last_cmd.text(), s.last_ts_ms, s.ready },
    ) catch return error.BufferTooSmall;
}

pub fn parseState(raw: []const u8) State {
    var s: State = .{};
    if (std.mem.indexOf(u8, raw, "\"paused\":true") != null) s.paused = true;
    if (std.mem.indexOf(u8, raw, "\"ready\":true") != null) s.ready = true;
    if (std.mem.indexOf(u8, raw, "\"last_cmd\"")) |ci| {
        const after = raw[ci + 10 ..];
        if (std.mem.indexOfScalar(u8, after, '"')) |q1| {
            const rest = after[q1 + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |q2| {
                s.last_cmd = Cmd.fromString(rest[0..q2]) orelse .none;
            }
        }
    }
    return s;
}

pub fn writeFile(io: std.Io, path: []const u8, contents: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = contents,
        .flags = .{ .truncate = true },
    });
}

pub fn readFile(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    return std.Io.Dir.cwd().readFile(io, path, buf) catch |err| switch (err) {
        error.FileNotFound => buf[0..0],
        else => err,
    };
}

pub fn consumeRequest(io: std.Io, path: []const u8, buf: []u8) !Request {
    const raw = try readFile(io, path, buf);
    if (raw.len == 0) return .{};
    const req = parseRequest(raw);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return req;
}

const testing = std.testing;

test "pathFromDb strips db suffix" {
    var buf: [128]u8 = undefined;
    const p = try pathFromDb("var/trading.db", &buf);
    try testing.expectEqualStrings("var/trading.control", p);
}

test "parse and format request roundtrip" {
    var buf: [128]u8 = undefined;
    const s = try formatRequest(&buf, .pause, 42);
    const r = parseRequest(s);
    try testing.expect(r.cmd == .pause);
    try testing.expectEqual(@as(i64, 42), r.ts_ms);
    const s2 = try formatRequest(&buf, .unpause, 1);
    try testing.expect(parseRequest(s2).cmd == .unpause);
    try testing.expect(Cmd.fromString("cancel-all").? == .cancel_all);
    try testing.expect(Cmd.fromString("flatten").? == .flatten);
    const s3 = try formatRequest(&buf, .flatten, 9);
    try testing.expect(parseRequest(s3).cmd == .flatten);
    const s4 = try formatRequestWeight(&buf, .target_weight, 7, "0.05");
    const r4 = parseRequest(s4);
    try testing.expect(r4.cmd == .target_weight);
    try testing.expectEqualStrings("0.05", r4.weight().?);
    const a = parseControlArg("target-weight=0.10");
    try testing.expect(a.cmd == .target_weight);
    try testing.expectEqualStrings("0.10", a.weight.?);
}

test "parse state paused" {
    const s = parseState("{\"paused\":true,\"last_cmd\":\"pause\",\"ready\":true}\n");
    try testing.expect(s.paused);
    try testing.expect(s.ready);
    try testing.expect(s.last_cmd == .pause);
}
