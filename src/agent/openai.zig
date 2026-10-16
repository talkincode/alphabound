//! OpenAI-compatible Chat Completions client (Gate 2 shadow).
//!
//! Talks to any endpoint that accepts:
//!   POST {base}/chat/completions
//!   Authorization: Bearer <key>
//!   {"model","messages":[{"role","content"},...]}
//!
//! Credentials stay in this adapter; agent context/proposal layers never see them.

const std = @import("std");
const builtin = @import("builtin");
const limits = @import("../security/limits.zig");

pub const Error = error{
    HttpFailed,
    Timeout,
    ConnectTimeout,
    ApiError,
    MalformedResponse,
    EmptyContent,
    OutOfMemory,
    BufferTooSmall,
};

pub const Usage = struct {
    /// True only when the provider returned a `usage` object. Zero-token
    /// responses are still distinguishable from models that omitted usage.
    reported: bool = false,
    prompt_tokens: u64 = 0,
    /// Provider-reported cached portion of prompt_tokens, when available.
    cached_prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
};

pub const ChatResult = struct {
    /// Caller frees with gpa.free.
    content: []u8,
    usage: Usage = .{},
    /// Present only when resilience is enabled; includes the initial attempt.
    attempts: ?u32 = null,
};

pub const AuthStyle = enum {
    /// Authorization: Bearer <key>
    bearer,
    /// api-key: <key>  (Azure OpenAI classic)
    api_key_header,
};

const TestTransport = struct {
    const Step = struct {
        status: std.http.Status = .ok,
        body: []const u8 = "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}",
        elapsed_ms: u32 = 0,
        timeout: ?Error = null,
    };
    steps: []const Step = &.{},
    index: usize = 0,
    response_start: bool = false,
    finished: std.atomic.Value(bool) = .init(false),

    fn fetch(self: *TestTransport, io: std.Io, options: std.http.Client.FetchOptions, head: ?*std.atomic.Value(bool)) std.http.Client.FetchError!std.http.Client.FetchResult {
        if (self.steps.len > 0) {
            const step = self.steps[self.index];
            self.index += 1;
            try options.response_writer.?.writeAll(step.body);
            return .{ .status = step.status };
        }
        defer self.finished.store(true, .release);
        if (self.response_start) {
            if (head) |h| h.store(true, .release);
        }
        io.sleep(.{ .nanoseconds = 900 * std.time.ns_per_ms }, .awake) catch {};
        try options.response_writer.?.writeAll("{\"choices\":[{\"message\":{\"content\":\"late\"}}]}");
        return .{ .status = .ok };
    }
};
const TestTransportHook = if (builtin.is_test) ?*TestTransport else void;

/// Optional deterministic clock, sleeper and random source for retry orchestration.
pub const RetryRuntime = struct {
    context: *anyopaque,
    now_ms: *const fn (*anyopaque) i64,
    sleep_ms: *const fn (*anyopaque, u32) void,
    random: *const fn (*anyopaque) u32,
};

