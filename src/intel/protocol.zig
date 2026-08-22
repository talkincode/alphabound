//! alphabound.intel.v1 — signed external intelligence envelope.
//!
//! AlphaBound does not collect intel. External agents push a signed record;
//! this module is the protocol: schema, HMAC, quality gates, TTL, dedup key,
//! and live grade/score. Payloads are UNTRUSTED DATA — never instructions,
//! never risk-kernel input.
//!
//! Canonical HMAC string (UTF-8):
//!   v1|{id}|{source_id}|{kind}|{instrument}|{headline}|{body}|{conf_3dp}|{as_of_ms}|{expires_ms}|{nonce}
//! signature = lowercase hex(HMAC-SHA256(ALPHABOUND_INTEL_HMAC, canonical))
//! confidence in the canonical is always 3 decimal places (0.620).

const std = @import("std");
const redaction = @import("../observability/redaction.zig");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const schema_id = "alphabound.intel.v1";

pub const max_id = 80;
pub const max_source = 64;
pub const max_instrument = 32;
pub const max_headline = 120;
pub const min_headline = 8;
pub const max_body = 800;
pub const max_claim_text = 160;
pub const max_claims = 6;
pub const min_claims = 1;
pub const max_tags = 8;
pub const max_tag = 24;
pub const max_refs = 3;
pub const max_ref_url = 200;
pub const max_ref_title = 80;
pub const max_nonce = 64;
pub const min_nonce = 16;
pub const max_claims_json = 1600;
pub const max_tags_json = 256;
pub const max_refs_json = 800;
pub const signature_hex_len = HmacSha256.mac_length * 2;
pub const dedup_hex_len = 64;
pub const min_hmac_key = 16;
pub const clock_skew_ms: i64 = 5 * 60 * 1000;
pub const context_limit: usize = 8;
pub const default_source_trust_milles: u16 = 1000;

pub const Kind = enum {
    macro,
    news,
    flow,
    regulatory,
    narrative,
    onchain,

    pub fn fromString(s: []const u8) ?Kind {
        if (std.mem.eql(u8, s, "macro")) return .macro;
        if (std.mem.eql(u8, s, "news")) return .news;
        if (std.mem.eql(u8, s, "flow")) return .flow;
        if (std.mem.eql(u8, s, "regulatory")) return .regulatory;
        if (std.mem.eql(u8, s, "narrative")) return .narrative;
        if (std.mem.eql(u8, s, "onchain")) return .onchain;
        return null;
    }

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .macro => "macro",
            .news => "news",
            .flow => "flow",
            .regulatory => "regulatory",
            .narrative => "narrative",
            .onchain => "onchain",
        };
    }

    pub fn defaultTtlMs(self: Kind) i64 {
        return switch (self) {
            .news => 12 * hour_ms,
            .flow => 48 * hour_ms,
            .narrative => 48 * hour_ms,
            .onchain => 24 * hour_ms,
            .macro => 7 * day_ms,
            .regulatory => 7 * day_ms,
        };
    }

    pub fn maxTtlMs(self: Kind) i64 {
        return switch (self) {
            .news => 24 * hour_ms,
            .flow => 72 * hour_ms,
            .narrative => 72 * hour_ms,
            .onchain => 72 * hour_ms,
            .macro => 14 * day_ms,
            .regulatory => 30 * day_ms,
        };
    }
};

const hour_ms: i64 = 3_600_000;
const day_ms: i64 = 86_400_000;

pub const Grade = enum {
    A,
    B,
    C,
    D,

    pub fn text(self: Grade) []const u8 {
        return switch (self) {
            .A => "A",
            .B => "B",
            .C => "C",
            .D => "D",
        };
    }

    pub fn fromScoreMilles(score: i64) Grade {
        if (score >= 700) return .A;
        if (score >= 450) return .B;
        if (score >= 200) return .C;
        return .D;
    }

    pub fn contextEligible(self: Grade) bool {
        return self != .D;
    }
};

pub const Polarity = enum {
    bull,
    bear,
    neutral,

    pub fn fromString(s: []const u8) ?Polarity {
        if (std.mem.eql(u8, s, "bull")) return .bull;
        if (std.mem.eql(u8, s, "bear")) return .bear;
        if (std.mem.eql(u8, s, "neutral")) return .neutral;
        return null;
    }

    pub fn text(self: Polarity) []const u8 {
        return switch (self) {
            .bull => "bull",
            .bear => "bear",
            .neutral => "neutral",
        };
    }
};

