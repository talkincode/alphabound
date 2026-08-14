//! Scheduled deterministic audit (定时审计, AC-OPS follow-up).
//!
//! Pure rule engine over the event ledger + live snapshot: no LLM in the
//! judgment path (the same fail-closed philosophy as the Risk Kernel). The
//! core loop collects an `Input` from SQLite every `audit_interval_ms`,
//! `writeReport` evaluates five check groups and emits a JSON report:
//!
//!   llm   — run success/error rates, consecutive failures, zombie detection
//!   tools — tool-call presence & latency, market staleness
//!   data  — snapshot invariants (equity identity, HWM, drawdown), sample
//!           freshness, SQLite quick_check
//!   flow  — trigger→proposal→admission→reflection chain, backups, faults
//!   self  — audit cadence itself, risk mode visibility
//!
//! Findings power the dashboard alert bell; nothing here can touch trading.

const std = @import("std");

pub const Severity = enum(u2) {
    ok = 0,
    warn = 1,
    alert = 2,

    pub fn text(self: Severity) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warn => "warn",
            .alert => "alert",
        };
    }

    fn max(a: Severity, b: Severity) Severity {
        return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
    }
};

/// Everything the rule engine needs, pre-collected (pure & testable).
pub const Input = struct {
    now_ms: i64,
    window_ms: i64,
    // --- llm ---
    agent_enabled: bool,
    runs_total: i64 = 0,
    runs_ok: i64 = 0,
    runs_invalid: i64 = 0,
    runs_error: i64 = 0,
    /// Leading non-ok statuses in newest-first agent_runs.
    consecutive_failures: i64 = 0,
    /// ms since last AGENT_PROPOSAL_OK; -1 = none on record.
    last_proposal_age_ms: i64 = -1,
    /// Zombie when last_proposal_age exceeds this (3× slowest cadence).
    zombie_threshold_ms: i64,
    // --- tools ---
    tool_calls_total: i64 = 0,
    tool_latency_max_ms: i64 = 0,
    runs_without_tools: i64 = 0,
    market_stale_count: i64 = 0,
    // --- data invariants ---
    equity_identity_ok: bool = true,
    hwm_ge_equity: bool = true,
    drawdown_consistent: bool = true,
    /// ms since newest equity sample; -1 = table empty.
    equity_sample_age_ms: i64 = -1,
    db_quick_check_ok: bool = true,
    // --- flow ---
    triggers: i64 = 0,
    outcomes: i64 = 0,
    proposals: i64 = 0,
    admissions: i64 = 0,
    reflections: i64 = 0,
    backup_ok_count: i64 = 0,
    /// FAULT + RECONCILE_MISMATCH + ORDER_UNKNOWN in window.
    critical_faults: i64 = 0,
    // --- self ---
    /// ms since previous audit report; -1 = first audit.
    last_audit_age_ms: i64 = -1,
    risk_mode: []const u8 = "NORMAL",
};

const W = std.Io.Writer;

fn finding(w: *W, first: *bool, check: []const u8, sev: Severity, comptime fmt: []const u8, args: anytype) W.Error!Severity {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.print("{{\"check\":\"{s}\",\"severity\":\"{s}\",\"detail\":\"", .{ check, sev.text() });
    try w.print(fmt, args);
    try w.writeAll("\"}");
    return sev;
}

