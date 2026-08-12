//! Local dashboard/ops HTTP API (§6.4).
//! Auth: optional API token (Bearer/X-API-Token) + session cookie + passkey.
//! Health probes stay open; data APIs require auth when token is configured.

const std = @import("std");
const state_mod = @import("../core/state.zig");
const sm = @import("../risk/state_machine.zig");
const clock = @import("../core/clock.zig");
const auth = @import("auth.zig");

pub const Response = struct {
    status: std.http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
    /// Optional full Set-Cookie header value (name=value; attrs…).
    set_cookie: ?[]const u8 = null,
    /// Optional Retry-After seconds (rate limit / lockout).
    retry_after_sec: ?u32 = null,
};

pub const RequestInfo = struct {
    method: std.http.Method,
    target: []const u8,
    authorization: ?[]const u8 = null,
    x_api_token: ?[]const u8 = null,
    cookie: ?[]const u8 = null,
    /// Raw Host header (may include port).
    host: ?[]const u8 = null,
    /// X-Forwarded-Proto when behind TLS terminator.
    forwarded_proto: ?[]const u8 = null,
    /// Client IP for fail guard (peer or trusted X-Forwarded-For).
    client_ip: []const u8 = "",
    body: []const u8 = "",
    now_ms: i64 = 0,
};

/// Everything the router may read. Immutable per request (except auth stores).
pub const Context = struct {
    snapshot: state_mod.PortfolioState,
    /// Process phase: true once RECONCILING completed (§7.1).
    ready: bool,
    software_version: []const u8,
    config_hash: []const u8,
    /// Most recent event lines (JSON objects), newest last. May be empty.
    recent_events: []const []const u8 = &.{},
    /// Pre-rendered JSON arrays/objects filled by the core loop (no DB on web thread).
    agent_runs_json: []const u8 = "[]",
    equity_json: []const u8 = "[]",
    shadow_json: []const u8 = "{}",
    events_json: []const u8 = "[]",
    candles_json: []const u8 = "[]",
    memories_json: []const u8 = "[]",
    system_json: []const u8 = "{}",
    decisions_json: []const u8 = "[]",
    /// Orders projection + recent fills: `{"orders":[...],"fills":[...]}`.
    orders_json: []const u8 = "{\"orders\":[],\"fills\":[]}",
    /// Dashboard HTML served at "/". Embedded at comptime; empty = 404.
    index_html: []const u8 = "",
    auth_cfg: auth.Config = .{},
    cred_store: ?*auth.CredStore = null,
    challenges: ?*auth.ChallengeBank = null,
    fail_guard: ?*auth.FailGuard = null,
    /// When true, prefer X-Forwarded-For over TCP peer (only behind a trusted edge).
    trust_proxy: bool = false,
    /// How many trusted proxy hops append to XFF (default 1 → use right-most IP).
    trusted_proxy_hops: u32 = 1,
    /// Scratch for Set-Cookie (owned by connection handler).
    cookie_buf: []u8 = &.{},
    /// Scratch for auth JSON bodies.
    auth_buf: []u8 = &.{},
};

fn riskModeText(mode: sm.RiskMode) []const u8 {
    return switch (mode) {
        .normal => "NORMAL",
        .exit_only => "EXIT_ONLY",
        .flattening => "FLATTENING",
        .halted => "HALTED",
    };
}

fn unauthorized() Response {
    return .{ .status = .unauthorized, .body = "{\"error\":\"unauthorized\"}" };
}

fn rateLimited(retry_after: u32) Response {
    return .{
        .status = .too_many_requests,
        .body = "{\"error\":\"rate_limited\",\"hint\":\"too_many_auth_failures\"}",
        .retry_after_sec = if (retry_after == 0) 60 else retry_after,
    };
}

fn clientKey(req: RequestInfo) []const u8 {
    if (req.client_ip.len > 0) return req.client_ip;
    return "unknown";
}

/// Record failed credential presentation; return lockout response if locked.
fn noteAuthFailure(ctx: Context, req: RequestInfo) ?Response {
    const g = ctx.fail_guard orelse return null;
    const left = g.recordFailure(clientKey(req), req.now_ms);
    if (left > 0) return rateLimited(left);
    return null;
}

fn noteAuthSuccess(ctx: Context, req: RequestInfo) void {
    if (ctx.fail_guard) |g| g.recordSuccess(clientKey(req), req.now_ms);
}

fn guardLocked(ctx: Context, req: RequestInfo) ?Response {
    const g = ctx.fail_guard orelse return null;
    const left = g.lockedSeconds(clientKey(req), req.now_ms);
    if (left > 0) return rateLimited(left);
    return null;
}

fn pathOnly(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
}

fn isPublicPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/health/live")) return true;
    if (std.mem.eql(u8, path, "/health/ready")) return true;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return true;
    if (std.mem.startsWith(u8, path, "/api/v1/auth/")) return true;
    return false;
}

fn isAuthed(ctx: Context, req: RequestInfo) bool {
    const r = auth.authorize(ctx.auth_cfg, req.authorization, req.x_api_token, req.cookie, req.now_ms);
    return r == .ok or r == .disabled_open;
}

