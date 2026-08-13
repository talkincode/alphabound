//! Dashboard / API authentication.
//!
//! - Bearer / X-API-Token for MCP and scripts
//! - HMAC session cookie for browser after token or passkey login
//! - When `api_token` is empty, auth is disabled (local dev / loopback)

const std = @import("std");
const crypto = std.crypto;
const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;

pub const cookie_name = "ab_session";
pub const max_token_len = 128;
pub const session_ttl_ms: i64 = 7 * 24 * 60 * 60 * 1000; // 7d

pub const Config = struct {
    /// Empty ⇒ auth disabled (all routes open).
    api_token: []const u8 = "",
    /// HMAC key for session cookies (32 bytes).
    session_secret: [32]u8 = [_]u8{0} ** 32,
    /// WebAuthn rpId (hostname), e.g. "localhost" or dashboard host.
    rp_id: []const u8 = "localhost",
    /// Expected origin, e.g. "http://127.0.0.1:8080" (no trailing slash).
    origin: []const u8 = "http://127.0.0.1:8080",

    pub fn required(self: Config) bool {
        return self.api_token.len > 0;
    }
};

pub fn deriveSessionSecret(api_token: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    if (api_token.len == 0) {
        // Distinct non-secret default only used when auth disabled.
        const label = "alphabound-auth-disabled";
        crypto.hash.sha2.Sha256.hash(label, &out, .{});
        return out;
    }
    HmacSha256.create(&out, "alphabound-session-v1", api_token);
    return out;
}

pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len == 0) return true;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

/// Extract API token from Authorization: Bearer … or X-API-Token.
pub fn tokenFromHeaders(authorization: ?[]const u8, x_api_token: ?[]const u8) ?[]const u8 {
    if (x_api_token) |t| {
        const trimmed = std.mem.trim(u8, t, " \t");
        if (trimmed.len > 0) return trimmed;
    }
    if (authorization) |h| {
        if (h.len > 7 and std.ascii.eqlIgnoreCase(h[0..7], "Bearer ")) {
            const t = std.mem.trim(u8, h[7..], " \t");
            if (t.len > 0) return t;
        }
    }
    return null;
}

pub fn tokenValid(cfg: Config, presented: []const u8) bool {
    if (!cfg.required()) return true;
    return constantTimeEql(cfg.api_token, presented);
}

/// Session payload: base64url(exp_ms) || "." || base64url(mac16)
pub fn mintSession(cfg: Config, now_ms: i64, out: []u8) error{BufferTooSmall}![]const u8 {
    const exp = now_ms + session_ttl_ms;
    var exp_buf: [32]u8 = undefined;
    const exp_s = std.fmt.bufPrint(&exp_buf, "{d}", .{exp}) catch return error.BufferTooSmall;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, exp_s, &cfg.session_secret);

    var exp_b64: [48]u8 = undefined;
    const exp_e = std.base64.url_safe_no_pad.Encoder.calcSize(exp_s.len);
    if (exp_e > exp_b64.len) return error.BufferTooSmall;
    _ = std.base64.url_safe_no_pad.Encoder.encode(exp_b64[0..exp_e], exp_s);

    var mac_b64: [32]u8 = undefined;
    const mac_slice = mac[0..16];
    const mac_e = std.base64.url_safe_no_pad.Encoder.calcSize(mac_slice.len);
    if (mac_e > mac_b64.len) return error.BufferTooSmall;
    _ = std.base64.url_safe_no_pad.Encoder.encode(mac_b64[0..mac_e], mac_slice);

    return std.fmt.bufPrint(out, "{s}.{s}", .{ exp_b64[0..exp_e], mac_b64[0..mac_e] }) catch error.BufferTooSmall;
}

