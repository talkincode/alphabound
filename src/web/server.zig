//! Local dashboard/ops HTTP API (§6.4).
//! Auth: optional API token (Bearer/X-API-Token) + session cookie + passkey.
//! Health probes stay open; data APIs require auth when token is configured.

const std = @import("std");
const state_mod = @import("../core/state.zig");
const sm = @import("../risk/state_machine.zig");
const clock = @import("../core/clock.zig");
const auth = @import("auth.zig");
const review = @import("review.zig");
const intel = @import("../intel/protocol.zig");
const intel_inbox = @import("../intel/inbox.zig");
const db = @import("../storage/db.zig");
const dec = @import("../core/decimal.zig");
const params_write = @import("../params/write.zig");
const params_store = @import("../params/store.zig");
const params_dynamic = @import("../params/dynamic.zig");
const params_backtest = @import("../params/backtest_api.zig");
const strategy_review = @import("../params/strategy_review.zig");
const app_config = @import("../config.zig");

const favicon_svg: []const u8 = @embedFile("favicon_svg");
const favicon_ico: []const u8 = @embedFile("favicon_ico");
const favicon_png: []const u8 = @embedFile("favicon_png");
const apple_touch_icon_png: []const u8 = @embedFile("apple_touch_icon_png");
const icon_192_png: []const u8 = @embedFile("icon_192_png");
const icon_512_png: []const u8 = @embedFile("icon_512_png");

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
    /// Newest non-ok agent runs with `error_class` (filterable history).
    agent_problems_json: []const u8 = "[]",
    equity_json: []const u8 = "[]",
    /// Bucketed long-horizon equity curve, oldest first (4h ≤14d, daily older).
    equity_long_json: []const u8 = "[]",
    /// ~48h downsampled span for `since` / `until` / `step`. Core loop publishes it.
    equity_span_json: []const u8 = "{\"stored_step_minutes\":1,\"window_start\":null,\"cached_from\":null,\"cached_to\":null,\"points\":[]}",
    shadow_json: []const u8 = "{}",
    events_json: []const u8 = "[]",
    candles_json: []const u8 = "[]",
    memories_json: []const u8 = "[]",
    system_json: []const u8 = "{}",
    decisions_json: []const u8 = "[]",
    /// Orders projection + recent fills: `{"orders":[...],"fills":[...]}`.
    orders_json: []const u8 = "{\"orders\":[],\"fills\":[]}",
    /// 复盘 chat transcripts (recent turns, newest first).
    review_json: []const u8 = "[]",
    /// Last rendered 复盘 context window (decision-anchored events).
    review_ctx_json: []const u8 = "{}",
    /// Review request mailbox; null = review feature unavailable.
    review_inbox: ?*review.Inbox = null,
    /// Recent scheduled-audit reports (newest first).
    audit_json: []const u8 = "[]",
    /// Recent 定期复盘 reports (newest first; 8h 小周期 + 周度大周期).
    periodic_json: []const u8 = "[]",
    /// Signed external intel history (no signature/nonce).
    intel_json: []const u8 = "[]",
    /// Fear & Greed daily curve (`now` + chronological `points`).
    sentiment_json: []const u8 = "{}",
    /// Active dynamic-parameter version. Read-only.
    params_json: []const u8 = "{}",
    /// Parameter version history, newest first. Read-only.
    param_versions_json: []const u8 = "[]",
    /// DB path for parameter writes. Empty = writes unavailable.
    /// Writes use a short-lived connection and never touch orders.
    param_db_path: [:0]const u8 = "",
    /// Production default is false: apply requires a passing backtest ref.
    param_allow_unbacked_apply: bool = false,
    /// Absolute notional floor copied from config. The backtest gate uses it
    /// for both sides. The trading loop does not read this field.
    param_min_trade_notional: dec.Decimal = dec.Decimal.zero,
    /// Set by the web cache from the process-owned atomics. Null in unit
    /// tests that do not start the review lane.
    strategy_review_kick: ?*std.atomic.Value(bool) = null,
    strategy_review_running: ?*std.atomic.Value(bool) = null,
    /// Intel ingest mailbox; null = ingest unavailable.
    intel_inbox: ?*intel_inbox.Inbox = null,
    /// HMAC key for alphabound.intel.v1; empty = ingest disabled.
    intel_hmac: []const u8 = "",
    /// AB 因子复盘 analytics blob (experimental, research-only).
    analytics_json: []const u8 = "{}",
    /// Durable LLM token/cost statistics, pre-rendered by the core loop.
    statistics_json: []const u8 = "{}",
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

fn isBrandIconPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/favicon.ico") or
        std.mem.eql(u8, path, "/favicon.svg") or
        std.mem.eql(u8, path, "/favicon.png") or
        std.mem.eql(u8, path, "/apple-touch-icon.png") or
        std.mem.eql(u8, path, "/icon-192.png") or
        std.mem.eql(u8, path, "/icon-512.png");
}

fn isPublicPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/health/live")) return true;
    if (std.mem.eql(u8, path, "/health/ready")) return true;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) return true;
    if (isBrandIconPath(path)) return true;
    if (std.mem.startsWith(u8, path, "/api/v1/auth/")) return true;
    return false;
}

fn brandIconResponse(path: []const u8) ?Response {
    if (std.mem.eql(u8, path, "/favicon.svg")) {
        return .{ .status = .ok, .content_type = "image/svg+xml", .body = favicon_svg };
    }
    if (std.mem.eql(u8, path, "/favicon.ico")) {
        return .{ .status = .ok, .content_type = "image/x-icon", .body = favicon_ico };
    }
    if (std.mem.eql(u8, path, "/favicon.png")) {
        return .{ .status = .ok, .content_type = "image/png", .body = favicon_png };
    }
    if (std.mem.eql(u8, path, "/apple-touch-icon.png")) {
        return .{ .status = .ok, .content_type = "image/png", .body = apple_touch_icon_png };
    }
    if (std.mem.eql(u8, path, "/icon-192.png")) {
        return .{ .status = .ok, .content_type = "image/png", .body = icon_192_png };
    }
    if (std.mem.eql(u8, path, "/icon-512.png")) {
        return .{ .status = .ok, .content_type = "image/png", .body = icon_512_png };
    }
    return null;
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

    // --- brand icons (public; browsers request before login) ---
    if (method == .GET) {
        if (brandIconResponse(path)) |icon| return icon;
    }

    // --- protected data APIs ---
    if (!isPublicPath(path)) {
        if (checkProtectedAuth(ctx, req)) |denied| return denied;
    }

    if (method == .POST and std.mem.eql(u8, path, "/api/v1/review/strategy")) {
        return handleStrategyReviewPost(ctx);
    }
    // --- review (复盘) POST mailbox: analysis-only, never touches trading ---
    if (method == .POST and std.mem.startsWith(u8, path, "/api/v1/review/")) {
        return handleReviewPost(req, path, ctx);
    }
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/intel")) {
        return handleIntelPost(buf, req, ctx);
    }
    if (method == .POST and std.mem.startsWith(u8, path, "/api/v1/params/")) {
        if (std.mem.eql(u8, path, "/api/v1/params/backtest")) return handleBacktestPost(buf, req, ctx);
        return handleParamPost(buf, req, path, ctx);
    }

    if (method != .GET) {
        return .{ .status = .method_not_allowed, .body = "{\"error\":\"method not allowed\"}" };
    }
    if (std.mem.eql(u8, path, "/api/v1/state")) return renderState(buf, ctx);
    if (std.mem.eql(u8, path, "/api/v1/events")) {
        const filter = EventFilter.fromTarget(req.target);
        if (filter.active()) return filterEventsJson(buf, ctx.events_json, filter);
        if (ctx.recent_events.len > 0) return renderEvents(buf, ctx);
        return copyBody(buf, ctx.events_json);
    }
    if (std.mem.eql(u8, path, "/api/v1/agent-runs")) {
        const q = RunsQuery.fromTarget(req.target);
        if (!q.active()) return copyBody(buf, ctx.agent_runs_json);
        // `status=ok` lives only in the recent-50 blob; everything else is in
        // the non-ok history blob.
        const ok_only = if (q.status) |st| std.ascii.eqlIgnoreCase(st, "ok") else false;
        return filterAgentRuns(buf, if (ok_only) ctx.agent_runs_json else ctx.agent_problems_json, if (ok_only) "recent" else "problems", q);
    }
    if (std.mem.eql(u8, path, "/api/v1/equity")) {
        const q = EquityQuery.fromTarget(req.target);
        if (!q.active()) return copyBody(buf, ctx.equity_json);
        if (q.ranged() and q.longActive()) {
            return .{ .status = .bad_request, .body = equity_conflict_body };
        }
        if (q.ranged()) return filterEquityRange(buf, ctx.equity_span_json, q);
        return filterEquityLong(buf, ctx.equity_long_json, q);
    }
    if (std.mem.eql(u8, path, "/api/v1/shadow")) return copyBody(buf, ctx.shadow_json);
    if (std.mem.eql(u8, path, "/api/v1/candles")) return copyBody(buf, ctx.candles_json);
    if (std.mem.eql(u8, path, "/api/v1/memories")) return copyBody(buf, ctx.memories_json);
    if (std.mem.eql(u8, path, "/api/v1/system")) return copyBody(buf, ctx.system_json);
    if (std.mem.eql(u8, path, "/api/v1/decisions")) return copyBody(buf, ctx.decisions_json);
    if (std.mem.eql(u8, path, "/api/v1/orders")) return copyBody(buf, ctx.orders_json);
    if (std.mem.eql(u8, path, "/api/v1/review/chats")) return copyBody(buf, ctx.review_json);
    if (std.mem.eql(u8, path, "/api/v1/review/context")) return copyBody(buf, ctx.review_ctx_json);
    if (std.mem.eql(u8, path, "/api/v1/review/analytics")) return copyBody(buf, ctx.analytics_json);
    if (std.mem.eql(u8, path, "/api/v1/review/periodic")) return copyBody(buf, ctx.periodic_json);
    if (std.mem.eql(u8, path, "/api/v1/review/strategy")) return handleStrategyReviewGet(buf, req, ctx);
    if (std.mem.eql(u8, path, "/api/v1/audit")) return copyBody(buf, ctx.audit_json);
    if (std.mem.eql(u8, path, "/api/v1/statistics")) return copyBody(buf, ctx.statistics_json);
    if (std.mem.eql(u8, path, "/api/v1/intel")) return copyBody(buf, ctx.intel_json);
    if (std.mem.eql(u8, path, "/api/v1/sentiment")) return copyBody(buf, ctx.sentiment_json);
    if (std.mem.eql(u8, path, "/api/v1/params/backtest")) return handleBacktestGet(buf, req, ctx);
    if (std.mem.eql(u8, path, "/api/v1/params/versions")) return copyBody(buf, ctx.param_versions_json);
    if (std.mem.eql(u8, path, "/api/v1/params")) return copyBody(buf, ctx.params_json);
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