/// Authorize protected routes: lockout → wrong presented token counts as fail.
fn checkProtectedAuth(ctx: Context, req: RequestInfo) ?Response {
    if (!ctx.auth_cfg.required()) return null;
    if (guardLocked(ctx, req)) |r| return r;
    const r = auth.authorize(ctx.auth_cfg, req.authorization, req.x_api_token, req.cookie, req.now_ms);
    if (r == .ok or r == .disabled_open) {
        // Only clear on successful *token* presentation; session cookies stay quiet.
        if (auth.tokenFromHeaders(req.authorization, req.x_api_token) != null) {
            noteAuthSuccess(ctx, req);
        }
        return null;
    }
    // Wrong token presented → count; bare 401 (no credential) does not.
    if (auth.tokenFromHeaders(req.authorization, req.x_api_token) != null) {
        if (noteAuthFailure(ctx, req)) |lim| return lim;
    }
    return unauthorized();
}

/// Route a request. `buf` backs the response body; must outlive the response.
pub fn handle(buf: []u8, method: std.http.Method, target: []const u8, ctx: Context) Response {
    return handleReq(buf, .{ .method = method, .target = target, .now_ms = 0 }, ctx);
}

pub fn handleReq(buf: []u8, req: RequestInfo, ctx: Context) Response {
    const path = pathOnly(req.target);
    const method = req.method;

    // --- public health ---
    if (method == .GET and std.mem.eql(u8, path, "/health/live")) {
        return .{ .status = .ok, .body = "{\"status\":\"ok\"}" };
    }
    if (method == .GET and std.mem.eql(u8, path, "/health/ready")) {
        if (ctx.ready) return .{ .status = .ok, .body = "{\"status\":\"ready\"}" };
        return .{ .status = .service_unavailable, .body = "{\"status\":\"not_ready\"}" };
    }

    // --- auth routes (public) ---
    if (std.mem.startsWith(u8, path, "/api/v1/auth/")) {
        return handleAuth(buf, req, path, ctx);
    }

    // --- static dashboard HTML always servable (gate is client-side + API 401) ---
    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html"))) {
        if (ctx.index_html.len > 0) {
            return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = ctx.index_html };
        }
        return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
    }

    // --- protected data APIs ---
    if (!isPublicPath(path)) {
        if (checkProtectedAuth(ctx, req)) |denied| return denied;
    }

    if (method != .GET) {
        return .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
    }
    if (std.mem.eql(u8, path, "/api/v1/state")) return renderState(buf, ctx);
    if (std.mem.eql(u8, path, "/api/v1/events")) {
        if (ctx.recent_events.len > 0) return renderEvents(buf, ctx);
        return copyBody(buf, ctx.events_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/agent-runs")) return copyBody(buf, ctx.agent_runs_json);
    if (std.mem.eql(u8, path, "/api/v1/equity")) return copyBody(buf, ctx.equity_json);
    if (std.mem.eql(u8, path, "/api/v1/shadow")) return copyBody(buf, ctx.shadow_json);
    if (std.mem.eql(u8, path, "/api/v1/candles")) return copyBody(buf, ctx.candles_json);
    if (std.mem.eql(u8, path, "/api/v1/memories")) return copyBody(buf, ctx.memories_json);
    if (std.mem.eql(u8, path, "/api/v1/system")) return copyBody(buf, ctx.system_json);
    if (std.mem.eql(u8, path, "/api/v1/decisions")) return copyBody(buf, ctx.decisions_json);
    if (std.mem.eql(u8, path, "/api/v1/orders")) return copyBody(buf, ctx.orders_json);
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

fn jsonGetString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn hostHeaderOk(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    for (host) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == ':' or c == '[' or c == ']';
        if (!ok) return false;
    }
    return true;
}

/// Resolve WebAuthn rpId + origin from the browser Host (preferred) or config fallback.
fn resolveWebAuthn(
    req: RequestInfo,
    cfg: auth.Config,
    origin_buf: []u8,
    rp_buf: []u8,
) struct { origin: []const u8, rp_id: []const u8 } {
    const host_raw = req.host orelse {
        return .{ .origin = cfg.origin, .rp_id = cfg.rp_id };
    };
    const host = std.mem.trim(u8, host_raw, " \t");
    if (!hostHeaderOk(host)) return .{ .origin = cfg.origin, .rp_id = cfg.rp_id };

    var hostname = host;
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        // strip port; keep IPv6 untouched (rare for our binds)
        if (std.mem.indexOfScalar(u8, host, ']') == null) {
            hostname = host[0..colon];
        }
    }
    if (hostname.len == 0 or hostname.len >= rp_buf.len) {
        return .{ .origin = cfg.origin, .rp_id = cfg.rp_id };
    }
    @memcpy(rp_buf[0..hostname.len], hostname);
    const rp_id = rp_buf[0..hostname.len];

    var proto: []const u8 = "http";
    if (req.forwarded_proto) |fp| {
        const p = std.mem.trim(u8, fp, " \t");
        if (std.ascii.eqlIgnoreCase(p, "https")) proto = "https";
    } else if (std.mem.startsWith(u8, cfg.origin, "https://")) {
        proto = "https";
    }
    const origin = std.fmt.bufPrint(origin_buf, "{s}://{s}", .{ proto, host }) catch cfg.origin;
    return .{ .origin = origin, .rp_id = rp_id };
}

fn cookieSecureForOrigin(origin: []const u8) bool {
    return std.mem.startsWith(u8, origin, "https://");
}

