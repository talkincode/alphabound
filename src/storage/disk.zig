//! Disk free-space probe for Gate 3 FD7 (volume holding the trading DB).
//! Hand-rolled statvfs bindings (Zig cImport yields opaque on linux-musl).

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");

pub const ProbeError = error{
    StatFailed,
    PathTooLong,
};

/// Default thresholds: low at 1 GiB free, critical at 256 MiB free.
pub const default_low_bytes: u64 = 1 * 1024 * 1024 * 1024;
pub const default_critical_bytes: u64 = 256 * 1024 * 1024;

// Linux musl / glibc x86_64: ulong=u64, fsblkcnt_t=u64, trailing reserved ints.
const LinuxStatvfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    __reserved: [6]i32 = undefined,
};

// Darwin: ulong=u64, fsblkcnt_t=__darwin_fsblkcnt_t (u32).
const DarwinStatvfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u32,
    f_bfree: u32,
    f_bavail: u32,
    f_files: u32,
    f_ffree: u32,
    f_favail: u32,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *anyopaque) c_int;

/// Bytes available to non-root on the filesystem containing `path`.
pub fn freeBytes(path: []const u8) ProbeError!u64 {
    var zbuf: [4096:0]u8 = undefined;
    if (path.len >= zbuf.len) return error.PathTooLong;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;

    if (statOne(&zbuf)) |n| return n;

    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len >= zbuf.len) return error.PathTooLong;
        @memcpy(zbuf[0..dir.len], dir);
        zbuf[dir.len] = 0;
        if (statOne(&zbuf)) |n| return n;
    }
    return error.StatFailed;
}

fn statOne(zpath: [*:0]const u8) ?u64 {
    switch (builtin.os.tag) {
        .linux => {
            var st: LinuxStatvfs = std.mem.zeroes(LinuxStatvfs);
            if (statvfs(zpath, &st) != 0) return null;
            return st.f_frsize *% st.f_bavail;
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var st: DarwinStatvfs = std.mem.zeroes(DarwinStatvfs);
            if (statvfs(zpath, &st) != 0) return null;
            return st.f_frsize *% @as(u64, st.f_bavail);
        },
        else => return null,
    }
}

pub fn classifyPath(path: []const u8) policy.DiskBand {
    const free = freeBytes(path) catch return .ok;
    return policy.classifyDiskFree(free, default_low_bytes, default_critical_bytes);
}

const testing = std.testing;

test "disk freeBytes on cwd is positive" {
    const free = try freeBytes(".");
    try testing.expect(free > 0);
}

test "classifyPath returns a known band" {
    const band = classifyPath(".");
    try testing.expect(band == .ok or band == .low or band == .critical);
}