pub const Client = struct {
    http: std.http.Client,
    gpa: std.mem.Allocator,
    /// Root URL without trailing slash, e.g. https://api.openai.com/v1
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    auth_style: AuthStyle = .bearer,
    /// With resilience enabled, the shared chat() budget across attempts and sleeps.
    /// Otherwise preserves the legacy per-attempt budget and transport retry.
    /// Slow Azure/DeepSeek completions often exceed 30s; production should use >=120s.
    timeout_ms: u32 = 120_000,
    /// 0 preserves the existing fetch path. >0: deadline for TCP/TLS connect + request write.
    connect_timeout_ms: u32 = 0,
    /// Optional per-attempt cap, also bounded by timeout_ms. 0 disables.
    request_timeout_ms: u32 = 0,
    llm_resilience_enabled: bool = false,
    llm_retry_on_timeout: bool = true,
    llm_retry_max: u32 = 1,
    llm_retry_backoff_ms: u32 = 500,
    llm_retry_jitter_ms: u32 = 250,
    llm_retry_5xx_max: u32 = 2,
    retry_runtime: ?RetryRuntime = null,
    /// Available after success or failure; null on the legacy path.
    last_attempt_count: ?u32 = null,
    last_http_status: u16 = 0,
    last_api_class: []const u8 = "",
    // Compiled out of production; tests can model a stalled transport without sockets.
    test_transport: TestTransportHook = if (builtin.is_test) null else {},

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        base_url: []const u8,
        api_key: []const u8,
        model: []const u8,
    ) Client {
        const root = trimTrailingSlash(base_url);
        return .{
            .http = .{ .allocator = gpa, .io = io },
            .gpa = gpa,
            .base_url = root,
            .api_key = api_key,
            .model = model,
            .auth_style = detectAuthStyle(root),
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// POST chat completion. Returns content + usage (caller frees content).
    pub fn chat(self: *Client, system: []const u8, user: []const u8) Error!ChatResult {
        self.last_attempt_count = if (self.llm_resilience_enabled) 0 else null;
        const started_ms = if (self.llm_resilience_enabled) self.retryNow() else 0;
        var body_aw = std.Io.Writer.Allocating.init(self.gpa);
        defer body_aw.deinit();
        try writeChatBody(&body_aw.writer, self.model, system, user);
        const body = body_aw.writer.buffered();

        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{self.base_url}) catch return error.BufferTooSmall;

        if (self.llm_resilience_enabled) return self.chatResilient(url, body, started_ms);

        // Wall-clock budget guards against half-open TLS hangs that never surface as
        // an error from std.http (observed in production after idle gateway drops).
        return self.chatBudgeted(url, body, null) catch |err| {
            // Retry transport flakes and empty-content (thinking models / gateway
            // blanks). Timeouts already consumed the full budget.
            if (err != error.HttpFailed and err != error.EmptyContent) return err;
            if (err == error.EmptyContent) {
                std.debug.print("[llm] empty_content; reset_http_retry\n", .{});
            } else {
                std.debug.print("[llm] transport_failed; reset_http_retry\n", .{});
            }
            self.resetHttp();
            return self.chatBudgeted(url, body, null);
        };
    }

    fn retryNow(self: *Client) i64 {
        if (self.retry_runtime) |rt| return rt.now_ms(rt.context);
        return @intCast(std.Io.Timestamp.now(self.http.io, .awake).toMilliseconds());
    }

    fn retrySleep(self: *Client, ms: u32) void {
        if (self.retry_runtime) |rt| return rt.sleep_ms(rt.context, ms);
        self.http.io.sleep(.{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms }, .awake) catch {};
    }

    fn retryDelay(self: *Client, retry: u32) u32 {
        const random = if (self.retry_runtime) |rt| rt.random(rt.context) else blk: {
            var value: u32 = undefined;
            self.http.io.random(std.mem.asBytes(&value));
            break :blk value;
        };
        const jitter = @as(u64, random) % (@as(u64, self.llm_retry_jitter_ms) + 1);
        const base = std.math.shl(u64, self.llm_retry_backoff_ms, @min(retry, 32));
        return @intCast(@min(std.math.maxInt(u32), base + jitter));
    }

    fn remainingBudget(self: *Client, started_ms: i64, budget: u32) u32 {
        const elapsed = @max(0, self.retryNow() - started_ms);
        return budget - @as(u32, @intCast(@min(budget, elapsed)));
    }

    fn chatResilient(self: *Client, url: []const u8, body: []const u8, started_ms: i64) Error!ChatResult {
        const budget = if (self.timeout_ms == 0) 120_000 else self.timeout_ms;
        var timeout_retries: u32 = 0;
        var status_retries: u32 = 0;
        var empty_retried = false;
        var retry: u32 = 0;
        while (true) {
            const remaining = self.remainingBudget(started_ms, budget);
            if (remaining == 0) return error.Timeout;
            self.last_http_status = 0;
            self.last_api_class = "";
            self.last_attempt_count.? +|= 1;
            var result = self.chatBudgeted(url, body, remaining) catch |err| {
                // Authentication always wins over a retryable status/body.
                if (self.last_http_status == 401 or self.last_http_status == 403 or
                    std.mem.eql(u8, self.last_api_class, "invalid_api_key") or
                    std.mem.eql(u8, self.last_api_class, "unauthorized")) return err;
                var floor: u64 = 0;
                if (err == error.Timeout or err == error.ConnectTimeout) {
                    if (!self.llm_retry_on_timeout or timeout_retries >= self.llm_retry_max) return err;
                    timeout_retries += 1;
                    floor = @as(u64, if (self.connect_timeout_ms == 0) 1000 else self.connect_timeout_ms) + 1000;
                } else if (switch (self.last_http_status) {
                    429, 500, 502, 503, 504 => true,
                    else => false,
                } or
                    std.mem.eql(u8, self.last_api_class, "rate_limit") or std.mem.eql(u8, self.last_api_class, "overloaded"))
                {
                    if (status_retries >= self.llm_retry_5xx_max) return err;
                    status_retries += 1;
                } else if (err == error.EmptyContent and !empty_retried) {
                    empty_retried = true;
                } else return err;
                const delay = if (err == error.EmptyContent) 0 else self.retryDelay(retry);
                retry +|= 1;
                // Leave the retry floor available AFTER sleeping, too.
                if (@as(u64, self.remainingBudget(started_ms, budget)) <= @as(u64, delay) + floor) return err;
                self.retrySleep(delay);
                if (@as(u64, self.remainingBudget(started_ms, budget)) <= floor) return err;
                self.resetHttp();
                continue;
            };
            if (self.remainingBudget(started_ms, budget) == 0) {
                self.gpa.free(result.content);
                return error.Timeout;
            }
            result.attempts = self.last_attempt_count;
            return result;
        }
    }

    fn chatBudgeted(self: *Client, url: []const u8, body: []const u8, remaining: ?u32) Error!ChatResult {
        const call_budget: u32 = remaining orelse (if (self.timeout_ms == 0) @as(u32, 120_000) else self.timeout_ms);
        const budget_ms = if (self.request_timeout_ms == 0) call_budget else @min(call_budget, self.request_timeout_ms);
        // Include allocation/spawn overhead in the enabled per-attempt deadline.
        const attempt_started = if (remaining != null) std.Io.Timestamp.now(self.http.io, .awake) else null;

        if (builtin.is_test) {
            if (self.test_transport) |transport| {
                if (transport.steps.len > 0 and self.retry_runtime != null) {
                    const step = transport.steps[transport.index];
                    self.retrySleep(@min(step.elapsed_ms, budget_ms));
                    if (step.elapsed_ms >= budget_ms) {
                        transport.index += 1;
                        return error.Timeout;
                    }
                    if (step.timeout) |err| {
                        transport.index += 1;
                        return err;
                    }
                    return self.chatOnce(url, body, null);
                }
            }
        }

        // Prefer a worker thread so a wedged socket cannot block the daemon forever.
        // Preserve the legacy sync fallback only when deadlines are disabled.
        const work = self.gpa.create(ChatWork) catch {
            if (remaining != null or self.connect_timeout_ms > 0 or self.request_timeout_ms > 0) return error.OutOfMemory;
            return self.chatOnce(url, body, null);
        };
        work.* = .{
            .gpa = self.gpa,
            .io = self.http.io,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .model = self.model,
            .auth_style = self.auth_style,
            .resilience_enabled = self.llm_resilience_enabled,
            .track_response_start = self.connect_timeout_ms > 0,
            .test_transport = self.test_transport,
            .url = self.gpa.dupe(u8, url) catch {
                self.gpa.destroy(work);
                return error.OutOfMemory;
            },
            .body = self.gpa.dupe(u8, body) catch {
                self.gpa.free(work.url);
                self.gpa.destroy(work);
                return error.OutOfMemory;
            },
        };

        const thread = std.Thread.spawn(.{}, ChatWork.run, .{work}) catch {
            const r: Error!ChatResult = if (remaining != null or self.connect_timeout_ms > 0 or self.request_timeout_ms > 0) error.HttpFailed else self.chatOnce(url, body, null);
            self.gpa.free(work.url);
            self.gpa.free(work.body);
            self.gpa.destroy(work);
            return r;
        };

        const deadlines_enabled = remaining != null or self.connect_timeout_ms > 0 or self.request_timeout_ms > 0;
        const started = attempt_started orelse (if (deadlines_enabled) std.Io.Timestamp.now(self.http.io, .awake) else null);
        var waited_ms: u32 = if (attempt_started) |start| @intCast(@min(std.math.maxInt(u32), @max(0, start.durationTo(std.Io.Timestamp.now(self.http.io, .awake)).toMilliseconds()))) else 0;
        var timeout_error: Error = error.Timeout;
        while (waited_ms < budget_ms) {
            if (work.phase.load(.acquire) == ChatWork.phase_done) {
                self.last_http_status = work.http_status;
                self.last_api_class = work.api_class;
                const r = work.result;
                thread.join();
                self.gpa.free(work.url);
                self.gpa.free(work.body);
                self.gpa.destroy(work);
                return r;
            }
            if (self.connect_timeout_ms > 0 and waited_ms >= self.connect_timeout_ms and
                !work.response_started.load(.acquire))
            {
                timeout_error = error.ConnectTimeout;
                break;
            }
            // Preserve the existing polling cadence when the switch is off.
            const sleep_ms: u32 = if (!deadlines_enabled) 100 else @min(100, @min(budget_ms - waited_ms, if (!work.response_started.load(.acquire) and waited_ms < self.connect_timeout_ms)
                self.connect_timeout_ms - waited_ms
            else
                budget_ms - waited_ms));
            self.http.io.sleep(.{ .nanoseconds = @as(i96, sleep_ms) * std.time.ns_per_ms }, .awake) catch {};
            waited_ms +|= sleep_ms;
            if (started) |start| {
                const elapsed = start.durationTo(std.Io.Timestamp.now(self.http.io, .awake)).toMilliseconds();
                waited_ms = @intCast(@min(std.math.maxInt(u32), @max(0, elapsed)));
            }
        }

        // If scheduling skipped past both deadlines, the earlier one wins.
        if (self.connect_timeout_ms > 0 and self.connect_timeout_ms < budget_ms and
            waited_ms >= self.connect_timeout_ms and !work.response_started.load(.acquire))
            timeout_error = error.ConnectTimeout;

        // Timed out: try to abandon. If worker finished in the race window, take the result.
        if (work.phase.cmpxchgStrong(ChatWork.phase_running, ChatWork.phase_abandoned, .acq_rel, .acquire)) |_| {
            // phase was not running → must be done
            self.last_http_status = work.http_status;
            self.last_api_class = work.api_class;
            const r = work.result;
            thread.join();
            self.gpa.free(work.url);
            self.gpa.free(work.body);
            self.gpa.destroy(work);
            return r;
        }
        thread.detach();
        if (timeout_error == error.ConnectTimeout) {
            std.debug.print("[llm] connect_timeout budget_ms={d}\n", .{self.connect_timeout_ms});
        } else {
            std.debug.print("[llm] timeout budget_ms={d}\n", .{budget_ms});
        }
        return timeout_error;
    }

    fn chatOnce(self: *Client, url: []const u8, body: []const u8, response_start: ?*std.atomic.Value(bool)) Error!ChatResult {
        var auth_buf: [600]u8 = undefined;
        const auth_headers: []const std.http.Header = switch (self.auth_style) {
            .bearer => blk: {
                const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch return error.BufferTooSmall;
                break :blk &.{
                    .{ .name = "Authorization", .value = auth },
                };
            },
            .api_key_header => &.{
                .{ .name = "api-key", .value = self.api_key },
            },
        };

        // AC-SEC5: fixed-capacity sink — a hostile endpoint cannot balloon memory.
        const sink = self.gpa.alloc(u8, limits.max_llm_response_bytes) catch return error.OutOfMemory;
        defer self.gpa.free(sink);
        var fixed_writer: std.Io.Writer = .fixed(sink);

        const options: std.http.Client.FetchOptions = .{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &fixed_writer,
            .extra_headers = auth_headers,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .keep_alive = false,
        };
        const result = self.fetch(options, response_start) catch |err| {
            if (err == error.WriteFailed) {
                std.debug.print("[llm] response_too_large cap={d}\n", .{limits.max_llm_response_bytes});
                return error.HttpFailed;
            }
            std.debug.print("[llm] transport_failed err={s}\n", .{@errorName(err)});
            return error.HttpFailed;
        };

        const owned = fixed_writer.buffered();

        const status_code: u16 = @intFromEnum(result.status);
        if (self.llm_resilience_enabled) {
            self.last_http_status = status_code;
            self.last_api_class = classifyApiErrorBody(owned);
        }
        if (self.llm_resilience_enabled and (status_code < 200 or status_code >= 300)) return error.ApiError;
        if (owned.len == 0) {
            std.debug.print("[llm] empty_body status={d}\n", .{status_code});
            return error.HttpFailed;
        }

        if (status_code < 200 or status_code >= 300) {
            const cls = if (self.llm_resilience_enabled) classifyApiErrorBody(owned) else classifyApiErrorBodyLegacy(owned);
            std.debug.print("[llm] http_status={d} class={s}\n", .{ status_code, cls });
        }

        const parsed = parseChatResult(self.gpa, owned) catch |err| {
            if (err == error.ApiError) {
                const cls = if (self.llm_resilience_enabled) classifyApiErrorBody(owned) else classifyApiErrorBodyLegacy(owned);
                std.debug.print("[llm] provider error class={s}\n", .{cls});
            } else if (err == error.MalformedResponse) {
                std.debug.print("[llm] malformed_response status={d} bytes={d}\n", .{ status_code, owned.len });
            }
            logBodySnippet(status_code, owned);
            return err;
        };
        return parsed;
    }

    fn fetch(self: *Client, options: std.http.Client.FetchOptions, head: ?*std.atomic.Value(bool)) std.http.Client.FetchError!std.http.Client.FetchResult {
        if (builtin.is_test) {
            if (self.test_transport) |transport| return transport.fetch(self.http.io, options, head);
        }
        return if (head) |h| self.fetchWithFirstByte(options, h) else self.http.fetch(options);
    }

    /// Equivalent to std.http.fetch for our POST, publishing when the connection is
    /// established and the request is sent. Slow responses remain total-budget timeouts.
    fn fetchWithFirstByte(self: *Client, options: std.http.Client.FetchOptions, head: *std.atomic.Value(bool)) std.http.Client.FetchError!std.http.Client.FetchResult {
        const uri = try std.Uri.parse(options.location.url);
        var req = try self.http.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .headers = options.headers,
            .extra_headers = options.extra_headers,
            .keep_alive = false,
        });
        defer req.deinit();
        const payload = options.payload.?;
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
        // TCP+TLS established and request fully written: the "connect" phase is over.
        // Non-streaming completions send no bytes until generation finishes, so waiting
        // for the first response byte here would misclassify slow models as connect failures.
        head.store(true, .release);
        var response = try req.receiveHead(&.{});
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer self.gpa.free(decompress_buffer);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(options.response_writer.?) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{ .status = response.head.status };
    }

    /// Drop any pooled sockets (including half-closed ones Zig may have re-offered).
    fn resetHttp(self: *Client) void {
        const io = self.http.io;
        const allocator = self.http.allocator;
        self.http.deinit();
        self.http = .{ .allocator = allocator, .io = io };
    }
};