/// Enqueue a review request (chat / context / summarize). The core loop
/// processes it and publishes results via the pre-rendered review blobs.
fn handleReviewPost(req: RequestInfo, path: []const u8, ctx: Context) Response {
    const inbox = ctx.review_inbox orelse {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"review_unavailable\"}" };
    };
    const kind: review.Kind = if (std.mem.eql(u8, path, "/api/v1/review/chat"))
        .chat
    else if (std.mem.eql(u8, path, "/api/v1/review/context"))
        .context
    else if (std.mem.eql(u8, path, "/api/v1/review/summarize"))
        .summarize
    else if (std.mem.eql(u8, path, "/api/v1/review/periodic"))
        .periodic
    else {
        return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
    };

    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, req.body, .{}) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .status = .bad_request, .body = "{\"error\":\"bad_json\"}" };
    const obj = parsed.value.object;
    const decision_id = if (kind == .periodic)
        (jsonGetString(obj, "cycle") orelse "")
    else
        (jsonGetString(obj, "decision_id") orelse "");
    const anchor_ts = jsonGetString(obj, "anchor_ts") orelse "";
    const message = std.mem.trim(u8, jsonGetString(obj, "message") orelse "", " \t\r\n");

    inbox.enqueue(kind, decision_id, anchor_ts, message) catch |err| switch (err) {
        review.EnqueueError.BadInput => return .{ .status = .bad_request, .body = "{\"error\":\"bad_input\"}" },
        review.EnqueueError.Full => return .{
            .status = .too_many_requests,
            .body = "{\"error\":\"busy\",\"hint\":\"review_queue_full\"}",
            .retry_after_sec = 5,
        },
        review.EnqueueError.DuplicatePending => return .{
            .status = .conflict,
            .body = "{\"error\":\"pending\",\"hint\":\"request_already_queued\"}",
        },
    };
    return .{ .status = .accepted, .body = "{\"ok\":true,\"queued\":true}" };
}

fn handleIntelPost(buf: []u8, req: RequestInfo, ctx: Context) Response {
    if (ctx.intel_hmac.len < intel.min_hmac_key) {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"signing_unconfigured\"}" };
    }
    const inbox = ctx.intel_inbox orelse {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"intel_unavailable\"}" };
    };
    const now = if (req.now_ms == 0) clock.SystemClock.clock().wallMs() else req.now_ms;
    var item = intel.Item{};
    intel.parse(std.heap.page_allocator, ctx.intel_hmac, now, req.body, &item) catch |err| {
        const reason = intel.errorReason(err);
        const body = std.fmt.bufPrint(buf, "{{\"error\":\"invalid_intel\",\"reason\":\"{s}\"}}", .{reason}) catch
            return .{ .status = .bad_request, .body = "{\"error\":\"invalid_intel\"}" };
        const status: std.http.Status = if (err == error.NoKey) .service_unavailable else .bad_request;
        return .{ .status = status, .body = body };
    };
    inbox.enqueue(item, now) catch |err| switch (err) {
        intel_inbox.EnqueueError.Full => return .{
            .status = .too_many_requests,
            .body = "{\"error\":\"busy\",\"hint\":\"intel_queue_full\"}",
            .retry_after_sec = 5,
        },
        intel_inbox.EnqueueError.DuplicatePending => return .{
            .status = .conflict,
            .body = "{\"error\":\"pending\",\"hint\":\"intel_already_queued\"}",
        },
        intel_inbox.EnqueueError.RateLimited => return .{
            .status = .too_many_requests,
            .body = "{\"error\":\"rate_limited\",\"hint\":\"intel_source_rate\"}",
            .retry_after_sec = 60,
        },
    };
    const body = std.fmt.bufPrint(
        buf,
        "{{\"ok\":true,\"queued\":true,\"id\":\"{s}\",\"dedup_key\":\"{s}\"}}",
        .{ item.id(), item.dedupKey() },
    ) catch return .{ .status = .accepted, .body = "{\"ok\":true,\"queued\":true}" };
    return .{ .status = .accepted, .body = body };
}

fn handleStrategyReviewPost(ctx: Context) Response {
    if (!ctx.auth_cfg.required()) {
        return .{ .status = .unauthorized, .body = "{\"error\":\"auth_required\"}" };
    }
    const kick = ctx.strategy_review_kick orelse {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"review_unavailable\"}" };
    };
    if (ctx.strategy_review_running) |running| {
        if (running.load(.acquire)) {
            return .{ .status = .conflict, .body = "{\"error\":\"pending\",\"hint\":\"review_already_running\"}" };
        }
    }
    kick.store(true, .release);
    return .{ .status = .accepted, .body = "{\"ok\":true,\"queued\":true}" };
}

fn handleStrategyReviewGet(buf: []u8, req: RequestInfo, ctx: Context) Response {
    if (ctx.param_db_path.len == 0) {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"review_unavailable\"}" };
    }
    var database = db.Db.open(ctx.param_db_path) catch {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"review_unavailable\"}" };
    };
    defer database.close();
    if (queryParam(req.target, "id")) |id| {
        const result = strategy_review.getJson(&database, id, buf) catch {
            return .{ .status = .internal_server_error, .body = "{\"error\":\"review_failed\"}" };
        };
        const status: std.http.Status = switch (result.status) {
            .ok => .ok,
            .bad_id => .bad_request,
            .not_found => .not_found,
        };
        return .{ .status = status, .body = result.body };
    }
    const body = strategy_review.listJson(&database, buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"review_failed\"}" };
    };
    return .{ .status = .ok, .body = body };
}

fn handleBacktestPost(buf: []u8, req: RequestInfo, ctx: Context) Response {
    if (!ctx.auth_cfg.required()) {
        return .{ .status = .unauthorized, .body = "{\"error\":\"auth_required\"}" };
    }
    if (ctx.param_db_path.len == 0) {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    }
    var database = db.Db.open(ctx.param_db_path) catch {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    };
    defer database.close();
    const now = if (req.now_ms == 0) clock.SystemClock.clock().wallMs() else req.now_ms;
    const result = params_backtest.run(&database, ctx.param_min_trade_notional, now, req.body, buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"backtest_failed\"}" };
    };
    return .{ .status = result.status.http(), .body = result.body };
}

fn handleBacktestGet(buf: []u8, req: RequestInfo, ctx: Context) Response {
    if (ctx.param_db_path.len == 0) {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    }
    const id = queryParam(req.target, "id") orelse {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad_id\",\"field\":\"id\"}" };
    };
    var database = db.Db.open(ctx.param_db_path) catch {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    };
    defer database.close();
    const result = params_backtest.get(&database, id, buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"backtest_failed\"}" };
    };
    return .{ .status = result.status.http(), .body = result.body };
}

fn handleParamPost(buf: []u8, req: RequestInfo, path: []const u8, ctx: Context) Response {
    if (!ctx.auth_cfg.required()) {
        return .{ .status = .unauthorized, .body = "{\"error\":\"auth_required\"}" };
    }
    const action: params_write.Action = if (std.mem.eql(u8, path, "/api/v1/params/propose"))
        .propose
    else if (std.mem.eql(u8, path, "/api/v1/params/apply"))
        .apply
    else if (std.mem.eql(u8, path, "/api/v1/params/rollback"))
        .rollback
    else
        return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
    if (ctx.param_db_path.len == 0) {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    }
    var database = db.Db.open(ctx.param_db_path) catch {
        return .{ .status = .service_unavailable, .body = "{\"error\":\"params_unavailable\"}" };
    };
    defer database.close();
    const now = if (req.now_ms == 0) clock.SystemClock.clock().wallMs() else req.now_ms;
    const result = params_write.writeApi(&database, ctx.param_allow_unbacked_apply, now, action, req.body, buf) catch {
        return .{ .status = .internal_server_error, .body = "{\"error\":\"params_write_failed\"}" };
    };
    return .{ .status = paramHttpStatus(result.status), .body = result.body };
}

fn paramHttpStatus(status: params_write.OpStatus) std.http.Status {
    return switch (status) {
        .ok, .unchanged => .ok,
        .rejected, .backtest_required, .backtest_rejected => .unprocessable_entity,
        .conflict, .bad_version => .conflict,
        .not_found => .not_found,
        .bad_request => .bad_request,
    };
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
            return finishPasskeyLogin(buf, ctx, req, wa.origin, wa.rp_id, now, bank, cred.pub_sec1, cd_buf[0..n2], auth_data_b64, sig_b64, challenge_b64);
        };
        return finishPasskeyLogin(buf, ctx, req, wa.origin, wa.rp_id, now, bank, cred.pub_sec1, cd_buf[0..cd_n], auth_data_b64, sig_b64, challenge_b64);
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
    expected_rp_id: []const u8,
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
        expected_rp_id,
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
        s.objectField("unresolved_orders") catch break :render;
        s.write(snap.unresolved_orders) catch break :render;
        s.objectField("foreign_pending") catch break :render;
        s.write(snap.foreign_pending) catch break :render;
        s.objectField("account_projected") catch break :render;
        s.write(snap.account_projected) catch break :render;
        s.objectField("ledger_ok") catch break :render;
        s.write(snap.ledger_ok) catch break :render;

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