pub const Error = error{
    MalformedJson,
    BadSchema,
    BadId,
    BadSource,
    BadKind,
    BadInstrument,
    HeadlineTooShort,
    HeadlineTooLong,
    BodyEmpty,
    BodyTooLong,
    BadClaims,
    BadTags,
    BadRefs,
    BadConfidence,
    BadTime,
    TtlTooLong,
    BadNonce,
    BadSignature,
    NoKey,
    ControlChars,
    Leaky,
    ForbiddenHtml,
    BufferTooSmall,
    OutOfMemory,
};

pub const Item = struct {
    id_buf: [max_id]u8 = undefined,
    id_len: usize = 0,
    source_buf: [max_source]u8 = undefined,
    source_len: usize = 0,
    kind: Kind = .news,
    instrument_buf: [max_instrument]u8 = undefined,
    instrument_len: usize = 0,
    headline_buf: [max_headline]u8 = undefined,
    headline_len: usize = 0,
    body_buf: [max_body]u8 = undefined,
    body_len: usize = 0,
    claims_json_buf: [max_claims_json]u8 = undefined,
    claims_json_len: usize = 0,
    tags_json_buf: [max_tags_json]u8 = undefined,
    tags_json_len: usize = 0,
    refs_json_buf: [max_refs_json]u8 = undefined,
    refs_json_len: usize = 0,
    nonce_buf: [max_nonce]u8 = undefined,
    nonce_len: usize = 0,
    signature_buf: [signature_hex_len]u8 = undefined,
    dedup_buf: [dedup_hex_len]u8 = undefined,
    conf_milles: u16 = 0,
    as_of_ms: i64 = 0,
    expires_ms: i64 = 0,

    pub fn id(self: *const Item) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    pub fn sourceId(self: *const Item) []const u8 {
        return self.source_buf[0..self.source_len];
    }
    pub fn instrument(self: *const Item) []const u8 {
        return self.instrument_buf[0..self.instrument_len];
    }
    pub fn headline(self: *const Item) []const u8 {
        return self.headline_buf[0..self.headline_len];
    }
    pub fn body(self: *const Item) []const u8 {
        return self.body_buf[0..self.body_len];
    }
    pub fn claimsJson(self: *const Item) []const u8 {
        return self.claims_json_buf[0..self.claims_json_len];
    }
    pub fn tagsJson(self: *const Item) []const u8 {
        return self.tags_json_buf[0..self.tags_json_len];
    }
    pub fn refsJson(self: *const Item) []const u8 {
        return self.refs_json_buf[0..self.refs_json_len];
    }
    pub fn nonce(self: *const Item) []const u8 {
        return self.nonce_buf[0..self.nonce_len];
    }
    pub fn signature(self: *const Item) []const u8 {
        return self.signature_buf[0..signature_hex_len];
    }
    pub fn dedupKey(self: *const Item) []const u8 {
        return self.dedup_buf[0..dedup_hex_len];
    }
};

pub fn formatConf3(milles: u16) [5]u8 {
    var out: [5]u8 = undefined;
    out[0] = '0' + @as(u8, @intCast(milles / 1000));
    out[1] = '.';
    const frac = milles % 1000;
    out[2] = '0' + @as(u8, @intCast(frac / 100));
    out[3] = '0' + @as(u8, @intCast((frac / 10) % 10));
    out[4] = '0' + @as(u8, @intCast(frac % 10));
    return out;
}

pub fn freshnessMilles(now_ms: i64, as_of_ms: i64, expires_ms: i64) u16 {
    if (expires_ms <= as_of_ms) return 0;
    if (now_ms >= expires_ms) return 0;
    if (now_ms <= as_of_ms) return 1000;
    const span = expires_ms - as_of_ms;
    const left = expires_ms - now_ms;
    const scaled = @divTrunc(left * 1000, span);
    if (scaled <= 0) return 0;
    if (scaled >= 1000) return 1000;
    return @intCast(scaled);
}

pub fn scoreMilles(trust_milles: u16, conf_milles: u16, fresh_milles: u16) i64 {
    const t: i64 = trust_milles;
    const c: i64 = conf_milles;
    const f: i64 = fresh_milles;
    return @divTrunc(t * c * f, 1_000_000);
}