/// Background chat attempt so the daemon can enforce a wall-clock budget.
const ChatWork = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    auth_style: AuthStyle,
    url: []u8,
    body: []u8,
    result: Error!ChatResult = error.HttpFailed,
    resilience_enabled: bool,
    http_status: u16 = 0,
    api_class: []const u8 = "",
    track_response_start: bool,
    test_transport: TestTransportHook,
    response_started: std.atomic.Value(bool) = .init(false),
    /// 0 running, 1 done (result published), 2 abandoned by waiter.
    phase: std.atomic.Value(u8) = .init(phase_running),

    const phase_running: u8 = 0;
    const phase_done: u8 = 1;
    const phase_abandoned: u8 = 2;

    fn run(self: *ChatWork) void {
        var client = Client.init(self.gpa, self.io, self.base_url, self.api_key, self.model);
        client.auth_style = self.auth_style;
        client.llm_resilience_enabled = self.resilience_enabled;
        client.test_transport = self.test_transport;
        defer client.deinit();

        const r = client.chatOnce(self.url, self.body, if (self.track_response_start) &self.response_started else null);
        // Publish result before flipping phase to done (release).
        self.http_status = client.last_http_status;
        self.api_class = client.last_api_class;
        self.result = r;
        if (self.phase.cmpxchgStrong(phase_running, phase_done, .release, .monotonic)) |_| {
            // Waiter abandoned us — free late success body and self.
            if (r) |ok| self.gpa.free(ok.content) else |_| {}
            self.gpa.free(self.url);
            self.gpa.free(self.body);
            self.gpa.destroy(self);
        }
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    var u = url;
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    return u;
}

