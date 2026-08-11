//! OKX private WebSocket protocol helpers (login + account channel).
//! Pure offline functions — no TLS/transport here. Runtime may send these
//! frames over a future WS client; shadow Gate 1 uses REST reconcile today
//! while these messages stay unit-tested and ready to wire.

const std = @import("std");
const auth = @import("auth.zig");
const dec = @import("../../core/decimal.zig");
const Decimal = dec.Decimal;

/// Private WS login signs: timestamp(seconds) + "GET" + "/users/self/verify"
pub const login_path = "/users/self/verify";

pub fn loginSign(
    out: *[auth.signature_len]u8,
    secret_key: []const u8,
    timestamp_sec: []const u8,
) []const u8 {
    return auth.sign(out, secret_key, timestamp_sec, .GET, login_path, "");
}

/// Build login JSON into `buf`. Never logs secrets; caller owns the slice.
pub fn formatLogin(
    buf: []u8,
    api_key: []const u8,
    passphrase: []const u8,
    timestamp_sec: []const u8,
    signature: []const u8,
) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "{{\"op\":\"login\",\"args\":[{{\"apiKey\":\"{s}\",\"passphrase\":\"{s}\",\"timestamp\":\"{s}\",\"sign\":\"{s}\"}}]}}",
        .{ api_key, passphrase, timestamp_sec, signature },
    ) catch return error.BufferTooSmall;
}

pub fn formatSubscribeAccount(buf: []u8) error{BufferTooSmall}![]const u8 {
    const msg = "{\"op\":\"subscribe\",\"args\":[{\"channel\":\"account\"}]}";
    if (buf.len < msg.len) return error.BufferTooSmall;
    @memcpy(buf[0..msg.len], msg);
    return buf[0..msg.len];
}

pub fn formatSubscribeBalanceAndPosition(buf: []u8) error{BufferTooSmall}![]const u8 {
    const msg = "{\"op\":\"subscribe\",\"args\":[{\"channel\":\"balance_and_position\"}]}";
    if (buf.len < msg.len) return error.BufferTooSmall;
    @memcpy(buf[0..msg.len], msg);
    return buf[0..msg.len];
}

pub const LoginAck = struct {
    ok: bool,
    code_buf: [32]u8 = undefined,
    code_len: usize = 0,
    msg_buf: [128]u8 = undefined,
    msg_len: usize = 0,

    pub fn code(self: *const LoginAck) []const u8 {
        return self.code_buf[0..self.code_len];
    }

    pub fn msg(self: *const LoginAck) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }
};

/// Parse login / subscribe event ack: {"event":"login","code":"0",...}
pub fn parseEventAck(gpa: std.mem.Allocator, body: []const u8) error{Malformed}!LoginAck {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    const obj = parsed.value.object;
    const code_v = obj.get("code") orelse return error.Malformed;
    const code_s = switch (code_v) {
        .string => |s| s,
        else => return error.Malformed,
    };
    var ack = LoginAck{
        .ok = std.mem.eql(u8, code_s, "0"),
    };
    if (code_s.len > ack.code_buf.len) return error.Malformed;
    @memcpy(ack.code_buf[0..code_s.len], code_s);
    ack.code_len = code_s.len;
    if (obj.get("msg")) |mv| {
        const msg_s = switch (mv) {
            .string => |s| s,
            else => "",
        };
        const n = @min(msg_s.len, ack.msg_buf.len);
        @memcpy(ack.msg_buf[0..n], msg_s[0..n]);
        ack.msg_len = n;
    }
    return ack;
}

pub const AccountPush = struct {
    usdt_cash: Decimal = Decimal.zero,
    usdt_avail: Decimal = Decimal.zero,
    btc_cash: Decimal = Decimal.zero,
    btc_avail: Decimal = Decimal.zero,
};

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getDec(obj: std.json.ObjectMap, key: []const u8) ?Decimal {
    const s = getString(obj, key) orelse return null;
    return Decimal.parse(s) catch null;
}

