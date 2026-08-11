//! Tool Registry — the "wide information intake" boundary (§4.4, FR-08).
//!
//! Tools only extend *observation*; they never prescribe usage order and the
//! agent may ignore any of them. Every call and result must reach the event
//! log so we can later measure which data actually improved decisions.
//!
//! Prompt-injection boundary: tool payloads (news bodies, wallet labels, web
//! text, third-party descriptions) are UNTRUSTED DATA. They live in
//! `ToolResult.data` and are never concatenated into system instructions.
//! Adapters must not expose secrets, filesystem, or arbitrary network access.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

/// Tool domains from the design table (§4.4).
pub const Domain = enum {
    market,
    derivatives,
    onchain,
    wallet,
    macro,
    news,

    pub fn prefix(self: Domain) []const u8 {
        return switch (self) {
            .market => "market.",
            .derivatives => "derivatives.",
            .onchain => "onchain.",
            .wallet => "wallet.",
            .macro => "macro.",
            .news => "news.",
        };
    }
};

pub const ResultStatus = enum {
    ok,
    unavailable,
    stale,
    err,

    pub fn text(self: ResultStatus) []const u8 {
        return switch (self) {
            .ok => "OK",
            .unavailable => "UNAVAILABLE",
            .stale => "STALE",
            .err => "ERROR",
        };
    }
};

/// Static description of a registered tool. Registration is code-level and
/// versioned with the binary — the agent cannot add or mutate tools.
pub const ToolSpec = struct {
    /// Fully-qualified name, must start with its domain prefix, e.g. "market.candles".
    name: []const u8,
    domain: Domain,
    source: []const u8,
    /// Result older than this is downgraded to STALE at admission time.
    max_age_ms: i64,
    /// Expected per-call cost (USD, decimal string), for budget accounting.
    cost_usd: Decimal = Decimal.zero,
    /// 0..1 prior trust in the source; agent sees it, kernel ignores it.
    trust: Decimal = Decimal.one,
    /// Human-readable JSON schema digest of `data` for the agent prompt.
    schema_note: []const u8 = "",
};

/// Unified return object (§4.4). `data` is untrusted third-party content.
pub const ToolResult = struct {
    status: ResultStatus,
    source: []const u8,
    /// Milliseconds since epoch when the underlying data was produced.
    as_of_ms: i64,
    confidence: ?Decimal = null,
    latency_ms: u32 = 0,
    cost_usd: Decimal = Decimal.zero,
    /// Raw JSON payload — UNTRUSTED. Never merge into instructions.
    data_json: []const u8 = "null",
    /// Optional reference to raw archived response (row id / blob ref).
    raw_ref: ?[]const u8 = null,
};

pub const RegistryError = error{
    DuplicateTool,
    BadToolName,
    RegistryFull,
};

pub const MAX_TOOLS = 64;