fn detectAuthStyle(base_url: []const u8) AuthStyle {
    // Azure OpenAI hosts typically want the api-key header.
    if (std.ascii.indexOfIgnoreCase(base_url, "openai.azure.com") != null) return .api_key_header;
    if (std.ascii.indexOfIgnoreCase(base_url, "cognitiveservices.azure.com") != null) return .api_key_header;
    return .bearer;
}

fn modelWantsThinkingOff(model: []const u8) bool {
    // DeepSeek V4 / R1-class default thinking=on: tokens land in
    // reasoning_content and `content` is often empty; some gateways also 400
    // when temperature is set while thinking is enabled.
    if (std.ascii.indexOfIgnoreCase(model, "deepseek-v4") != null) return true;
    if (std.ascii.indexOfIgnoreCase(model, "deepseek-r1") != null) return true;
    if (std.ascii.indexOfIgnoreCase(model, "reasoner") != null) return true;
    return false;
}

fn writeChatBody(w: *std.Io.Writer, model: []const u8, system: []const u8, user: []const u8) Error!void {
    w.writeAll("{\"model\":\"") catch return error.OutOfMemory;
    writeJsonString(w, model) catch return error.OutOfMemory;
    if (modelWantsThinkingOff(model)) {
        w.writeAll("\",\"temperature\":0.2,\"thinking\":{\"type\":\"disabled\"},\"messages\":[") catch return error.OutOfMemory;
    } else {
        w.writeAll("\",\"temperature\":0.2,\"messages\":[") catch return error.OutOfMemory;
    }
    w.writeAll("{\"role\":\"system\",\"content\":\"") catch return error.OutOfMemory;
    writeJsonString(w, system) catch return error.OutOfMemory;
    w.writeAll("\"},{\"role\":\"user\",\"content\":\"") catch return error.OutOfMemory;
    writeJsonString(w, user) catch return error.OutOfMemory;
    w.writeAll("\"}]}") catch return error.OutOfMemory;
}