pub fn verifySession(cfg: Config, cookie_val: []const u8, now_ms: i64) bool {
    const dot = std.mem.indexOfScalar(u8, cookie_val, '.') orelse return false;
    const exp_b64 = cookie_val[0..dot];
    const mac_b64 = cookie_val[dot + 1 ..];
    if (exp_b64.len == 0 or mac_b64.len == 0) return false;

    var exp_raw: [32]u8 = undefined;
    const exp_n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(exp_b64) catch return false;
    if (exp_n > exp_raw.len) return false;
    std.base64.url_safe_no_pad.Decoder.decode(exp_raw[0..exp_n], exp_b64) catch return false;
    const exp_s = exp_raw[0..exp_n];
    const exp = std.fmt.parseInt(i64, exp_s, 10) catch return false;
    if (now_ms > exp) return false;

    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, exp_s, &cfg.session_secret);
    var mac_raw: [16]u8 = undefined;
    const mac_n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(mac_b64) catch return false;
    if (mac_n != 16) return false;
    std.base64.url_safe_no_pad.Decoder.decode(&mac_raw, mac_b64) catch return false;
    return constantTimeEql(mac[0..16], &mac_raw);
}

/// Parse Cookie header for ab_session=value.
pub fn sessionFromCookieHeader(cookie_header: ?[]const u8) ?[]const u8 {
    const h = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, h, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        if (p.len > cookie_name.len + 1 and std.mem.startsWith(u8, p, cookie_name) and p[cookie_name.len] == '=') {
            return p[cookie_name.len + 1 ..];
        }
    }
    return null;
}

pub const AuthResult = enum { ok, unauthorized, disabled_open };

pub fn authorize(cfg: Config, authorization: ?[]const u8, x_api_token: ?[]const u8, cookie_header: ?[]const u8, now_ms: i64) AuthResult {
    if (!cfg.required()) return .disabled_open;
    if (tokenFromHeaders(authorization, x_api_token)) |t| {
        if (tokenValid(cfg, t)) return .ok;
        return .unauthorized;
    }
    if (sessionFromCookieHeader(cookie_header)) |s| {
        if (verifySession(cfg, s, now_ms)) return .ok;
    }
    return .unauthorized;
}

pub fn setCookieHeader(session: []const u8, secure: bool, out: []u8) error{BufferTooSmall}![]const u8 {
    // Path=/; HttpOnly; SameSite=Strict; Max-Age=7d; Secure (HTTPS only)
    if (secure) {
        return std.fmt.bufPrint(
            out,
            "{s}={s}; Path=/; HttpOnly; SameSite=Strict; Secure; Max-Age={d}",
            .{ cookie_name, session, @divTrunc(session_ttl_ms, 1000) },
        ) catch error.BufferTooSmall;
    }
    return std.fmt.bufPrint(
        out,
        "{s}={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age={d}",
        .{ cookie_name, session, @divTrunc(session_ttl_ms, 1000) },
    ) catch error.BufferTooSmall;
}

pub fn cookieSecure(cfg: Config) bool {
    return std.mem.startsWith(u8, cfg.origin, "https://");
}