/// Query-string filter for /api/v1/events: ?type= / ?severity= / ?exclude_type=.
/// Values are matched case-insensitively against top-level event fields.
const EventFilter = struct {
    type_eq: ?[]const u8 = null,
    exclude_type: ?[]const u8 = null,
    severity_eq: ?[]const u8 = null,

    fn active(self: EventFilter) bool {
        return self.type_eq != null or self.exclude_type != null or self.severity_eq != null;
    }

    fn fromTarget(target: []const u8) EventFilter {
        const qpos = std.mem.indexOfScalar(u8, target, '?') orelse return .{};
        var f = EventFilter{};
        var it = std.mem.splitScalar(u8, target[qpos + 1 ..], '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (val.len == 0 or val.len > 64) continue;
            if (std.mem.eql(u8, key, "type")) f.type_eq = val;
            if (std.mem.eql(u8, key, "exclude_type")) f.exclude_type = val;
            if (std.mem.eql(u8, key, "severity")) f.severity_eq = val;
        }
        return f;
    }

    fn matches(self: EventFilter, obj: []const u8) bool {
        if (self.type_eq) |want| {
            const got = topLevelString(obj, "type") orelse return false;
            if (!std.ascii.eqlIgnoreCase(got, want)) return false;
        }
        if (self.exclude_type) |skip| {
            if (topLevelString(obj, "type")) |got| {
                if (std.ascii.eqlIgnoreCase(got, skip)) return false;
            }
        }
        if (self.severity_eq) |want| {
            const got = topLevelString(obj, "severity") orelse return false;
            if (!std.ascii.eqlIgnoreCase(got, want)) return false;
        }
        return true;
    }
};

/// Extract a top-level (depth-1) string value from a rendered JSON object.
/// Depth/string-aware so keys inside nested payload objects never match.
fn topLevelString(obj: []const u8, key: []const u8) ?[]const u8 {
    var depth: i32 = 0;
    var in_str = false;
    var escaped = false;
    var i: usize = 0;
    while (i < obj.len) : (i += 1) {
        const ch = obj[i];
        if (in_str) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_str = false;
            }
            continue;
        }
        switch (ch) {
            '{', '[' => depth += 1,
            '}', ']' => depth -= 1,
            '"' => {
                if (depth == 1) {
                    // Candidate key at top level: "key":"value"
                    const rest = obj[i + 1 ..];
                    if (rest.len > key.len + 3 and
                        std.mem.startsWith(u8, rest, key) and
                        std.mem.startsWith(u8, rest[key.len..], "\":\""))
                    {
                        const vstart = i + 1 + key.len + 3;
                        var j = vstart;
                        while (j < obj.len) : (j += 1) {
                            if (obj[j] == '\\') {
                                j += 1;
                                continue;
                            }
                            if (obj[j] == '"') return obj[vstart..j];
                        }
                        return null;
                    }
                }
                in_str = true;
            },
            else => {},
        }
    }
    return null;
}

/// Stream the pre-rendered events array through the filter into `buf`.
/// Splits top-level array elements with a string/escape-aware scanner.
fn filterEventsJson(buf: []u8, src: []const u8, filter: EventFilter) Response {
    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.writeAll("[") catch break :render;
        var wrote = false;
        var depth: i32 = 0;
        var in_str = false;
        var escaped = false;
        var obj_start: ?usize = null;
        for (src, 0..) |ch, i| {
            if (in_str) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    in_str = false;
                }
                continue;
            }
            switch (ch) {
                '"' => in_str = true,
                '{' => {
                    if (depth == 1 and obj_start == null) obj_start = i;
                    depth += 1;
                },
                '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth == 1) {
                        if (obj_start) |s| {
                            const obj = src[s .. i + 1];
                            obj_start = null;
                            if (filter.matches(obj)) {
                                if (wrote) w.writeAll(",") catch break :render;
                                w.writeAll(obj) catch break :render;
                                wrote = true;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        w.writeAll("]") catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

/// Iterates the top-level objects of a pre-rendered JSON array
/// (string/escape-aware, like `filterEventsJson`).
const ArrayObjIter = struct {
    src: []const u8,
    i: usize = 0,
    depth: i32 = 0,
    in_str: bool = false,
    escaped: bool = false,
    obj_start: ?usize = null,

    fn next(self: *ArrayObjIter) ?[]const u8 {
        while (self.i < self.src.len) : (self.i += 1) {
            const ch = self.src[self.i];
            if (self.in_str) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (ch == '\\') {
                    self.escaped = true;
                } else if (ch == '"') {
                    self.in_str = false;
                }
                continue;
            }
            switch (ch) {
                '"' => self.in_str = true,
                '{' => {
                    if (self.depth == 1 and self.obj_start == null) self.obj_start = self.i;
                    self.depth += 1;
                },
                '[' => self.depth += 1,
                '}', ']' => {
                    self.depth -= 1;
                    if (self.depth == 1) {
                        if (self.obj_start) |st| {
                            self.obj_start = null;
                            self.i += 1;
                            return self.src[st..self.i];
                        }
                    }
                },
                else => {},
            }
        }
        return null;
    }
};

fn queryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const qpos = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[qpos + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const val = pair[eq + 1 ..];
        if (val.len == 0 or val.len > 64) return null;
        return val;
    }
    return null;
}

const runs_page_default: usize = 50;
const runs_page_max: usize = 200;

/// /api/v1/agent-runs filters: ?status= (exact, or family prefix `error` →
/// `error_*`), ?error_class=, ?before=<started_ts cursor>, ?limit=.
const RunsQuery = struct {
    status: ?[]const u8 = null,
    error_class: ?[]const u8 = null,
    before: ?[]const u8 = null,
    limit: usize = runs_page_default,
    paged: bool = false,

    fn active(self: RunsQuery) bool {
        return self.status != null or self.error_class != null or self.before != null or self.paged;
    }

    fn fromTarget(target: []const u8) RunsQuery {
        var q = RunsQuery{
            .status = queryParam(target, "status"),
            .error_class = queryParam(target, "error_class"),
            .before = queryParam(target, "before"),
        };
        if (queryParam(target, "limit")) |raw| {
            if (std.fmt.parseInt(usize, raw, 10)) |n| {
                q.limit = std.math.clamp(n, 1, runs_page_max);
                q.paged = true;
            } else |_| {}
        }
        return q;
    }

    fn matches(self: RunsQuery, obj: []const u8) bool {
        if (self.status) |want| {
            const got = topLevelString(obj, "status") orelse return false;
            const exact = std.ascii.eqlIgnoreCase(got, want);
            const family = got.len > want.len and got[want.len] == '_' and std.ascii.eqlIgnoreCase(got[0..want.len], want);
            if (!exact and !family) return false;
        }
        if (self.error_class) |want| {
            const got = topLevelString(obj, "error_class") orelse return false;
            if (!std.ascii.eqlIgnoreCase(got, want)) return false;
        }
        return true;
    }
};

/// Tiny fixed-capacity string→count tally for the by_status / by_class summaries.
const Tally = struct {
    const cap = 16;
    keys: [cap][]const u8 = undefined,
    counts: [cap]usize = @splat(0),
    n: usize = 0,
    other: usize = 0,

    fn add(self: *Tally, key: []const u8) void {
        for (self.keys[0..self.n], 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                self.counts[i] += 1;
                return;
            }
        }
        if (self.n < cap) {
            self.keys[self.n] = key;
            self.counts[self.n] = 1;
            self.n += 1;
        } else self.other += 1;
    }

    fn write(self: *const Tally, w: *std.Io.Writer) error{WriteFailed}!void {
        try w.writeAll("{");
        for (self.keys[0..self.n], 0..) |k, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\":{d}", .{ k, self.counts[i] });
        }
        if (self.other > 0) {
            if (self.n > 0) try w.writeAll(",");
            try w.print("\"_other\":{d}", .{self.other});
        }
        try w.writeAll("}");
    }
};

