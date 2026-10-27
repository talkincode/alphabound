//! Boundary redaction. Sensitive JSON fields are replaced as whole values;
//! free-text assignments are scanned without leaving Bearer/quoted suffixes.
//! Invalid structured input or insufficient output capacity fails closed.
const std = @import("std");
const limits = @import("../security/limits.zig");
const SENSITIVE_KEYS = [_][]const u8{
    "secret",        "passphrase",     "api_key",       "apikey",               "api-key", "private_key",
    "authorization", "ok-access-sign", "ok-access-key", "ok-access-passphrase", "token",   "password",
};
pub const MASK = "[REDACTED]";
const parse_capacity = 128 * 1024;

fn sensitiveName(name: []const u8) bool {
    for (SENSITIVE_KEYS) |key| {
        // Preserve support for prefixed environment names (e.g. *_SECRET).
        if (name.len >= key.len and std.ascii.eqlIgnoreCase(name[name.len - key.len ..], key)) return true;
    }
    return false;
}
const Span = struct { start: usize, end: usize };
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}
fn nextAssignment(s: []const u8, start: usize) bool {
    var i = start;
    while (i < s.len and isSpace(s[i])) : (i += 1) {}
    const begin = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_' or s[i] == '-')) : (i += 1) {}
    return i > begin and i < s.len and (s[i] == '=' or s[i] == ':');
}
fn valueSpan(s: []const u8, after_key: usize) ?Span {
    var i = after_key;
    if (i < s.len and (s[i] == '"' or s[i] == '\'')) i += 1;
    while (i < s.len and isSpace(s[i])) : (i += 1) {}
    if (i == s.len or (s[i] != ':' and s[i] != '=')) return null;
    i += 1;
    while (i < s.len and isSpace(s[i])) : (i += 1) {}
    if (i == s.len) return .{ .start = i, .end = i };
    if (s[i] == '"' or s[i] == '\'') {
        const quote = s[i];
        i += 1;
        const start = i;
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (s[i] == quote) break;
        }
        return .{ .start = start, .end = i };
    }
    const start = i;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n' or s[i] == '&' or s[i] == ',') break;
        // Whitespace is part of a header/credential unless a new named
        // assignment starts. In particular, never mask just "Bearer".
        if (isSpace(s[i]) and nextAssignment(s, i)) break;
    }
    return .{ .start = start, .end = i };
}
fn nextSensitive(s: []const u8, offset: usize) ?Span {
    var i = offset;
    while (i < s.len) : (i += 1) {
        for (SENSITIVE_KEYS) |key| {
            if (key.len <= s.len - i and std.ascii.eqlIgnoreCase(s[i..][0..key.len], key)) {
                if (valueSpan(s, i + key.len)) |span| return span;
            }
        }
    }
    return null;
}
fn textLeaky(s: []const u8) bool {
    var offset: usize = 0;
    while (nextSensitive(s, offset)) |span| {
        if (!std.mem.eql(u8, s[span.start..span.end], MASK)) return true;
        offset = span.end;
    }
    return false;
}
fn jsonLeaky(value: std.json.Value) bool {
    switch (value) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (sensitiveName(entry.key_ptr.*)) {
                    const v = entry.value_ptr.*;
                    if (v != .string or !std.mem.eql(u8, v.string, MASK)) return true;
                } else if (jsonLeaky(entry.value_ptr.*)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |v| {
                if (jsonLeaky(v)) return true;
            }
        },
        .string => |s| return textLeaky(s),
        else => {},
    }
    return false;
}
fn scrubJson(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (sensitiveName(entry.key_ptr.*)) entry.value_ptr.* = .{ .string = MASK } else scrubJson(entry.value_ptr);
            }
        },
        .array => |*arr| {
            for (arr.items) |*v| scrubJson(v);
        },
        .string => |s| {
            if (textLeaky(s)) value.* = .{ .string = MASK };
        },
        else => {},
    }
}
fn looksStructured(s: []const u8) bool {
    const text = std.mem.trimStart(u8, s, " \t\r\n");
    return text.len > 0 and (text[0] == '{' or text[0] == '[' or text[0] == '"');
}