fn handleAuth(buf: []u8, req_in: RequestInfo, path: []const u8, ctx: Context) Response {
    var req = req_in;
    if (req.now_ms == 0) req.now_ms = clock.SystemClock.clock().wallMs();
    const now = req.now_ms;
    var origin_buf: [256]u8 = undefined;
    var rp_buf: [128]u8 = undefined;
    const wa = resolveWebAuthn(req, ctx.auth_cfg, &origin_buf, &rp_buf);

    // status
    if (req.method == .GET and std.mem.eql(u8, path, "/api/v1/auth/status")) {
        const reqd = ctx.auth_cfg.required();
        const authed = if (!reqd) true else isAuthed(ctx, req);
        const ncred: usize = if (ctx.cred_store) |s| s.count() else 0;
        // passkey_hint: client still needs isSecureContext; we report expected rp/origin.
        const body = std.fmt.bufPrint(buf, "{{\"auth_required\":{},\"authenticated\":{},\"passkeys\":{d},\"rp_id\":\"{s}\",\"origin\":\"{s}\",\"passkey_note\":\"requires_secure_context_https_or_localhost\"}}", .{
            reqd,
            authed,
            ncred,
            wa.rp_id,
            wa.origin,
        }) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"buf\"}" };
        return .{ .status = .ok, .body = body };
    }

    // token login
    if (req.method == .POST and std.mem.eql(u8, path, "/api/v1/auth/login")) {
        if (!ctx.auth_cfg.required()) {
            return .{ .status = .ok, .body = "{\"ok\":true,\"auth_required\":false}" };
        }
        if (guardLocked(ctx, req)) |r| return r;
        if (ctx.fail_guard) |g| {
            if (g.noteLoginAttempt(now)) return rateLimited(60);
        }
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req.body, .{}) catch {
            return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        const token = jsonGetString(parsed.value.object, "token") orelse
            return .{ .status = .bad_request, .body = "{\"error\":\"missing_token\"}" };
        if (!auth.tokenValid(ctx.auth_cfg, token)) {
            if (noteAuthFailure(ctx, req)) |lim| return lim;
            return unauthorized();
        }
        noteAuthSuccess(ctx, req);
        if (ctx.cookie_buf.len == 0) return .{ .status = .internal_server_error, .body = "{\"error\":\"cookie_buf\"}" };
        var sess_buf: [128]u8 = undefined;
        const sess = auth.mintSession(ctx.auth_cfg, now, &sess_buf) catch {
            return .{ .status = .internal_server_error, .body = "{\"error\":\"session\"}" };
        };
        const sc = auth.setCookieHeader(sess, cookieSecureForOrigin(wa.origin), ctx.cookie_buf) catch {
            return .{ .status = .internal_server_error, .body = "{\"error\":\"cookie\"}" };
        };
        return .{ .status = .ok, .body = "{\"ok\":true}", .set_cookie = sc };
    }

    if (req.method == .POST and std.mem.eql(u8, path, "/api/v1/auth/logout")) {
        if (ctx.cookie_buf.len == 0) return .{ .status = .ok, .body = "{\"ok\":true}" };
        const sc = auth.clearCookieHeader(ctx.cookie_buf) catch {
            return .{ .status = .ok, .body = "{\"ok\":true}" };
        };
        return .{ .status = .ok, .body = "{\"ok\":true}", .set_cookie = sc };
    }

    // passkey register options — must already be authenticated (token/session)
    if (req.method == .GET and std.mem.eql(u8, path, "/api/v1/auth/passkey/register/options")) {
        if (ctx.auth_cfg.required() and !isAuthed(ctx, req)) return unauthorized();
        const bank = ctx.challenges orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        var ch_b64: [64]u8 = undefined;
        const ch = bank.issue(now, &ch_b64) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"challenge\"}" };
        const body = std.fmt.bufPrint(buf, "{{\"challenge\":\"{s}\",\"rp\":{{\"name\":\"AlphaBound\",\"id\":\"{s}\"}},\"user\":{{\"id\":\"YWRtaW4\",\"name\":\"admin\",\"displayName\":\"Admin\"}},\"pubKeyCredParams\":[{{\"type\":\"public-key\",\"alg\":-7}}],\"timeout\":60000,\"attestation\":\"none\",\"authenticatorSelection\":{{\"residentKey\":\"preferred\",\"userVerification\":\"preferred\"}}}}", .{ ch, wa.rp_id }) catch {
            return .{ .status = .internal_server_error, .body = "{\"error\":\"buf\"}" };
        };
        return .{ .status = .ok, .body = body };
    }

    // passkey register finish
    if (req.method == .POST and std.mem.eql(u8, path, "/api/v1/auth/passkey/register")) {
        if (ctx.auth_cfg.required() and !isAuthed(ctx, req)) return unauthorized();
        const store = ctx.cred_store orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req.body, .{}) catch {
            return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        const id_b64 = jsonGetString(parsed.value.object, "id") orelse
            return .{ .status = .bad_request, .body = "{\"error\":\"missing_id\"}" };
        const spki_b64 = jsonGetString(parsed.value.object, "publicKeySpki") orelse
            return .{ .status = .bad_request, .body = "{\"error\":\"missing_publicKeySpki\"}" };
        var spki_buf: [512]u8 = undefined;
        const spki_n = std.base64.standard.Decoder.calcSizeForSlice(spki_b64) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"b64\"}" };
        if (spki_n > spki_buf.len) return .{ .status = .bad_request, .body = "{\"error\":\"key_too_large\"}" };
        std.base64.standard.Decoder.decode(spki_buf[0..spki_n], spki_b64) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"b64\"}" };
        const sec1 = auth.sec1FromSpki(spki_buf[0..spki_n]) orelse
            return .{ .status = .bad_request, .body = "{\"error\":\"bad_spki\"}" };
        store.add(id_b64, sec1) catch |err| switch (err) {
            error.Duplicate => return .{ .status = .conflict, .body = "{\"error\":\"duplicate\"}" },
            else => return .{ .status = .internal_server_error, .body = "{\"error\":\"store\"}" },
        };
        return .{ .status = .ok, .body = "{\"ok\":true}" };
    }

    // passkey login options
    if (req.method == .GET and std.mem.eql(u8, path, "/api/v1/auth/passkey/login/options")) {
        const bank = ctx.challenges orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        const store = ctx.cred_store orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        var ch_b64: [64]u8 = undefined;
        const ch = bank.issue(now, &ch_b64) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"challenge\"}" };
        var allow_buf: [4096]u8 = undefined;
        const allow = store.allowCredentialsJson(&allow_buf) catch
            return .{ .status = .internal_server_error, .body = "{\"error\":\"ids\"}" };
        const body = std.fmt.bufPrint(buf, "{{\"challenge\":\"{s}\",\"timeout\":60000,\"rpId\":\"{s}\",\"userVerification\":\"preferred\",\"allowCredentials\":{s}}}", .{
            ch,
            wa.rp_id,
            allow,
        }) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"buf\"}" };
        return .{ .status = .ok, .body = body };
    }

    // passkey login finish
    if (req.method == .POST and std.mem.eql(u8, path, "/api/v1/auth/passkey/login")) {
        if (!ctx.auth_cfg.required()) {
            return .{ .status = .ok, .body = "{\"ok\":true,\"auth_required\":false}" };
        }
        if (guardLocked(ctx, req)) |r| return r;
        if (ctx.fail_guard) |g| {
            if (g.noteLoginAttempt(now)) return rateLimited(60);
        }
        const bank = ctx.challenges orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        const store = ctx.cred_store orelse return .{ .status = .service_unavailable, .body = "{\"error\":\"passkey_disabled\"}" };
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req.body, .{}) catch {
            return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
        const obj = parsed.value.object;
        const id_b64 = jsonGetString(obj, "id") orelse return .{ .status = .bad_request, .body = "{\"error\":\"missing_id\"}" };
        const client_data_b64 = jsonGetString(obj, "clientDataJSON") orelse return .{ .status = .bad_request, .body = "{\"error\":\"missing_clientDataJSON\"}" };
        const auth_data_b64 = jsonGetString(obj, "authenticatorData") orelse return .{ .status = .bad_request, .body = "{\"error\":\"missing_authenticatorData\"}" };
        const sig_b64 = jsonGetString(obj, "signature") orelse return .{ .status = .bad_request, .body = "{\"error\":\"missing_signature\"}" };
        const challenge_b64 = jsonGetString(obj, "challenge") orelse return .{ .status = .bad_request, .body = "{\"error\":\"missing_challenge\"}" };

        const cred = store.find(id_b64) orelse {
            if (noteAuthFailure(ctx, req)) |lim| return lim;
            return unauthorized();
        };

        var cd_buf: [4096]u8 = undefined;
        const cd_n = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(client_data_b64) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"b64\"}" };
        if (cd_n > cd_buf.len) return .{ .status = .bad_request, .body = "{\"error\":\"too_large\"}" };
        // clientDataJSON from browser is typically standard base64 in ArrayBuffer; client should send base64url
        std.base64.url_safe_no_pad.Decoder.decode(cd_buf[0..cd_n], client_data_b64) catch {
            // try standard
            const n2 = std.base64.standard.Decoder.calcSizeForSlice(client_data_b64) catch
                return .{ .status = .bad_request, .body = "{\"error\":\"b64\"}" };
            if (n2 > cd_buf.len) return .{ .status = .bad_request, .body = "{\"error\":\"too_large\"}" };
            std.base64.standard.Decoder.decode(cd_buf[0..n2], client_data_b64) catch
                return .{ .status = .bad_request, .body = "{\"error\":\"b64\"}" };
            return finishPasskeyLogin(buf, ctx, req, wa.origin, now, bank, cred.pub_sec1, cd_buf[0..n2], auth_data_b64, sig_b64, challenge_b64);
        };
        return finishPasskeyLogin(buf, ctx, req, wa.origin, now, bank, cred.pub_sec1, cd_buf[0..cd_n], auth_data_b64, sig_b64, challenge_b64);
    }

    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