/// Page the pre-rendered agent-run history through the query. Items are newest
/// first; `next_before` is the cursor for the next page (null when exhausted).
/// Counts cover every matching row regardless of `before`/`limit`.
fn filterAgentRuns(buf: []u8, src: []const u8, source: []const u8, q: RunsQuery) Response {
    var by_status = Tally{};
    var by_class = Tally{};
    var total: usize = 0;
    var it = ArrayObjIter{ .src = src };
    while (it.next()) |obj| {
        if (!q.matches(obj)) continue;
        total += 1;
        by_status.add(topLevelString(obj, "status") orelse "");
        if (topLevelString(obj, "error_class")) |c| by_class.add(c);
    }

    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.print("{{\"source\":\"{s}\",\"total_matching\":{d},\"by_status\":", .{ source, total }) catch break :render;
        by_status.write(&w) catch break :render;
        w.writeAll(",\"by_class\":") catch break :render;
        by_class.write(&w) catch break :render;
        w.writeAll(",\"items\":[") catch break :render;

        var returned: usize = 0;
        var last_ts: []const u8 = "";
        var more = false;
        var it2 = ArrayObjIter{ .src = src };
        while (it2.next()) |obj| {
            if (!q.matches(obj)) continue;
            const ts = topLevelString(obj, "started_ts") orelse "";
            if (q.before) |b| {
                if (std.mem.order(u8, ts, b) != .lt) continue;
            }
            if (returned >= q.limit) {
                more = true;
                break;
            }
            if (returned > 0) w.writeAll(",") catch break :render;
            w.writeAll(obj) catch break :render;
            returned += 1;
            last_ts = ts;
        }
        w.print("],\"returned\":{d},\"next_before\":", .{returned}) catch break :render;
        if (more) {
            w.print("\"{s}\"", .{last_ts}) catch break :render;
        } else {
            w.writeAll("null") catch break :render;
        }
        w.writeAll("}") catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

/// Hard cap for `since` / `until` / `step` so one response stays inside the
/// HTTP body buffer even when decimal text is wide.
pub const equity_range_max_points: usize = 480;

const equity_conflict_body = "{\"error\":\"conflicting_query\",\"hint\":\"since, until, and step cannot be combined with window, from, to, or limit\"}";
const equity_range_auto_steps = [_]i64{ 1, 5, 10, 15, 30, 60, 120, 240, 480, 720, 1440 };

/// /api/v1/equity long-horizon view: ?window=long[&from=<RFC3339 prefix>&to=<prefix>&limit=N].
/// `from`/`to` are inclusive date(-time) prefixes, e.g. `2026-09-09`.
/// Ranged view: ?since=&until=&step= over the pre-rendered ~48h span.
const EquityQuery = struct {
    long: bool = false,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    limit: usize = 0,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    step_raw: ?[]const u8 = null,

    fn ranged(self: EquityQuery) bool {
        return self.since != null or self.until != null or self.step_raw != null;
    }

    fn longActive(self: EquityQuery) bool {
        return self.long or self.from != null or self.to != null or self.limit > 0;
    }

    fn active(self: EquityQuery) bool {
        return self.ranged() or self.longActive();
    }

    fn fromTarget(target: []const u8) EquityQuery {
        var q = EquityQuery{ .from = queryParam(target, "from"), .to = queryParam(target, "to") };
        q.since = queryParam(target, "since");
        q.until = queryParam(target, "until");
        q.step_raw = queryParam(target, "step");
        if (queryParam(target, "window")) |wnd| q.long = std.ascii.eqlIgnoreCase(wnd, "long");
        if (queryParam(target, "limit")) |raw| {
            q.limit = std.fmt.parseInt(usize, raw, 10) catch 0;
        }
        return q;
    }

    fn inSpan(self: EquityQuery, ts: []const u8) bool {
        if (self.since) |f| {
            const n = @min(ts.len, f.len);
            if (n == 0 or std.mem.order(u8, ts[0..n], f[0..n]) == .lt) return false;
        }
        if (self.until) |t| {
            const n = @min(ts.len, t.len);
            if (n == 0 or std.mem.order(u8, ts[0..n], t[0..n]) == .gt) return false;
        }
        return true;
    }

    fn inRange(self: EquityQuery, ts: []const u8) bool {
        if (self.from) |f| {
            if (std.mem.order(u8, ts[0..@min(ts.len, f.len)], f) == .lt) return false;
        }
        if (self.to) |t| {
            if (std.mem.order(u8, ts[0..@min(ts.len, t.len)], t) == .gt) return false;
        }
        return true;
    }
};

/// Serve the bucketed long-horizon equity rows (oldest first) within the
/// requested range; with `limit`, only the newest N matching rows.
fn filterEquityLong(buf: []u8, src: []const u8, q: EquityQuery) Response {
    var matched: usize = 0;
    var it = ArrayObjIter{ .src = src };
    while (it.next()) |obj| {
        if (q.inRange(topLevelString(obj, "ts") orelse "")) matched += 1;
    }
    const skip = if (q.limit > 0 and matched > q.limit) matched - q.limit else 0;

    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.writeAll("[") catch break :render;
        var seen: usize = 0;
        var wrote = false;
        var it2 = ArrayObjIter{ .src = src };
        while (it2.next()) |obj| {
            if (!q.inRange(topLevelString(obj, "ts") orelse "")) continue;
            seen += 1;
            if (seen <= skip) continue;
            if (wrote) w.writeAll(",") catch break :render;
            w.writeAll(obj) catch break :render;
            wrote = true;
        }
        w.writeAll("]") catch break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
}

const SpanMeta = struct {
    step: i64 = 1,
    window_start: ?[]const u8 = null,
    cached_from: ?[]const u8 = null,
    cached_to: ?[]const u8 = null,
    points: []const u8 = "[]",
};

fn wrapperAt(src: []const u8, key: []const u8) ?usize {
    var needle: [64]u8 = undefined;
    const n = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    return std.mem.indexOf(u8, src, n);
}

fn wrapperString(src: []const u8, key: []const u8) ?[]const u8 {
    const at = wrapperAt(src, key) orelse return null;
    var needle: [64]u8 = undefined;
    const n = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    var i = at + n.len;
    while (i < src.len and src[i] == ' ') i += 1;
    if (i >= src.len or src[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
    return src[start..end];
}

fn wrapperInt(src: []const u8, key: []const u8) ?i64 {
    const at = wrapperAt(src, key) orelse return null;
    var needle: [64]u8 = undefined;
    const n = std.fmt.bufPrint(&needle, "\"{s}\":", .{key}) catch return null;
    var i = at + n.len;
    while (i < src.len and src[i] == ' ') i += 1;
    const start = i;
    if (i < src.len and (src[i] == '-' or src[i] == '+')) i += 1;
    const digits = i;
    while (i < src.len and src[i] >= '0' and src[i] <= '9') i += 1;
    if (i == digits) return null;
    return std.fmt.parseInt(i64, src[start..i], 10) catch null;
}

fn spanMeta(src: []const u8) SpanMeta {
    const points = if (std.mem.indexOf(u8, src, "\"points\":")) |at| blk: {
        const rest = src[at + "\"points\":".len ..];
        const lb = std.mem.indexOfScalar(u8, rest, '[') orelse break :blk "[]";
        break :blk rest[lb..];
    } else if (src.len > 0 and src[0] == '[') src else "[]";
    const step = wrapperInt(src, "stored_step_minutes") orelse 1;
    return .{
        .step = if (step < 1) 1 else step,
        .window_start = wrapperString(src, "window_start"),
        .cached_from = wrapperString(src, "cached_from"),
        .cached_to = wrapperString(src, "cached_to"),
        .points = points,
    };
}

fn parseStepMinutes(raw: []const u8) ?i64 {
    if (raw.len == 0 or raw.len > 5) return null;
    for (raw) |ch| if (ch < '0' or ch > '9') return null;
    const n = std.fmt.parseInt(i64, raw, 10) catch return null;
    if (n < 1 or n > 10080) return null;
    return n;
}

fn prefixBefore(bound: []const u8, ts: []const u8) bool {
    const n = @min(bound.len, ts.len);
    if (n == 0) return false;
    return std.mem.order(u8, bound[0..n], ts[0..n]) == .lt;
}

fn countSpanStep(points: []const u8, q: EquityQuery, step_min: i64) usize {
    const step_ms = step_min * std.time.ms_per_min;
    var count: usize = 0;
    var open = false;
    var open_bucket: i64 = 0;
    var it = ArrayObjIter{ .src = points };
    while (it.next()) |obj| {
        const ts = topLevelString(obj, "ts") orelse continue;
        if (!q.inSpan(ts)) continue;
        const ts_ms = clock.parseRfc3339Ms(ts) catch continue;
        const bucket = @divFloor(ts_ms, step_ms);
        if (!open or bucket != open_bucket) {
            if (open) count += 1;
            open = true;
            open_bucket = bucket;
        }
    }
    if (open) count += 1;
    return count;
}

fn nextAutoStep(stored: i64, current: i64) ?i64 {
    var seen = false;
    for (equity_range_auto_steps) |step| {
        if (step < stored or @mod(step, stored) != 0) continue;
        if (!seen) {
            if (step == current) seen = true;
            continue;
        }
        return step;
    }
    return null;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    try w.writeAll(s);
    try w.writeByte('"');
}

/// Bounded `since` / `until` / `step` view. Default (no range params) never
/// reaches here. Points are the bucket's last sample, oldest first. An omitted
/// step uses the stored step and coarsens only when the selection would exceed
/// `equity_range_max_points`. An explicit step that is too wide is rejected.
fn filterEquityRange(buf: []u8, src: []const u8, q: EquityQuery) Response {
    const meta = spanMeta(src);
    if (q.since) |since| {
        if (meta.window_start == null or prefixBefore(since, meta.window_start.?)) {
            var w: std.Io.Writer = .fixed(buf);
            w.writeAll("{\"error\":\"range_not_cached\",\"window_start\":") catch {
                return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            };
            if (meta.window_start) |ws| {
                writeJsonString(&w, ws) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            } else {
                w.writeAll("null") catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            }
            w.print(
                ",\"stored_step_minutes\":{d},\"hint\":\"series covers about 48h; use window=long for older buckets or get_statistics for 7d and 30d windows\"}}",
                .{meta.step},
            ) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            return .{ .status = .bad_request, .body = w.buffered() };
        }
    }

    var step: i64 = meta.step;
    var explicit = false;
    if (q.step_raw) |raw| {
        explicit = true;
        step = parseStepMinutes(raw) orelse {
            var w: std.Io.Writer = .fixed(buf);
            w.print(
                "{{\"error\":\"bad_step\",\"stored_step_minutes\":{d},\"hint\":\"step is whole minutes from 1 to 10080 and a multiple of stored_step_minutes\"}}",
                .{meta.step},
            ) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            return .{ .status = .bad_request, .body = w.buffered() };
        };
        if (@mod(step, meta.step) != 0) {
            var w: std.Io.Writer = .fixed(buf);
            w.print(
                "{{\"error\":\"step_too_fine\",\"stored_step_minutes\":{d},\"hint\":\"step must be a positive multiple of stored_step_minutes\"}}",
                .{meta.step},
            ) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
            return .{ .status = .bad_request, .body = w.buffered() };
        }
    }

    var count = countSpanStep(meta.points, q, step);
    if (!explicit) {
        while (count > equity_range_max_points) {
            step = nextAutoStep(meta.step, step) orelse break;
            count = countSpanStep(meta.points, q, step);
        }
    }
    if (count > equity_range_max_points) {
        var w: std.Io.Writer = .fixed(buf);
        w.print(
            "{{\"error\":\"range_too_wide\",\"max_points\":{d},\"stored_step_minutes\":{d},\"hint\":\"narrow since/until or increase step\"}}",
            .{ equity_range_max_points, meta.step },
        ) catch return .{ .status = .internal_server_error, .body = "{\"error\":\"render\"}" };
        return .{ .status = .bad_request, .body = w.buffered() };
    }

    const step_ms = step * std.time.ms_per_min;
    var w: std.Io.Writer = .fixed(buf);
    render: {
        w.print(
            "{{\"stored_step_minutes\":{d},\"step_minutes\":{d},\"max_points\":{d},\"window_start\":",
            .{ meta.step, step, equity_range_max_points },
        ) catch break :render;
        if (meta.window_start) |ws| writeJsonString(&w, ws) catch break :render else w.writeAll("null") catch break :render;
        w.writeAll(",\"cached_from\":") catch break :render;
        if (meta.cached_from) |cf| writeJsonString(&w, cf) catch break :render else w.writeAll("null") catch break :render;
        w.writeAll(",\"cached_to\":") catch break :render;
        if (meta.cached_to) |ct| writeJsonString(&w, ct) catch break :render else w.writeAll("null") catch break :render;
        w.print(",\"returned\":{d},\"points\":[", .{count}) catch break :render;

        var wrote: usize = 0;
        var open = false;
        var open_obj: []const u8 = "";
        var open_bucket: i64 = 0;
        var it = ArrayObjIter{ .src = meta.points };
        while (it.next()) |obj| {
            const ts = topLevelString(obj, "ts") orelse continue;
            if (!q.inSpan(ts)) continue;
            const ts_ms = clock.parseRfc3339Ms(ts) catch continue;
            const bucket = @divFloor(ts_ms, step_ms);
            if (!open or bucket != open_bucket) {
                if (open) {
                    if (wrote > 0) w.writeByte(',') catch break :render;
                    w.writeAll(open_obj) catch break :render;
                    wrote += 1;
                }
                open = true;
                open_bucket = bucket;
            }
            open_obj = obj;
        }
        if (open) {
            if (wrote > 0) w.writeByte(',') catch break :render;
            w.writeAll(open_obj) catch break :render;
            wrote += 1;
        }
        w.writeAll("]}") catch break :render;
        if (wrote != count) break :render;
        return .{ .status = .ok, .body = w.buffered() };
    }
    return .{
        .status = .bad_request,
        .body = "{\"error\":\"range_too_wide\",\"hint\":\"narrow since/until or increase step\"}",
    };
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
    const backtest_upload = method == .POST and std.mem.eql(u8, pathOnly(target_buf[0..target_len]), "/api/v1/params/backtest");

    // Review chat + alphabound.intel.v1 envelopes stay small. A backtest
    // request may carry exported candle and decision CSV.
    var body_storage: [16384]u8 = undefined;
    var body_heap: []u8 = &.{};
    defer if (body_heap.len != 0) std.heap.page_allocator.free(body_heap);
    var body_len: usize = 0;
    var body_ptr: [*]u8 = &body_storage;
    if (method == .POST) {
        if (content_length) |cl| {
            const body_cap: usize = if (backtest_upload) 1_048_576 else body_storage.len;
            if (cl > body_cap) {
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
                if (want > body_storage.len) {
                    body_heap = std.heap.page_allocator.alloc(u8, want) catch {
                        try req.respond("{\"error\":\"backtest_failed\"}", .{
                            .status = .internal_server_error,
                            .extra_headers = &.{
                                .{ .name = "content-type", .value = "application/json" },
                            },
                        });
                        return;
                    };
                    body_ptr = body_heap.ptr;
                }
                var body_reader_buf: [512]u8 = undefined;
                const br = req.readerExpectNone(&body_reader_buf);
                br.readSliceAll(body_ptr[0..want]) catch {
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
        .body = body_ptr[0..body_len],
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
    // Order-chain health is visible to operators and drills.
    try testing.expect(!obj.get("unresolved_orders").?.bool);
    try testing.expect(!obj.get("foreign_pending").?.bool);
    try testing.expect(!obj.get("account_projected").?.bool);
    try testing.expect(obj.get("ledger_ok").?.bool);
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

test "events endpoint filters by type, exclude_type and severity" {
    var buf: [2048]u8 = undefined;
    var ctx = testCtx();
    ctx.events_json =
        "[{\"event_id\":\"e1\",\"type\":\"PRIVATE_BALANCE_OK\",\"severity\":\"INFO\",\"payload\":{\"type\":\"nested\"}}," ++
        "{\"event_id\":\"e2\",\"type\":\"ORDER_REJECTED\",\"severity\":\"WARN\",\"payload\":{}}," ++
        "{\"event_id\":\"e3\",\"type\":\"ORDER_ACK\",\"severity\":\"INFO\",\"payload\":{\"note\":\"a{b}c\"}}]";

    const by_type = handle(&buf, .GET, "/api/v1/events?type=ORDER_REJECTED", ctx);
    try testing.expectEqual(std.http.Status.ok, by_type.status);
    try testing.expect(std.mem.indexOf(u8, by_type.body, "e2") != null);
    try testing.expect(std.mem.indexOf(u8, by_type.body, "e1") == null);

    const excl = handle(&buf, .GET, "/api/v1/events?exclude_type=PRIVATE_BALANCE_OK", ctx);
    try testing.expect(std.mem.indexOf(u8, excl.body, "e1") == null);
    try testing.expect(std.mem.indexOf(u8, excl.body, "e2") != null);
    try testing.expect(std.mem.indexOf(u8, excl.body, "e3") != null);

    const by_sev = handle(&buf, .GET, "/api/v1/events?severity=warn", ctx);
    try testing.expect(std.mem.indexOf(u8, by_sev.body, "e2") != null);
    try testing.expect(std.mem.indexOf(u8, by_sev.body, "e1") == null);
    try testing.expect(std.mem.indexOf(u8, by_sev.body, "e3") == null);

    // Nested payload "type" key must not leak into top-level matching.
    const nested = handle(&buf, .GET, "/api/v1/events?type=nested", ctx);
    try testing.expectEqualStrings("[]", nested.body);

    // Combined filters AND together.
    const combo = handle(&buf, .GET, "/api/v1/events?severity=INFO&exclude_type=PRIVATE_BALANCE_OK", ctx);
    try testing.expect(std.mem.indexOf(u8, combo.body, "e3") != null);
    try testing.expect(std.mem.indexOf(u8, combo.body, "e1") == null);
    try testing.expect(std.mem.indexOf(u8, combo.body, "e2") == null);

    // No filter params -> unfiltered blob passthrough.
    const plain = handle(&buf, .GET, "/api/v1/events", ctx);
    try testing.expectEqualStrings(ctx.events_json, plain.body);
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
    ctx.review_json = "[{\"role\":\"user\"}]";
    ctx.review_ctx_json = "{\"decision_id\":\"dec_1\"}";
    ctx.audit_json = "[{\"audit_id\":\"aud_1\",\"status\":\"ok\"}]";
    ctx.periodic_json = "[{\"review_id\":\"pr_1\",\"cycle\":\"short\"}]";
    ctx.analytics_json = "{\"factor_version\":\"v1\",\"points\":[]}";
    ctx.statistics_json = "{\"timezone\":\"UTC\",\"last_24h\":{\"calls\":1}}";
    try testing.expectEqualStrings("[{\"run_id\":\"r1\"}]", handle(&buf, .GET, "/api/v1/agent-runs", ctx).body);
    try testing.expectEqualStrings("[{\"equity\":\"100\"}]", handle(&buf, .GET, "/api/v1/equity", ctx).body);
    try testing.expectEqualStrings("{\"alpha\":\"0\"}", handle(&buf, .GET, "/api/v1/shadow", ctx).body);
    try testing.expectEqualStrings("[{\"c\":\"1\"}]", handle(&buf, .GET, "/api/v1/candles", ctx).body);
    try testing.expectEqualStrings("[{\"memory_id\":\"m1\"}]", handle(&buf, .GET, "/api/v1/memories", ctx).body);
    try testing.expectEqualStrings("{\"ready\":true}", handle(&buf, .GET, "/api/v1/system", ctx).body);
    try testing.expectEqualStrings("[{\"type\":\"AGENT_PROPOSAL_OK\"}]", handle(&buf, .GET, "/api/v1/decisions", ctx).body);
    ctx.params_json = "{\"version_id\":1,\"source\":\"bootstrap\"}";
    ctx.param_versions_json = "[{\"id\":1,\"status\":\"active\"}]";
    try testing.expectEqualStrings("{\"version_id\":1,\"source\":\"bootstrap\"}", handle(&buf, .GET, "/api/v1/params", ctx).body);
    try testing.expectEqualStrings("[{\"id\":1,\"status\":\"active\"}]", handle(&buf, .GET, "/api/v1/params/versions", ctx).body);
    try testing.expectEqual(std.http.Status.method_not_allowed, handle(&buf, .POST, "/api/v1/params", ctx).status);
    try testing.expectEqualStrings("{\"orders\":[{\"status\":\"FILLED\"}],\"fills\":[]}", handle(&buf, .GET, "/api/v1/orders", ctx).body);
    try testing.expectEqualStrings("[{\"role\":\"user\"}]", handle(&buf, .GET, "/api/v1/review/chats", ctx).body);
    try testing.expectEqualStrings("{\"decision_id\":\"dec_1\"}", handle(&buf, .GET, "/api/v1/review/context", ctx).body);
    try testing.expectEqualStrings("[{\"audit_id\":\"aud_1\",\"status\":\"ok\"}]", handle(&buf, .GET, "/api/v1/audit", ctx).body);
    try testing.expectEqualStrings("{\"factor_version\":\"v1\",\"points\":[]}", handle(&buf, .GET, "/api/v1/review/analytics", ctx).body);
    try testing.expectEqualStrings("[{\"review_id\":\"pr_1\",\"cycle\":\"short\"}]", handle(&buf, .GET, "/api/v1/review/periodic", ctx).body);
    try testing.expectEqualStrings("{\"timezone\":\"UTC\",\"last_24h\":{\"calls\":1}}", handle(&buf, .GET, "/api/v1/statistics", ctx).body);
    ctx.intel_json = "[{\"id\":\"intel_x\"}]";
    try testing.expectEqualStrings("[{\"id\":\"intel_x\"}]", handle(&buf, .GET, "/api/v1/intel", ctx).body);
    ctx.sentiment_json = "{\"now\":20}";
    try testing.expectEqualStrings("{\"now\":20}", handle(&buf, .GET, "/api/v1/sentiment", ctx).body);
}

const test_problem_runs =
    "[{\"run_id\":\"r5\",\"status\":\"error_llm\",\"error_class\":\"timeout\",\"model\":\"m\",\"started_ts\":\"2026-09-05T00:00:00.000Z\",\"finished_ts\":\"\"}," ++
    "{\"run_id\":\"r4\",\"status\":\"invalid_proposal\",\"error_class\":\"MalformedJson\",\"model\":\"m\",\"started_ts\":\"2026-09-04T00:00:00.000Z\",\"finished_ts\":\"\"}," ++
    "{\"run_id\":\"r3\",\"status\":\"error_llm\",\"error_class\":\"api_error\",\"model\":\"m\",\"started_ts\":\"2026-09-03T00:00:00.000Z\",\"finished_ts\":\"\"}," ++
    "{\"run_id\":\"r2\",\"status\":\"error_llm\",\"error_class\":\"timeout\",\"model\":\"m\",\"started_ts\":\"2026-09-02T00:00:00.000Z\",\"finished_ts\":\"\"}," ++
    "{\"run_id\":\"r1\",\"status\":\"running\",\"error_class\":\"unfinished\",\"model\":\"m\",\"started_ts\":\"2026-09-01T00:00:00.000Z\",\"finished_ts\":\"\"}]";

test "agent-runs status / error_class filters, counts and cursor paging" {
    var buf: [8192]u8 = undefined;
    var ctx = testCtx();
    ctx.agent_runs_json = "[{\"run_id\":\"ok1\",\"status\":\"ok\",\"started_ts\":\"2026-09-06T00:00:00.000Z\"}]";
    ctx.agent_problems_json = test_problem_runs;

    // Unfiltered request stays the recent-50 blob.
    try testing.expectEqualStrings(ctx.agent_runs_json, handle(&buf, .GET, "/api/v1/agent-runs", ctx).body);

    // Family prefix: `error` matches `error_llm` only.
    const err = handle(&buf, .GET, "/api/v1/agent-runs?status=error", ctx);
    try testing.expect(std.mem.indexOf(u8, err.body, "\"total_matching\":3") != null);
    try testing.expect(std.mem.indexOf(u8, err.body, "\"by_class\":{\"timeout\":2,\"api_error\":1}") != null);
    try testing.expect(std.mem.indexOf(u8, err.body, "r4") == null);
    try testing.expect(std.mem.indexOf(u8, err.body, "\"next_before\":null") != null);

    // Class filter across statuses.
    const cls = handle(&buf, .GET, "/api/v1/agent-runs?error_class=timeout", ctx);
    try testing.expect(std.mem.indexOf(u8, cls.body, "\"total_matching\":2") != null);

    // Cursor paging: limit 2 → next_before is the last returned started_ts.
    const page1 = handle(&buf, .GET, "/api/v1/agent-runs?limit=2", ctx);
    try testing.expect(std.mem.indexOf(u8, page1.body, "\"returned\":2") != null);
    try testing.expect(std.mem.indexOf(u8, page1.body, "\"next_before\":\"2026-09-04T00:00:00.000Z\"") != null);
    try testing.expect(std.mem.indexOf(u8, page1.body, "r5") != null and std.mem.indexOf(u8, page1.body, "r3") == null);
    const page2 = handle(&buf, .GET, "/api/v1/agent-runs?limit=2&before=2026-09-04T00:00:00.000Z", ctx);
    try testing.expect(std.mem.indexOf(u8, page2.body, "r3") != null and std.mem.indexOf(u8, page2.body, "r2") != null);
    try testing.expect(std.mem.indexOf(u8, page2.body, "r4") == null);
    try testing.expect(std.mem.indexOf(u8, page2.body, "\"next_before\":\"2026-09-02T00:00:00.000Z\"") != null);
    const page3 = handle(&buf, .GET, "/api/v1/agent-runs?limit=2&before=2026-09-02T00:00:00.000Z", ctx);
    try testing.expect(std.mem.indexOf(u8, page3.body, "\"returned\":1") != null);
    try testing.expect(std.mem.indexOf(u8, page3.body, "\"next_before\":null") != null);

    // status=ok is answered from the recent blob, not the problems blob.
    const ok = handle(&buf, .GET, "/api/v1/agent-runs?status=ok", ctx);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"source\":\"recent\"") != null);
    try testing.expect(std.mem.indexOf(u8, ok.body, "ok1") != null);

    // Oversized limit is clamped; no match yields an empty page, not an error.
    const none = handle(&buf, .GET, "/api/v1/agent-runs?status=nope&limit=9999", ctx);
    try testing.expectEqual(std.http.Status.ok, none.status);
    try testing.expect(std.mem.indexOf(u8, none.body, "\"items\":[]") != null);
}

test "equity long window filters by date prefix and limit" {
    var buf: [4096]u8 = undefined;
    var ctx = testCtx();
    ctx.equity_json = "[{\"equity\":\"100\"}]";
    ctx.equity_long_json =
        "[{\"ts\":\"2026-09-08T20:00:00.000Z\",\"bucket_ms\":14400000,\"equity\":\"1\"}," ++
        "{\"ts\":\"2026-09-09T20:00:00.000Z\",\"bucket_ms\":14400000,\"equity\":\"2\"}," ++
        "{\"ts\":\"2026-09-10T20:00:00.000Z\",\"bucket_ms\":14400000,\"equity\":\"3\"}," ++
        "{\"ts\":\"2026-09-15T08:00:00.000Z\",\"bucket_ms\":14400000,\"equity\":\"4\"}]";

    try testing.expectEqualStrings("[{\"equity\":\"100\"}]", handle(&buf, .GET, "/api/v1/equity", ctx).body);
    try testing.expectEqualStrings(ctx.equity_long_json, handle(&buf, .GET, "/api/v1/equity?window=long", ctx).body);

    const ranged = handle(&buf, .GET, "/api/v1/equity?window=long&from=2026-09-09&to=2026-09-10", ctx);
    try testing.expect(std.mem.indexOf(u8, ranged.body, "\"equity\":\"1\"") == null);
    try testing.expect(std.mem.indexOf(u8, ranged.body, "\"equity\":\"2\"") != null);
    try testing.expect(std.mem.indexOf(u8, ranged.body, "\"equity\":\"3\"") != null);
    try testing.expect(std.mem.indexOf(u8, ranged.body, "\"equity\":\"4\"") == null);

    const newest = handle(&buf, .GET, "/api/v1/equity?window=long&limit=2", ctx);
    try testing.expect(std.mem.indexOf(u8, newest.body, "\"equity\":\"3\"") != null);
    try testing.expect(std.mem.indexOf(u8, newest.body, "\"equity\":\"4\"") != null);
    try testing.expect(std.mem.indexOf(u8, newest.body, "\"equity\":\"2\"") == null);
}

const equity_span_fixture =
    "{\"stored_step_minutes\":5,\"window_start\":\"2026-10-12T00:00:00.000Z\",\"cached_from\":\"2026-10-12T00:00:00.000Z\",\"cached_to\":\"2026-10-12T00:30:00.000Z\",\"points\":[" ++
    "{\"ts\":\"2026-10-12T00:00:00.000Z\",\"equity\":\"0\",\"hwm\":\"0\",\"drawdown\":\"0\",\"bh_equity\":null,\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:05:00.000Z\",\"equity\":\"5\",\"hwm\":\"5\",\"drawdown\":\"0\",\"bh_equity\":\"5\",\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:10:00.000Z\",\"equity\":\"10\",\"hwm\":\"10\",\"drawdown\":\"0\",\"bh_equity\":\"10\",\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:15:00.000Z\",\"equity\":\"15\",\"hwm\":\"15\",\"drawdown\":\"0\",\"bh_equity\":\"15\",\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:20:00.000Z\",\"equity\":\"20\",\"hwm\":\"20\",\"drawdown\":\"0\",\"bh_equity\":\"20\",\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:25:00.000Z\",\"equity\":\"25\",\"hwm\":\"25\",\"drawdown\":\"0\",\"bh_equity\":\"25\",\"capital_flow\":null}," ++
    "{\"ts\":\"2026-10-12T00:30:00.000Z\",\"equity\":\"30\",\"hwm\":\"30\",\"drawdown\":\"0\",\"bh_equity\":null,\"capital_flow\":\"1\"}]}";

test "equity since/until/step is bounded and the default series stays put" {
    var buf: [8192]u8 = undefined;
    var ctx = testCtx();
    ctx.equity_json = "[{\"equity\":\"100\"}]";
    ctx.equity_long_json = "[{\"ts\":\"2026-09-08T20:00:00.000Z\",\"equity\":\"1\"}]";
    ctx.equity_span_json = equity_span_fixture;

    // No query params: the newest ~240 one-minute cache, untouched.
    try testing.expectEqualStrings("[{\"equity\":\"100\"}]", handle(&buf, .GET, "/api/v1/equity", ctx).body);

    const conflict = handle(&buf, .GET, "/api/v1/equity?window=long&since=2026-10-12T00:00:00.000Z", ctx);
    try testing.expectEqual(std.http.Status.bad_request, conflict.status);
    try testing.expect(std.mem.indexOf(u8, conflict.body, "conflicting_query") != null);

    const too_old = handle(&buf, .GET, "/api/v1/equity?since=2026-10-11T00:00:00.000Z", ctx);
    try testing.expectEqual(std.http.Status.bad_request, too_old.status);
    try testing.expect(std.mem.indexOf(u8, too_old.body, "range_not_cached") != null);

    const fine = handle(&buf, .GET, "/api/v1/equity?since=2026-10-12T00:00:00.000Z&step=1", ctx);
    try testing.expectEqual(std.http.Status.bad_request, fine.status);
    try testing.expect(std.mem.indexOf(u8, fine.body, "step_too_fine") != null);

    const bad = handle(&buf, .GET, "/api/v1/equity?step=abc", ctx);
    try testing.expectEqual(std.http.Status.bad_request, bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "bad_step") != null);

    // step=15 keeps the last sample of each 15-minute bucket: 00:10, 00:25, 00:30.
    const stepped = handle(&buf, .GET, "/api/v1/equity?since=2026-10-12T00:00:00.000Z&until=2026-10-12T00:30:00.000Z&step=15", ctx);
    try testing.expectEqual(std.http.Status.ok, stepped.status);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"step_minutes\":15") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"returned\":3") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"equity\":\"10\"") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"equity\":\"25\"") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"equity\":\"30\"") != null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"equity\":\"0\"") == null);
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"equity\":\"15\"") == null);
    // Missing buy-and-hold stays null in the source row that was kept.
    try testing.expect(std.mem.indexOf(u8, stepped.body, "\"bh_equity\":null") != null);

    const tail = handle(&buf, .GET, "/api/v1/equity?since=2026-10-12T00:15:00.000Z&step=15", ctx);
    try testing.expectEqual(std.http.Status.ok, tail.status);
    try testing.expect(std.mem.indexOf(u8, tail.body, "\"equity\":\"25\"") != null);
    try testing.expect(std.mem.indexOf(u8, tail.body, "\"equity\":\"30\"") != null);
    try testing.expect(std.mem.indexOf(u8, tail.body, "\"equity\":\"10\"") == null);

    // Inside the cached window but with no samples: an empty list, not a zero return.
    ctx.equity_span_json = "{\"stored_step_minutes\":5,\"window_start\":\"2026-10-12T00:00:00.000Z\",\"cached_from\":null,\"cached_to\":null,\"points\":[]}";
    const empty = handle(&buf, .GET, "/api/v1/equity?since=2026-10-12T00:00:00.000Z&step=5", ctx);
    try testing.expectEqual(std.http.Status.ok, empty.status);
    try testing.expect(std.mem.indexOf(u8, empty.body, "\"returned\":0") != null);
    try testing.expect(std.mem.indexOf(u8, empty.body, "\"points\":[]") != null);
}

