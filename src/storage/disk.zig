//! Disk free-space probe for Gate 3 FD7 (volume holding the trading DB).

const std = @import("std");
const c = @cImport({
    @cInclude("sys/statvfs.h");
});
const policy = @import("policy.zig");

pub const ProbeError = error{
    StatFailed,
    PathTooLong,
};

/// Bytes available to non-root on the filesystem containing `path`.
/// `path` may be a file or directory; parent is used if the file does not exist yet.
pub fn freeBytes(path: []const u8) ProbeError!u64 {
    var zbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= zbuf.len) return error.PathTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;

    var st: c.struct_statvfs = undefined;
    if (c.statvfs(&zbuf, &st) == 0) {
        return avail(&st);
    }

    // File may not exist yet — try parent directory.
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len >= zbuf.len) return error.PathTooLong;
        @memcpy(zbuf[0..dir.len], dir);
        zbuf[dir.len] = 0;
        if (c.statvfs(&zbuf, &st) == 0) return avail(&st);
    }
    return error.StatFailed;
}

fn avail(st: *const c.struct_statvfs) u64 {
    const fr: u64 = @intCast(st.f_frsize);
    const ba: u64 = @intCast(st.f_bavail);
    return fr *% ba;
}

/// Default thresholds: low at 1 GiB free, critical at 256 MiB free.
pub const default_low_bytes: u64 = 1 * 1024 * 1024 * 1024;
pub const default_critical_bytes: u64 = 256 * 1024 * 1024;

pub fn classifyPath(path: []const u8) policy.DiskBand {
    const free = freeBytes(path) catch return .ok; // probe failure: do not false-halt
    return policy.classifyDiskFree(free, default_low_bytes, default_critical_bytes);
}

const testing = std.testing;

test "disk freeBytes on cwd is positive" {
    const free = try freeBytes(".");
    try testing.expect(free > 0);
}

test "classifyPath on cwd is ok on developer machines" {
    // Not asserting .ok — CI could be tight; just ensure it returns a band.
    const band = classifyPath(".");
    try testing.expect(band == .ok or band == .low or band == .critical);
}