fn bytesToHexLower(out: []u8, bytes: []const u8) []const u8 {
    const hex = "0123456789abcdef";
    std.debug.assert(out.len >= bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out[0 .. bytes.len * 2];
}

pub fn clearCookieHeader(out: []u8) error{BufferTooSmall}![]const u8 {
    return std.fmt.bufPrint(out, "{s}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0", .{cookie_name}) catch error.BufferTooSmall;
}

// -- Passkey credential store (file-backed JSON lines) -----------------------

pub const Credential = struct {
    /// Base64url credential id
    id_b64: []u8,
    /// Uncompressed SEC1 public key (65 bytes: 0x04||X||Y)
    pub_sec1: [65]u8,
    sign_count: u32,
};

/// File-backed passkey store. Touched only from the single-threaded web accept loop
/// (plus one boot-time `load` before the web thread starts).
pub const CredStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    items: std.ArrayList(Credential) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) CredStore {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(self: *CredStore) void {
        for (self.items.items) |c| self.gpa.free(c.id_b64);
        self.items.deinit(self.gpa);
    }

    pub fn load(self: *CredStore) void {
        var buf: [64 * 1024]u8 = undefined;
        const data = std.Io.Dir.cwd().readFile(self.io, self.path, &buf) catch return;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len < 8) continue;
            var parts = std.mem.splitScalar(u8, line, ' ');
            const id = parts.next() orelse continue;
            const pk_hex = parts.next() orelse continue;
            const sc_s = parts.next() orelse "0";
            if (pk_hex.len != 130) continue; // 65 bytes hex
            var sec1: [65]u8 = undefined;
            _ = std.fmt.hexToBytes(&sec1, pk_hex) catch continue;
            const id_copy = self.gpa.dupe(u8, id) catch continue;
            const sc: u32 = std.fmt.parseInt(u32, sc_s, 10) catch 0;
            self.items.append(self.gpa, .{ .id_b64 = id_copy, .pub_sec1 = sec1, .sign_count = sc }) catch {
                self.gpa.free(id_copy);
            };
        }
    }

    fn persist(self: *CredStore) void {
        var file_buf: [64 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&file_buf);
        var hex_buf: [130]u8 = undefined;
        for (self.items.items) |c| {
            const hex = bytesToHexLower(&hex_buf, &c.pub_sec1);
            w.print("{s} {s} {d}\n", .{ c.id_b64, hex, c.sign_count }) catch return;
        }
        const data = w.buffered();
        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = data,
            .flags = .{ .truncate = true },
        }) catch {};
    }

    pub fn count(self: *const CredStore) usize {
        return self.items.items.len;
    }

    pub fn add(self: *CredStore, id_b64: []const u8, pub_sec1: [65]u8) !void {
        for (self.items.items) |c| {
            if (std.mem.eql(u8, c.id_b64, id_b64)) return error.Duplicate;
        }
        const id_copy = try self.gpa.dupe(u8, id_b64);
        try self.items.append(self.gpa, .{ .id_b64 = id_copy, .pub_sec1 = pub_sec1, .sign_count = 0 });
        self.persist();
    }

    pub fn find(self: *const CredStore, id_b64: []const u8) ?Credential {
        for (self.items.items) |c| {
            if (std.mem.eql(u8, c.id_b64, id_b64)) return c;
        }
        return null;
    }

    pub fn listIdsJson(self: *const CredStore, buf: []u8) error{BufferTooSmall}![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll("[") catch return error.BufferTooSmall;
        for (self.items.items, 0..) |c, i| {
            if (i > 0) w.writeAll(",") catch return error.BufferTooSmall;
            w.print("\"{s}\"", .{c.id_b64}) catch return error.BufferTooSmall;
        }
        w.writeAll("]") catch return error.BufferTooSmall;
        return w.buffered();
    }

    pub fn allowCredentialsJson(self: *const CredStore, buf: []u8) error{BufferTooSmall}![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll("[") catch return error.BufferTooSmall;
        for (self.items.items, 0..) |c, i| {
            if (i > 0) w.writeAll(",") catch return error.BufferTooSmall;
            w.print("{{\"type\":\"public-key\",\"id\":\"{s}\"}}", .{c.id_b64}) catch return error.BufferTooSmall;
        }
        w.writeAll("]") catch return error.BufferTooSmall;
        return w.buffered();
    }
};

// -- WebAuthn helpers --------------------------------------------------------

pub const ChallengeSlot = struct {
    bytes: [32]u8 = undefined,
    exp_ms: i64 = 0,
    used: bool = false,
};

/// Single-use WebAuthn challenges (web thread only).
pub const ChallengeBank = struct {
    io: std.Io,
    slots: [16]ChallengeSlot = [_]ChallengeSlot{.{}} ** 16,

    pub fn init(io: std.Io) ChallengeBank {
        return .{ .io = io };
    }

    pub fn issue(self: *ChallengeBank, now_ms: i64, out_b64: []u8) error{BufferTooSmall}![]const u8 {
        var raw: [32]u8 = undefined;
        self.io.random(&raw);
        var idx: usize = 0;
        var oldest = self.slots[0].exp_ms;
        for (self.slots, 0..) |s, i| {
            if (!s.used or s.exp_ms < now_ms) {
                idx = i;
                break;
            }
            if (s.exp_ms < oldest) {
                oldest = s.exp_ms;
                idx = i;
            }
        }
        self.slots[idx] = .{ .bytes = raw, .exp_ms = now_ms + 5 * 60 * 1000, .used = true };
        const n = std.base64.url_safe_no_pad.Encoder.calcSize(raw.len);
        if (n > out_b64.len) return error.BufferTooSmall;
        return std.base64.url_safe_no_pad.Encoder.encode(out_b64[0..n], &raw);
    }

    pub fn consume(self: *ChallengeBank, challenge_b64: []const u8, now_ms: i64) bool {
        var raw: [32]u8 = undefined;
        const need = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(challenge_b64) catch return false;
        if (need != 32) return false;
        std.base64.url_safe_no_pad.Decoder.decode(&raw, challenge_b64) catch return false;
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (now_ms > s.exp_ms) {
                s.used = false;
                continue;
            }
            if (constantTimeEql(&s.bytes, &raw)) {
                s.used = false;
                return true;
            }
        }
        return false;
    }
};