test "equity range rejects an explicit step that would exceed the point cap" {
    var src: [96 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&src);
    w.writeAll("{\"stored_step_minutes\":1,\"window_start\":\"2026-10-11T00:00:00.000Z\",\"cached_from\":\"2026-10-11T00:00:00.000Z\",\"cached_to\":\"2026-10-11T08:00:00.000Z\",\"points\":[") catch return error.OutOfMemory;
    const n = equity_range_max_points + 1;
    const origin = try clock.parseRfc3339Ms("2026-10-11T00:00:00.000Z");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        var ts: [40]u8 = undefined;
        const stamp = try clock.formatRfc3339Ms(origin + @as(i64, @intCast(i)) * std.time.ms_per_min, &ts);
        w.print("{{\"ts\":\"{s}\",\"equity\":\"1\",\"hwm\":\"1\",\"drawdown\":\"0\",\"bh_equity\":null,\"capital_flow\":null}}", .{stamp}) catch return error.OutOfMemory;
    }
    w.writeAll("]}") catch return error.OutOfMemory;

    var buf: [4096]u8 = undefined;
    var ctx = testCtx();
    ctx.equity_json = "[{\"equity\":\"100\"}]";
    ctx.equity_span_json = w.buffered();
    const wide = handle(&buf, .GET, "/api/v1/equity?since=2026-10-11T00:00:00.000Z&step=1", ctx);
    try testing.expectEqual(std.http.Status.bad_request, wide.status);
    try testing.expect(std.mem.indexOf(u8, wide.body, "range_too_wide") != null);

    // Omitting step coarsens until the selection fits, and says so.
    var body: [196608]u8 = undefined;
    const auto = handle(&body, .GET, "/api/v1/equity?since=2026-10-11T00:00:00.000Z", ctx);
    try testing.expectEqual(std.http.Status.ok, auto.status);
    try testing.expect(std.mem.indexOf(u8, auto.body, "\"stored_step_minutes\":1") != null);
    try testing.expect(std.mem.indexOf(u8, auto.body, "\"step_minutes\":5") != null);
    try testing.expect(std.mem.indexOf(u8, auto.body, "\"returned\":") != null);
    try testing.expect(std.mem.indexOf(u8, auto.body, "\"equity\":\"100\"") == null);
}