pub fn expired(now_ms: i64, expires_ms: i64) bool {
    return now_ms >= expires_ms;
}

pub fn parse(gpa: std.mem.Allocator, hmac_key: []const u8, now_ms: i64, raw: []const u8, out: *Item) Error!void {
    if (hmac_key.len < min_hmac_key) return error.NoKey;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{
        .max_value_len = 8 * 1024,
    }) catch return error.MalformedJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedJson;
    const obj = parsed.value.object;

    const schema = getString(obj, "schema") catch return error.BadSchema;
    if (!std.mem.eql(u8, schema, schema_id)) return error.BadSchema;

    const id_s = try getString(obj, "id");
    if (!validId(id_s)) return error.BadId;
    const source_s = try getString(obj, "source_id");
    if (!validSource(source_s)) return error.BadSource;
    const kind_s = try getString(obj, "kind");
    const kind = Kind.fromString(kind_s) orelse return error.BadKind;
    const inst_s = try getString(obj, "instrument");
    if (!validInstrument(inst_s)) return error.BadInstrument;

    const headline_s = try getString(obj, "headline");
    try checkText(headline_s);
    if (headline_s.len < min_headline) return error.HeadlineTooShort;
    if (headline_s.len > max_headline) return error.HeadlineTooLong;

    const body_s = try getString(obj, "body");
    try checkText(body_s);
    if (body_s.len == 0) return error.BodyEmpty;
    if (body_s.len > max_body) return error.BodyTooLong;

    const conf = try getConfMilles(obj, "confidence");
    const as_of = try getI64(obj, "as_of_ms");
    if (as_of <= 0) return error.BadTime;
    if (as_of > now_ms + clock_skew_ms) return error.BadTime;

    var expires: i64 = 0;
    if (obj.get("expires_ms")) |_| {
        expires = try getI64(obj, "expires_ms");
    } else {
        expires = as_of + kind.defaultTtlMs();
    }
    if (expires <= as_of) return error.BadTime;
    if (expires - as_of > kind.maxTtlMs()) return error.TtlTooLong;

    const nonce_s = try getString(obj, "nonce");
    if (!validNonce(nonce_s)) return error.BadNonce;
    const sig_s = try getString(obj, "signature");
    if (sig_s.len != signature_hex_len or !isHex(sig_s)) return error.BadSignature;

    var item = Item{
        .kind = kind,
        .conf_milles = conf,
        .as_of_ms = as_of,
        .expires_ms = expires,
    };
    copyBuf(&item.id_buf, &item.id_len, id_s);
    copyBuf(&item.source_buf, &item.source_len, source_s);
    copyBuf(&item.instrument_buf, &item.instrument_len, inst_s);
    copyBuf(&item.headline_buf, &item.headline_len, headline_s);
    copyBuf(&item.body_buf, &item.body_len, body_s);
    copyBuf(&item.nonce_buf, &item.nonce_len, nonce_s);
    @memcpy(item.signature_buf[0..signature_hex_len], sig_s);

    try writeClaimsJson(&item, obj);
    try writeTagsJson(&item, obj);
    try writeRefsJson(&item, obj);

    var leak_scan: [2048]u8 = undefined;
    const scanned = joinLeakScan(&leak_scan, item.headline(), item.body(), item.claimsJson());
    if (redaction.looksLeaky(scanned)) return error.Leaky;

    computeDedup(&item);

    var canon_buf: [2048]u8 = undefined;
    const canonical = try writeCanonical(&canon_buf, &item);
    if (!verifyHmac(hmac_key, canonical, item.signature())) return error.BadSignature;

    out.* = item;
}

pub fn signItem(hmac_key: []const u8, item: *Item) Error!void {
    if (hmac_key.len < min_hmac_key) return error.NoKey;
    var canon_buf: [2048]u8 = undefined;
    const canonical = try writeCanonical(&canon_buf, item);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    var ctx = HmacSha256.init(hmac_key);
    ctx.update(canonical);
    ctx.final(&mac);
    hexEncode(&item.signature_buf, &mac);
}