/// Extract uncompressed P-256 SEC1 key from SPKI DER (SubjectPublicKeyInfo).
pub fn sec1FromSpki(spki: []const u8) ?[65]u8 {
    // Prefer trailing 65-byte uncompressed point.
    if (spki.len >= 65) {
        const off = spki.len - 65;
        if (spki[off] == 0x04) {
            var out: [65]u8 = undefined;
            @memcpy(&out, spki[off..][0..65]);
            return out;
        }
    }
    // Scan for 0x04 followed by 64 bytes inside buffer.
    if (spki.len < 65) return null;
    var i: usize = 0;
    while (i + 65 <= spki.len) : (i += 1) {
        if (spki[i] == 0x04) {
            var out: [65]u8 = undefined;
            @memcpy(&out, spki[i..][0..65]);
            return out;
        }
    }
    return null;
}

/// Extract a JSON string field value by exact key. Byte-exact match only —
/// no unescaping, which is fine for type/origin/challenge fields the browser
/// emits without escapes.
fn clientDataField(client_data_json: []const u8, comptime name: []const u8) ?[]const u8 {
    const key = "\"" ++ name ++ "\":\"";
    const pos = std.mem.indexOf(u8, client_data_json, key) orelse return null;
    const start = pos + key.len;
    const end = std.mem.indexOfScalar(u8, client_data_json[start..], '"') orelse return null;
    return client_data_json[start .. start + end];
}

pub fn verifyWebAuthnAssertion(
    pub_sec1: [65]u8,
    authenticator_data: []const u8,
    client_data_json: []const u8,
    sig_der: []const u8,
    expected_challenge_b64: []const u8,
    expected_origin: []const u8,
    expected_rp_id: []const u8,
    challenge_bank: *ChallengeBank,
    now_ms: i64,
) bool {
    // Exact field matches — substring search would let `webauthn.create`
    // ceremonies or origin-prefix lookalikes (`http://host.evil.com`) pass.
    const typ = clientDataField(client_data_json, "type") orelse return false;
    if (!std.mem.eql(u8, typ, "webauthn.get")) return false;
    const origin = clientDataField(client_data_json, "origin") orelse return false;
    if (!std.mem.eql(u8, origin, expected_origin)) return false;
    const ch_b64 = clientDataField(client_data_json, "challenge") orelse return false;
    if (!std.mem.eql(u8, ch_b64, expected_challenge_b64)) return false;
    // Challenge must be one we issued (single-use).
    if (!challenge_bank.consume(ch_b64, now_ms)) return false;
    if (authenticator_data.len < 37) return false;
    // rpIdHash must match SHA-256(rpId) and the User Present flag must be set.
    var rp_hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(expected_rp_id, &rp_hash, .{});
    if (!constantTimeEql(authenticator_data[0..32], &rp_hash)) return false;
    if (authenticator_data[32] & 0x01 == 0) return false;

    var cd_hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(client_data_json, &cd_hash, .{});

    var msg_buf: [2048]u8 = undefined;
    if (authenticator_data.len + cd_hash.len > msg_buf.len) return false;
    @memcpy(msg_buf[0..authenticator_data.len], authenticator_data);
    @memcpy(msg_buf[authenticator_data.len..][0..cd_hash.len], &cd_hash);
    const msg = msg_buf[0 .. authenticator_data.len + cd_hash.len];

    const pk = Ecdsa.PublicKey.fromSec1(&pub_sec1) catch return false;
    // WebAuthn ES256 signatures are commonly DER; some platforms emit raw r||s (64).
    const sig = if (Ecdsa.Signature.fromDer(sig_der)) |s| s else |_| blk: {
        if (sig_der.len != 64) return false;
        var raw: [64]u8 = undefined;
        @memcpy(&raw, sig_der[0..64]);
        break :blk Ecdsa.Signature.fromBytes(raw);
    };
    sig.verify(msg, pk) catch return false;
    return true;
}