fn decodeB64Flexible(out: []u8, in: []const u8) ?[]const u8 {
    if (std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(in)) |n| {
        if (n <= out.len) {
            if (std.base64.url_safe_no_pad.Decoder.decode(out[0..n], in)) |_| return out[0..n] else |_| {}
        }
    } else |_| {}
    if (std.base64.standard.Decoder.calcSizeForSlice(in)) |n| {
        if (n <= out.len) {
            if (std.base64.standard.Decoder.decode(out[0..n], in)) |_| return out[0..n] else |_| {}
        }
    } else |_| {}
    return null;
}

fn finishPasskeyLogin(
    buf: []u8,
    ctx: Context,
    req: RequestInfo,
    expected_origin: []const u8,
    now: i64,
    bank: *auth.ChallengeBank,
    pub_sec1: [65]u8,
    client_data_json: []const u8,
    auth_data_b64: []const u8,
    sig_b64: []const u8,
    challenge_b64: []const u8,
) Response {
    _ = buf;
    var ad_buf: [512]u8 = undefined;
    const ad = decodeB64Flexible(&ad_buf, auth_data_b64) orelse
        return .{ .status = .bad_request, .body = "{\"error\":\"b64_authdata\"}" };
    var sig_buf: [256]u8 = undefined;
    const sig = decodeB64Flexible(&sig_buf, sig_b64) orelse
        return .{ .status = .bad_request, .body = "{\"error\":\"b64_sig\"}" };

    const ok = auth.verifyWebAuthnAssertion(
        pub_sec1,
        ad,
        client_data_json,
        sig,
        challenge_b64,
        expected_origin,
        bank,
        now,
    );
    if (!ok) {
        if (noteAuthFailure(ctx, req)) |lim| return lim;
        return unauthorized();
    }
    noteAuthSuccess(ctx, req);
    if (ctx.cookie_buf.len == 0) return .{ .status = .internal_server_error, .body = "{\"error\":\"cookie_buf\"}" };
    var sess_buf: [128]u8 = undefined;
    const sess = auth.mintSession(ctx.auth_cfg, now, &sess_buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"session\"}" };
    };
    const sc = auth.setCookieHeader(sess, cookieSecureForOrigin(expected_origin), ctx.cookie_buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"cookie\"}" };
    };
    return .{ .status = .ok, .body = "{\"ok\":true}", .set_cookie = sc };
}

