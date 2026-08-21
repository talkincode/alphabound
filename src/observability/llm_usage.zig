//! LLM metering policy: turns provider-reported usage into a durable,
//! privacy-safe accounting row. This module intentionally stores no prompt,
//! completion, URL, credential, or provider error body.

const std = @import("std");
const openai = @import("../agent/openai.zig");
const storage = @import("../storage/db.zig");
const clock = @import("../core/clock.zig");

pub const Outcome = enum {
    ok,
    failed,

    pub fn text(self: Outcome) []const u8 {
        return switch (self) {
            .ok => "ok",
            .failed => "error",
        };
    }
};

pub const Call = struct {
    ts_ms: i64,
    call_kind: []const u8,
    run_id: []const u8 = "",
    decision_id: []const u8 = "",
    model: []const u8,
    outcome: Outcome,
    error_class: []const u8 = "",
    latency_ms: i64 = 0,
    usage: openai.Usage = .{},
};

const Pricing = struct {
    profile: []const u8,
    cache_hit_nano_per_token: u64,
    cache_miss_nano_per_token: u64,
    output_nano_per_token: u64,
};

/// Convert one provider call into a row suitable for the durable ledger.
///
/// Unknown model prices and omitted usage are represented explicitly through
/// `cost_known = false`; callers must never interpret their zero cost as free.
pub fn row(call: Call, ts_buf: []u8) storage.LlmUsageRow {
    const ts = clock.formatRfc3339Ms(call.ts_ms, ts_buf) catch "";
    const prompt = call.usage.prompt_tokens;
    const cached = @min(call.usage.cached_prompt_tokens, prompt);
    const total = if (call.usage.total_tokens > 0)
        call.usage.total_tokens
    else
        prompt +| call.usage.completion_tokens;

    var out = storage.LlmUsageRow{
        .ts = ts,
        .call_kind = call.call_kind,
        .run_id = call.run_id,
        .decision_id = call.decision_id,
        .model = call.model,
        .outcome = call.outcome.text(),
        .error_class = call.error_class,
        .latency_ms = @max(@as(i64, 0), call.latency_ms),
        .usage_reported = call.usage.reported,
        .prompt_tokens = prompt,
        .cached_prompt_tokens = cached,
        .completion_tokens = call.usage.completion_tokens,
        .total_tokens = total,
    };

    if (call.outcome != .ok or !call.usage.reported) return out;
    const pricing = pricingFor(call.model, call.ts_ms) orelse return out;
    const uncached = prompt - cached;
    out.price_profile = pricing.profile;
    out.input_cost_nano_usd = cached *| pricing.cache_hit_nano_per_token +| uncached *| pricing.cache_miss_nano_per_token;
    out.output_cost_nano_usd = call.usage.completion_tokens *| pricing.output_nano_per_token;
    out.cost_known = true;
    return out;
}

/// DeepSeek's published direct-API market rates for V4 Flash on 2026-08-21.
/// The dashboard labels this a market estimate, not an invoice: a gateway or
/// reseller may bill differently. Unknown models intentionally stay unpriced.
fn pricingFor(model: []const u8, ts_ms: i64) ?Pricing {
    if (std.ascii.indexOfIgnoreCase(model, "deepseek-v4-flash") == null) return null;
    const hour_utc: i64 = @mod(@divFloor(ts_ms, std.time.ms_per_hour), 24);
    const peak = (hour_utc >= 1 and hour_utc < 4) or (hour_utc >= 6 and hour_utc < 10);
    return if (peak)
        .{
            .profile = "deepseek-v4-flash-2026-08-21-peak",
            .cache_hit_nano_per_token = 14,
            .cache_miss_nano_per_token = 440,
            .output_nano_per_token = 1320,
        }
    else
        .{
            .profile = "deepseek-v4-flash-2026-08-21-offpeak",
            .cache_hit_nano_per_token = 7,
            .cache_miss_nano_per_token = 220,
            .output_nano_per_token = 660,
        };
}

const testing = std.testing;

test "DeepSeek V4 Flash pricing applies peak and cache rates" {
    var offpeak_ts: [40]u8 = undefined;
    const offpeak = row(.{
        .ts_ms = 0,
        .call_kind = "proposal",
        .model = "DeepSeek-V4-Flash-0731",
        .outcome = .ok,
        .usage = .{
            .reported = true,
            .prompt_tokens = 100,
            .cached_prompt_tokens = 40,
            .completion_tokens = 10,
        },
    }, &offpeak_ts);
    try testing.expect(offpeak.cost_known);
    try testing.expectEqual(@as(u64, 13_480), offpeak.input_cost_nano_usd);
    try testing.expectEqual(@as(u64, 6_600), offpeak.output_cost_nano_usd);

    var peak_ts: [40]u8 = undefined;
    const peak = row(.{
        .ts_ms = std.time.ms_per_hour,
        .call_kind = "proposal",
        .model = "deepseek-v4-flash",
        .outcome = .ok,
        .usage = .{ .reported = true, .prompt_tokens = 1, .completion_tokens = 1 },
    }, &peak_ts);
    try testing.expectEqual(@as(u64, 440), peak.input_cost_nano_usd);
    try testing.expectEqual(@as(u64, 1320), peak.output_cost_nano_usd);
}

test "unknown or omitted usage remains explicitly unpriced" {
    var unknown_ts: [40]u8 = undefined;
    const unknown = row(.{
        .ts_ms = 0,
        .call_kind = "proposal",
        .model = "unknown-model",
        .outcome = .ok,
        .usage = .{ .reported = true, .prompt_tokens = 9 },
    }, &unknown_ts);
    try testing.expect(!unknown.cost_known);

    var omitted_ts: [40]u8 = undefined;
    const omitted = row(.{
        .ts_ms = 0,
        .call_kind = "proposal",
        .model = "deepseek-v4-flash",
        .outcome = .ok,
    }, &omitted_ts);
    try testing.expect(!omitted.cost_known);
}