/// JSON-escape `s` and repair invalid UTF-8 on the way out. Request bodies
/// must be valid UTF-8 or the provider rejects the whole call (HTTP 400
/// "invalid unicode code point"); one bad byte in a quoted event line used
/// to take down every periodic review. Invalid sequences become U+FFFD.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try w.print("\\u{x:0>4}", .{c});
                    } else {
                        try w.writeByte(c);
                    }
                },
            }
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            try w.writeAll("\xEF\xBF\xBD");
            i += 1;
            continue;
        };
        if (i + seq_len > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + seq_len])) {
            try w.writeAll("\xEF\xBF\xBD");
            i += 1;
            continue;
        }
        try w.writeAll(s[i .. i + seq_len]);
        i += seq_len;
    }
}

test "writeJsonString repairs truncated UTF-8 instead of forwarding it" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // "a—" with the em dash cut to two bytes, then a quote.
    try writeJsonString(&w, "a\xE2\x80\"z");
    const out = w.buffered();
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"z") != null);

    var w2: std.Io.Writer = .fixed(&buf);
    try writeJsonString(&w2, "ok — 中文");
    try std.testing.expectEqualStrings("ok — 中文", w2.buffered());
}

/// Map provider error JSON to a short stable token (no secrets).
pub fn classifyApiErrorBody(body: []const u8) []const u8 {
    const cls = classifyApiErrorBodyLegacy(body);
    if ((std.mem.eql(u8, cls, "api_error") or std.mem.eql(u8, cls, "http_or_network")) and
        std.mem.indexOf(u8, body, "overloaded") != null) return "overloaded";
    return cls;
}

// Keep disabled-path diagnostic classifications unchanged.
fn classifyApiErrorBodyLegacy(body: []const u8) []const u8 {
    if (std.mem.indexOf(u8, body, "DeploymentNotFound") != null) return "deployment_not_found";
    if (std.mem.indexOf(u8, body, "model_not_found") != null) return "model_not_found";
    if (std.mem.indexOf(u8, body, "invalid_api_key") != null) return "invalid_api_key";
    if (std.mem.indexOf(u8, body, "401") != null) return "unauthorized";
    if (std.mem.indexOf(u8, body, "insufficient_quota") != null) return "quota";
    if (std.mem.indexOf(u8, body, "RateLimit") != null or std.mem.indexOf(u8, body, "rate_limit") != null) return "rate_limit";
    if (std.mem.indexOf(u8, body, "\"error\"") != null) return "api_error";
    return "http_or_network";
}

/// Parse OpenAI-style response; returns owned assistant content string.
pub fn parseAssistantContent(gpa: std.mem.Allocator, body: []const u8) Error![]u8 {
    const r = try parseChatResult(gpa, body);
    return r.content;
}

/// Parse content + usage.token fields when present.
pub fn parseChatResult(gpa: std.mem.Allocator, body: []const u8) Error!ChatResult {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{
        .max_value_len = 512 * 1024,
    }) catch return error.MalformedResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const obj = parsed.value.object;

    if (obj.get("error")) |err_v| {
        _ = err_v;
        return error.ApiError;
    }

    const choices_v = obj.get("choices") orelse return error.MalformedResponse;
    if (choices_v != .array or choices_v.array.items.len == 0) return error.MalformedResponse;
    const first = choices_v.array.items[0];
    if (first != .object) return error.MalformedResponse;
    const msg_v = first.object.get("message") orelse return error.MalformedResponse;
    if (msg_v != .object) return error.MalformedResponse;
    const content = collectAssistantText(gpa, msg_v) catch |err| return err;
    defer if (content.owned) gpa.free(content.text);
    if (content.text.len == 0) return error.EmptyContent;

    var usage: Usage = .{};
    if (obj.get("usage")) |uv| {
        if (uv == .object) {
            usage.reported = true;
            usage.prompt_tokens = jsonU64(uv.object.get("prompt_tokens"));
            usage.completion_tokens = jsonU64(uv.object.get("completion_tokens"));
            usage.total_tokens = jsonU64(uv.object.get("total_tokens"));
            usage.cached_prompt_tokens = jsonU64(uv.object.get("prompt_cache_hit_tokens"));
            if (usage.cached_prompt_tokens == 0) {
                usage.cached_prompt_tokens = jsonU64(uv.object.get("cached_tokens"));
            }
            if (usage.cached_prompt_tokens == 0) {
                if (uv.object.get("prompt_tokens_details")) |details| {
                    if (details == .object) {
                        usage.cached_prompt_tokens = jsonU64(details.object.get("cached_tokens"));
                        if (usage.cached_prompt_tokens == 0) {
                            usage.cached_prompt_tokens = jsonU64(details.object.get("cache_hit_tokens"));
                        }
                    }
                }
            }
            usage.cached_prompt_tokens = @min(usage.cached_prompt_tokens, usage.prompt_tokens);
            if (usage.total_tokens == 0)
                usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
        }
    }

    const owned = gpa.dupe(u8, content.text) catch return error.OutOfMemory;
    return .{ .content = owned, .usage = usage };
}

const AssistantText = struct {
    text: []const u8,
    owned: bool = false,
};

