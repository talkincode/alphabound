//! AlphaBound — bounded-autonomy trading agent.
//! Module map mirrors the design document Appendix A.

pub const decimal = @import("core/decimal.zig");
pub const clock = @import("core/clock.zig");
pub const risk_equity = @import("risk/equity.zig");
pub const risk_state = @import("risk/state_machine.zig");
pub const admission = @import("risk/admission.zig");
pub const orders = @import("execution/orders.zig");
pub const planner = @import("execution/planner.zig");
pub const okx_trade = @import("execution/okx_trade.zig");
pub const demo_runner = @import("execution/demo_runner.zig");
pub const proposal = @import("agent/proposal.zig");
pub const events = @import("core/events.zig");
pub const redaction = @import("observability/redaction.zig");
pub const journal = @import("observability/journal.zig");
pub const maintenance = @import("observability/maintenance.zig");
pub const auditor = @import("observability/auditor.zig");
pub const llm_usage = @import("observability/llm_usage.zig");
pub const config = @import("config.zig");
pub const state = @import("core/state.zig");
pub const storage = @import("storage/db.zig");
pub const storage_policy = @import("storage/policy.zig");
pub const storage_disk = @import("storage/disk.zig");
pub const retention = @import("storage/retention.zig");
pub const backup = @import("storage/backup.zig");
pub const security_limits = @import("security/limits.zig");
pub const latency = @import("observability/latency.zig");
pub const okx_auth = @import("exchange/okx/auth.zig");
pub const okx_rest = @import("exchange/okx/rest.zig");
pub const okx_ws = @import("exchange/okx/ws.zig");
pub const okx_private_ws = @import("exchange/okx/private_ws.zig");
pub const okx_private_ws_client = @import("exchange/okx/private_ws_client.zig");
pub const tools = @import("tools/registry.zig");
pub const market_tools = @import("tools/market.zig");
pub const indicators = @import("tools/indicators.zig");
pub const review_tools = @import("tools/review_tools.zig");
pub const external_tools = @import("tools/external.zig");
pub const memory = @import("memory/store.zig");
pub const reflection = @import("agent/reflection.zig");
pub const periodic_review = @import("agent/periodic_review.zig");
pub const context = @import("agent/context.zig");
pub const openai = @import("agent/openai.zig");
pub const shadow_bench = @import("core/shadow_bench.zig");
pub const scheduler = @import("core/scheduler.zig");
pub const admin_control = @import("admin/control.zig");
pub const web = @import("web/server.zig");
pub const web_auth = @import("web/auth.zig");
pub const web_cache = @import("web/cache.zig");
pub const web_review = @import("web/review.zig");
pub const analytics = @import("analytics/ab_factor.zig");
pub const fault_matrix = @import("fault/matrix.zig");
pub const security_isolation = @import("security/isolation.zig");

pub const Decimal = decimal.Decimal;

test {
    @import("std").testing.refAllDecls(@This());
}
