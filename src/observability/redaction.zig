//! Secret redaction (§7.3): LLM context, logs, error traces and dashboard
//! responses must never contain secrets, passphrases or signing material.

const std = @import("std");

/// Key names whose values must be masked wherever they appear.
const SENSITIVE_KEYS = [_][]const u8{
    "secret",
    "passphrase",
    "api_key",
    "apikey",
    "api-key",
    "private_key",
    "authorization",
    "ok-access-sign",
    "ok-access-key",
    "ok-access-passphrase",
    "token",
    "password",
};

pub const MASK = "[REDACTED]";

/// Redact `key=value` / `"key": "value"` shapes for sensitive keys in free
/// text (logs, error messages). Writes redacted text to `out`, returns slice.
/// out must be at least in.len + 64 bytes to accommodate mask expansion.
pub fn redact(in: []const u8, out: []u8) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    outer: while (i < in.len) {
        for (SENSITIVE_KEYS) |key| {
            if (matchesKeyAt(in, i, key)) {
                // copy the key
                if (w + key.len >= out.len) break :outer;
                @memcpy(out[w .. w + key.len], in[i .. i + key.len]);
                w += key.len;
                i += key.len;
                // copy separator chars: whitespace, quotes, :, =
                while (i < in.len and (in[i] == '"' or in[i] == '\'' or in[i] == ':' or in[i] == '=' or in[i] == ' ')) {
                    if (w >= out.len) break :outer;
                    out[w] = in[i];
                    w += 1;
                    i += 1;
                }
                // mask the value run
                const start = i;
                while (i < in.len and in[i] != '"' and in[i] != '\'' and in[i] != ' ' and in[i] != ',' and in[i] != '}' and in[i] != '\n' and in[i] != '&') i += 1;
                if (i > start) {
                    if (w + MASK.len >= out.len) break :outer;
                    @memcpy(out[w .. w + MASK.len], MASK);
                    w += MASK.len;
                }
                continue :outer;
            }
        }
        if (w >= out.len) break;
        out[w] = in[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

fn matchesKeyAt(in: []const u8, i: usize, key: []const u8) bool {
    if (i + key.len > in.len) return false;
    if (!std.ascii.eqlIgnoreCase(in[i .. i + key.len], key)) return false;
    // must be followed by a separator so "tokenizer" doesn't match "token"
    if (i + key.len < in.len) {
        const c = in[i + key.len];
        if (c != '"' and c != '\'' and c != ':' and c != '=' and c != ' ') return false;
    }
    // No preceding-char restriction: prefixed shapes like OKX_SECRET or
    // mysecret=... must still be caught; the separator requirement above
    // already prevents matches inside words like "tokenizer".
    return true;
}

/// True if text still contains something that looks like a leaked secret.
/// Used as a final assertion before text leaves the process boundary.
pub fn looksLeaky(text: []const u8) bool {
    for (SENSITIVE_KEYS) |key| {
        var i: usize = 0;
        while (i + key.len <= text.len) : (i += 1) {
            if (matchesKeyAt(text, i, key)) {
                // key present — value must be the mask
                var j = i + key.len;
                while (j < text.len and (text[j] == '"' or text[j] == '\'' or text[j] == ':' or text[j] == '=' or text[j] == ' ')) j += 1;
                if (j < text.len and !std.mem.startsWith(u8, text[j..], MASK)) return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "redacts json and env shapes" {
    var buf: [512]u8 = undefined;
    const r1 = redact(
        \\{"api_key": "abc123", "note": "hello"}
    , &buf);
    try testing.expect(std.mem.indexOf(u8, r1, "abc123") == null);
    try testing.expect(std.mem.indexOf(u8, r1, "[REDACTED]") != null);
    try testing.expect(std.mem.indexOf(u8, r1, "hello") != null);

    var buf2: [512]u8 = undefined;
    const r2 = redact("OKX_SECRET=supersecret OKX_PASSPHRASE=hunter2 host=okx.com", &buf2);
    try testing.expect(std.mem.indexOf(u8, r2, "supersecret") == null);
    try testing.expect(std.mem.indexOf(u8, r2, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, r2, "host=okx.com") != null);
}

test "does not mangle innocent text" {
    var buf: [256]u8 = undefined;
    const r = redact("the tokenizer splits words; keychain is a mac thing", &buf);
    try testing.expectEqualStrings("the tokenizer splits words; keychain is a mac thing", r);
}

test "looksLeaky detects unmasked secrets" {
    try testing.expect(looksLeaky("api_key=raw_value_here"));
    var buf: [256]u8 = undefined;
    const clean = redact("api_key=raw_value_here", &buf);
    try testing.expect(!looksLeaky(clean));
}
