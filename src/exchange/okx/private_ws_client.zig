//! OKX private WebSocket transport (Gate 1): TLS connect → handshake → login
//! → subscribe account → optional one push. Shadow never places orders.
//!
//! Prefer reusing an already-warmed `std.http.Client` (REST client instance)
//! so system CA / `now` are already loaded.

const std = @import("std");
const auth = @import("auth.zig");
const codec = @import("ws.zig");
const proto = @import("private_ws.zig");

pub const Error = error{
    ConnectFailed,
    HandshakeFailed,
    LoginFailed,
    SubscribeFailed,
    ReadFailed,
    WriteFailed,
    Timeout,
    OutOfMemory,
    BufferTooSmall,
};

pub const ProbeResult = struct {
    login_ok: bool = false,
    subscribed: bool = false,
    push_seen: bool = false,
    detail: []const u8 = "",
};

pub const default_host = "ws.okx.com";
pub const default_port: u16 = 8443;
pub const default_path = "/ws/v5/private";

fn failDetail(out: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(out, fmt, args) catch "probe_failed";
}

/// One-shot private WS probe using a **warmed** HTTP client (CA + now set).
/// `out_detail` backs the returned `detail` slice.
pub fn probe(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    creds: auth.Credentials,
    now_ms: i64,
    out_detail: []u8,
) Error!ProbeResult {
    if (client.now == null) {
        const now = std.Io.Clock.real.now(client.io);
        client.ca_bundle.rescan(gpa, client.io, now) catch {
            return softFail(out_detail, "ca_rescan_failed");
        };
        client.now = now;
    }

    // Prefer IPv4 literals to avoid long IPv6 blackhole stalls on some networks.
    // SNI/Host still use ws.okx.com via proxied_host.
    const sni = std.Io.net.HostName{ .bytes = default_host };
    const ipv4_literals = [_][]const u8{ "172.64.144.82", "104.18.43.174" };
    const conn = blk: {
        for (ipv4_literals) |ip| {
            const hip = std.Io.net.HostName{ .bytes = ip };
            if (client.connectTcpOptions(.{
                .host = hip,
                .port = default_port,
                .protocol = .tls,
                .proxied_host = sni,
                .proxied_port = default_port,
            })) |c| break :blk c else |_| continue;
        }
        // Fallback: hostname (may be slow if AAAA blackholes).
        break :blk client.connectTcp(sni, default_port, .tls) catch {
            return softFail(out_detail, "connect_tls_failed");
        };
    };
    defer {
        conn.closing = true;
        client.connection_pool.release(conn, client.io);
    }

    // --- HTTP upgrade (Host without non-default-port form; Cloudflare OKX accepts both) ---
    var key_raw: [16]u8 = undefined;
    client.io.random(&key_raw);
    var key_b64_buf: [32]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, &key_raw);

    var hs_buf: [640]u8 = undefined;
    const hs = std.fmt.bufPrint(
        &hs_buf,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Origin: https://www.okx.com\r\n" ++
            "User-Agent: alphabound/0.1\r\n\r\n",
        .{ default_path, default_host, key_b64 },
    ) catch return error.BufferTooSmall;

    {
        const w = conn.writer();
        w.writeAll(hs) catch return softFail(out_detail, "handshake_write_failed");
        conn.flush() catch return softFail(out_detail, "handshake_flush_failed");
    }

    var resp_buf: [4096]u8 = undefined;
    var resp_len: usize = 0;
    const r = conn.reader();
    var read_rounds: usize = 0;
    while (resp_len < resp_buf.len and read_rounds < 64) : (read_rounds += 1) {
        const n = r.readSliceShort(resp_buf[resp_len..]) catch {
            return softFail(out_detail, "handshake_read_failed");
        };
        if (n == 0) break;
        resp_len += n;
        if (std.mem.indexOf(u8, resp_buf[0..resp_len], "\r\n\r\n")) |_| break;
    }
    const resp = resp_buf[0..resp_len];
    if (resp_len == 0) return softFail(out_detail, "handshake_empty");
    if (std.mem.indexOf(u8, resp, "101") == null) {
        // Capture status line for journal (no secrets).
        const line_end = std.mem.indexOf(u8, resp, "\r\n") orelse @min(resp.len, 48);
        const status = resp[0..line_end];
        return .{ .detail = failDetail(out_detail, "handshake_not_101:{s}", .{status}) };
    }

    var stream_buf: [8192]u8 = undefined;
    var stream_len: usize = 0;
    if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |hdr_end| {
        const body_start = hdr_end + 4;
        if (body_start < resp_len) {
            const leftover = resp[body_start..resp_len];
            if (leftover.len > stream_buf.len) return error.BufferTooSmall;
            @memcpy(stream_buf[0..leftover.len], leftover);
            stream_len = leftover.len;
        }
    }

    // --- Login ---
    // Brief post-upgrade settle: some TLS stacks still finish the 101 flight
    // before accepting the first WS data frame. Busy-poll a few empty reads.
    {
        var settle: usize = 0;
        while (settle < 4) : (settle += 1) {
            var tmp: [1]u8 = undefined;
            const n = conn.reader().readSliceShort(&tmp) catch break;
            if (n == 0) break;
            if (stream_len + n <= stream_buf.len) {
                @memcpy(stream_buf[stream_len .. stream_len + n], tmp[0..n]);
                stream_len += n;
            }
        }
    }

    var ts_sec_buf: [32]u8 = undefined;
    const ts_sec = std.fmt.bufPrint(&ts_sec_buf, "{d}", .{@divFloor(now_ms, 1000)}) catch return error.BufferTooSmall;
    var sig_buf: [auth.signature_len]u8 = undefined;
    const sig = proto.loginSign(&sig_buf, creds.secret_key, ts_sec);
    var login_buf: [512]u8 = undefined;
    const login_json = proto.formatLogin(&login_buf, creds.api_key, creds.passphrase, ts_sec, sig) catch return error.BufferTooSmall;

    // Encode login frame and capture header for diagnostics (no secrets).
    var mask: [4]u8 = undefined;
    client.io.random(&mask);
    var frame_out: [1024]u8 = undefined;
    const login_frame = codec.encode(&frame_out, .text, login_json, mask, true) catch return error.BufferTooSmall;
    {
        const w = conn.writer();
        w.writeAll(login_frame) catch return softFail(out_detail, "login_write_failed");
        conn.flush() catch return softFail(out_detail, "login_flush_failed");
        // Second flush: some http.Client paths buffer until a subsequent flush.
        conn.flush() catch {};
    }

    const login_payload = readTextFrame(conn, &stream_buf, &stream_len) catch {
        // Dump stream buffer head for diagnosis (binary-safe hex).
        var hex: [48]u8 = undefined;
        const n = @min(stream_len, 16);
        const hexed = std.fmt.bufPrint(&hex, "{x}", .{stream_buf[0..n]}) catch "xx";
        var hdr_hex: [24]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_hex, "{x}", .{login_frame[0..@min(login_frame.len, 8)]}) catch "??";
        return .{
            .detail = failDetail(
                out_detail,
                "login_read_failed frame_len={d} json_len={d} buf_len={d} head={s} hdr={s}",
                .{ login_frame.len, login_json.len, stream_len, hexed, hdr },
            ),
        };
    };
    const login_ack = proto.parseEventAck(gpa, login_payload) catch {
        return .{ .detail = failDetail(out_detail, "login_ack_malformed", .{}) };
    };
    if (!login_ack.ok) {
        return .{
            .login_ok = false,
            .detail = failDetail(out_detail, "login_code_{s}", .{login_ack.code()}),
        };
    }

    // --- Subscribe account ---
    var sub_buf: [128]u8 = undefined;
    const sub = proto.formatSubscribeAccount(&sub_buf) catch return error.BufferTooSmall;
    sendText(conn, sub) catch return softFail(out_detail, "subscribe_write_failed");

    var subscribed = false;
    var push_seen = false;
    var usdt_note: []const u8 = "";

    var reads: usize = 0;
    while (reads < 6) : (reads += 1) {
        const payload = readTextFrame(conn, &stream_buf, &stream_len) catch break;
        if (std.mem.indexOf(u8, payload, "\"event\":\"subscribe\"") != null) {
            if (std.mem.indexOf(u8, payload, "\"code\":\"0\"") != null or
                std.mem.indexOf(u8, payload, "\"channel\":\"account\"") != null)
            {
                subscribed = true;
            }
        }
        if (std.mem.indexOf(u8, payload, "\"data\"") != null) {
            if (proto.parseAccountPush(gpa, payload)) |push| {
                push_seen = true;
                subscribed = true;
                usdt_note = failDetail(out_detail, "push_usdt={f}", .{push.usdt_cash});
            } else |_| {
                push_seen = true;
                subscribed = true;
            }
        }
        if (std.mem.indexOf(u8, payload, "\"event\":\"error\"") != null) {
            return .{
                .login_ok = true,
                .subscribed = subscribed,
                .detail = failDetail(out_detail, "ws_error_frame", .{}),
            };
        }
        if (subscribed and push_seen) break;
    }

    if (usdt_note.len == 0) {
        return .{
            .login_ok = true,
            .subscribed = subscribed,
            .push_seen = push_seen,
            .detail = failDetail(out_detail, "login_ok subscribed={} push={}", .{ subscribed, push_seen }),
        };
    }
    return .{
        .login_ok = true,
        .subscribed = true,
        .push_seen = push_seen,
        .detail = usdt_note,
    };
}