fn renderState(buf: []u8, ctx: Context) Response {
    var w: std.Io.Writer = .fixed(buf);
    var s: std.json.Stringify = .{ .writer = &w };
    const snap = ctx.snapshot;

    var num_buf: [dec_str_len]u8 = undefined;

    render: {
        s.beginObject() catch break :render;
        s.objectField("version") catch break :render;
        s.write(snap.version) catch break :render;
        s.objectField("as_of_ms") catch break :render;
        s.write(snap.as_of_ms) catch break :render;
        s.objectField("risk_mode") catch break :render;
        s.write(riskModeText(snap.risk_mode)) catch break :render;
        s.objectField("reconciled") catch break :render;
        s.write(snap.reconciled) catch break :render;

        s.objectField("cash_usdt") catch break :render;
        s.write(decStr(&num_buf, snap.cash_usdt)) catch break :render;
        s.objectField("btc_total") catch break :render;
        s.write(decStr(&num_buf, snap.btc_total)) catch break :render;
        s.objectField("bid_price") catch break :render;
        s.write(decStr(&num_buf, snap.bid_price)) catch break :render;
        s.objectField("conservative_equity") catch break :render;
        s.write(decStr(&num_buf, snap.conservative_equity)) catch break :render;
        s.objectField("high_watermark") catch break :render;
        s.write(decStr(&num_buf, snap.high_watermark)) catch break :render;
        s.objectField("drawdown") catch break :render;
        s.write(decStr(&num_buf, snap.drawdown)) catch break :render;

        s.objectField("software_version") catch break :render;
        s.write(ctx.software_version) catch break :render;
        s.objectField("config_hash") catch break :render;
        s.write(ctx.config_hash) catch break :render;
        s.endObject() catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

fn renderEvents(buf: []u8, ctx: Context) Response {
    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.writeAll("[") catch break :render;
        for (ctx.recent_events, 0..) |line, i| {
            if (i > 0) w.writeAll(",") catch break :render;
            w.writeAll(line) catch break :render;
        }
        w.writeAll("]") catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

/// Copy a pre-rendered JSON blob into the per-request body buffer so the
/// seqlock snapshot need not remain valid across the full socket write.
fn copyBody(buf: []u8, src: []const u8) Response {
    if (src.len > buf.len) {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"payload_too_large\"}" };
    }
    @memcpy(buf[0..src.len], src);
    return .{ .status = .ok, .body = buf[0..src.len] };
}

const dec_str_len = 48;

fn decStr(buf: *[dec_str_len]u8, v: @import("../core/decimal.zig").Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

// -- Socket loop (thin adapter) ----------------------------------------------

pub const ServerOptions = struct {
    /// Host to bind. Config allows only `127.0.0.1` (default) or `0.0.0.0`
    /// (container / compose behind host-loopback publish).
    host: []const u8 = "127.0.0.1",
    port: u16 = 8722,
};

/// Provider callback: fills a Context for each request.
pub const ContextFn = *const fn (userdata: ?*anyopaque) Context;

/// Blocking accept loop. Each connection handles one request batch.
/// Runs until the stream listener fails; caller owns thread/lifecycle.
pub fn serve(
    io: std.Io,
    opts: ServerOptions,
    ctx_fn: ContextFn,
    userdata: ?*anyopaque,
) !void {
    const addr = try std.Io.net.IpAddress.parse(opts.host, opts.port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    while (true) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };
        handleConnection(io, stream, ctx_fn, userdata) catch {};
    }
}

fn headerValue(head_buf: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head_buf, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hn = line[0..colon];
        if (std.ascii.eqlIgnoreCase(hn, name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

fn copyOptHeader(head_buf: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    const v = headerValue(head_buf, name) orelse return null;
    if (v.len > out.len) return null;
    @memcpy(out[0..v.len], v);
    return out[0..v.len];
}

fn formatPeerIp(stream: std.Io.net.Stream, out: []u8) []const u8 {
    var addr: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(stream.socket.handle, @ptrCast(&addr), &len) catch return "unknown";
    const sa: *align(1) const std.posix.sockaddr = @ptrCast(&addr);
    if (sa.family == std.posix.AF.INET) {
        const in4: *align(1) const std.posix.sockaddr.in = @ptrCast(&addr);
        const b: *const [4]u8 = @ptrCast(&in4.addr);
        return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch "unknown";
    }
    if (sa.family == std.posix.AF.INET6) {
        const in6: *align(1) const std.posix.sockaddr.in6 = @ptrCast(&addr);
        const p = in6.addr;
        // Fixed hex key (not pretty-print); enough for fail-guard identity.
        if (out.len < 32) return "unknown";
        const hex = "0123456789abcdef";
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            out[i * 2] = hex[p[i] >> 4];
            out[i * 2 + 1] = hex[p[i] & 0xf];
        }
        return out[0..32];
    }
    return "unknown";
}

/// Pick client IP from X-Forwarded-For under a *trusted* reverse proxy.
///
/// Proxies that **append** (Azure App Gateway, many nginx configs) produce:
///   client-forged..., real-client, [optional extra hops]
/// The left-most value is attacker-controlled. With `hops` trusted proxy layers
/// that each append once, the client is at index `len - hops` (0-based from left),
/// i.e. `hops` from the right. Default hops=1 → **right-most** IP.
fn forwardedClientIp(xff: []const u8, hops: u32) []const u8 {
    const trimmed = std.mem.trim(u8, xff, " \t");
    if (trimmed.len == 0) return "";
    const use_hops: u32 = if (hops == 0) 1 else hops;

    // Collect up to 16 comma-separated tokens (right-most wins for our purpose).
    var parts: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (n < parts.len) {
            parts[n] = p;
            n += 1;
        } else {
            // shift left, keep last 16
            var i: usize = 0;
            while (i + 1 < parts.len) : (i += 1) parts[i] = parts[i + 1];
            parts[parts.len - 1] = p;
        }
    }
    if (n == 0) return "";
    const h: usize = @min(@as(usize, use_hops), n);
    return parts[n - h];
}

fn clientIpOk(ip: []const u8) bool {
    if (ip.len == 0 or ip.len > 64) return false;
    for (ip) |c| {
        const ok = (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or
            (c >= '0' and c <= '9') or c == '.' or c == ':' or c == '%';
        if (!ok) return false;
    }
    return true;
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, ctx_fn: ContextFn, userdata: ?*anyopaque) !void {
    defer stream.close(io);
    var in_buf: [8192]u8 = undefined;
    // Large enough for multi-timeframe candles JSON + headers (and dashboard HTML path).
    var out_buf: [196608]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = server.receiveHead() catch return;

    // Copy request-line fields and auth headers BEFORE body read:
    // `readerExpectNone` invalidates head string slices.
    var target_buf: [512]u8 = undefined;
    const target_len = @min(req.head.target.len, target_buf.len);
    @memcpy(target_buf[0..target_len], req.head.target[0..target_len]);
    const method = req.head.method;

    var authz_buf: [512]u8 = undefined;
    var x_tok_buf: [256]u8 = undefined;
    var cookie_hdr_buf: [1024]u8 = undefined;
    var host_buf: [256]u8 = undefined;
    var fwd_proto_buf: [32]u8 = undefined;
    var xff_buf: [256]u8 = undefined;
    var peer_ip_buf: [64]u8 = undefined;
    const authorization = copyOptHeader(req.head_buffer, "authorization", &authz_buf);
    const x_api_token = copyOptHeader(req.head_buffer, "x-api-token", &x_tok_buf);
    const cookie_hdr = copyOptHeader(req.head_buffer, "cookie", &cookie_hdr_buf);
    const host_hdr = copyOptHeader(req.head_buffer, "host", &host_buf);
    const fwd_proto = copyOptHeader(req.head_buffer, "x-forwarded-proto", &fwd_proto_buf);
    const xff_hdr = copyOptHeader(req.head_buffer, "x-forwarded-for", &xff_buf);
    const peer_ip = formatPeerIp(stream, &peer_ip_buf);
    const content_length = req.head.content_length;

    var body_storage: [8192]u8 = undefined;
    var body_len: usize = 0;
    if (method == .POST) {
        if (content_length) |cl| {
            if (cl > body_storage.len) {
                try req.respond("{\"error\":\"body_too_large\"}", .{
                    .status = .payload_too_large,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json" },
                    },
                });
                return;
            }
            if (cl > 0) {
                const want: usize = @intCast(cl);
                var body_reader_buf: [512]u8 = undefined;
                const br = req.readerExpectNone(&body_reader_buf);
                br.readSliceAll(body_storage[0..want]) catch {
                    try req.respond("{\"error\":\"bad_body\"}", .{
                        .status = .bad_request,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "application/json" },
                        },
                    });
                    return;
                };
                body_len = want;
            }
        }
    }

    var cookie_buf: [256]u8 = undefined;
    var auth_buf: [4096]u8 = undefined;
    var ctx = ctx_fn(userdata);
    ctx.cookie_buf = &cookie_buf;
    ctx.auth_buf = &auth_buf;

    var client_ip: []const u8 = peer_ip;
    if (ctx.trust_proxy) {
        if (xff_hdr) |xff| {
            const hops = if (ctx.trusted_proxy_hops == 0) 1 else ctx.trusted_proxy_hops;
            const picked = forwardedClientIp(xff, hops);
            if (clientIpOk(picked)) client_ip = picked;
        }
        // No XFF → keep TCP peer (usually the proxy). Do not honor client-spoofable headers alone.
    }

    const info = RequestInfo{
        .method = method,
        .target = target_buf[0..target_len],
        .authorization = authorization,
        .x_api_token = x_api_token,
        .cookie = cookie_hdr,
        .host = host_hdr,
        .forwarded_proto = fwd_proto,
        .client_ip = client_ip,
        .body = body_storage[0..body_len],
        .now_ms = clock.SystemClock.clock().wallMs(),
    };

    var body_buf: [196608]u8 = undefined;
    const resp = handleReq(&body_buf, info, ctx);

    var retry_buf: [16]u8 = undefined;
    const retry_hdr: ?[]const u8 = if (resp.retry_after_sec) |sec|
        std.fmt.bufPrint(&retry_buf, "{d}", .{sec}) catch null
    else
        null;

    if (resp.set_cookie) |sc| {
        if (retry_hdr) |ra| {
            try req.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = resp.content_type },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "set-cookie", .value = sc },
                    .{ .name = "retry-after", .value = ra },
                },
            });
        } else {
            try req.respond(resp.body, .{
                .status = resp.status,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = resp.content_type },
                    .{ .name = "cache-control", .value = "no-store" },
                    .{ .name = "set-cookie", .value = sc },
                },
            });
        }
    } else if (retry_hdr) |ra| {
        try req.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = resp.content_type },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "retry-after", .value = ra },
            },
        });
    } else {
        try req.respond(resp.body, .{
            .status = resp.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = resp.content_type },
                .{ .name = "cache-control", .value = "no-store" },
            },
        });
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const Decimal = @import("../core/decimal.zig").Decimal;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn testCtx() Context {
    var snap = state_mod.PortfolioState{};
    snap.version = 42;
    snap.as_of_ms = 1_786_264_264_482;
    snap.cash_usdt = d("87.5");
    snap.btc_total = d("0.0001");
    snap.bid_price = d("99123.3");
    snap.conservative_equity = d("97.33");
    snap.high_watermark = d("100");
    snap.drawdown = d("0.0267");
    snap.risk_mode = .normal;
    snap.reconciled = true;
    return .{
        .snapshot = snap,
        .ready = true,
        .software_version = "0.1.0+test",
        .config_hash = "sha256:abc",
    };
}