test "review POST enqueues into inbox; validation and limits enforced" {
    var buf: [1024]u8 = undefined;
    var inbox: review.Inbox = .{};
    var ctx = testCtx();
    ctx.review_inbox = &inbox;

    // Missing inbox → 503
    {
        const no_ctx = testCtx();
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "{\"decision_id\":\"dec_1\",\"message\":\"why\"}",
        }, no_ctx);
        try testing.expectEqual(std.http.Status.service_unavailable, r.status);
    }

    // Happy path chat
    {
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "{\"decision_id\":\"dec_1\",\"anchor_ts\":\"2026-08-14T03:00:00.000Z\",\"message\":\"为什么 HOLD？\"}",
        }, ctx);
        try testing.expectEqual(std.http.Status.accepted, r.status);
        try testing.expectEqual(@as(usize, 1), inbox.pending());
    }
    // Duplicate chat for same decision → 409
    {
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "{\"decision_id\":\"dec_1\",\"message\":\"again\"}",
        }, ctx);
        try testing.expectEqual(std.http.Status.conflict, r.status);
    }
    // Context + summarize routes accepted
    {
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/context",
            .body = "{\"decision_id\":\"dec_1\",\"anchor_ts\":\"2026-08-14T03:00:00.000Z\"}",
        }, ctx);
        try testing.expectEqual(std.http.Status.accepted, r.status);
        const s = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/summarize",
            .body = "{\"decision_id\":\"dec_1\"}",
        }, ctx);
        try testing.expectEqual(std.http.Status.accepted, s.status);
    }
    // Bad JSON / empty message / empty decision → 400
    {
        try testing.expectEqual(std.http.Status.bad_request, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "not json",
        }, ctx).status);
        try testing.expectEqual(std.http.Status.bad_request, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "{\"decision_id\":\"dec_2\",\"message\":\"   \"}",
        }, ctx).status);
        try testing.expectEqual(std.http.Status.bad_request, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/chat",
            .body = "{\"message\":\"hi\"}",
        }, ctx).status);
    }
    // Periodic 复盘 trigger: cycle travels in the body, unknown cycle → 400.
    {
        while (inbox.drain()) |_| {}
        const r = handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/periodic",
            .body = "{\"cycle\":\"short\"}",
        }, ctx);
        try testing.expectEqual(std.http.Status.accepted, r.status);
        try testing.expectEqual(std.http.Status.conflict, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/periodic",
            .body = "{\"cycle\":\"short\"}",
        }, ctx).status);
        try testing.expectEqual(std.http.Status.bad_request, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/periodic",
            .body = "{\"cycle\":\"decade\"}",
        }, ctx).status);
    }
    // Unknown review subpath → 404; drain leaves queue reusable
    {
        try testing.expectEqual(std.http.Status.not_found, handleReq(&buf, .{
            .method = .POST,
            .target = "/api/v1/review/execute",
            .body = "{\"decision_id\":\"dec_1\"}",
        }, ctx).status);
        while (inbox.drain()) |_| {}
        try testing.expectEqual(@as(usize, 0), inbox.pending());
    }
}