// -- Brute-force guard (single-threaded web loop) ----------------------------
//
// Tracks failed *credential presentations* per client key (IP). Missing auth
// (browser first paint) does not count. Success clears the slot.

pub const fail_window_ms: i64 = 15 * 60 * 1000;
pub const fail_lockout_ms: i64 = 15 * 60 * 1000;
pub const fail_max_per_window: u32 = 8;
/// Soft global ceiling on login POSTs (all clients) per rolling minute.
pub const login_global_max_per_min: u32 = 60;

pub const FailGuard = struct {
    const max_slots = 128;
    const Slot = struct {
        key: u64 = 0,
        fails: u32 = 0,
        window_start_ms: i64 = 0,
        locked_until_ms: i64 = 0,
        last_ms: i64 = 0,
    };

    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    login_window_start_ms: i64 = 0,
    login_count: u32 = 0,

    fn hashKey(key: []const u8) u64 {
        // FNV-1a 64
        var h: u64 = 0xcbf29ce484222325;
        for (key) |c| {
            h ^= c;
            h *%= 0x100000001b3;
        }
        return if (h == 0) 1 else h;
    }

    fn findSlot(self: *FailGuard, key_h: u64) *Slot {
        var free_i: ?usize = null;
        var oldest_i: usize = 0;
        var oldest_ms: i64 = std.math.maxInt(i64);
        for (&self.slots, 0..) |*s, i| {
            if (s.key == key_h) return s;
            if (s.key == 0 and free_i == null) free_i = i;
            if (s.last_ms < oldest_ms) {
                oldest_ms = s.last_ms;
                oldest_i = i;
            }
        }
        if (free_i) |i| return &self.slots[i];
        return &self.slots[oldest_i];
    }

    /// Seconds remaining in lockout, or 0 if allowed.
    pub fn lockedSeconds(self: *FailGuard, key: []const u8, now_ms: i64) u32 {
        if (key.len == 0) return 0;
        const h = hashKey(key);
        const s = self.findSlot(h);
        if (s.key != h) return 0;
        if (now_ms >= s.locked_until_ms) return 0;
        const left = s.locked_until_ms - now_ms;
        const sec = @divTrunc(left + 999, 1000);
        return @intCast(@min(sec, std.math.maxInt(u32)));
    }

    pub fn recordFailure(self: *FailGuard, key: []const u8, now_ms: i64) u32 {
        if (key.len == 0) return 0;
        const h = hashKey(key);
        const s = self.findSlot(h);
        if (s.key != h) {
            s.* = .{ .key = h, .fails = 0, .window_start_ms = now_ms, .locked_until_ms = 0, .last_ms = now_ms };
        }
        s.last_ms = now_ms;
        // Unlock expired lockouts and roll the failure window.
        if (s.locked_until_ms != 0 and now_ms >= s.locked_until_ms) {
            s.fails = 0;
            s.window_start_ms = now_ms;
            s.locked_until_ms = 0;
        }
        if (now_ms - s.window_start_ms > fail_window_ms) {
            s.fails = 0;
            s.window_start_ms = now_ms;
        }
        s.fails +|= 1;
        if (s.fails >= fail_max_per_window) {
            s.locked_until_ms = now_ms + fail_lockout_ms;
        }
        return self.lockedSeconds(key, now_ms);
    }

    pub fn recordSuccess(self: *FailGuard, key: []const u8, now_ms: i64) void {
        if (key.len == 0) return;
        const h = hashKey(key);
        const s = self.findSlot(h);
        if (s.key != h) return;
        s.* = .{ .key = 0, .fails = 0, .window_start_ms = 0, .locked_until_ms = 0, .last_ms = now_ms };
    }

    /// Count a login POST. Returns true when over the global per-minute cap.
    pub fn noteLoginAttempt(self: *FailGuard, now_ms: i64) bool {
        if (self.login_window_start_ms == 0 or now_ms - self.login_window_start_ms >= 60_000) {
            self.login_window_start_ms = now_ms;
            self.login_count = 0;
        }
        self.login_count +|= 1;
        return self.login_count > login_global_max_per_min;
    }
};