test "health endpoints" {
    var buf: [1024]u8 = undefined;
    const live = handle(&buf, .GET, "/health/live", testCtx());
    try testing.expectEqual(std.http.Status.ok, live.status);

    var ctx = testCtx();
    ctx.ready = false;
    const ready = handle(&buf, .GET, "/health/ready", ctx);
    try testing.expectEqual(std.http.Status.service_unavailable, ready.status);

    ctx.ready = true;
    const ready2 = handle(&buf, .GET, "/health/ready", ctx);
    try testing.expectEqual(std.http.Status.ok, ready2.status);
}

test "state endpoint renders decimals as strings" {
    var buf: [4096]u8 = undefined;
    const resp = handle(&buf, .GET, "/api/v1/state", testCtx());
    try testing.expectEqual(std.http.Status.ok, resp.status);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, 42), obj.get("version").?.integer);
    try testing.expectEqualStrings("NORMAL", obj.get("risk_mode").?.string);
    try testing.expectEqualStrings("87.5", obj.get("cash_usdt").?.string);
    try testing.expectEqualStrings("0.0267", obj.get("drawdown").?.string);
    try testing.expectEqualStrings("sha256:abc", obj.get("config_hash").?.string);
}

test "events endpoint concatenates recent lines" {
    var buf: [4096]u8 = undefined;
    var ctx = testCtx();
    const lines = [_][]const u8{
        "{\"type\":\"ORDER_SUBMITTED\"}",
        "{\"type\":\"ORDER_FILLED\"}",
    };
    ctx.recent_events = &lines;
    const resp = handle(&buf, .GET, "/api/v1/events", ctx);
    try testing.expectEqual(std.http.Status.ok, resp.status);
    try testing.expectEqualStrings("[{\"type\":\"ORDER_SUBMITTED\"},{\"type\":\"ORDER_FILLED\"}]", resp.body);
}