/// OpenAI string content, or the concatenated `text` parts of a content array.
/// Empty / missing / null → EmptyContent. Reasoning-only replies are empty:
/// structured JSON tasks must send `thinking.type=disabled` instead of mining CoT.
fn collectAssistantText(gpa: std.mem.Allocator, msg_v: std.json.Value) Error!AssistantText {
    if (msg_v != .object) return error.MalformedResponse;
    const msg = msg_v.object;
    const content_v = msg.get("content") orelse return error.EmptyContent;
    switch (content_v) {
        .string => |s| return .{ .text = s },
        .null => return error.EmptyContent,
        .array => |arr| {
            var aw = std.Io.Writer.Allocating.init(gpa);
            defer aw.deinit();
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| aw.writer.writeAll(s) catch return error.OutOfMemory,
                    .object => |o| {
                        if (o.get("text")) |t| {
                            if (t == .string) aw.writer.writeAll(t.string) catch return error.OutOfMemory;
                        } else if (o.get("content")) |c| {
                            if (c == .string) aw.writer.writeAll(c.string) catch return error.OutOfMemory;
                        }
                    },
                    else => {},
                }
            }
            const slice = aw.writer.buffered();
            if (slice.len == 0) return error.EmptyContent;
            const owned = gpa.dupe(u8, slice) catch return error.OutOfMemory;
            return .{ .text = owned, .owned = true };
        },
        else => return error.MalformedResponse,
    }
}

fn logBodySnippet(status: u16, body: []const u8) void {
    var buf: [96]u8 = undefined;
    var n: usize = 0;
    for (body) |c| {
        if (n >= buf.len) break;
        if (c >= 0x20 and c < 0x7f) {
            buf[n] = c;
            n += 1;
        } else if (c == '\n' or c == '\t' or c == '\r') {
            buf[n] = ' ';
            n += 1;
        }
    }
    std.debug.print("[llm] body_snippet status={d} bytes={d} text={s}\n", .{ status, body.len, buf[0..n] });
}

fn jsonU64(v: ?std.json.Value) u64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0 or !std.math.isFinite(f)) 0 else @intFromFloat(f),
        else => 0,
    };
}

/// Best-effort extract of a top-level JSON object from model text
/// (handles ```json fences and leading prose).
pub fn extractJsonObject(text: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
            s = s[nl + 1 ..];
        }
        if (std.mem.endsWith(u8, s, "```")) {
            s = std.mem.trimEnd(u8, s[0 .. s.len - 3], " \t\r\n");
        } else if (std.mem.lastIndexOf(u8, s, "```")) |end| {
            s = std.mem.trimEnd(u8, s[0..end], " \t\r\n");
        }
    }
    s = std.mem.trim(u8, s, " \t\r\n");
    const start = std.mem.indexOfScalar(u8, s, '{') orelse return null;
    // Match braces (naive, good enough for proposal objects).
    var depth: i32 = 0;
    var in_str = false;
    var esc = false;
    var i: usize = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "parseAssistantContent happy path" {
    const body =
        \\{"id":"x","choices":[{"message":{"role":"assistant","content":"{\"action\":\"HOLD\"}"}}]}
    ;
    const c = try parseAssistantContent(testing.allocator, body);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("{\"action\":\"HOLD\"}", c);
}

test "parseAssistantContent api error" {
    const body =
        \\{"error":{"message":"nope","type":"invalid_request_error"}}
    ;
    try testing.expectError(error.ApiError, parseAssistantContent(testing.allocator, body));
}

test "extractJsonObject strips fence and prose" {
    const raw =
        \\Here you go:
        \\```json
        \\{"decision_id":"dec_1","action":"HOLD"}
        \\```
    ;
    const j = extractJsonObject(raw).?;
    try testing.expectEqualStrings("{\"decision_id\":\"dec_1\",\"action\":\"HOLD\"}", j);
}

test "extractJsonObject nested braces in strings" {
    const raw = "{\"a\":{\"b\":1},\"c\":\"x{y}\"}";
    const j = extractJsonObject(raw).?;
    try testing.expectEqualStrings(raw, j);
}

test "v4 flash chat body disables thinking" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeChatBody(&w, "deepseek-v4-flash", "sys", "hi");
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"temperature\":0.2") != null);
}

test "non-reasoner chat body has no thinking field" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeChatBody(&w, "gpt-4o-mini", "sys", "hi");
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "thinking") == null);
}

test "parseAssistantContent concatenates content array" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"{\"action\":"},{"type":"text","text":"\"HOLD\"}"}]}}]}
    ;
    const c = try parseAssistantContent(testing.allocator, body);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("{\"action\":\"HOLD\"}", c);
}

test "parseAssistantContent empty content is EmptyContent" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"","reasoning_content":"thoughts"}}]}
    ;
    try testing.expectError(error.EmptyContent, parseAssistantContent(testing.allocator, body));
}

test "parses usage tokens" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"{\"a\":1}"}}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18,"prompt_tokens_details":{"cached_tokens":4}}}
    ;
    const r = try parseChatResult(std.testing.allocator, body);
    defer std.testing.allocator.free(r.content);
    try std.testing.expect(r.usage.reported);
    try std.testing.expectEqual(@as(u64, 11), r.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 4), r.usage.cached_prompt_tokens);
    try std.testing.expectEqual(@as(u64, 7), r.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 18), r.usage.total_tokens);
}