pub fn writeCanonical(buf: []u8, item: *const Item) Error![]const u8 {
    const conf = formatConf3(item.conf_milles);
    var w: std.Io.Writer = .fixed(buf);
    w.print(
        "v1|{s}|{s}|{s}|{s}|{s}|{s}|{s}|{d}|{d}|{s}",
        .{
            item.id(),
            item.sourceId(),
            item.kind.text(),
            item.instrument(),
            item.headline(),
            item.body(),
            conf[0..],
            item.as_of_ms,
            item.expires_ms,
            item.nonce(),
        },
    ) catch return error.BufferTooSmall;
    return w.buffered();
}

pub fn verifyHmac(hmac_key: []const u8, canonical: []const u8, sig_hex: []const u8) bool {
    if (hmac_key.len < min_hmac_key) return false;
    if (sig_hex.len != signature_hex_len) return false;
    var expected: [HmacSha256.mac_length]u8 = undefined;
    var ctx = HmacSha256.init(hmac_key);
    ctx.update(canonical);
    ctx.final(&expected);
    var presented: [HmacSha256.mac_length]u8 = undefined;
    if (!hexDecode(&presented, sig_hex)) return false;
    return constantTimeEql(&expected, &presented);
}

pub fn errorReason(err: Error) []const u8 {
    return switch (err) {
        error.MalformedJson => "malformed_json",
        error.BadSchema => "bad_schema",
        error.BadId => "bad_id",
        error.BadSource => "bad_source",
        error.BadKind => "bad_kind",
        error.BadInstrument => "bad_instrument",
        error.HeadlineTooShort => "headline_too_short",
        error.HeadlineTooLong => "headline_too_long",
        error.BodyEmpty => "body_empty",
        error.BodyTooLong => "body_too_long",
        error.BadClaims => "bad_claims",
        error.BadTags => "bad_tags",
        error.BadRefs => "bad_refs",
        error.BadConfidence => "bad_confidence",
        error.BadTime => "bad_time",
        error.TtlTooLong => "ttl_too_long",
        error.BadNonce => "bad_nonce",
        error.BadSignature => "bad_signature",
        error.NoKey => "signing_unconfigured",
        error.ControlChars => "control_chars",
        error.Leaky => "leaky_payload",
        error.ForbiddenHtml => "forbidden_html",
        error.BufferTooSmall => "buffer",
        error.OutOfMemory => "oom",
    };
}

pub fn writeContextObject(w: *std.Io.Writer, item: *const Item, score: i64, grade: Grade) !void {
    const conf = formatConf3(item.conf_milles);
    try w.writeAll("{\"id\":\"");
    try writeJsonString(w, item.id());
    try w.writeAll("\",\"source_id\":\"");
    try writeJsonString(w, item.sourceId());
    try w.print("\",\"kind\":\"{s}\",\"instrument\":\"", .{item.kind.text()});
    try writeJsonString(w, item.instrument());
    try w.writeAll("\",\"headline\":\"");
    try writeJsonString(w, item.headline());
    try w.writeAll("\",\"body\":\"");
    try writeJsonString(w, item.body());
    try w.writeAll("\",\"claims\":");
    try w.writeAll(item.claimsJson());
    try w.writeAll(",\"tags\":");
    try w.writeAll(item.tagsJson());
    try w.print(
        ",\"confidence\":\"{s}\",\"grade\":\"{s}\",\"score\":\"{d}.{d:0>3}\",\"as_of_ms\":{d},\"expires_ms\":{d},\"untrusted\":true}}",
        .{
            conf[0..],
            grade.text(),
            @divTrunc(score, 1000),
            @mod(score, 1000),
            item.as_of_ms,
            item.expires_ms,
        },
    );
}