test "unknown route 404, non-GET 405, query string stripped" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqual(std.http.Status.not_found, handle(&buf, .GET, "/nope", testCtx()).status);
    try testing.expectEqual(std.http.Status.method_not_allowed, handle(&buf, .POST, "/api/v1/state", testCtx()).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/health/live?x=1", testCtx()).status);
}

test "agent-runs equity shadow endpoints serve context blobs" {
    var buf: [1024]u8 = undefined;
    var ctx = testCtx();
    ctx.agent_runs_json = "[{\"run_id\":\"r1\"}]";
    ctx.equity_json = "[{\"equity\":\"100\"}]";
    ctx.shadow_json = "{\"alpha\":\"0\"}";
    ctx.candles_json = "[{\"c\":\"1\"}]";
    ctx.memories_json = "[{\"memory_id\":\"m1\"}]";
    ctx.system_json = "{\"ready\":true}";
    ctx.decisions_json = "[{\"type\":\"AGENT_PROPOSAL_OK\"}]";
    ctx.orders_json = "{\"orders\":[{\"status\":\"FILLED\"}],\"fills\":[]}";
    try testing.expectEqualStrings("[{\"run_id\":\"r1\"}]", handle(&buf, .GET, "/api/v1/agent-runs", ctx).body);
    try testing.expectEqualStrings("[{\"equity\":\"100\"}]", handle(&buf, .GET, "/api/v1/equity", ctx).body);
    try testing.expectEqualStrings("{\"alpha\":\"0\"}", handle(&buf, .GET, "/api/v1/shadow", ctx).body);
    try testing.expectEqualStrings("[{\"c\":\"1\"}]", handle(&buf, .GET, "/api/v1/candles", ctx).body);
    try testing.expectEqualStrings("[{\"memory_id\":\"m1\"}]", handle(&buf, .GET, "/api/v1/memories", ctx).body);
    try testing.expectEqualStrings("{\"ready\":true}", handle(&buf, .GET, "/api/v1/system", ctx).body);
    try testing.expectEqualStrings("[{\"type\":\"AGENT_PROPOSAL_OK\"}]", handle(&buf, .GET, "/api/v1/decisions", ctx).body);
    try testing.expectEqualStrings("{\"orders\":[{\"status\":\"FILLED\"}],\"fills\":[]}", handle(&buf, .GET, "/api/v1/orders", ctx).body);
}