fn softFail(out: []u8, tag: []const u8) ProbeResult {
    return .{ .detail = failDetail(out, "{s}", .{tag}) };
}

fn sendText(conn: *std.http.Client.Connection, payload: []const u8) Error!void {
    var mask: [4]u8 = undefined;
    conn.client.io.random(&mask);

    var out: [1024]u8 = undefined;
    const frame = codec.encode(&out, .text, payload, mask, true) catch return error.BufferTooSmall;
    const w = conn.writer();
    w.writeAll(frame) catch return error.WriteFailed;
    conn.flush() catch return error.WriteFailed;
}

fn readTextFrame(conn: *std.http.Client.Connection, buf: []u8, filled: *usize) Error![]u8 {
    const r = conn.reader();
    var spins: usize = 0;
    while (spins < 256) : (spins += 1) {
        if (filled.* >= 2) {
            if (codec.decode(buf[0..filled.*])) |decoded| {
                if (decoded.frame.opcode == .ping) {
                    var pong_out: [128]u8 = undefined;
                    var mask: [4]u8 = undefined;
                    conn.client.io.random(&mask);
                    if (codec.encode(&pong_out, .pong, decoded.frame.payload, mask, true)) |pf| {
                        conn.writer().writeAll(pf) catch {};
                        conn.flush() catch {};
                    } else |_| {}
                    const rest = filled.* - decoded.consumed;
                    if (rest > 0) std.mem.copyForwards(u8, buf[0..rest], buf[decoded.consumed..filled.*]);
                    filled.* = rest;
                    continue;
                }
                if (decoded.frame.opcode == .text or decoded.frame.opcode == .binary) {
                    const payload = decoded.frame.payload;
                    const payload_len = payload.len;
                    var tmp: [4096]u8 = undefined;
                    if (payload_len > tmp.len) return error.BufferTooSmall;
                    @memcpy(tmp[0..payload_len], payload);
                    const rest = filled.* - decoded.consumed;
                    if (rest > 0) std.mem.copyForwards(u8, buf[payload_len .. payload_len + rest], buf[decoded.consumed..filled.*]);
                    @memcpy(buf[0..payload_len], tmp[0..payload_len]);
                    filled.* = payload_len + rest;
                    return buf[0..payload_len];
                }
                if (decoded.frame.opcode == .close) return error.ReadFailed;
                const rest = filled.* - decoded.consumed;
                if (rest > 0) std.mem.copyForwards(u8, buf[0..rest], buf[decoded.consumed..filled.*]);
                filled.* = rest;
                continue;
            } else |err| switch (err) {
                error.NeedMoreData => {},
                else => return error.ReadFailed,
            }
        }
        if (filled.* >= buf.len) return error.BufferTooSmall;
        const n = r.readSliceShort(buf[filled.*..]) catch return error.ReadFailed;
        if (n == 0) return error.ReadFailed;
        filled.* += n;
    }
    return error.Timeout;
}


test "encode login-sized frame header" {
    var out: [256]u8 = undefined;
    var payload: [200]u8 = @splat('x');
    const f = try codec.encode(&out, .text, &payload, .{ 1, 2, 3, 4 }, true);
    try std.testing.expectEqual(@as(u8, 0x81), f[0]);
    try std.testing.expectEqual(@as(u8, 0xFE), f[1]); // masked + 126
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, f[2..4], .big));
    try std.testing.expectEqual(@as(usize, 208), f.len);
}