pub fn writeApiObject(w: *std.Io.Writer, item: *const Item, now_ms: i64, accepted_ms: i64) !void {
    const fresh = freshnessMilles(now_ms, item.as_of_ms, item.expires_ms);
    const score = scoreMilles(default_source_trust_milles, item.conf_milles, fresh);
    const grade = Grade.fromScoreMilles(score);
    const conf = formatConf3(item.conf_milles);
    const is_expired = expired(now_ms, item.expires_ms);
    try w.writeAll("{\"id\":\"");
    try writeJsonString(w, item.id());
    try w.writeAll("\",\"source_id\":\"");
    try writeJsonString(w, item.sourceId());
    try w.print("\",\"kind\":\"{s}\",\"instrument\":\"", .{item.kind.text()});
    try writeJsonString(w, item.instrument());
    try w.writeAll("\",\"headline\":\"");
    try writeJsonString(w, item.headline());
    try w.writeAll("\",\"body\":\"");
    try writeJsonString(w, item.body());
    try w.writeAll("\",\"claims\":");
    try w.writeAll(item.claimsJson());
    try w.writeAll(",\"tags\":");
    try w.writeAll(item.tagsJson());
    try w.writeAll(",\"refs\":");
    try w.writeAll(item.refsJson());
    try w.print(
        ",\"confidence\":\"{s}\",\"grade\":\"{s}\",\"score\":\"{d}.{d:0>3}\",\"as_of_ms\":{d},\"expires_ms\":{d},\"accepted_ms\":{d},\"expired\":{},\"untrusted\":true}}",
        .{
            conf[0..],
            grade.text(),
            @divTrunc(score, 1000),
            @mod(score, 1000),
            item.as_of_ms,
            item.expires_ms,
            accepted_ms,
            is_expired,
        },
    );
}

pub const Ranked = struct {
    item: *const Item,
    score: i64,
    grade: Grade,
};

pub fn rank(items: []const Item, now_ms: i64, trust_milles: u16, out: []Ranked) []Ranked {
    var n: usize = 0;
    for (items) |*it| {
        if (expired(now_ms, it.expires_ms)) continue;
        const fresh = freshnessMilles(now_ms, it.as_of_ms, it.expires_ms);
        const score = scoreMilles(trust_milles, it.conf_milles, fresh);
        const grade = Grade.fromScoreMilles(score);
        if (!grade.contextEligible()) continue;
        if (n >= out.len) break;
        out[n] = .{ .item = it, .score = score, .grade = grade };
        n += 1;
    }
    const slice = out[0..n];
    std.mem.sort(Ranked, slice, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.item.id(), b.item.id());
        }
    }.lessThan);
    const cap = @min(slice.len, context_limit);
    return slice[0..cap];
}

pub fn computeDedup(item: *Item) void {
    var norm: [max_headline]u8 = undefined;
    const nlen = normalizeHeadline(item.headline(), &norm);
    const day = @divTrunc(item.as_of_ms, day_ms);
    var pre: [256]u8 = undefined;
    const material = std.fmt.bufPrint(&pre, "{s}|{s}|{s}|{d}", .{
        item.kind.text(),
        item.instrument(),
        norm[0..nlen],
        day,
    }) catch item.headline();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(material, &digest, .{});
    hexEncode(&item.dedup_buf, &digest);
}

fn normalizeHeadline(in: []const u8, out: []u8) usize {
    var w: usize = 0;
    var prev_space = false;
    for (in) |c| {
        if (c < 0x80) {
            const lower = std.ascii.toLower(c);
            const keep = std.ascii.isAlphanumeric(lower);
            if (keep) {
                if (w < out.len) {
                    out[w] = lower;
                    w += 1;
                }
                prev_space = false;
            } else if (std.ascii.isWhitespace(c)) {
                if (!prev_space and w > 0 and w < out.len) {
                    out[w] = ' ';
                    w += 1;
                    prev_space = true;
                }
            }
        } else {
            if (w < out.len) {
                out[w] = c;
                w += 1;
            }
            prev_space = false;
        }
    }
    if (w > 0 and out[w - 1] == ' ') w -= 1;
    return w;
}

fn writeClaimsJson(item: *Item, obj: std.json.ObjectMap) Error!void {
    const v = obj.get("claims") orelse return error.BadClaims;
    if (v != .array) return error.BadClaims;
    const arr = v.array;
    if (arr.items.len < min_claims or arr.items.len > max_claims) return error.BadClaims;
    var w: std.Io.Writer = .fixed(item.claims_json_buf[0..]);
    w.writeByte('[') catch return error.BadClaims;
    for (arr.items, 0..) |item_v, i| {
        if (item_v != .object) return error.BadClaims;
        const cobj = item_v.object;
        const text = getString(cobj, "text") catch return error.BadClaims;
        try checkText(text);
        if (text.len == 0 or text.len > max_claim_text) return error.BadClaims;
        const pol_s = getString(cobj, "polarity") catch return error.BadClaims;
        const pol = Polarity.fromString(pol_s) orelse return error.BadClaims;
        if (i > 0) w.writeByte(',') catch return error.BadClaims;
        w.writeAll("{\"text\":\"") catch return error.BadClaims;
        writeJsonString(&w, text) catch return error.BadClaims;
        w.print("\",\"polarity\":\"{s}\"}}", .{pol.text()}) catch return error.BadClaims;
    }
    w.writeByte(']') catch return error.BadClaims;
    item.claims_json_len = w.buffered().len;
}