/// Parse account / balance_and_position push payloads (data array of details).
pub fn parseAccountPush(gpa: std.mem.Allocator, body: []const u8) error{Malformed}!AccountPush {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    const root = parsed.value.object;

    var out = AccountPush{};
    _ = root.get("arg");

    const data_v = root.get("data") orelse return error.Malformed;
    const data = switch (data_v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    if (data.items.len == 0) return out;

    // account channel: data[0].details[]
    // balance_and_position: data[0].balData[]
    const first = switch (data.items[0]) {
        .object => |o| o,
        else => return error.Malformed,
    };

    const details_key: []const u8 = if (first.get("details") != null) "details" else "balData";
    const details_v = first.get(details_key) orelse {
        // Some pushes put ccy rows directly in data[]
        for (data.items) |item| {
            const row = switch (item) {
                .object => |o| o,
                else => continue,
            };
            applyCcy(&out, row);
        }
        return out;
    };
    const details = switch (details_v) {
        .array => |a| a,
        else => return error.Malformed,
    };
    for (details.items) |item| {
        const row = switch (item) {
            .object => |o| o,
            else => continue,
        };
        applyCcy(&out, row);
    }
    return out;
}

fn applyCcy(out: *AccountPush, row: std.json.ObjectMap) void {
    const ccy = getString(row, "ccy") orelse return;
    // cashBal preferred; fallback eq/availBal fields used by balData
    const cash = getDec(row, "cashBal") orelse getDec(row, "eq") orelse Decimal.zero;
    const avail = getDec(row, "availBal") orelse getDec(row, "availEq") orelse cash;
    if (std.mem.eql(u8, ccy, "USDT")) {
        out.usdt_cash = cash;
        out.usdt_avail = avail;
    } else if (std.mem.eql(u8, ccy, "BTC")) {
        out.btc_cash = cash;
        out.btc_avail = avail;
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "login sign uses REST-style HMAC over WS path" {
    var out_a: [auth.signature_len]u8 = undefined;
    var out_b: [auth.signature_len]u8 = undefined;
    const sig = loginSign(&out_a, "22582BD0CFF14C41EDBF1AB98506286D", "1607418537");
    const expected = auth.sign(&out_b, "22582BD0CFF14C41EDBF1AB98506286D", "1607418537", .GET, login_path, "");
    try testing.expectEqualStrings(expected, sig);
    try testing.expect(sig.len == auth.signature_len);
}

test "formatLogin embeds args without leaking structure errors" {
    var buf: [512]u8 = undefined;
    const msg = try formatLogin(&buf, "key", "pp", "1607418537", "SIG==");
    try testing.expect(std.mem.indexOf(u8, msg, "\"op\":\"login\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"apiKey\":\"key\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"sign\":\"SIG==\"") != null);
}

test "parse login ack ok and fail" {
    const ok = try parseEventAck(testing.allocator,
        \\{"event":"login","code":"0","msg":""}
    );
    try testing.expect(ok.ok);
    const bad = try parseEventAck(testing.allocator,
        \\{"event":"error","code":"60009","msg":"Login failed"}
    );
    try testing.expect(!bad.ok);
    try testing.expectEqualStrings("60009", bad.code());
}

test "parse account push extracts USDT/BTC" {
    const body =
        \\{"arg":{"channel":"account","uid":"1"},"data":[{"details":[
        \\  {"ccy":"USDT","cashBal":"100","availBal":"90"},
        \\  {"ccy":"BTC","cashBal":"0.01","availBal":"0.01"}
        \\]}]}
    ;
    const push = try parseAccountPush(testing.allocator, body);
    try testing.expect(push.usdt_cash.eql(d("100")));
    try testing.expect(push.usdt_avail.eql(d("90")));
    try testing.expect(push.btc_cash.eql(d("0.01")));
}

test "subscribe helpers are stable JSON" {
    var buf: [128]u8 = undefined;
    const a = try formatSubscribeAccount(&buf);
    try testing.expectEqualStrings("{\"op\":\"subscribe\",\"args\":[{\"channel\":\"account\"}]}", a);
}