// -- tests -------------------------------------------------------------------

const testing = std.testing;

test "fail guard locks after max failures and clears on success" {
    var g = FailGuard{};
    const ip = "203.0.113.9";
    var now: i64 = 1_000_000;
    var i: u32 = 0;
    while (i < fail_max_per_window - 1) : (i += 1) {
        const left = g.recordFailure(ip, now);
        try testing.expectEqual(@as(u32, 0), left);
        now += 1000;
    }
    const locked = g.recordFailure(ip, now);
    try testing.expect(locked > 0);
    try testing.expect(g.lockedSeconds(ip, now) > 0);
    // other IP not locked
    try testing.expectEqual(@as(u32, 0), g.lockedSeconds("198.51.100.1", now));
    g.recordSuccess(ip, now);
    try testing.expectEqual(@as(u32, 0), g.lockedSeconds(ip, now));
}

test "fail guard global login flood" {
    var g = FailGuard{};
    const now: i64 = 60_000 * 42;
    var n: u32 = 0;
    var flooded = false;
    while (n < login_global_max_per_min + 5) : (n += 1) {
        if (g.noteLoginAttempt(now)) flooded = true;
    }
    try testing.expect(flooded);
}

test "token header parse and constant time" {
    try testing.expect(constantTimeEql("abc", "abc"));
    try testing.expect(!constantTimeEql("abc", "abd"));
    const h_ok = "Be" ++ "arer " ++ "sekrit";
    try testing.expectEqualStrings("sekrit", tokenFromHeaders(h_ok, null).?);
    try testing.expectEqualStrings("t2", tokenFromHeaders(null, "t2").?);
}

test "session mint verify roundtrip" {
    var cfg = Config{ .api_token = "test-token-value-32chars-minimum!!" };
    cfg.session_secret = deriveSessionSecret(cfg.api_token);
    var buf: [128]u8 = undefined;
    const sess = try mintSession(cfg, 1_000_000, &buf);
    try testing.expect(verifySession(cfg, sess, 1_000_000));
    try testing.expect(!verifySession(cfg, sess, 1_000_000 + session_ttl_ms + 1));
    try testing.expect(!verifySession(cfg, "bad.cookie", 1_000_000));
}

test "authorize bearer and cookie" {
    var cfg = Config{ .api_token = "tok" };
    cfg.session_secret = deriveSessionSecret(cfg.api_token);
    const h_ok = "Be" ++ "arer " ++ "tok";
    const h_bad = "Be" ++ "arer " ++ "nope";
    try testing.expect(authorize(cfg, h_ok, null, null, 0) == .ok);
    try testing.expect(authorize(cfg, h_bad, null, null, 0) == .unauthorized);
    var buf: [128]u8 = undefined;
    const sess = try mintSession(cfg, 100, &buf);
    var cookie_buf: [256]u8 = undefined;
    const ch = try std.fmt.bufPrint(&cookie_buf, "foo=1; {s}={s}", .{ cookie_name, sess });
    try testing.expect(authorize(cfg, null, null, ch, 100) == .ok);
}

test "sec1 from spki trailing" {
    var spki: [70]u8 = undefined;
    @memset(&spki, 0);
    spki[5] = 0x04;
    for (0..64) |i| spki[6 + i] = @intCast(i);
    // Make trailing 65 the canonical location
    var spki2: [65]u8 = undefined;
    spki2[0] = 0x04;
    @memset(spki2[1..], 0x11);
    const got = sec1FromSpki(&spki2).?;
    try testing.expect(got[0] == 0x04);
}

// -- WebAuthn assertion verification (positive + negative) --------------------

const Ecdsa = crypto.sign.ecdsa.EcdsaP256Sha256;