test "intel POST validates hmac and enqueues" {
    var buf: [2048]u8 = undefined;
    var inbox: intel_inbox.Inbox = .{};
    var ctx = testCtx();
    ctx.intel_inbox = &inbox;
    ctx.intel_hmac = intel.test_hmac_key;
    const now: i64 = 1_700_000_000_000;

    try testing.expectEqual(std.http.Status.service_unavailable, handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/intel",
        .body = "{}",
        .now_ms = now,
    }, testCtx()).status);

    try testing.expectEqual(std.http.Status.bad_request, handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/intel",
        .body = "{\"schema\":\"nope\"}",
        .now_ms = now,
    }, ctx).status);

    var item = intel.Item{
        .kind = .macro,
        .conf_milles = 620,
        .as_of_ms = now - 60_000,
        .expires_ms = now - 60_000 + 7 * 86_400_000,
    };
    const id = "intel_web_test_01";
    @memcpy(item.id_buf[0..id.len], id);
    item.id_len = id.len;
    const src = "collector.macro";
    @memcpy(item.source_buf[0..src.len], src);
    item.source_len = src.len;
    const inst = "BTC-USDT";
    @memcpy(item.instrument_buf[0..inst.len], inst);
    item.instrument_len = inst.len;
    const hl = "US spot BTC ETF saw net inflows";
    @memcpy(item.headline_buf[0..hl.len], hl);
    item.headline_len = hl.len;
    const body_s = "Issuers reported a second consecutive session of net creations.";
    @memcpy(item.body_buf[0..body_s.len], body_s);
    item.body_len = body_s.len;
    const nonce = "0123456789abcdef0123456789abcdef";
    @memcpy(item.nonce_buf[0..nonce.len], nonce);
    item.nonce_len = nonce.len;
    const claims = "[{\"text\":\"ETF creations continued\",\"polarity\":\"bull\"}]";
    @memcpy(item.claims_json_buf[0..claims.len], claims);
    item.claims_json_len = claims.len;
    const tags = "[\"etf\"]";
    @memcpy(item.tags_json_buf[0..tags.len], tags);
    item.tags_json_len = tags.len;
    @memcpy(item.refs_json_buf[0..2], "[]");
    item.refs_json_len = 2;
    intel.computeDedup(&item);
    try intel.signItem(intel.test_hmac_key, &item);
    var env_buf: [2048]u8 = undefined;
    const env = std.fmt.bufPrint(&env_buf, "{{\"schema\":\"{s}\",\"id\":\"{s}\",\"source_id\":\"{s}\",\"kind\":\"macro\",\"instrument\":\"BTC-USDT\",\"headline\":\"{s}\",\"body\":\"{s}\",\"claims\":{s},\"tags\":{s},\"confidence\":0.620,\"as_of_ms\":{d},\"expires_ms\":{d},\"nonce\":\"{s}\",\"signature\":\"{s}\"}}", .{
        intel.schema_id,
        item.id(),
        item.sourceId(),
        item.headline(),
        item.body(),
        item.claimsJson(),
        item.tagsJson(),
        item.as_of_ms,
        item.expires_ms,
        item.nonce(),
        item.signature(),
    }) catch unreachable;

    const r = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/intel",
        .body = env,
        .now_ms = now,
    }, ctx);
    try testing.expectEqual(std.http.Status.accepted, r.status);
    try testing.expectEqual(@as(usize, 1), inbox.pending());
    try testing.expectEqual(std.http.Status.conflict, handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/intel",
        .body = env,
        .now_ms = now,
    }, ctx).status);
}

