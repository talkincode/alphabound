//! Minimal RFC 6455 WebSocket codec (§4.4 WS ingestion). Pure frame
//! encode/decode plus handshake key math — transport (TCP/TLS) is injected
//! elsewhere, so everything here is offline-testable.
//!
//! Client rules implemented: client frames are always masked, server frames
//! must not be masked; control frames ≤125 bytes; close/ping/pong handling
//! is the caller's job (codec only classifies).

const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Payload slice — points into the input buffer for decode (unmasked in
    /// place), or the caller's data for encode.
    payload: []u8,
};

pub const DecodeError = error{
    NeedMoreData,
    MaskedServerFrame,
    ControlFrameTooLong,
    ReservedBitsSet,
    PayloadTooLarge,
};

pub const max_payload = 4 * 1024 * 1024; // 4 MiB guard for a ticker feed

pub const Decoded = struct {
    frame: Frame,
    /// Total bytes consumed from the input.
    consumed: usize,
};

/// Decode one server→client frame from `buf`. The payload is a sub-slice of
/// `buf`. Returns NeedMoreData when the buffer holds only a partial frame.
pub fn decode(buf: []u8) DecodeError!Decoded {
    if (buf.len < 2) return DecodeError.NeedMoreData;
    const b0 = buf[0];
    const b1 = buf[1];
    if (b0 & 0x70 != 0) return DecodeError.ReservedBitsSet;
    const fin = b0 & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = b1 & 0x80 != 0;
    if (masked) return DecodeError.MaskedServerFrame;

    var len: u64 = b1 & 0x7F;
    var header_len: usize = 2;
    if (len == 126) {
        if (buf.len < 4) return DecodeError.NeedMoreData;
        len = std.mem.readInt(u16, buf[2..4], .big);
        header_len = 4;
    } else if (len == 127) {
        if (buf.len < 10) return DecodeError.NeedMoreData;
        len = std.mem.readInt(u64, buf[2..10], .big);
        header_len = 10;
    }
    if (opcode.isControl() and len > 125) return DecodeError.ControlFrameTooLong;
    if (len > max_payload) return DecodeError.PayloadTooLarge;
    const total = header_len + @as(usize, @intCast(len));
    if (buf.len < total) return DecodeError.NeedMoreData;

    return .{
        .frame = .{
            .fin = fin,
            .opcode = opcode,
            .payload = buf[header_len..total],
        },
        .consumed = total,
    };
}

/// Encoded frame size for a client→server frame with payload_len bytes.
pub fn encodedLen(payload_len: usize) usize {
    const ext: usize = if (payload_len < 126) 0 else if (payload_len <= 0xFFFF) 2 else 8;
    return 2 + ext + 4 + payload_len; // header + extended len + mask key + payload
}

/// Encode a masked client frame into `out`. Returns the written slice.
/// `mask_key` should come from a CSPRNG in production; injectable for tests.
pub fn encode(out: []u8, opcode: Opcode, payload: []const u8, mask_key: [4]u8, fin: bool) error{BufferTooSmall}![]u8 {
    const need = encodedLen(payload.len);
    if (out.len < need) return error.BufferTooSmall;

    out[0] = (if (fin) @as(u8, 0x80) else 0) | @intFromEnum(opcode);
    var idx: usize = 2;
    if (payload.len < 126) {
        out[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        out[1] = 0x80 | 126;
        std.mem.writeInt(u16, out[2..4], @intCast(payload.len), .big);
        idx = 4;
    } else {
        out[1] = 0x80 | 127;
        std.mem.writeInt(u64, out[2..10], payload.len, .big);
        idx = 10;
    }
    @memcpy(out[idx..][0..4], &mask_key);
    idx += 4;
    for (payload, 0..) |byte, i| {
        out[idx + i] = byte ^ mask_key[i % 4];
    }
    return out[0 .. idx + payload.len];
}

/// Unmask (or re-mask — XOR is symmetric) a payload in place.
pub fn applyMask(payload: []u8, mask_key: [4]u8) void {
    for (payload, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }
}

/// Sec-WebSocket-Accept = base64(SHA1(key ++ magic GUID)).
pub fn acceptKey(out: *[28]u8, client_key: []const u8) []const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(client_key);
    sha.update(magic);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// Generate the client handshake request lines (caller supplies random key).
pub fn handshakeRequest(
    out: []u8,
    host: []const u8,
    path: []const u8,
    key_b64: []const u8,
) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(out,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ path, host, key_b64 },
    );
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "decode unmasked server text frame" {
    // "Hello" example straight from RFC 6455 §5.7
    var buf = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const r = try decode(&buf);
    try testing.expect(r.frame.fin);
    try testing.expectEqual(Opcode.text, r.frame.opcode);
    try testing.expectEqualStrings("Hello", r.frame.payload);
    try testing.expectEqual(@as(usize, 7), r.consumed);
}