/// Evaluate all checks, writing a findings JSON array (only warn/alert are
/// listed; an empty array means all green). Returns the overall severity.
pub fn writeFindings(w: *W, in: Input) W.Error!Severity {
    var overall: Severity = .ok;
    var first = true;
    try w.writeByte('[');

    // ---- llm ----
    if (in.runs_total > 0) {
        const bad = in.runs_error + in.runs_invalid;
        const rate_pct = @divTrunc(bad * 100, in.runs_total);
        if (rate_pct >= 60) {
            overall = overall.max(try finding(w, &first, "llm.error_rate", .alert, "窗口内 {d}/{d} 次 run 失败（{d}%）", .{ bad, in.runs_total, rate_pct }));
        } else if (rate_pct >= 30) {
            overall = overall.max(try finding(w, &first, "llm.error_rate", .warn, "窗口内 {d}/{d} 次 run 失败（{d}%）", .{ bad, in.runs_total, rate_pct }));
        }
    }
    if (in.consecutive_failures >= 3) {
        overall = overall.max(try finding(w, &first, "llm.consecutive_failures", .alert, "最近连续 {d} 次 run 未成功（invalid/error）", .{in.consecutive_failures}));
    } else if (in.consecutive_failures == 2) {
        overall = overall.max(try finding(w, &first, "llm.consecutive_failures", .warn, "最近连续 2 次 run 未成功", .{}));
    }
    if (in.agent_enabled) {
        if (in.last_proposal_age_ms > in.zombie_threshold_ms) {
            overall = overall.max(try finding(w, &first, "llm.zombie", .alert, "距上次有效提案已 {d} 分钟（阈值 {d} 分钟）——慢环疑似停摆", .{ @divTrunc(in.last_proposal_age_ms, 60_000), @divTrunc(in.zombie_threshold_ms, 60_000) }));
        } else if (in.last_proposal_age_ms < 0 and in.runs_total == 0 and in.last_audit_age_ms >= 0) {
            overall = overall.max(try finding(w, &first, "llm.zombie", .warn, "账本中从未出现有效提案且本窗口无 run", .{}));
        }
    }

    // ---- tools ----
    if (in.runs_without_tools > 0) {
        overall = overall.max(try finding(w, &first, "tools.missing", .warn, "{d} 次 run 没有任何工具调用记录", .{in.runs_without_tools}));
    }
    if (in.tool_latency_max_ms > 15_000) {
        overall = overall.max(try finding(w, &first, "tools.latency", .warn, "窗口内工具调用最大延迟 {d}ms", .{in.tool_latency_max_ms}));
    }
    if (in.market_stale_count >= 10) {
        overall = overall.max(try finding(w, &first, "tools.market_stale", .alert, "窗口内 MARKET_STALE {d} 次——行情通道持续劣化", .{in.market_stale_count}));
    } else if (in.market_stale_count >= 3) {
        overall = overall.max(try finding(w, &first, "tools.market_stale", .warn, "窗口内 MARKET_STALE {d} 次", .{in.market_stale_count}));
    }

    // ---- data ----
    if (!in.equity_identity_ok) {
        overall = overall.max(try finding(w, &first, "data.equity_identity", .alert, "保守净值与 cash+btc×bid 重算不一致（超容差）", .{}));
    }
    if (!in.hwm_ge_equity) {
        overall = overall.max(try finding(w, &first, "data.hwm_monotonic", .alert, "HWM 低于当前净值——高水位状态被破坏", .{}));
    }
    if (!in.drawdown_consistent) {
        overall = overall.max(try finding(w, &first, "data.drawdown", .alert, "drawdown 与 1-equity/HWM 重算不一致", .{}));
    }
    if (in.equity_sample_age_ms < 0) {
        overall = overall.max(try finding(w, &first, "data.equity_samples", .warn, "equity_samples 为空", .{}));
    } else if (in.equity_sample_age_ms > 10 * 60_000) {
        overall = overall.max(try finding(w, &first, "data.equity_samples", .warn, "最新净值样本已 {d} 分钟未更新", .{@divTrunc(in.equity_sample_age_ms, 60_000)}));
    }
    if (!in.db_quick_check_ok) {
        overall = overall.max(try finding(w, &first, "data.db_integrity", .alert, "SQLite quick_check 未返回 ok", .{}));
    }

    // ---- flow ----
    if (in.triggers - in.outcomes > 1) {
        overall = overall.max(try finding(w, &first, "flow.trigger_outcomes", .warn, "{d} 次 AGENT_TRIGGER 只有 {d} 个终态事件——决策链存在断裂", .{ in.triggers, in.outcomes }));
    }
    if (in.proposals != in.admissions) {
        overall = overall.max(try finding(w, &first, "flow.admissions", .warn, "提案 {d} 个 vs 准入事件 {d} 个——风险准入记录缺失", .{ in.proposals, in.admissions }));
    }
    if (in.reflections + 1 < in.proposals) {
        overall = overall.max(try finding(w, &first, "flow.reflections", .warn, "提案 {d} 个仅 {d} 个反思——记忆闭环不完整", .{ in.proposals, in.reflections }));
    }
    if (in.backup_ok_count == 0 and in.window_ms >= 2 * 3_600_000) {
        overall = overall.max(try finding(w, &first, "flow.backup", .warn, "窗口内没有成功的 SQLite 备份", .{}));
    }
    if (in.critical_faults > 0) {
        overall = overall.max(try finding(w, &first, "flow.critical_events", .alert, "窗口内出现 {d} 个严重事件（FAULT/RECONCILE_MISMATCH/ORDER_UNKNOWN）", .{in.critical_faults}));
    }

    // ---- self ----
    if (in.last_audit_age_ms > 2 * in.window_ms and in.last_audit_age_ms >= 0) {
        overall = overall.max(try finding(w, &first, "self.audit_overdue", .warn, "距上次审计已 {d} 分钟（应约 {d} 分钟一次）", .{ @divTrunc(in.last_audit_age_ms, 60_000), @divTrunc(in.window_ms, 60_000) }));
    }
    if (!std.mem.eql(u8, in.risk_mode, "NORMAL")) {
        overall = overall.max(try finding(w, &first, "self.risk_mode", .warn, "风险模式为 {s}（非 NORMAL）", .{in.risk_mode}));
    }

    try w.writeByte(']');
    return overall;
}