// A transport hook is used because sandboxed runners can forbid loopback binds.
// It exercises the real worker, polling, abandonment, and late-result cleanup.
fn expectTransportTimeout(connect_ms: u32, request_ms: u32, send_byte: bool, expected: Error, min_ms: i64, max_ms: i64) !void {
    const io = std.testing.io;
    var transport = TestTransport{ .response_start = send_byte };
    // The hook must outlive the abandoned worker's transport call.
    defer while (!transport.finished.load(.acquire)) {
        io.sleep(.{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    };
    // Workers intentionally outlive timed-out callers; use a process-lifetime
    // allocator, rather than a test allocator that could be torn down first.
    var client = Client.init(std.heap.page_allocator, io, "http://test.invalid", "synthetic", "test-model");
    defer client.deinit();
    client.test_transport = &transport;
    client.timeout_ms = 600;
    client.connect_timeout_ms = connect_ms;
    client.request_timeout_ms = request_ms;
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(expected, client.chat("test", "test"));
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try std.testing.expect(elapsed >= min_ms);
    try std.testing.expect(elapsed < max_ms);
}

test "silent transport hits connect deadline before total budget" {
    try expectTransportTimeout(200, 0, false, error.ConnectTimeout, 150, 550);
}

test "disabled connect deadline preserves total budget timeout" {
    try expectTransportTimeout(0, 0, false, error.Timeout, 550, 850);
}

test "connected then slow response is total timeout, not connect" {
    try expectTransportTimeout(200, 0, true, error.Timeout, 550, 850);
}

test "request timeout caps attempt and never extends call budget" {
    try expectTransportTimeout(0, 200, false, error.Timeout, 150, 550);
    try expectTransportTimeout(0, 2000, false, error.Timeout, 550, 850);
}

const TestRetryRuntime = struct {
    elapsed: i64 = 0,
    sleeps: [32]u32 = @splat(0),
    sleep_count: usize = 0,
    rng: std.Random.DefaultPrng = .init(42),

    fn now(context: *anyopaque) i64 {
        const self: *TestRetryRuntime = @ptrCast(@alignCast(context));
        return self.elapsed;
    }
    fn sleep(context: *anyopaque, ms: u32) void {
        const self: *TestRetryRuntime = @ptrCast(@alignCast(context));
        self.elapsed += ms;
        if (ms > 0) {
            self.sleeps[self.sleep_count] = ms;
            self.sleep_count += 1;
        }
    }
    fn random(context: *anyopaque) u32 {
        const self: *TestRetryRuntime = @ptrCast(@alignCast(context));
        return self.rng.random().int(u32);
    }
    fn hooks(self: *TestRetryRuntime) RetryRuntime {
        return .{ .context = self, .now_ms = now, .sleep_ms = sleep, .random = random };
    }
};

fn retryTestClient(transport: *TestTransport, runtime: *TestRetryRuntime) Client {
    var client = Client.init(testing.allocator, testing.io, "http://test.invalid", "synthetic", "test-model");
    client.test_transport = transport;
    client.retry_runtime = runtime.hooks();
    client.llm_resilience_enabled = true;
    client.timeout_ms = 10_000;
    return client;
}

test "resilience timeout and connect timeout retry same model within shared budget" {
    for ([_]Error{ error.Timeout, error.ConnectTimeout }) |err| {
        var transport: TestTransport = .{ .steps = &.{ .{ .elapsed_ms = 1000, .timeout = err }, .{} } };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        const result = try client.chat("test", "test");
        defer testing.allocator.free(result.content);
        try testing.expectEqual(@as(?u32, 2), result.attempts);
        try testing.expectEqual(@as(?u32, 2), client.last_attempt_count);
        try testing.expect(runtime.elapsed <= client.timeout_ms);
        try testing.expectEqualStrings("test-model", client.model);
    }
}

test "resilience timeout retry requires floor plus backoff after elapsed attempt" {
    var transport: TestTransport = .{ .steps = &.{.{ .elapsed_ms = 8000, .timeout = error.Timeout }} };
    var runtime: TestRetryRuntime = .{};
    var client = retryTestClient(&transport, &runtime);
    defer client.deinit();
    try testing.expectError(error.Timeout, client.chat("test", "test"));
    try testing.expectEqual(@as(?u32, 1), client.last_attempt_count);
    try testing.expectEqual(@as(i64, 8000), runtime.elapsed);
    try testing.expectEqual(@as(usize, 1), runtime.sleep_count);
}

test "resilience status retries record exponential backoff plus deterministic jitter" {
    for ([_]std.http.Status{ .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout, .too_many_requests }) |status| {
        // Empty error bodies must still carry the actual status to the retry layer.
        var transport: TestTransport = .{ .steps = &.{ .{ .status = status, .body = "" }, .{ .status = status, .body = "" }, .{} } };
        var runtime: TestRetryRuntime = .{};
        var expected_rng = std.Random.DefaultPrng.init(42);
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        const result = try client.chat("test", "test");
        defer testing.allocator.free(result.content);
        try testing.expectEqual(@as(?u32, 3), result.attempts);
        try testing.expectEqual(@as(usize, 2), runtime.sleep_count);
        try testing.expectEqual(500 + @as(u32, @intCast(@as(u64, expected_rng.random().int(u32)) % 251)), runtime.sleeps[0]);
        try testing.expectEqual(1000 + @as(u32, @intCast(@as(u64, expected_rng.random().int(u32)) % 251)), runtime.sleeps[1]);
    }
}

test "resilience authentication errors never retry even with retryable body or status" {
    for ([_]TestTransport.Step{
        .{ .status = .unauthorized, .body = "{\"error\":\"rate_limit\"}" },
        .{ .status = .forbidden, .body = "{\"error\":\"overloaded\"}" },
        .{ .status = .service_unavailable, .body = "{\"error\":\"invalid_api_key\"}" },
        .{ .body = "{\"error\":\"invalid_api_key\"}" },
    }) |step| {
        var transport: TestTransport = .{ .steps = &.{step} };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        try testing.expectError(error.ApiError, client.chat("test", "test"));
        try testing.expectEqual(@as(?u32, 1), client.last_attempt_count);
        try testing.expectEqual(@as(usize, 0), runtime.sleep_count);
    }
}

test "resilience recognises rate limit and overload bodies without retryable status" {
    for ([_][]const u8{ "{\"error\":\"rate_limit\"}", "{\"error\":\"overloaded\"}" }) |body| {
        var transport: TestTransport = .{ .steps = &.{ .{ .body = body }, .{} } };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        const result = try client.chat("test", "test");
        defer testing.allocator.free(result.content);
        try testing.expectEqual(@as(?u32, 2), result.attempts);
    }
}

test "disabled resilience retains legacy transport and empty content retry only" {
    for ([_]TestTransport.Step{
        .{ .body = "" }, // HttpFailed
        .{ .body = "{\"choices\":[{\"message\":{\"content\":\"\"}}]}" },
    }) |step| {
        var transport: TestTransport = .{ .steps = &.{ step, .{} } };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        client.llm_resilience_enabled = false;
        const result = try client.chat("test", "test");
        defer testing.allocator.free(result.content);
        try testing.expectEqual(@as(usize, 2), transport.index);
        try testing.expectEqual(@as(?u32, null), result.attempts);
        try testing.expectEqual(@as(?u32, null), client.last_attempt_count);
        try testing.expectEqual(@as(usize, 0), runtime.sleep_count);
    }
    for ([_]TestTransport.Step{
        .{ .timeout = error.Timeout },
        .{ .status = .service_unavailable, .body = "{\"error\":\"overloaded\"}" },
    }) |step| {
        var transport: TestTransport = .{ .steps = &.{step} };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        client.llm_resilience_enabled = false;
        _ = client.chat("test", "test") catch {};
        try testing.expectEqual(@as(usize, 1), transport.index);
        try testing.expectEqual(@as(?u32, null), client.last_attempt_count);
    }
}

test "outage replay every attempt times out with bounded attempts and elapsed budget" {
    for ([_]u32{ 1, 100 }) |max_retries| {
        const steps = [_]TestTransport.Step{.{ .elapsed_ms = 10_000, .timeout = error.Timeout }} ** 16;
        var transport: TestTransport = .{ .steps = &steps };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        client.request_timeout_ms = 1000;
        client.llm_retry_max = max_retries;
        try testing.expectError(error.Timeout, client.chat("test", "test"));
        try testing.expect(client.last_attempt_count.? >= 2);
        try testing.expect(client.last_attempt_count.? <= max_retries + 1);
        try testing.expect(runtime.elapsed <= client.timeout_ms);
    }
}

test "resilience caps attempts to remaining budget including backoff" {
    var transport: TestTransport = .{ .steps = &.{ .{ .status = .service_unavailable, .body = "" }, .{ .elapsed_ms = 20_000 } } };
    var runtime: TestRetryRuntime = .{};
    var client = retryTestClient(&transport, &runtime);
    defer client.deinit();
    try testing.expectError(error.Timeout, client.chat("test", "test"));
    try testing.expectEqual(@as(?u32, 2), client.last_attempt_count);
    try testing.expectEqual(@as(i64, client.timeout_ms), runtime.elapsed);
}

test "resilience timeout retry can be disabled separately and retry counts can be zero" {
    for ([_]bool{ false, true }) |timeout_enabled| {
        var transport: TestTransport = .{ .steps = &.{.{ .timeout = error.Timeout }} };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        client.llm_retry_on_timeout = timeout_enabled;
        client.llm_retry_max = if (timeout_enabled) 0 else 10;
        try testing.expectError(error.Timeout, client.chat("test", "test"));
        try testing.expectEqual(@as(?u32, 1), client.last_attempt_count);
    }
}

test "resilience worker publishes actual HTTP status back to retry orchestration" {
    var transport: TestTransport = .{ .steps = &.{ .{ .status = .service_unavailable, .body = "" }, .{ .status = .too_many_requests, .body = "" }, .{} } };
    var client = Client.init(testing.allocator, testing.io, "http://test.invalid", "synthetic", "test-model");
    defer client.deinit();
    client.test_transport = &transport;
    client.llm_resilience_enabled = true;
    client.llm_retry_backoff_ms = 0;
    client.llm_retry_jitter_ms = 0;
    client.timeout_ms = 5000;
    const result = try client.chat("test", "test");
    defer testing.allocator.free(result.content);
    try testing.expectEqual(@as(?u32, 3), result.attempts);
    try testing.expectEqual(@as(u16, 200), client.last_http_status);
}

test "resilience retains one empty content reset retry and bounds status retries" {
    for ([_]TestTransport.Step{
        .{ .body = "{\"choices\":[{\"message\":{\"content\":\"\"}}]}" },
        .{ .status = .service_unavailable, .body = "" },
    }) |step| {
        var transport: TestTransport = .{ .steps = &.{ step, step } };
        var runtime: TestRetryRuntime = .{};
        var client = retryTestClient(&transport, &runtime);
        defer client.deinit();
        client.llm_retry_5xx_max = 1;
        const expected: Error = if (step.status == .ok) error.EmptyContent else error.ApiError;
        try testing.expectError(expected, client.chat("test", "test"));
        try testing.expectEqual(@as(?u32, 2), client.last_attempt_count);
    }
}

test "retry delay saturates instead of overflowing for extreme config values" {
    var transport: TestTransport = .{};
    var runtime: TestRetryRuntime = .{};
    var client = retryTestClient(&transport, &runtime);
    defer client.deinit();
    client.llm_retry_backoff_ms = std.math.maxInt(u32);
    client.llm_retry_jitter_ms = std.math.maxInt(u32);
    try testing.expectEqual(std.math.maxInt(u32), client.retryDelay(std.math.maxInt(u32)));
}