test "decode rejects masked server frame" {
    var buf = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try testing.expectError(DecodeError.MaskedServerFrame, decode(&buf));
}

test "decode needs more data on partial frame" {
    var buf = [_]u8{ 0x81, 0x05, 0x48 };
    try testing.expectError(DecodeError.NeedMoreData, decode(&buf));
    var hdr_only = [_]u8{0x81};
    try testing.expectError(DecodeError.NeedMoreData, decode(&hdr_only));
}

test "decode 16-bit extended length" {
    var buf: [4 + 300]u8 = undefined;
    buf[0] = 0x82; // fin binary
    buf[1] = 126;
    std.mem.writeInt(u16, buf[2..4], 300, .big);
    for (buf[4..], 0..) |*b, i| b.* = @truncate(i);
    const r = try decode(&buf);
    try testing.expectEqual(@as(usize, 300), r.frame.payload.len);
    try testing.expectEqual(Opcode.binary, r.frame.opcode);
}

test "encode round-trips through mask" {
    var out: [64]u8 = undefined;
    const written = try encode(&out, .text, "{\"op\":\"subscribe\"}", .{ 0x12, 0x34, 0x56, 0x78 }, true);
    // Client frame is masked; strip and verify payload
    try testing.expectEqual(@as(u8, 0x81), written[0]);
    try testing.expect(written[1] & 0x80 != 0); // mask bit
    const plen = written[1] & 0x7F;
    try testing.expectEqual(@as(u8, 18), plen);
    var payload_copy: [18]u8 = undefined;
    @memcpy(&payload_copy, written[6..24]);
    applyMask(&payload_copy, .{ 0x12, 0x34, 0x56, 0x78 });
    try testing.expectEqualStrings("{\"op\":\"subscribe\"}", &payload_copy);
}

test "control frame length guard" {
    var buf: [4 + 200]u8 = undefined;
    buf[0] = 0x89; // fin ping
    buf[1] = 126;
    std.mem.writeInt(u16, buf[2..4], 200, .big);
    try testing.expectError(DecodeError.ControlFrameTooLong, decode(&buf));
}

test "accept key matches RFC example" {
    var out: [28]u8 = undefined;
    const accept = acceptKey(&out, "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "handshake request shape" {
    var buf: [512]u8 = undefined;
    const req = try handshakeRequest(&buf, "ws.okx.com:8443", "/ws/v5/public", "dGhlIHNhbXBsZSBub25jZQ==");
    try testing.expect(std.mem.startsWith(u8, req, "GET /ws/v5/public HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13") != null);
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "fragmented message classification" {
    // fragment 1: fin=0 text; fragment 2: fin=1 continuation
    var f1 = [_]u8{ 0x01, 0x03, 'a', 'b', 'c' };
    var f2 = [_]u8{ 0x80, 0x02, 'd', 'e' };
    const r1 = try decode(&f1);
    try testing.expect(!r1.frame.fin);
    try testing.expectEqual(Opcode.text, r1.frame.opcode);
    const r2 = try decode(&f2);
    try testing.expect(r2.frame.fin);
    try testing.expectEqual(Opcode.continuation, r2.frame.opcode);
}
