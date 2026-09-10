//! OpenAI-compatible Chat Completions client (Gate 2 shadow).
//!
//! Talks to any endpoint that accepts:
//!   POST {base}/chat/completions
//!   Authorization: Bearer <key>
//!   {"model","messages":[{"role","content"},...]}
//!
//! Credentials stay in this adapter; agent context/proposal layers never see them.

const std = @import("std");
const limits = @import("../security/limits.zig");

pub const Error = error{
    HttpFailed,
    Timeout,
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
};

pub const AuthStyle = enum {
    /// Authorization: Bearer <key>
    bearer,
    /// api-key: <key>  (Azure OpenAI classic)
    api_key_header,
};

pub const Client = struct {
    http: std.http.Client,
    gpa: std.mem.Allocator,
    /// Root URL without trailing slash, e.g. https://api.openai.com/v1
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    auth_style: AuthStyle = .bearer,
    /// Hard wall-clock budget for one chat() attempt (including one transport retry).
    /// Slow Azure/DeepSeek completions often exceed 30s; production should use >=120s.
    timeout_ms: u32 = 120_000,

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
        var body_aw = std.Io.Writer.Allocating.init(self.gpa);
        defer body_aw.deinit();
        try writeChatBody(&body_aw.writer, self.model, system, user);
        const body = body_aw.writer.buffered();

        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/chat/completions", .{self.base_url}) catch return error.BufferTooSmall;

        // Wall-clock budget guards against half-open TLS hangs that never surface as
        // an error from std.http (observed in production after idle gateway drops).
        return self.chatBudgeted(url, body) catch |err| {
            // Retry transport flakes and empty-content (thinking models / gateway
            // blanks). Timeouts already consumed the full budget.
            if (err != error.HttpFailed and err != error.EmptyContent) return err;
            if (err == error.EmptyContent) {
                std.debug.print("[llm] empty_content; reset_http_retry\n", .{});
            } else {
                std.debug.print("[llm] transport_failed; reset_http_retry\n", .{});
            }
            self.resetHttp();
            return self.chatBudgeted(url, body);
        };
    }

    fn chatBudgeted(self: *Client, url: []const u8, body: []const u8) Error!ChatResult {
        const budget_ms: u32 = if (self.timeout_ms == 0) 120_000 else self.timeout_ms;

        // Prefer a worker thread so a wedged socket cannot block the daemon forever.
        // Fallback to sync if threads are unavailable.
        const work = self.gpa.create(ChatWork) catch return self.chatOnce(url, body);
        work.* = .{
            .gpa = self.gpa,
            .io = self.http.io,
            .base_url = self.base_url,
            .api_key = self.api_key,
            .model = self.model,
            .auth_style = self.auth_style,
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
            const r = self.chatOnce(url, body);
            self.gpa.free(work.url);
            self.gpa.free(work.body);
            self.gpa.destroy(work);
            return r;
        };

        var waited_ms: u32 = 0;
        while (waited_ms < budget_ms) {
            if (work.phase.load(.acquire) == ChatWork.phase_done) {
                const r = work.result;
                thread.join();
                self.gpa.free(work.url);
                self.gpa.free(work.body);
                self.gpa.destroy(work);
                return r;
            }
            self.http.io.sleep(.{ .nanoseconds = 100_000_000 }, .awake) catch {};
            waited_ms +|= 100;
        }

        // Timed out: try to abandon. If worker finished in the race window, take the result.
        if (work.phase.cmpxchgStrong(ChatWork.phase_running, ChatWork.phase_abandoned, .acq_rel, .acquire)) |_| {
            // phase was not running → must be done
            const r = work.result;
            thread.join();
            self.gpa.free(work.url);
            self.gpa.free(work.body);
            self.gpa.destroy(work);
            return r;
        }
        thread.detach();
        std.debug.print("[llm] timeout budget_ms={d}\n", .{budget_ms});
        return error.Timeout;
    }

    fn chatOnce(self: *Client, url: []const u8, body: []const u8) Error!ChatResult {
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

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &fixed_writer,
            .extra_headers = auth_headers,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .keep_alive = false,
        }) catch |err| {
            if (err == error.WriteFailed) {
                std.debug.print("[llm] response_too_large cap={d}\n", .{limits.max_llm_response_bytes});
                return error.HttpFailed;
            }
            std.debug.print("[llm] transport_failed err={s}\n", .{@errorName(err)});
            return error.HttpFailed;
        };

        const owned = fixed_writer.buffered();

        const status_code: u16 = @intFromEnum(result.status);
        if (owned.len == 0) {
            std.debug.print("[llm] empty_body status={d}\n", .{status_code});
            return error.HttpFailed;
        }

        if (status_code < 200 or status_code >= 300) {
            const cls = classifyApiErrorBody(owned);
            std.debug.print("[llm] http_status={d} class={s}\n", .{ status_code, cls });
        }

        const parsed = parseChatResult(self.gpa, owned) catch |err| {
            if (err == error.ApiError) {
                const cls = classifyApiErrorBody(owned);
                std.debug.print("[llm] provider error class={s}\n", .{cls});
            } else if (err == error.MalformedResponse) {
                std.debug.print("[llm] malformed_response status={d} bytes={d}\n", .{ status_code, owned.len });
            }
            logBodySnippet(status_code, owned);
            return err;
        };
        return parsed;
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
    /// 0 running, 1 done (result published), 2 abandoned by waiter.
    phase: std.atomic.Value(u8) = .init(phase_running),

    const phase_running: u8 = 0;
    const phase_done: u8 = 1;
    const phase_abandoned: u8 = 2;

    fn run(self: *ChatWork) void {
        var client = Client.init(self.gpa, self.io, self.base_url, self.api_key, self.model);
        client.auth_style = self.auth_style;
        defer client.deinit();

        const r = client.chatOnce(self.url, self.body);
        // Publish result before flipping phase to done (release).
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

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
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
    }
}

/// Map provider error JSON to a short stable token (no secrets).
pub fn classifyApiErrorBody(body: []const u8) []const u8 {
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
