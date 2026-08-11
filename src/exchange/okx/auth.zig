//! OKX API v5 request signing (§4.4). Pure functions — no network here.
//! prehash = timestamp + METHOD + requestPath[?query] + body
//! sign    = base64(HMAC-SHA256(secret, prehash))
//!
//! Credentials live only in this exchange adapter layer; nothing above it
//! (agent, tools, web) ever sees them (§2.3 boundary).

const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const Method = enum {
    GET,
    POST,

    pub fn text(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
        };
    }
};

pub const Credentials = struct {
    api_key: []const u8,
    secret_key: []const u8,
    passphrase: []const u8,
};

pub const signature_len = std.base64.standard.Encoder.calcSize(HmacSha256.mac_length);

/// Compute the OK-ACCESS-SIGN value into `out` (fixed 44 bytes for SHA-256).
pub fn sign(
    out: *[signature_len]u8,
    secret_key: []const u8,
    timestamp: []const u8,
    method: Method,
    request_path: []const u8,
    body: []const u8,
) []const u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var ctx = HmacSha256.init(secret_key);
    ctx.update(timestamp);
    ctx.update(method.text());
    ctx.update(request_path);
    ctx.update(body);
    ctx.final(&mac);
    return std.base64.standard.Encoder.encode(out, &mac);
}

/// OKX REST timestamp: RFC3339 UTC with millisecond precision.
/// Reuses the core clock formatter (already emits the exact shape).
pub const formatTimestamp = @import("../../core/clock.zig").formatRfc3339Ms;

pub const HeaderSet = struct {
    timestamp_buf: [32]u8 = undefined,
    sign_buf: [signature_len]u8 = undefined,
    timestamp: []const u8 = "",
    signature: []const u8 = "",

    /// Compose all OK-ACCESS-* header values for one request.
    pub fn build(
        self: *HeaderSet,
        creds: Credentials,
        now_ms: i64,
        method: Method,
        request_path: []const u8,
        body: []const u8,
    ) void {
        self.timestamp = formatTimestamp(now_ms, &self.timestamp_buf) catch unreachable;
        self.signature = sign(&self.sign_buf, creds.secret_key, self.timestamp, method, request_path, body);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "known vector: GET balance (OKX docs shape)" {
    var out: [signature_len]u8 = undefined;
    const sig = sign(
        &out,
        "22582BD0CFF14C41EDBF1AB98506286D",
        "2020-12-08T09:08:57.715Z",
        .GET,
        "/api/v5/account/balance?ccy=BTC",
        "",
    );
    try testing.expectEqualStrings("HiZhvSfMtWJA3uUIVXV3a/bSXNPCWvYFXoGCVS8V4zY=", sig);
}

test "known vector: POST order with JSON body" {
    var out: [signature_len]u8 = undefined;
    const body =
        \\{"instId":"BTC-USDT","tdMode":"cash","side":"buy","ordType":"limit","px":"100000","sz":"0.001","clOrdId":"ab0102030405060708090a0b0c0d0e"}
    ;
    const sig = sign(
        &out,
        "22582BD0CFF14C41EDBF1AB98506286D",
        "2026-01-02T03:04:05.678Z",
        .POST,
        "/api/v5/trade/order",
        body,
    );
    try testing.expectEqualStrings("AnLuStsnNlK9sN6UqHer99lfGkZKGJTjeFYQ5npum3A=", sig);
}

test "header set builds timestamp and signature together" {
    var hs = HeaderSet{};
    hs.build(.{
        .api_key = "key",
        .secret_key = "22582BD0CFF14C41EDBF1AB98506286D",
        .passphrase = "pp",
    }, 1607418537715, .GET, "/api/v5/account/balance?ccy=BTC", "");
    try testing.expectEqualStrings("2020-12-08T09:08:57.715Z", hs.timestamp);
    try testing.expectEqualStrings("HiZhvSfMtWJA3uUIVXV3a/bSXNPCWvYFXoGCVS8V4zY=", hs.signature);
}

test "signature differs when any component changes" {
    var a: [signature_len]u8 = undefined;
    var b: [signature_len]u8 = undefined;
    const base = sign(&a, "secret", "2026-01-01T00:00:00.000Z", .GET, "/api/v5/public/time", "");
    const diff_path = sign(&b, "secret", "2026-01-01T00:00:00.000Z", .GET, "/api/v5/public/timex", "");
    try testing.expect(!std.mem.eql(u8, base, diff_path));
    var c2: [signature_len]u8 = undefined;
    const diff_method = sign(&c2, "secret", "2026-01-01T00:00:00.000Z", .POST, "/api/v5/public/time", "");
    try testing.expect(!std.mem.eql(u8, base, diff_method));
}