/// Offline test rig: deterministic key, self-issued challenge, valid assertion.
/// Stores lengths (not slices) so the struct stays trivially copyable.
const WebAuthnRig = struct {
    const rp_id = "localhost";
    const origin = "http://127.0.0.1:8080";
    const now: i64 = 1_000_000;

    kp: Ecdsa.KeyPair,
    pub_sec1: [65]u8,
    challenge_b64_buf: [64]u8,
    challenge_b64_len: usize,
    auth_data: [37]u8,
    client_data_buf: [256]u8,
    client_data_len: usize,
    sig_der_buf: [Ecdsa.Signature.der_encoded_length_max]u8,
    sig_der_len: usize,

    fn challenge(rig: *const WebAuthnRig) []const u8 {
        return rig.challenge_b64_buf[0..rig.challenge_b64_len];
    }
    fn clientData(rig: *const WebAuthnRig) []const u8 {
        return rig.client_data_buf[0..rig.client_data_len];
    }
    fn sigDer(rig: *const WebAuthnRig) []const u8 {
        return rig.sig_der_buf[0..rig.sig_der_len];
    }

    fn init() !WebAuthnRig {
        var rig: WebAuthnRig = undefined;
        rig.kp = try Ecdsa.KeyPair.generateDeterministic([_]u8{7} ** 32);
        rig.pub_sec1 = rig.kp.public_key.toUncompressedSec1();

        const raw_challenge = [_]u8{0xA5} ** 32;
        const n = std.base64.url_safe_no_pad.Encoder.calcSize(raw_challenge.len);
        _ = std.base64.url_safe_no_pad.Encoder.encode(rig.challenge_b64_buf[0..n], &raw_challenge);
        rig.challenge_b64_len = n;

        crypto.hash.sha2.Sha256.hash(rp_id, rig.auth_data[0..32], .{});
        rig.auth_data[32] = 0x01; // UP flag
        @memset(rig.auth_data[33..37], 0); // counter

        const cd = try std.fmt.bufPrint(
            &rig.client_data_buf,
            "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\",\"crossOrigin\":false}}",
            .{ rig.challenge_b64_buf[0..n], origin },
        );
        rig.client_data_len = cd.len;
        try rig.signOver(rig.clientData());
        return rig;
    }

    /// Sign auth_data ++ SHA256(client_data_json) with the rig key.
    fn signOver(rig: *WebAuthnRig, client_data_json: []const u8) !void {
        var cd_hash: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(client_data_json, &cd_hash, .{});
        var msg: [69]u8 = undefined;
        @memcpy(msg[0..37], &rig.auth_data);
        @memcpy(msg[37..69], &cd_hash);
        const sig = try rig.kp.sign(&msg, null);
        rig.sig_der_len = sig.toDer(&rig.sig_der_buf).len;
    }

    /// Bank pre-seeded with the rig challenge (bypasses io-backed issue()).
    fn seededBank(rig: *const WebAuthnRig) ChallengeBank {
        var bank = ChallengeBank{ .io = undefined };
        var raw: [32]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&raw, rig.challenge()) catch unreachable;
        bank.slots[0] = .{ .bytes = raw, .exp_ms = now + 60_000, .used = true };
        return bank;
    }

    fn verify(rig: *const WebAuthnRig, bank: *ChallengeBank) bool {
        return verifyWebAuthnAssertion(
            rig.pub_sec1,
            &rig.auth_data,
            rig.clientData(),
            rig.sigDer(),
            rig.challenge(),
            origin,
            rp_id,
            bank,
            now,
        );
    }
};

test "webauthn assertion valid signature passes" {
    var rig = try WebAuthnRig.init();
    var bank = rig.seededBank();
    try testing.expect(rig.verify(&bank));
}