/// Returns a safe slice. On malformed JSON, depth/allocation/output limits,
/// returns the static valid JSON value "null"; never a partially masked prefix.
pub fn redact(in: []const u8, out: []u8) []const u8 {
    if (looksStructured(in)) {
        if (!limits.jsonStructureSane(in, limits.max_json_depth)) return "null";
        var arena: [parse_capacity]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&arena);
        var parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), in, .{}) catch return "null";
        defer parsed.deinit();
        scrubJson(&parsed.value);
        var w: std.Io.Writer = .fixed(out);
        std.json.Stringify.value(parsed.value, .{}, &w) catch return "null";
        return w.buffered();
    }
    var w: std.Io.Writer = .fixed(out);
    var offset: usize = 0;
    while (nextSensitive(in, offset)) |span| {
        w.writeAll(in[offset..span.start]) catch return "null";
        w.writeAll(MASK) catch return "null";
        offset = span.end;
        if (offset == in.len) break;
    }
    w.writeAll(in[offset..]) catch return "null";
    return w.buffered();
}

/// Invalid structured data is unsafe; a mask prefix with a secret suffix is
/// not redaction. This check uses the same complete-value boundaries.
pub fn looksLeaky(text: []const u8) bool {
    if (!looksStructured(text)) return textLeaky(text);
    if (!limits.jsonStructureSane(text, limits.max_json_depth)) return true;
    var arena: [parse_capacity]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena);
    var parsed = std.json.parseFromSlice(std.json.Value, fba.allocator(), text, .{}) catch return true;
    defer parsed.deinit();
    return jsonLeaky(parsed.value);
}

const testing = std.testing;
test "redacts JSON and environment assignments" {
    var buf: [512]u8 = undefined;
    const clean = redact("{\"api_key\":\"synthetic-value\",\"note\":\"hello\"}", &buf);
    try testing.expect(std.mem.indexOf(u8, clean, "synthetic-value") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "hello") != null);
    try testing.expect(!looksLeaky(clean));
    const env = redact("EXAMPLE_SECRET=synthetic-a EXAMPLE_PASSPHRASE=synthetic-b host=example.invalid", &buf);
    try testing.expect(std.mem.indexOf(u8, env, "synthetic-") == null);
    try testing.expect(std.mem.indexOf(u8, env, "host=example.invalid") != null);
    try testing.expect(!looksLeaky(env));
}
test "whole Bearer, quoted and nested values are masked" {
    const inputs = [_][]const u8{
        "{\"authorization\":\"Bearer synthetic-secret\"}",
        "Authorization: Bearer synthetic-secret",
        "password='two words synthetic-secret' host=example.invalid",
        "{\"password\":\"two words \\\"synthetic-secret\\\"\",\"rows\":[{\"TOKEN\":{\"value\":\"synthetic-secret\"}}]}",
        "{\"note\":\"Authorization: Bearer synthetic-secret\"}",
        "{\"api_\\u006bey\":\"synthetic-secret\"}",
    };
    for (inputs) |input| {
        var buf: [1024]u8 = undefined;
        try testing.expect(looksLeaky(input));
        const clean = redact(input, &buf);
        try testing.expect(std.mem.indexOf(u8, clean, "synthetic-secret") == null);
        try testing.expect(!looksLeaky(clean));
        if (looksStructured(input)) {
            var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, clean, .{});
            parsed.deinit();
        }
    }
    try testing.expect(looksLeaky("{\"authorization\":\"[REDACTED] synthetic-secret\"}"));
}
test "redaction fails closed on malformed JSON and insufficient capacity" {
    var small: [4]u8 = undefined;
    try testing.expectEqualStrings("null", redact("password=synthetic-secret", &small));
    try testing.expectEqualStrings("null", redact("{\"token\":\"synthetic-secret", &small));
    try testing.expect(looksLeaky("{\"token\":\"synthetic-secret"));
}
test "innocent text and token counts remain unchanged" {
    var buf: [512]u8 = undefined;
    const text = "the tokenizer splits words; keychain is a mac thing";
    try testing.expectEqualStrings(text, redact(text, &buf));
    try testing.expect(!looksLeaky("{\"prompt_tokens\":10,\"completion_tokens\":20}"));
    try testing.expect(!looksLeaky("token-aware research"));
}