/// Full report object: {"audit_id","ts","window_ms","status","findings":[...],"stats":{...}}.
/// Returns overall severity.
pub fn writeReport(w: *W, in: Input, audit_id: []const u8, ts: []const u8) W.Error!Severity {
    try w.print("{{\"audit_id\":\"{s}\",\"ts\":\"{s}\",\"window_ms\":{d},", .{ audit_id, ts, in.window_ms });
    // findings into a scratch first so status can precede them in the JSON.
    var scratch: [8192]u8 = undefined;
    var fw: W = .fixed(&scratch);
    const overall = writeFindings(&fw, in) catch blk: {
        break :blk Severity.alert; // findings overflow → treat as alert, keep truncation visible
    };
    try w.print("\"status\":\"{s}\",\"findings\":{s},", .{ overall.text(), fw.buffered() });
    try w.print(
        "\"stats\":{{\"runs_total\":{d},\"runs_ok\":{d},\"runs_invalid\":{d},\"runs_error\":{d},\"consecutive_failures\":{d},\"last_proposal_age_ms\":{d},\"tool_calls\":{d},\"tool_latency_max_ms\":{d},\"runs_without_tools\":{d},\"market_stale\":{d},\"triggers\":{d},\"outcomes\":{d},\"proposals\":{d},\"admissions\":{d},\"reflections\":{d},\"backups_ok\":{d},\"critical_faults\":{d},\"equity_sample_age_ms\":{d}}}}}",
        .{
            in.runs_total,       in.runs_ok,           in.runs_invalid, in.runs_error,
            in.consecutive_failures, in.last_proposal_age_ms, in.tool_calls_total, in.tool_latency_max_ms,
            in.runs_without_tools,   in.market_stale_count,   in.triggers,     in.outcomes,
            in.proposals,            in.admissions,           in.reflections,  in.backup_ok_count,
            in.critical_faults,      in.equity_sample_age_ms,
        },
    );
    return overall;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn healthyInput() Input {
    return .{
        .now_ms = 1_000_000_000,
        .window_ms = 4 * 3_600_000,
        .agent_enabled = true,
        .runs_total = 16,
        .runs_ok = 16,
        .last_proposal_age_ms = 10 * 60_000,
        .zombie_threshold_ms = 3 * 3_600_000,
        .tool_calls_total = 80,
        .tool_latency_max_ms = 900,
        .equity_sample_age_ms = 30_000,
        .triggers = 16,
        .outcomes = 16,
        .proposals = 16,
        .admissions = 16,
        .reflections = 16,
        .backup_ok_count = 4,
        .last_audit_age_ms = 4 * 3_600_000,
    };
}

test "healthy input yields ok with empty findings" {
    var buf: [8192]u8 = undefined;
    var w: W = .fixed(&buf);
    const sev = try writeReport(&w, healthyInput(), "aud_1", "2026-08-14T05:00:00.000Z");
    try testing.expectEqual(Severity.ok, sev);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "\"status\":\"ok\"") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\"findings\":[]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
    parsed.deinit();
}

test "consecutive llm failures and zombie escalate to alert" {
    var in = healthyInput();
    in.consecutive_failures = 3;
    in.last_proposal_age_ms = 5 * 3_600_000; // > 3h threshold
    var buf: [8192]u8 = undefined;
    var w: W = .fixed(&buf);
    const sev = try writeReport(&w, in, "aud_2", "t");
    try testing.expectEqual(Severity.alert, sev);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "llm.consecutive_failures") != null);
    try testing.expect(std.mem.indexOf(u8, s, "llm.zombie") != null);
}

test "data invariant breaks are alerts; chain gaps are warns" {
    var in = healthyInput();
    in.equity_identity_ok = false;
    in.drawdown_consistent = false;
    var buf: [8192]u8 = undefined;
    var w: W = .fixed(&buf);
    try testing.expectEqual(Severity.alert, try writeFindings(&w, in));
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "data.equity_identity") != null);

    var in2 = healthyInput();
    in2.admissions = 14; // two missing
    in2.reflections = 10;
    in2.triggers = 20;
    var w2: W = .fixed(&buf);
    try testing.expectEqual(Severity.warn, try writeFindings(&w2, in2));
    const s2 = w2.buffered();
    try testing.expect(std.mem.indexOf(u8, s2, "flow.admissions") != null);
    try testing.expect(std.mem.indexOf(u8, s2, "flow.reflections") != null);
    try testing.expect(std.mem.indexOf(u8, s2, "flow.trigger_outcomes") != null);
}

test "risk mode and stale samples surface as warns; disabled agent skips zombie" {
    var in = healthyInput();
    in.agent_enabled = false;
    in.last_proposal_age_ms = 99 * 3_600_000; // would be zombie if enabled
    in.risk_mode = "EXIT_ONLY";
    in.equity_sample_age_ms = 30 * 60_000;
    var buf: [8192]u8 = undefined;
    var w: W = .fixed(&buf);
    const sev = try writeFindings(&w, in);
    try testing.expectEqual(Severity.warn, sev);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "llm.zombie") == null);
    try testing.expect(std.mem.indexOf(u8, s, "self.risk_mode") != null);
    try testing.expect(std.mem.indexOf(u8, s, "data.equity_samples") != null);
}
