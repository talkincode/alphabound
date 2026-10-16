//! Privacy-safe typed LLM failure metadata; no provider body is accepted here.
const std = @import("std");
pub const Cause = enum { timeout, connect, empty, api_status, http_failed, malformed, breaker_open, budget_exhausted };
pub fn classify(err: anyerror, status: ?u16, connected_failed: bool) Cause {
    if (err == error.Timeout) return .timeout;
    if (status) |code| {
        if (code < 200 or code >= 300) return .api_status;
    }
    return switch (err) {
        error.ConnectFailed, error.ConnectTimeout => .connect,
        error.HttpFailed => if (connected_failed) .connect else .http_failed,
        error.EmptyContent => .empty,
        error.ApiError => .api_status,
        error.MalformedResponse, error.BufferTooSmall => .malformed,
        error.BreakerOpen => .breaker_open,
        error.BudgetExhausted, error.OutOfMemory => .budget_exhausted,
        else => .http_failed,
    };
}
test "legacy LLM error mapping and optional HTTP status" {
    const t = std.testing;
    try t.expectEqual(Cause.connect, classify(error.ConnectTimeout, null, false));
    try t.expectEqual(Cause.timeout, classify(error.Timeout, null, false));
    try t.expectEqual(Cause.connect, classify(error.HttpFailed, null, true));
    try t.expectEqual(Cause.http_failed, classify(error.HttpFailed, null, false));
    try t.expectEqual(Cause.empty, classify(error.EmptyContent, 200, false));
    try t.expectEqual(Cause.api_status, classify(error.MalformedResponse, 429, false));
    try t.expectEqual(Cause.api_status, classify(error.ApiError, null, false));
    try t.expectEqual(Cause.malformed, classify(error.MalformedResponse, 200, false));
    try t.expectEqual(Cause.malformed, classify(error.BufferTooSmall, null, false));
    try t.expectEqual(Cause.budget_exhausted, classify(error.OutOfMemory, null, false));
    try t.expectEqual(Cause.breaker_open, classify(error.BreakerOpen, null, false));
    try t.expectEqual(Cause.budget_exhausted, classify(error.BudgetExhausted, null, false));
}