fn writeTagsJson(item: *Item, obj: std.json.ObjectMap) Error!void {
    if (obj.get("tags") == null) {
        @memcpy(item.tags_json_buf[0..2], "[]");
        item.tags_json_len = 2;
        return;
    }
    const v = obj.get("tags").?;
    if (v != .array) return error.BadTags;
    const arr = v.array;
    if (arr.items.len > max_tags) return error.BadTags;
    var w: std.Io.Writer = .fixed(item.tags_json_buf[0..]);
    w.writeByte('[') catch return error.BadTags;
    for (arr.items, 0..) |tv, i| {
        if (tv != .string) return error.BadTags;
        if (!validTag(tv.string)) return error.BadTags;
        if (i > 0) w.writeByte(',') catch return error.BadTags;
        w.writeByte('"') catch return error.BadTags;
        writeJsonString(&w, tv.string) catch return error.BadTags;
        w.writeByte('"') catch return error.BadTags;
    }
    w.writeByte(']') catch return error.BadTags;
    item.tags_json_len = w.buffered().len;
}

fn writeRefsJson(item: *Item, obj: std.json.ObjectMap) Error!void {
    if (obj.get("refs") == null) {
        @memcpy(item.refs_json_buf[0..2], "[]");
        item.refs_json_len = 2;
        return;
    }
    const v = obj.get("refs").?;
    if (v != .array) return error.BadRefs;
    const arr = v.array;
    if (arr.items.len > max_refs) return error.BadRefs;
    var w: std.Io.Writer = .fixed(item.refs_json_buf[0..]);
    w.writeByte('[') catch return error.BadRefs;
    for (arr.items, 0..) |rv, i| {
        if (rv != .object) return error.BadRefs;
        const robj = rv.object;
        const url = getString(robj, "url") catch return error.BadRefs;
        if (!validRefUrl(url)) return error.BadRefs;
        const title = getString(robj, "title") catch "";
        if (title.len > max_ref_title) return error.BadRefs;
        try checkText(title);
        if (i > 0) w.writeByte(',') catch return error.BadRefs;
        w.writeAll("{\"url\":\"") catch return error.BadRefs;
        writeJsonString(&w, url) catch return error.BadRefs;
        w.writeAll("\",\"title\":\"") catch return error.BadRefs;
        writeJsonString(&w, title) catch return error.BadRefs;
        w.writeAll("\"}") catch return error.BadRefs;
    }
    w.writeByte(']') catch return error.BadRefs;
    item.refs_json_len = w.buffered().len;
}

fn checkText(s: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(s)) return error.ControlChars;
    for (s) |c| {
        if (c < 0x20) return error.ControlChars;
        if (c == '<' or c == '>') return error.ForbiddenHtml;
    }
    if (std.ascii.indexOfIgnoreCase(s, "javascript:") != null) return error.ForbiddenHtml;
}