test "auth required blocks data APIs without token" {
    var buf: [2048]u8 = undefined;
    var ctx = testCtx();
    ctx.auth_cfg = .{ .api_token = "secret-token" };
    ctx.auth_cfg.session_secret = auth.deriveSessionSecret(ctx.auth_cfg.api_token);
    try testing.expectEqual(std.http.Status.unauthorized, handle(&buf, .GET, "/api/v1/state", ctx).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/health/live", ctx).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/api/v1/auth/status", ctx).status);

    const authed = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/state",
        .x_api_token = "secret-token",
        .now_ms = 1_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, authed.status);

    var cookie_scratch: [256]u8 = undefined;
    ctx.cookie_buf = &cookie_scratch;
    const login = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/auth/login",
        .body = "{\"token\":\"secret-token\"}",
        .now_ms = 1_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, login.status);
    try testing.expect(login.set_cookie != null);
}

test "auth status rp_id follows Host header" {
    var buf: [2048]u8 = undefined;
    var ctx = testCtx();
    ctx.auth_cfg = .{
        .api_token = "t",
        .rp_id = "localhost",
        .origin = "http://127.0.0.1:8080",
    };
    ctx.auth_cfg.session_secret = auth.deriveSessionSecret(ctx.auth_cfg.api_token);

    const r = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/auth/status",
        .host = "10.0.0.5:8080",
        .now_ms = 1,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, r.status);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"rp_id\":\"10.0.0.5\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.body, "\"origin\":\"http://10.0.0.5:8080\"") != null);

    const r2 = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/auth/status",
        .host = "dash.example.com",
        .forwarded_proto = "https",
        .now_ms = 1,
    }, ctx);
    try testing.expect(std.mem.indexOf(u8, r2.body, "\"rp_id\":\"dash.example.com\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2.body, "\"origin\":\"https://dash.example.com\"") != null);

    // reject host chars that would break JSON
    const r3 = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/auth/status",
        .host = "evil\",\"x\":\"1",
        .now_ms = 1,
    }, ctx);
    try testing.expect(std.mem.indexOf(u8, r3.body, "\"rp_id\":\"localhost\"") != null);
}

test "forwardedClientIp uses rightmost under append semantics" {
    // Client forged left side; real client is last hop before our single trusted proxy.
    try testing.expectEqualStrings(
        "203.0.113.50",
        forwardedClientIp("1.2.3.4, 203.0.113.50", 1),
    );
    try testing.expectEqualStrings(
        "203.0.113.50",
        forwardedClientIp("203.0.113.50", 1),
    );
    // Two trusted hops: client is second from right.
    try testing.expectEqualStrings(
        "198.51.100.7",
        forwardedClientIp("evil, 198.51.100.7, 10.0.0.1", 2),
    );
    try testing.expectEqualStrings("", forwardedClientIp("  ", 1));
}

test "auth fail guard locks login after repeated bad tokens" {
    var buf: [2048]u8 = undefined;
    var guard = auth.FailGuard{};
    var ctx = testCtx();
    ctx.auth_cfg = .{ .api_token = "correct-token-value-ok" };
    ctx.auth_cfg.session_secret = auth.deriveSessionSecret(ctx.auth_cfg.api_token);
    ctx.fail_guard = &guard;
    var cookie_scratch: [256]u8 = undefined;
    ctx.cookie_buf = &cookie_scratch;

    var now: i64 = 5_000_000;
    var i: u32 = 0;
    while (i < auth.fail_max_per_window) : (i += 1) {
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/auth/login",
            .client_ip = "198.51.100.20",
            .body = "{\"token\":\"wrong\"}",
            .now_ms = now,
        }, ctx);
        now += 10;
        if (i + 1 < auth.fail_max_per_window) {
            try testing.expectEqual(std.http.Status.unauthorized, r.status);
        } else {
            try testing.expectEqual(std.http.Status.too_many_requests, r.status);
            try testing.expect(r.retry_after_sec != null);
        }
    }
    // still locked
    const locked = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/auth/login",
        .client_ip = "198.51.100.20",
        .body = "{\"token\":\"correct-token-value-ok\"}",
        .now_ms = now,
    }, ctx);
    try testing.expectEqual(std.http.Status.too_many_requests, locked.status);

    // other IP can still login
    const ok = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/auth/login",
        .client_ip = "198.51.100.99",
        .body = "{\"token\":\"correct-token-value-ok\"}",
        .now_ms = now,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, ok.status);

    // bare 401 without credential does not consume budget
    var guard2 = auth.FailGuard{};
    ctx.fail_guard = &guard2;
    var j: u32 = 0;
    while (j < auth.fail_max_per_window + 3) : (j += 1) {
        const r = handleReq(&buf, .{
            .method = .GET,
            .target = "/api/v1/state",
            .client_ip = "203.0.113.1",
            .now_ms = now + j,
        }, ctx);
        try testing.expectEqual(std.http.Status.unauthorized, r.status);
    }
    try testing.expectEqual(@as(u32, 0), guard2.lockedSeconds("203.0.113.1", now + 100));

    // wrong bearer does consume budget
    var k: u32 = 0;
    while (k < auth.fail_max_per_window) : (k += 1) {
        _ = handleReq(&buf, .{
            .method = .GET,
            .target = "/api/v1/state",
            .client_ip = "203.0.113.1",
            .x_api_token = "nope",
            .now_ms = now + 1000 + k,
        }, ctx);
    }
    try testing.expect(guard2.lockedSeconds("203.0.113.1", now + 2000) > 0);
}