test "webauthn assertion raw r||s signature passes" {
    var rig = try WebAuthnRig.init();
    // Re-encode the DER signature as raw 64-byte r||s (some platforms emit this).
    const sig = try Ecdsa.Signature.fromDer(rig.sigDer());
    const raw = sig.toBytes();
    var bank = rig.seededBank();
    try testing.expect(verifyWebAuthnAssertion(
        rig.pub_sec1,
        &rig.auth_data,
        rig.clientData(),
        &raw,
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion rejects corrupted signature" {
    var rig = try WebAuthnRig.init();
    var bad_sig: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined;
    @memcpy(bad_sig[0..rig.sigDer().len], rig.sigDer());
    bad_sig[rig.sigDer().len - 1] ^= 0x01;
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        rig.pub_sec1,
        &rig.auth_data,
        rig.clientData(),
        bad_sig[0..rig.sigDer().len],
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion rejects tampered challenge" {
    var rig = try WebAuthnRig.init();
    // Attacker swaps the signed-over challenge for one we never issued.
    var forged: [256]u8 = undefined;
    const fc = "FORGED_CHALLENGE_AAAAAAAAAAAAAAAAAAAAAAAAAA";
    const cd = try std.fmt.bufPrint(
        &forged,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}\",\"crossOrigin\":false}}",
        .{ fc, WebAuthnRig.origin },
    );
    try rig.signOver(cd); // even a *validly signed* wrong challenge must fail
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        rig.pub_sec1,
        &rig.auth_data,
        cd,
        rig.sigDer(),
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion challenge is single use (replay)" {
    var rig = try WebAuthnRig.init();
    var bank = rig.seededBank();
    try testing.expect(rig.verify(&bank));
    // Identical, fully valid assertion replayed: challenge already consumed.
    try testing.expect(!rig.verify(&bank));
}

test "webauthn assertion rejects expired challenge" {
    var rig = try WebAuthnRig.init();
    var bank = rig.seededBank();
    bank.slots[0].exp_ms = WebAuthnRig.now - 1;
    try testing.expect(!rig.verify(&bank));
}

test "webauthn assertion rejects wrong origin" {
    var rig = try WebAuthnRig.init();
    // Signed client data claims a lookalike origin with the real one as prefix.
    var cd_buf: [256]u8 = undefined;
    const cd = try std.fmt.bufPrint(
        &cd_buf,
        "{{\"type\":\"webauthn.get\",\"challenge\":\"{s}\",\"origin\":\"{s}.evil.example\",\"crossOrigin\":false}}",
        .{ rig.challenge(), WebAuthnRig.origin },
    );
    try rig.signOver(cd);
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        rig.pub_sec1,
        &rig.auth_data,
        cd,
        rig.sigDer(),
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion rejects wrong ceremony type" {
    var rig = try WebAuthnRig.init();
    // webauthn.create (registration) response must not authenticate a login.
    var cd_buf: [256]u8 = undefined;
    const cd = try std.fmt.bufPrint(
        &cd_buf,
        "{{\"type\":\"webauthn.create\",\"challenge\":\"{s}\",\"origin\":\"{s}\",\"crossOrigin\":false}}",
        .{ rig.challenge(), WebAuthnRig.origin },
    );
    try rig.signOver(cd);
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        rig.pub_sec1,
        &rig.auth_data,
        cd,
        rig.sigDer(),
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion rejects wrong rpIdHash" {
    var rig = try WebAuthnRig.init();
    crypto.hash.sha2.Sha256.hash("attacker.example", rig.auth_data[0..32], .{});
    try rig.signOver(rig.clientData()); // resign so only rpIdHash is at fault
    var bank = rig.seededBank();
    try testing.expect(!rig.verify(&bank));
}

test "webauthn assertion rejects missing user-present flag" {
    var rig = try WebAuthnRig.init();
    rig.auth_data[32] = 0x00;
    try rig.signOver(rig.clientData()); // resign so only the UP flag is at fault
    var bank = rig.seededBank();
    try testing.expect(!rig.verify(&bank));
}

test "webauthn assertion rejects truncated authenticator data" {
    var rig = try WebAuthnRig.init();
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        rig.pub_sec1,
        rig.auth_data[0..36],
        rig.clientData(),
        rig.sigDer(),
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}

test "webauthn assertion rejects wrong public key" {
    var rig = try WebAuthnRig.init();
    const other = try Ecdsa.KeyPair.generateDeterministic([_]u8{9} ** 32);
    var bank = rig.seededBank();
    try testing.expect(!verifyWebAuthnAssertion(
        other.public_key.toUncompressedSec1(),
        &rig.auth_data,
        rig.clientData(),
        rig.sigDer(),
        rig.challenge(),
        WebAuthnRig.origin,
        WebAuthnRig.rp_id,
        &bank,
        WebAuthnRig.now,
    ));
}
