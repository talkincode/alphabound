//! OpenAI-compatible Chat Completions client (Gate 2 shadow).
//!
//! Talks to any endpoint that accepts:
//!   POST {base}/chat/completions
//!   Authorization: Bearer <key>
//!   {"model","messages":[{"role","content"},...]}
//!
//! Credentials stay in this adapter; agent context/proposal layers never see them.

const std = @import("std");

pub const Error = error{
    HttpFailed,
    ApiError,
    MalformedResponse,
    EmptyContent,
    OutOfMemory,
    BufferTooSmall,
};

pub const Usage = struct {
    prompt_tokens: u64 = 0,
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

        var resp_aw = std.Io.Writer.Allocating.init(self.gpa);
        defer resp_aw.deinit();

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &resp_aw.writer,
            .extra_headers = auth_headers,
            .headers = .{ .content_type = .{ .override = "application/json" } },
        }) catch {
            // No response body — DNS/TLS/timeout/connect. Never log URL query secrets.
            std.debug.print("[llm] transport_failed\n", .{});
            return error.HttpFailed;
        };

        var list = resp_aw.toArrayList();
        const owned = list.toOwnedSlice(self.gpa) catch return error.OutOfMemory;
        errdefer self.gpa.free(owned);

        const status_code: u16 = @intFromEnum(result.status);
        if (owned.len == 0) {
            std.debug.print("[llm] empty_body status={d}\n", .{status_code});
            self.gpa.free(owned);
            return error.HttpFailed;
        }

        // Non-2xx: classify without dumping body (may contain request ids only — still keep short).
        if (status_code < 200 or status_code >= 300) {
            const cls = classifyApiErrorBody(owned);
            std.debug.print("[llm] http_status={d} class={s}\n", .{ status_code, cls });
        }

        // parseAssistantContent maps error object → ApiError; classify on ApiError path too.
        const parsed = parseChatResult(self.gpa, owned) catch |err| {
            if (err == error.ApiError) {
                const cls = classifyApiErrorBody(owned);
                std.debug.print("[llm] provider error class={s}\n", .{cls});
            } else if (err == error.MalformedResponse) {
                std.debug.print("[llm] malformed_response status={d} bytes={d}\n", .{ status_code, owned.len });
            }
            self.gpa.free(owned);
            return err;
        };
        self.gpa.free(owned);
        return parsed;
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

fn writeChatBody(w: *std.Io.Writer, model: []const u8, system: []const u8, user: []const u8) Error!void {
    w.writeAll("{\"model\":\"") catch return error.OutOfMemory;
    writeJsonString(w, model) catch return error.OutOfMemory;
    w.writeAll("\",\"temperature\":0.2,\"messages\":[") catch return error.OutOfMemory;
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
    const content_v = msg_v.object.get("content") orelse return error.EmptyContent;
    const content = switch (content_v) {
        .string => |s| s,
        .null => return error.EmptyContent,
        else => return error.MalformedResponse,
    };
    if (content.len == 0) return error.EmptyContent;

    var usage: Usage = .{};
    if (obj.get("usage")) |uv| {
        if (uv == .object) {
            usage.prompt_tokens = jsonU64(uv.object.get("prompt_tokens"));
            usage.completion_tokens = jsonU64(uv.object.get("completion_tokens"));
            usage.total_tokens = jsonU64(uv.object.get("total_tokens"));
            if (usage.total_tokens == 0)
                usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
        }
    }

    const owned = gpa.dupe(u8, content) catch return error.OutOfMemory;
    return .{ .content = owned, .usage = usage };
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

test "parses usage tokens" {
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"{\"a\":1}"}}],"usage":{"prompt_tokens":11,"completion_tokens":7,"total_tokens":18}}
    ;
    const r = try parseChatResult(std.testing.allocator, body);
    defer std.testing.allocator.free(r.content);
    try std.testing.expectEqual(@as(u64, 11), r.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 7), r.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 18), r.usage.total_tokens);
}