test "review endpoints require auth when token configured" {
    var buf: [1024]u8 = undefined;
    var inbox: review.Inbox = .{};
    var ctx = testCtx();
    ctx.review_inbox = &inbox;
    ctx.auth_cfg = .{ .api_token = "secret-token" };
    ctx.auth_cfg.session_secret = auth.deriveSessionSecret(ctx.auth_cfg.api_token);

    try testing.expectEqual(std.http.Status.unauthorized, handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/chat",
        .body = "{\"decision_id\":\"dec_1\",\"message\":\"hi\"}",
    }, ctx).status);
    try testing.expectEqual(@as(usize, 0), inbox.pending());
    try testing.expectEqual(std.http.Status.unauthorized, handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/review/chats",
    }, ctx).status);

    // With token → accepted
    const r = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/chat",
        .authorization = "Bearer secret-token",
        .body = "{\"decision_id\":\"dec_1\",\"message\":\"hi\"}",
    }, ctx);
    try testing.expectEqual(std.http.Status.accepted, r.status);
    try testing.expectEqual(@as(usize, 1), inbox.pending());
}

test "brand icons are public and embedded" {
    var buf: [256]u8 = undefined;
    var ctx = testCtx();
    ctx.auth_cfg = .{ .api_token = "secret-token" };
    ctx.auth_cfg.session_secret = auth.deriveSessionSecret(ctx.auth_cfg.api_token);

    const svg = handle(&buf, .GET, "/favicon.svg", ctx);
    try testing.expectEqual(std.http.Status.ok, svg.status);
    try testing.expectEqualStrings("image/svg+xml", svg.content_type);
    try testing.expect(svg.body.len > 32);
    try testing.expect(std.mem.indexOf(u8, svg.body, "<svg") != null);

    const ico = handle(&buf, .GET, "/favicon.ico", ctx);
    try testing.expectEqual(std.http.Status.ok, ico.status);
    try testing.expectEqualStrings("image/x-icon", ico.content_type);
    try testing.expect(ico.body.len > 16);

    const png = handle(&buf, .GET, "/favicon.png", ctx);
    try testing.expectEqual(std.http.Status.ok, png.status);
    try testing.expectEqualStrings("image/png", png.content_type);
    try testing.expect(png.body.len > 16);
    // PNG magic
    try testing.expectEqual(@as(u8, 0x89), png.body[0]);
    try testing.expectEqualStrings("PNG", png.body[1..4]);

    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/apple-touch-icon.png", ctx).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/icon-192.png", ctx).status);
    try testing.expectEqual(std.http.Status.ok, handle(&buf, .GET, "/icon-512.png", ctx).status);
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

test "param writes require the admin token and never accept max_drawdown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [640:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/params.db", .{dir_buf[0..n]});
    var database = try db.Db.open(path);
    defer database.close();
    var cfg = try app_config.parse(std.testing.allocator, "");
    defer cfg.deinit();
    _ = try params_store.ensureActive(&database, &cfg, 1_700_000_000_000);

    var ctx = testCtx();
    ctx.param_db_path = path;
    var buf: [8192]u8 = undefined;
    const open_mode = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/propose",
        .body = "{}",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.unauthorized, open_mode.status);

    ctx.auth_cfg = .{ .api_token = "test-token-not-a-secret-value" };
    const denied = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/propose",
        .body = "{}",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.unauthorized, denied.status);
    try testing.expectEqual(std.http.Status.method_not_allowed, handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx).status);

    var p = params_dynamic.Params{};
    p.daily_trade_cap = 7;
    var pbuf: [1024]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&pbuf);
    try p.writeJson(&pw);
    var body: [2048]u8 = undefined;
    const req_body = try std.fmt.bufPrint(&body, "{{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"cap\",\"params\":{s}}}", .{pw.buffered()});
    const ok = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/propose",
        .x_api_token = "test-token-not-a-secret-value",
        .body = req_body,
        .now_ms = 1_700_000_000_000 + params_dynamic.day_ms,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, ok.status);
    try testing.expect(std.mem.indexOf(u8, ok.body, "\"code\":\"ok\"") != null);

    const locked = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/propose",
        .x_api_token = "test-token-not-a-secret-value",
        .body = "{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"no\",\"max_drawdown\":\"0.2\"}",
        .now_ms = 1_700_000_000_000 + params_dynamic.day_ms,
    }, ctx);
    try testing.expectEqual(std.http.Status.unprocessable_entity, locked.status);
    try testing.expect(std.mem.indexOf(u8, locked.body, "\"field\":\"max_drawdown\"") != null);
    try testing.expectEqual(@as(i64, 0), try database.queryInt("SELECT COUNT(*) FROM orders"));
}

test "backtest gate http returns a stored report and does not place orders" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [640:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/params.db", .{dir_buf[0..n]});
    var database = try db.Db.open(path);
    defer database.close();
    var cfg = try app_config.parse(std.testing.allocator, "");
    defer cfg.deinit();
    _ = try params_store.ensureActive(&database, &cfg, 1_700_000_000_000);

    var ctx = testCtx();
    ctx.param_db_path = path;
    ctx.auth_cfg = .{ .api_token = "test-token-not-a-secret-value" };
    var buf: [65536]u8 = undefined;
    const denied = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/backtest",
        .body = "{}",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.unauthorized, denied.status);

    var p = params_dynamic.Params{};
    var pbuf: [1024]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&pbuf);
    try p.writeJson(&pw);
    var body: [4096]u8 = undefined;
    const req_body = try std.fmt.bufPrint(&body, "{{\"source\":\"manual\",\"operator\":\"ops\",\"reason\":\"gate\",\"params\":{s},\"candles\":\"ts_ms,close\\n0,100\\n900000,100\\n\",\"decisions\":\"ts_ms,target_weight\\n0,0.4\\n\"}}", .{pw.buffered()});
    const ran = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/params/backtest",
        .x_api_token = "test-token-not-a-secret-value",
        .body = req_body,
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, ran.status);
    try testing.expect(std.mem.indexOf(u8, ran.body, "\"passed\":false") != null);
    try testing.expect(std.mem.indexOf(u8, ran.body, "insufficient_bars") != null);
    try testing.expect(std.mem.indexOf(u8, ran.body, "cannot say what the model would have proposed") != null);
    const key = "\"id\":\"";
    const at = std.mem.indexOf(u8, ran.body, key) orelse return error.TestUnexpectedResult;
    const rest = ran.body[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;
    var id_buf: [32]u8 = undefined;
    if (end > id_buf.len) return error.TestUnexpectedResult;
    @memcpy(id_buf[0..end], rest[0..end]);
    var target_buf: [96]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "/api/v1/params/backtest?id={s}", .{id_buf[0..end]});
    const got = handleReq(&buf, .{
        .method = .GET,
        .target = target,
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, id_buf[0..end]) != null);
    try testing.expectEqual(std.http.Status.not_found, handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/params/backtest?id=bt_missing",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx).status);
    try testing.expectEqual(@as(i64, 1), try database.queryInt("SELECT COUNT(*) FROM backtest_reports"));
    try testing.expectEqual(@as(i64, 0), try database.queryInt("SELECT COUNT(*) FROM orders"));
}

test "strategy review queues off the request thread and stays readable" {
    var buf: [8192]u8 = undefined;
    var ctx = testCtx();
    const open = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/strategy",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.unauthorized, open.status);

    ctx.auth_cfg = .{ .api_token = "test-token-not-a-secret-value" };
    const unavailable = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/strategy",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.service_unavailable, unavailable.status);

    var kick = std.atomic.Value(bool).init(false);
    var running = std.atomic.Value(bool).init(false);
    ctx.strategy_review_kick = &kick;
    ctx.strategy_review_running = &running;
    const queued = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/strategy",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.accepted, queued.status);
    try testing.expect(std.mem.indexOf(u8, queued.body, "\"queued\":true") != null);
    try testing.expect(kick.load(.acquire));

    kick.store(false, .release);
    running.store(true, .release);
    const busy = handleReq(&buf, .{
        .method = .POST,
        .target = "/api/v1/review/strategy",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.conflict, busy.status);
    try testing.expect(!kick.load(.acquire));

    const nodb = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/review/strategy",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_000_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.service_unavailable, nodb.status);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path_buf: [640:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/review.db", .{dir_buf[0..n]});
    var database = try db.Db.open(path);
    defer database.close();
    var cfg = try app_config.parse(std.testing.allocator, "");
    defer cfg.deinit();
    _ = try params_store.ensureActive(&database, &cfg, 1_700_000_000_000);
    strategy_review.execute(&database, Decimal.zero, 1_700_003_000_000, .off, "manual", 0.01, true);
    ctx.param_db_path = path;
    const listed = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/review/strategy",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_003_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.ok, listed.status);
    try testing.expect(std.mem.indexOf(u8, listed.body, "skipped") != null);
    const bad = handleReq(&buf, .{
        .method = .GET,
        .target = "/api/v1/review/strategy?id=nope%20id",
        .x_api_token = "test-token-not-a-secret-value",
        .now_ms = 1_700_003_000_000,
    }, ctx);
    try testing.expectEqual(std.http.Status.bad_request, bad.status);
    try testing.expectEqual(@as(i64, 0), try database.queryInt("SELECT COUNT(*) FROM orders"));
}