fn validId(s: []const u8) bool {
    if (s.len < 8 or s.len > max_id) return false;
    if (!std.mem.startsWith(u8, s, "intel_")) return false;
    const rest = s["intel_".len..];
    if (rest.len < 2) return false;
    for (rest) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validSource(s: []const u8) bool {
    if (s.len < 3 or s.len > max_source) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validInstrument(s: []const u8) bool {
    if (s.len == 0 or s.len > max_instrument) return false;
    if (std.mem.eql(u8, s, "*")) return true;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn validTag(s: []const u8) bool {
    if (s.len == 0 or s.len > max_tag) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn validNonce(s: []const u8) bool {
    return s.len >= min_nonce and s.len <= max_nonce and isHex(s);
}

fn validRefUrl(s: []const u8) bool {
    if (s.len < 12 or s.len > max_ref_url) return false;
    if (!std.mem.startsWith(u8, s, "https://")) return false;
    for (s) |c| {
        if (c < 0x21 or c > 0x7e) return false;
        if (c == '<' or c == '>' or c == '"') return false;
    }
    return true;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const v = obj.get(key) orelse return error.MalformedJson;
    if (v != .string) return error.MalformedJson;
    return v.string;
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) Error!i64 {
    const v = obj.get(key) orelse return error.BadTime;
    return switch (v) {
        .integer => |i| i,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return error.BadTime;
            break :blk @intFromFloat(@round(f));
        },
        else => error.BadTime,
    };
}

fn getConfMilles(obj: std.json.ObjectMap, key: []const u8) Error!u16 {
    const v = obj.get(key) orelse return error.BadConfidence;
    const milles: i64 = switch (v) {
        .integer => |i| i * 1000,
        .float => |f| blk: {
            if (!std.math.isFinite(f)) return error.BadConfidence;
            break :blk @intFromFloat(@round(f * 1000.0));
        },
        .number_string => |s| blk: {
            const parsed = std.fmt.parseFloat(f64, s) catch return error.BadConfidence;
            if (!std.math.isFinite(parsed)) return error.BadConfidence;
            break :blk @intFromFloat(@round(parsed * 1000.0));
        },
        else => return error.BadConfidence,
    };
    if (milles < 0 or milles > 1000) return error.BadConfidence;
    return @intCast(milles);
}

fn copyBuf(dest: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    len.* = n;
}

fn joinLeakScan(buf: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}\n{s}\n{s}", .{ a, b, c }) catch return a;
    return w.buffered();
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

fn hexEncode(out: []u8, bytes: []const u8) void {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        out[i * 2] = hex[bytes[i] >> 4];
        out[i * 2 + 1] = hex[bytes[i] & 0x0f];
    }
}

fn hexDecode(out: []u8, hex_s: []const u8) bool {
    if (hex_s.len != out.len * 2) return false;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = hexVal(hex_s[i * 2]) orelse return false;
        const lo = hexVal(hex_s[i * 2 + 1]) orelse return false;
        out[i] = (hi << 4) | lo;
    }
    return true;
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    return null;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
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

const testing = std.testing;

pub const test_hmac_key = "test-intel-hmac-key-32bytes!!!!";

fn sampleItem(as_of: i64) Item {
    var item = Item{
        .kind = .macro,
        .conf_milles = 620,
        .as_of_ms = as_of,
        .expires_ms = as_of + 7 * day_ms,
    };
    const id = "intel_etf_flow_01";
    const src = "collector.macro";
    const inst = "BTC-USDT";
    const hl = "US spot BTC ETF saw net inflows";
    const body = "Issuers reported a second consecutive session of net creations. Treat as untrusted flow colour, not a trade signal.";
    const nonce = "0123456789abcdef0123456789abcdef";
    copyBuf(&item.id_buf, &item.id_len, id);
    copyBuf(&item.source_buf, &item.source_len, src);
    copyBuf(&item.instrument_buf, &item.instrument_len, inst);
    copyBuf(&item.headline_buf, &item.headline_len, hl);
    copyBuf(&item.body_buf, &item.body_len, body);
    copyBuf(&item.nonce_buf, &item.nonce_len, nonce);
    const claims = "[{\"text\":\"ETF creations continued\",\"polarity\":\"bull\"}]";
    copyBuf(&item.claims_json_buf, &item.claims_json_len, claims);
    const tags = "[\"etf\",\"flows\"]";
    copyBuf(&item.tags_json_buf, &item.tags_json_len, tags);
    copyBuf(&item.refs_json_buf, &item.refs_json_len, "[]");
    computeDedup(&item);
    return item;
}

fn envelopeJson(gpa: std.mem.Allocator, item: *Item) ![]u8 {
    try signItem(test_hmac_key, item);
    return std.fmt.allocPrint(
        gpa,
        "{{\"schema\":\"{s}\",\"id\":\"{s}\",\"source_id\":\"{s}\",\"kind\":\"{s}\",\"instrument\":\"{s}\",\"headline\":\"{s}\",\"body\":\"{s}\",\"claims\":{s},\"tags\":{s},\"confidence\":0.620,\"as_of_ms\":{d},\"expires_ms\":{d},\"nonce\":\"{s}\",\"signature\":\"{s}\"}}",
        .{
            schema_id,
            item.id(),
            item.sourceId(),
            item.kind.text(),
            item.instrument(),
            item.headline(),
            item.body(),
            item.claimsJson(),
            item.tagsJson(),
            item.as_of_ms,
            item.expires_ms,
            item.nonce(),
            item.signature(),
        },
    );
}

test "sign and parse round-trip" {
    const now: i64 = 1_700_000_000_000;
    var item = sampleItem(now - 60_000);
    const raw = try envelopeJson(testing.allocator, &item);
    defer testing.allocator.free(raw);
    var parsed = Item{};
    try parse(testing.allocator, test_hmac_key, now, raw, &parsed);
    try testing.expectEqualStrings(item.id(), parsed.id());
    try testing.expectEqual(item.conf_milles, parsed.conf_milles);
    try testing.expectEqualStrings(item.dedupKey(), parsed.dedupKey());
}

test "hmac tamper is rejected" {
    const now: i64 = 1_700_000_000_000;
    var item = sampleItem(now - 60_000);
    const raw = try envelopeJson(testing.allocator, &item);
    defer testing.allocator.free(raw);
    var buf = try testing.allocator.dupe(u8, raw);
    defer testing.allocator.free(buf);
    if (std.mem.indexOf(u8, buf, "second consecutive")) |i| buf[i] = 'S';
    var parsed = Item{};
    try testing.expectError(error.BadSignature, parse(testing.allocator, test_hmac_key, now, buf, &parsed));
}

test "quality gates reject missing key and bad json" {
    const now: i64 = 1_700_000_000_000;
    var parsed = Item{};
    try testing.expectError(error.NoKey, parse(testing.allocator, "short", now, "{}", &parsed));
    try testing.expectError(error.MalformedJson, parse(testing.allocator, test_hmac_key, now, "not-json", &parsed));
    try testing.expectError(error.BadSchema, parse(testing.allocator, test_hmac_key, now, "{\"schema\":\"nope\"}", &parsed));
}

test "ttl cap and future as_of rejected" {
    const now: i64 = 1_700_000_000_000;
    var item = sampleItem(now - 60_000);
    item.kind = .news;
    item.expires_ms = item.as_of_ms + 10 * day_ms;
    const raw = try envelopeJson(testing.allocator, &item);
    defer testing.allocator.free(raw);
    var parsed = Item{};
    try testing.expectError(error.TtlTooLong, parse(testing.allocator, test_hmac_key, now, raw, &parsed));

    var future = sampleItem(now + hour_ms);
    const raw2 = try envelopeJson(testing.allocator, &future);
    defer testing.allocator.free(raw2);
    try testing.expectError(error.BadTime, parse(testing.allocator, test_hmac_key, now, raw2, &parsed));
}

test "dedup key is stable for same headline/kind/day" {
    const now: i64 = 1_700_000_000_000;
    var a = sampleItem(now);
    var b = sampleItem(now + 3_600_000);
    computeDedup(&a);
    computeDedup(&b);
    try testing.expectEqualStrings(a.dedupKey(), b.dedupKey());
    b.kind = .news;
    computeDedup(&b);
    try testing.expect(!std.mem.eql(u8, a.dedupKey(), b.dedupKey()));
}

test "freshness score grade ranking excludes D and expired" {
    const now: i64 = 1_000_000;
    var strong = sampleItem(now);
    strong.conf_milles = 900;
    strong.expires_ms = now + day_ms;
    var weak = sampleItem(now);
    weak.id_buf[weak.id_len - 1] = '2';
    weak.conf_milles = 100;
    weak.expires_ms = now + day_ms;
    var old = sampleItem(now - day_ms);
    old.id_buf[old.id_len - 1] = '3';
    old.expires_ms = now - 1;
    const items = [_]Item{ weak, strong, old };
    var ranked_buf: [8]Ranked = undefined;
    const ranked = rank(&items, now, 1000, &ranked_buf);
    try testing.expectEqual(@as(usize, 1), ranked.len);
    try testing.expectEqual(Grade.A, ranked[0].grade);
    try testing.expectEqualStrings(strong.id(), ranked[0].item.id());
}

test "canonical confidence is always 3 decimal places" {
    try testing.expectEqualStrings("0.620", formatConf3(620)[0..]);
    try testing.expectEqualStrings("1.000", formatConf3(1000)[0..]);
    try testing.expectEqualStrings("0.000", formatConf3(0)[0..]);
}

test "html and control chars are rejected in checkText" {
    try testing.expectError(error.ForbiddenHtml, checkText("<script>"));
    try testing.expectError(error.ControlChars, checkText("bad\nline"));
    try checkText("ETF inflows continued");
}