/// Fixed-capacity registry: no allocation, immutable after wiring.
pub const Registry = struct {
    specs: [MAX_TOOLS]ToolSpec = undefined,
    len: usize = 0,

    pub fn register(self: *Registry, spec: ToolSpec) RegistryError!void {
        if (self.len >= MAX_TOOLS) return error.RegistryFull;
        if (!std.mem.startsWith(u8, spec.name, spec.domain.prefix())) {
            return error.BadToolName;
        }
        if (spec.name.len <= spec.domain.prefix().len) return error.BadToolName;
        if (self.find(spec.name) != null) return error.DuplicateTool;
        self.specs[self.len] = spec;
        self.len += 1;
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const ToolSpec {
        for (self.specs[0..self.len]) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn all(self: *const Registry) []const ToolSpec {
        return self.specs[0..self.len];
    }
};

/// Admission-time staleness check: a result that arrived OK but whose data is
/// older than the tool's freshness contract is downgraded to STALE. The risk
/// kernel treats STALE evidence as missing (fail-closed), never as zero.
pub fn effectiveStatus(spec: *const ToolSpec, result: ToolResult, now_ms: i64) ResultStatus {
    if (result.status != .ok) return result.status;
    if (result.as_of_ms <= 0) return .stale; // unknown provenance = stale
    const age = now_ms - result.as_of_ms;
    if (age > spec.max_age_ms) return .stale;
    return .ok;
}

/// Audit record for the tool_calls table + event log (design §6.2).
pub const AuditRecord = struct {
    tool: []const u8,
    source: []const u8,
    status: []const u8,
    as_of_ms: i64,
    latency_ms: u32,
    cost_usd: Decimal,
    /// SHA-256 of data_json — proves what the agent saw without trusting it.
    result_digest: [64]u8,
};

pub fn auditRecord(spec: *const ToolSpec, result: ToolResult, now_ms: i64) AuditRecord {
    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.data_json, &digest_bytes, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest_bytes}) catch unreachable;
    return .{
        .tool = spec.name,
        .source = result.source,
        .status = effectiveStatus(spec, result, now_ms).text(),
        .as_of_ms = result.as_of_ms,
        .latency_ms = result.latency_ms,
        .cost_usd = result.cost_usd,
        .result_digest = hex,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn testSpec() ToolSpec {
    return .{
        .name = "market.candles",
        .domain = .market,
        .source = "okx",
        .max_age_ms = 60_000,
    };
}

test "register enforces domain prefix and uniqueness" {
    var reg = Registry{};
    try reg.register(testSpec());
    try testing.expectError(error.DuplicateTool, reg.register(testSpec()));
    try testing.expectError(error.BadToolName, reg.register(.{
        .name = "candles", // missing domain prefix
        .domain = .market,
        .source = "okx",
        .max_age_ms = 1000,
    }));
    try testing.expectError(error.BadToolName, reg.register(.{
        .name = "news.", // empty suffix
        .domain = .news,
        .source = "x",
        .max_age_ms = 1000,
    }));
    // wrong domain for the given prefix
    try testing.expectError(error.BadToolName, reg.register(.{
        .name = "market.funding",
        .domain = .derivatives,
        .source = "okx",
        .max_age_ms = 1000,
    }));
    try testing.expect(reg.find("market.candles") != null);
    try testing.expect(reg.find("market.nope") == null);
    try testing.expectEqual(@as(usize, 1), reg.all().len);
}

test "effectiveStatus downgrades old data to STALE, passes errors through" {
    const spec = testSpec();
    const now: i64 = 1_000_000;

    // Fresh OK stays OK.
    try testing.expectEqual(ResultStatus.ok, effectiveStatus(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = now - 1_000,
    }, now));

    // Beyond freshness contract -> STALE.
    try testing.expectEqual(ResultStatus.stale, effectiveStatus(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = now - 61_000,
    }, now));

    // Unknown provenance -> STALE (never trusted as fresh).
    try testing.expectEqual(ResultStatus.stale, effectiveStatus(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = 0,
    }, now));

    // Failure statuses pass through unchanged.
    try testing.expectEqual(ResultStatus.unavailable, effectiveStatus(&spec, .{
        .status = .unavailable,
        .source = "okx",
        .as_of_ms = now,
    }, now));
    try testing.expectEqual(ResultStatus.err, effectiveStatus(&spec, .{
        .status = .err,
        .source = "okx",
        .as_of_ms = now,
    }, now));
}

test "auditRecord digests untrusted payload and reports effective status" {
    const spec = testSpec();
    const now: i64 = 1_000_000;
    const rec = auditRecord(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = now - 500,
        .latency_ms = 42,
        .data_json = "{\"c\":[1,2,3]}",
    }, now);
    try testing.expectEqualStrings("market.candles", rec.tool);
    try testing.expectEqualStrings("OK", rec.status);
    try testing.expectEqual(@as(u32, 42), rec.latency_ms);
    // Digest is deterministic for identical payloads.
    const rec2 = auditRecord(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = now - 500,
        .latency_ms = 999,
        .data_json = "{\"c\":[1,2,3]}",
    }, now);
    try testing.expectEqualSlices(u8, &rec.result_digest, &rec2.result_digest);
    // Different payload -> different digest.
    const rec3 = auditRecord(&spec, .{
        .status = .ok,
        .source = "okx",
        .as_of_ms = now - 500,
        .data_json = "{\"c\":[9]}",
    }, now);
    try testing.expect(!std.mem.eql(u8, &rec.result_digest, &rec3.result_digest));
}
