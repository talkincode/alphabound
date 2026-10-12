//! Dynamic filter-layer parameters (phase 1).
//!
//! The decision path reads the active version of this set. Defaults are the
//! values the daemon already uses, so a bootstrap from an unchanged config
//! file does not move any trade, schedule, or stress check.
//!
//! Hard bounds, the 20% step, and the 24h change gate are compile-time
//! constants in this file. They are not config keys and not database columns.
//! `max_drawdown` is not a field: the risk kernel keeps 0.10.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const config = @import("../config.zig");
const guardrails = @import("../risk/guardrails.zig");
const gate = @import("../risk/gate.zig");
const admission = @import("../risk/admission.zig");
const scheduler = @import("../core/scheduler.zig");

const Decimal = dec.Decimal;

pub const day_ms: i64 = 86_400_000;
pub const step_numerator: i128 = 1;
pub const step_denominator: i128 = 5; // 20%

/// Locked risk-kernel drawdown. Not part of `Params` and rejected if a
/// proposal JSON tries to carry it.
pub const max_drawdown_locked: Decimal = Decimal.fromRaw(10_000_000); // 0.10

pub const default_price_shock: Decimal = Decimal.fromRaw(5_000_000); // 0.05
pub const default_exit_reserve: Decimal = Decimal.fromRaw(50_000_000); // 0.50
pub const default_position_cap: Decimal = Decimal.one;

pub const daily_cap_min: u32 = 0;
pub const daily_cap_max: u32 = 48;
pub const cooldown_min_ms: i64 = 0;
pub const cooldown_max_ms: i64 = day_ms;
pub const equity_frac_min: Decimal = Decimal.zero;
pub const equity_frac_max: Decimal = Decimal.fromRaw(50_000_000); // 0.50
pub const sell_exempt_min: Decimal = Decimal.zero;
pub const sell_exempt_max: Decimal = max_drawdown_locked;
pub const trend_period_min: u32 = 20;
pub const trend_period_max: u32 = 200;
pub const position_cap_min: Decimal = Decimal.zero;
pub const position_cap_max: Decimal = Decimal.one;
pub const price_shock_min: Decimal = default_price_shock;
pub const price_shock_max: Decimal = Decimal.fromRaw(20_000_000); // 0.20
pub const exit_reserve_min: Decimal = default_exit_reserve;
pub const exit_reserve_max: Decimal = Decimal.fromRaw(500_000_000); // 5.00
pub const event_move_max: Decimal = Decimal.fromRaw(5_000_000); // 0.05
pub const event_dd_max: Decimal = Decimal.fromRaw(5_000_000); // 0.05
pub const event_drift_max: Decimal = Decimal.fromRaw(10_000_000); // 0.10
pub const window_min_ms: i64 = 600_000;
pub const window_max_ms: i64 = scheduler.volatility_window_ms; // 15m; fits the ring
pub const gap_min_ms: i64 = 30_000;
pub const gap_max_ms: i64 = 180_000;
pub const window_step_ms: i64 = 60_000;

pub const Reason = enum {
    ok,
    unchanged,
    out_of_bounds,
    step_too_large,
    too_soon,
    not_tighter,
    /// A proposal named `max_drawdown`. The kernel constant is not a field.
    locked,

    pub fn text(self: Reason) []const u8 {
        return @tagName(self);
    }
};

pub const Verdict = struct {
    reason: Reason = .ok,
    field: []const u8 = "",

    pub fn allowed(self: Verdict) bool {
        return self.reason == .ok or self.reason == .unchanged;
    }
};

pub const ParseError = error{
    MalformedJson,
    UnknownField,
    MissingField,
    WrongType,
    OutOfRange,
    OutOfMemory,
};

/// Filter-layer set. Field defaults are today's shipped behaviour.
pub const Params = struct {
    daily_trade_cap: u32 = guardrails.Params.default_daily_trade_cap,
    reverse_cooldown_ms: i64 = guardrails.Params.default_reverse_cooldown_ms,
    min_trade_equity_frac: Decimal = guardrails.Params.default_min_trade_equity_frac,
    macro_sell_requires_trend_break: bool = false,
    sell_exempt_drawdown: Decimal = guardrails.Params.default_sell_exempt_drawdown,
    trend_ma_period: u32 = guardrails.TREND_MA_PERIOD,
    /// Upper bound on admitted BTC weight. 1.0 leaves the existing [0,1] gate
    /// untouched. Proposals may only lower it.
    position_cap: Decimal = default_position_cap,
    /// Adverse price shock. Proposals may only raise it (more conservative).
    price_shock: Decimal = default_price_shock,
    /// Exit reserve in USDT. Proposals may only raise it (more conservative).
    exit_reserve: Decimal = default_exit_reserve,
    event_price_move: Decimal = Decimal.fromRaw(500_000), // 0.005
    event_drawdown_step: Decimal = Decimal.fromRaw(1_000_000), // 0.01
    event_price_drift: Decimal = Decimal.fromRaw(2_000_000), // 0.02
    volatility_window_ms: i64 = scheduler.volatility_window_ms,
    volatility_gap_ms: i64 = scheduler.volatility_max_gap_ms,

    pub fn eql(a: Params, b: Params) bool {
        return a.daily_trade_cap == b.daily_trade_cap and
            a.reverse_cooldown_ms == b.reverse_cooldown_ms and
            a.min_trade_equity_frac.eql(b.min_trade_equity_frac) and
            a.macro_sell_requires_trend_break == b.macro_sell_requires_trend_break and
            a.sell_exempt_drawdown.eql(b.sell_exempt_drawdown) and
            a.trend_ma_period == b.trend_ma_period and
            a.position_cap.eql(b.position_cap) and
            a.price_shock.eql(b.price_shock) and
            a.exit_reserve.eql(b.exit_reserve) and
            a.event_price_move.eql(b.event_price_move) and
            a.event_drawdown_step.eql(b.event_drawdown_step) and
            a.event_price_drift.eql(b.event_price_drift) and
            a.volatility_window_ms == b.volatility_window_ms and
            a.volatility_gap_ms == b.volatility_gap_ms;
    }

    /// Absolute notional floor stays on the config file; it is not dynamic.
    pub fn guardOf(self: Params, min_trade_notional: Decimal) guardrails.Params {
        return .{
            .min_trade_notional = min_trade_notional,
            .min_trade_equity_frac = self.min_trade_equity_frac,
            .daily_trade_cap = self.daily_trade_cap,
            .reverse_cooldown_ms = self.reverse_cooldown_ms,
            .macro_sell_requires_trend_break = self.macro_sell_requires_trend_break,
            .sell_exempt_drawdown = self.sell_exempt_drawdown,
        };
    }

    /// Identity when `position_cap` is 1. Weights outside [0,1] are left alone
    /// so admission still rejects them instead of silently clipping into range.
    pub fn applyPositionCap(self: Params, weight: Decimal) Decimal {
        if (!self.position_cap.lt(Decimal.one)) return weight;
        if (weight.isNegative() or weight.gt(Decimal.one)) return weight;
        if (weight.gt(self.position_cap)) return self.position_cap;
        return weight;
    }

    pub fn writeJson(self: Params, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            "{{\"daily_trade_cap\":{d},\"reverse_cooldown_ms\":{d},\"min_trade_equity_frac\":\"{f}\"," ++
                "\"macro_sell_requires_trend_break\":{},\"sell_exempt_drawdown\":\"{f}\",\"trend_ma_period\":{d}," ++
                "\"position_cap\":\"{f}\",\"price_shock\":\"{f}\",\"exit_reserve\":\"{f}\"," ++
                "\"event_price_move\":\"{f}\",\"event_drawdown_step\":\"{f}\",\"event_price_drift\":\"{f}\"," ++
                "\"volatility_window_ms\":{d},\"volatility_gap_ms\":{d}}}",
            .{
                self.daily_trade_cap,
                self.reverse_cooldown_ms,
                self.min_trade_equity_frac,
                self.macro_sell_requires_trend_break,
                self.sell_exempt_drawdown,
                self.trend_ma_period,
                self.position_cap,
                self.price_shock,
                self.exit_reserve,
                self.event_price_move,
                self.event_drawdown_step,
                self.event_price_drift,
                self.volatility_window_ms,
                self.volatility_gap_ms,
            },
        );
    }
};

pub fn fromConfig(cfg: *const config.Config) Params {
    return .{
        .daily_trade_cap = cfg.guard_daily_trade_cap,
        .reverse_cooldown_ms = cfg.guard_reverse_cooldown_ms,
        .min_trade_equity_frac = cfg.guard_min_trade_equity_frac,
        .macro_sell_requires_trend_break = cfg.guard_macro_sell_trend_break,
        .sell_exempt_drawdown = cfg.guard_sell_exempt_drawdown,
        .event_price_move = cfg.event_price_move,
        .event_drawdown_step = cfg.event_drawdown_step,
        .event_price_drift = cfg.event_price_drift,
    };
}

/// Config keys that seed the first parameter version and nothing after it.
/// `position_cap`, `price_shock`, `exit_reserve`, `trend_ma_period`, and the
/// volatility window/gap live only in the parameter store, so they are not
/// compared here. An empty result means the bootstrap fields match `active`.
/// This does not write the database.
pub fn configDrift(active: Params, cfg: *const config.Config, buf: []u8) []const u8 {
    const file = fromConfig(cfg);
    var w: std.Io.Writer = .fixed(buf);
    var n: usize = 0;
    if (!active.min_trade_equity_frac.eql(file.min_trade_equity_frac)) appendDrift(&w, &n, "guard_min_trade_equity_frac");
    if (active.daily_trade_cap != file.daily_trade_cap) appendDrift(&w, &n, "guard_daily_trade_cap");
    if (active.reverse_cooldown_ms != file.reverse_cooldown_ms) appendDrift(&w, &n, "guard_reverse_cooldown_ms");
    if (active.macro_sell_requires_trend_break != file.macro_sell_requires_trend_break) appendDrift(&w, &n, "guard_macro_sell_trend_break");
    if (!active.sell_exempt_drawdown.eql(file.sell_exempt_drawdown)) appendDrift(&w, &n, "guard_sell_exempt_drawdown");
    if (!active.event_price_move.eql(file.event_price_move)) appendDrift(&w, &n, "event_price_move");
    if (!active.event_drawdown_step.eql(file.event_drawdown_step)) appendDrift(&w, &n, "event_drawdown_step");
    if (!active.event_price_drift.eql(file.event_price_drift)) appendDrift(&w, &n, "event_price_drift");
    return w.buffered();
}

fn appendDrift(w: *std.Io.Writer, n: *usize, name: []const u8) void {
    if (n.* > 0) w.writeByte(',') catch return;
    w.writeAll(name) catch return;
    n.* += 1;
}

pub fn stressOf(cfg: *const config.Config, p: Params) admission.StressParams {
    var s = gate.defaultStressParams(cfg);
    s.price_shock = p.price_shock;
    s.exit_reserve = p.exit_reserve;
    return s;
}

const json_keys = [_][]const u8{
    "daily_trade_cap",
    "reverse_cooldown_ms",
    "min_trade_equity_frac",
    "macro_sell_requires_trend_break",
    "sell_exempt_drawdown",
    "trend_ma_period",
    "position_cap",
    "price_shock",
    "exit_reserve",
    "event_price_move",
    "event_drawdown_step",
    "event_price_drift",
    "volatility_window_ms",
    "volatility_gap_ms",
};

pub fn parseJson(gpa: std.mem.Allocator, raw: []const u8) ParseError!Params {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return error.MalformedJson;
    defer parsed.deinit();
    return parseValue(parsed.value);
}

pub fn parseValue(value: std.json.Value) ParseError!Params {
    if (value != .object) return error.MalformedJson;
    const obj = value.object;
    if (obj.get("max_drawdown") != null) return error.UnknownField;
    if (obj.count() != json_keys.len) return error.UnknownField;
    for (json_keys) |k| {
        if (obj.get(k) == null) return error.MissingField;
    }
    return .{
        .daily_trade_cap = try getU32(obj, "daily_trade_cap"),
        .reverse_cooldown_ms = try getI64(obj, "reverse_cooldown_ms"),
        .min_trade_equity_frac = try getDec(obj, "min_trade_equity_frac"),
        .macro_sell_requires_trend_break = try getBool(obj, "macro_sell_requires_trend_break"),
        .sell_exempt_drawdown = try getDec(obj, "sell_exempt_drawdown"),
        .trend_ma_period = try getU32(obj, "trend_ma_period"),
        .position_cap = try getDec(obj, "position_cap"),
        .price_shock = try getDec(obj, "price_shock"),
        .exit_reserve = try getDec(obj, "exit_reserve"),
        .event_price_move = try getDec(obj, "event_price_move"),
        .event_drawdown_step = try getDec(obj, "event_drawdown_step"),
        .event_price_drift = try getDec(obj, "event_price_drift"),
        .volatility_window_ms = try getI64(obj, "volatility_window_ms"),
        .volatility_gap_ms = try getI64(obj, "volatility_gap_ms"),
    };
}

/// True when a request body names the locked drawdown field. Any such
/// proposal is rejected before it can become a version.
pub fn rawLocksDrawdown(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "\"max_drawdown\"") != null;
}

/// Absolute bounds only. Rollback uses this: step size, the 24h gate, and
/// the one-way knobs do not apply, but a restored set must still fit.
pub fn validateAbsolute(proposed: Params) Verdict {
    if (proposed.daily_trade_cap < daily_cap_min or proposed.daily_trade_cap > daily_cap_max) {
        return .{ .reason = .out_of_bounds, .field = "daily_trade_cap" };
    }
    if (proposed.reverse_cooldown_ms < cooldown_min_ms or proposed.reverse_cooldown_ms > cooldown_max_ms) {
        return .{ .reason = .out_of_bounds, .field = "reverse_cooldown_ms" };
    }
    if (proposed.min_trade_equity_frac.lt(equity_frac_min) or proposed.min_trade_equity_frac.gt(equity_frac_max)) {
        return .{ .reason = .out_of_bounds, .field = "min_trade_equity_frac" };
    }
    if (proposed.sell_exempt_drawdown.lt(sell_exempt_min) or proposed.sell_exempt_drawdown.gt(sell_exempt_max)) {
        return .{ .reason = .out_of_bounds, .field = "sell_exempt_drawdown" };
    }
    if (proposed.trend_ma_period < trend_period_min or proposed.trend_ma_period > trend_period_max) {
        return .{ .reason = .out_of_bounds, .field = "trend_ma_period" };
    }
    if (proposed.position_cap.lt(position_cap_min) or proposed.position_cap.gt(position_cap_max)) {
        return .{ .reason = .out_of_bounds, .field = "position_cap" };
    }
    if (proposed.price_shock.lt(price_shock_min) or proposed.price_shock.gt(price_shock_max)) {
        return .{ .reason = .out_of_bounds, .field = "price_shock" };
    }
    if (proposed.exit_reserve.lt(exit_reserve_min) or proposed.exit_reserve.gt(exit_reserve_max)) {
        return .{ .reason = .out_of_bounds, .field = "exit_reserve" };
    }
    if (proposed.event_price_move.lt(Decimal.zero) or proposed.event_price_move.gt(event_move_max)) {
        return .{ .reason = .out_of_bounds, .field = "event_price_move" };
    }
    if (proposed.event_drawdown_step.lt(Decimal.zero) or proposed.event_drawdown_step.gt(event_dd_max)) {
        return .{ .reason = .out_of_bounds, .field = "event_drawdown_step" };
    }
    if (proposed.event_price_drift.lt(Decimal.zero) or proposed.event_price_drift.gt(event_drift_max)) {
        return .{ .reason = .out_of_bounds, .field = "event_price_drift" };
    }
    if (proposed.volatility_window_ms < window_min_ms or proposed.volatility_window_ms > window_max_ms or
        @mod(proposed.volatility_window_ms, window_step_ms) != 0)
    {
        return .{ .reason = .out_of_bounds, .field = "volatility_window_ms" };
    }
    if (proposed.volatility_gap_ms < gap_min_ms or proposed.volatility_gap_ms > gap_max_ms) {
        return .{ .reason = .out_of_bounds, .field = "volatility_gap_ms" };
    }
    return .{ .reason = .ok };
}

/// `last_change_ms <= 0` means there is no prior change (the gate is open).
/// Identical sets are `unchanged` and do not consume the 24h slot.
pub fn validate(current: Params, proposed: Params, now_ms: i64, last_change_ms: i64) Verdict {
    if (current.eql(proposed)) return .{ .reason = .unchanged };
    if (last_change_ms > 0 and (now_ms < last_change_ms or now_ms - last_change_ms < day_ms)) {
        return .{ .reason = .too_soon };
    }

    if (checkU32("daily_trade_cap", current.daily_trade_cap, proposed.daily_trade_cap, daily_cap_min, daily_cap_max, current.daily_trade_cap)) |v| return v;
    if (checkI64("reverse_cooldown_ms", current.reverse_cooldown_ms, proposed.reverse_cooldown_ms, cooldown_min_ms, cooldown_max_ms, guardrails.Params.default_reverse_cooldown_ms, .any)) |v| return v;
    if (checkDec("min_trade_equity_frac", current.min_trade_equity_frac, proposed.min_trade_equity_frac, equity_frac_min, equity_frac_max, guardrails.Params.default_min_trade_equity_frac, .any)) |v| return v;
    if (checkDec("sell_exempt_drawdown", current.sell_exempt_drawdown, proposed.sell_exempt_drawdown, sell_exempt_min, sell_exempt_max, guardrails.Params.default_sell_exempt_drawdown, .any)) |v| return v;
    if (checkU32("trend_ma_period", current.trend_ma_period, proposed.trend_ma_period, trend_period_min, trend_period_max, guardrails.TREND_MA_PERIOD)) |v| return v;
    if (checkDec("position_cap", current.position_cap, proposed.position_cap, position_cap_min, position_cap_max, default_position_cap, .only_down)) |v| return v;
    if (checkDec("price_shock", current.price_shock, proposed.price_shock, price_shock_min, price_shock_max, default_price_shock, .only_up)) |v| return v;
    if (checkDec("exit_reserve", current.exit_reserve, proposed.exit_reserve, exit_reserve_min, exit_reserve_max, default_exit_reserve, .only_up)) |v| return v;
    if (checkDec("event_price_move", current.event_price_move, proposed.event_price_move, Decimal.zero, event_move_max, Decimal.fromRaw(500_000), .any)) |v| return v;
    if (checkDec("event_drawdown_step", current.event_drawdown_step, proposed.event_drawdown_step, Decimal.zero, event_dd_max, Decimal.fromRaw(1_000_000), .any)) |v| return v;
    if (checkDec("event_price_drift", current.event_price_drift, proposed.event_price_drift, Decimal.zero, event_drift_max, Decimal.fromRaw(2_000_000), .any)) |v| return v;
    if (checkI64("volatility_window_ms", current.volatility_window_ms, proposed.volatility_window_ms, window_min_ms, window_max_ms, scheduler.volatility_window_ms, .any)) |v| return v;
    if (proposed.volatility_window_ms != current.volatility_window_ms and @mod(proposed.volatility_window_ms, window_step_ms) != 0) {
        return .{ .reason = .out_of_bounds, .field = "volatility_window_ms" };
    }
    if (checkI64("volatility_gap_ms", current.volatility_gap_ms, proposed.volatility_gap_ms, gap_min_ms, gap_max_ms, scheduler.volatility_max_gap_ms, .any)) |v| return v;
    return .{ .reason = .ok };
}

const Dir = enum { any, only_up, only_down };

fn checkU32(field: []const u8, current: u32, proposed: u32, min: u32, max: u32, zero_scale: u32) ?Verdict {
    if (current == proposed) return null;
    if (proposed < min or proposed > max) return .{ .reason = .out_of_bounds, .field = field };
    if (!stepOk(@intCast(current), @intCast(proposed), @intCast(zero_scale))) return .{ .reason = .step_too_large, .field = field };
    return null;
}

fn checkI64(field: []const u8, current: i64, proposed: i64, min: i64, max: i64, zero_scale: i64, dir: Dir) ?Verdict {
    if (current == proposed) return null;
    if (proposed < min or proposed > max) return .{ .reason = .out_of_bounds, .field = field };
    switch (dir) {
        .any => {},
        .only_up => if (proposed < current) return .{ .reason = .not_tighter, .field = field },
        .only_down => if (proposed > current) return .{ .reason = .not_tighter, .field = field },
    }
    if (!stepOk(current, proposed, zero_scale)) return .{ .reason = .step_too_large, .field = field };
    return null;
}

fn checkDec(field: []const u8, current: Decimal, proposed: Decimal, min: Decimal, max: Decimal, zero_scale: Decimal, dir: Dir) ?Verdict {
    if (current.eql(proposed)) return null;
    if (proposed.lt(min) or proposed.gt(max)) return .{ .reason = .out_of_bounds, .field = field };
    switch (dir) {
        .any => {},
        .only_up => if (proposed.lt(current)) return .{ .reason = .not_tighter, .field = field },
        .only_down => if (proposed.gt(current)) return .{ .reason = .not_tighter, .field = field },
    }
    if (!stepOk(current.raw, proposed.raw, zero_scale.raw)) return .{ .reason = .step_too_large, .field = field };
    return null;
}

fn stepOk(current: i128, proposed: i128, zero_scale: i128) bool {
    if (current == proposed) return true;
    const base: i128 = if (current == 0) abs128(zero_scale) else abs128(current);
    if (base == 0) return false;
    const delta = abs128(proposed - current);
    return delta * step_denominator <= base * step_numerator;
}

fn abs128(v: i128) i128 {
    return if (v < 0) -v else v;
}

fn getU32(obj: std.json.ObjectMap, key: []const u8) ParseError!u32 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .integer) return error.WrongType;
    if (v.integer < 0 or v.integer > std.math.maxInt(u32)) return error.OutOfRange;
    return @intCast(v.integer);
}

fn getI64(obj: std.json.ObjectMap, key: []const u8) ParseError!i64 {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .integer) return error.WrongType;
    return v.integer;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ParseError!bool {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .bool) return error.WrongType;
    return v.bool;
}

fn getDec(obj: std.json.ObjectMap, key: []const u8) ParseError!Decimal {
    const v = obj.get(key) orelse return error.MissingField;
    if (v != .string) return error.WrongType;
    return Decimal.parse(v.string) catch return error.OutOfRange;
}

pub const backtest_ref_schema = "alphabound.backtest_ref.v1";

pub const BacktestRefError = error{
    Missing,
    Malformed,
    Schema,
    NotPassed,
    BadId,
};

/// Shape check for a passing backtest reference. Existence, the pass bit,
/// parameter equality and the 24h expiry are checked by `gate.validateStoredRef`
/// against `backtest_reports`. Empty input is `Missing`. A present reference
/// must be `alphabound.backtest_ref.v1` with a non-empty id and `passed: true`.
/// Optional `digest` (string) and `as_of_ms` (integer) are accepted here and
/// compared to the stored row by the lookup. Any other key is rejected.
pub fn validateBacktestRef(gpa: std.mem.Allocator, raw: []const u8) BacktestRefError!void {
    if (raw.len == 0) return error.Missing;
    if (raw.len > 1024) return error.Malformed;
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return error.Malformed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.Malformed;
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const known = std.mem.eql(u8, entry.key_ptr.*, "schema") or
            std.mem.eql(u8, entry.key_ptr.*, "id") or
            std.mem.eql(u8, entry.key_ptr.*, "passed") or
            std.mem.eql(u8, entry.key_ptr.*, "digest") or
            std.mem.eql(u8, entry.key_ptr.*, "as_of_ms");
        if (!known) return error.Malformed;
    }
    const schema = obj.get("schema") orelse return error.Schema;
    if (schema != .string or !std.mem.eql(u8, schema.string, backtest_ref_schema)) return error.Schema;
    const id = obj.get("id") orelse return error.BadId;
    if (id != .string or id.string.len < 4 or id.string.len > 80) return error.BadId;
    for (id.string) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) return error.BadId;
    }
    const passed = obj.get("passed") orelse return error.NotPassed;
    if (passed != .bool or !passed.bool) return error.NotPassed;
    if (obj.get("digest")) |digest| {
        if (digest != .string or digest.string.len == 0 or digest.string.len > 128) return error.Malformed;
    }
    if (obj.get("as_of_ms")) |at| {
        if (at != .integer or at.integer < 0) return error.Malformed;
    }
}

/// Copy scheduler knobs from the active filter set. Cadence floors that are
/// not part of `Params` are left alone.
pub fn adoptScheduler(sched: *scheduler.Scheduler, p: Params) void {
    sched.params.price_move = p.event_price_move;
    sched.params.drawdown_step = p.event_drawdown_step;
    sched.params.price_drift = p.event_price_drift;
    sched.params.volatility_window_ms = p.volatility_window_ms;
    sched.params.volatility_gap_ms = p.volatility_gap_ms;
}

/// The system prompt states the position band as `[0, 1]`. That sentence is
/// the only numeric guardrail in the prompt. When the active cap is still 1
/// the template is returned unchanged, so a daemon that nobody reconfigures
/// sends the same bytes as before. A lower cap is rendered in place.
pub fn renderSystemPrompt(dst: []u8, template: []const u8, params: Params) []const u8 {
    if (!params.position_cap.lt(Decimal.one)) return template;
    const needle = "target.btc` in [0, 1]";
    const at = std.mem.indexOf(u8, template, needle) orelse return template;
    var cap_buf: [32]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cap_buf);
    cw.print("{f}", .{params.position_cap}) catch return template;
    const cap = cw.buffered();
    const prefix = "target.btc` in [0, ";
    var w: std.Io.Writer = .fixed(dst);
    w.writeAll(template[0..at]) catch return template;
    w.writeAll(prefix) catch return template;
    w.writeAll(cap) catch return template;
    w.writeByte(']') catch return template;
    w.writeAll(template[at + needle.len ..]) catch return template;
    return w.buffered();
}

/// JSON array of fields whose values differ. Decimal fields are strings,
/// matching `Params.writeJson`.
pub fn writeDiff(w: *std.Io.Writer, current: Params, proposed: Params) std.Io.Writer.Error!void {
    try w.writeByte('[');
    var n: usize = 0;
    if (current.daily_trade_cap != proposed.daily_trade_cap) {
        try comma(w, &n);
        try w.print("{{\"field\":\"daily_trade_cap\",\"before\":{d},\"after\":{d}}}", .{ current.daily_trade_cap, proposed.daily_trade_cap });
    }
    if (current.reverse_cooldown_ms != proposed.reverse_cooldown_ms) {
        try comma(w, &n);
        try w.print("{{\"field\":\"reverse_cooldown_ms\",\"before\":{d},\"after\":{d}}}", .{ current.reverse_cooldown_ms, proposed.reverse_cooldown_ms });
    }
    if (!current.min_trade_equity_frac.eql(proposed.min_trade_equity_frac)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"min_trade_equity_frac\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.min_trade_equity_frac, proposed.min_trade_equity_frac });
    }
    if (current.macro_sell_requires_trend_break != proposed.macro_sell_requires_trend_break) {
        try comma(w, &n);
        try w.print("{{\"field\":\"macro_sell_requires_trend_break\",\"before\":{},\"after\":{}}}", .{ current.macro_sell_requires_trend_break, proposed.macro_sell_requires_trend_break });
    }
    if (!current.sell_exempt_drawdown.eql(proposed.sell_exempt_drawdown)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"sell_exempt_drawdown\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.sell_exempt_drawdown, proposed.sell_exempt_drawdown });
    }
    if (current.trend_ma_period != proposed.trend_ma_period) {
        try comma(w, &n);
        try w.print("{{\"field\":\"trend_ma_period\",\"before\":{d},\"after\":{d}}}", .{ current.trend_ma_period, proposed.trend_ma_period });
    }
    if (!current.position_cap.eql(proposed.position_cap)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"position_cap\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.position_cap, proposed.position_cap });
    }
    if (!current.price_shock.eql(proposed.price_shock)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"price_shock\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.price_shock, proposed.price_shock });
    }
    if (!current.exit_reserve.eql(proposed.exit_reserve)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"exit_reserve\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.exit_reserve, proposed.exit_reserve });
    }
    if (!current.event_price_move.eql(proposed.event_price_move)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"event_price_move\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.event_price_move, proposed.event_price_move });
    }
    if (!current.event_drawdown_step.eql(proposed.event_drawdown_step)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"event_drawdown_step\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.event_drawdown_step, proposed.event_drawdown_step });
    }
    if (!current.event_price_drift.eql(proposed.event_price_drift)) {
        try comma(w, &n);
        try w.print("{{\"field\":\"event_price_drift\",\"before\":\"{f}\",\"after\":\"{f}\"}}", .{ current.event_price_drift, proposed.event_price_drift });
    }
    if (current.volatility_window_ms != proposed.volatility_window_ms) {
        try comma(w, &n);
        try w.print("{{\"field\":\"volatility_window_ms\",\"before\":{d},\"after\":{d}}}", .{ current.volatility_window_ms, proposed.volatility_window_ms });
    }
    if (current.volatility_gap_ms != proposed.volatility_gap_ms) {
        try comma(w, &n);
        try w.print("{{\"field\":\"volatility_gap_ms\",\"before\":{d},\"after\":{d}}}", .{ current.volatility_gap_ms, proposed.volatility_gap_ms });
    }
    try w.writeByte(']');
}

fn comma(w: *std.Io.Writer, n: *usize) std.Io.Writer.Error!void {
    if (n.* > 0) try w.writeByte(',');
    n.* += 1;
}

/// Insert `"param_version":N` before the final `}` of a JSON object.
/// Returns `payload` unchanged when it is not an object or does not fit.
pub fn withParamVersion(dst: []u8, payload: []const u8, version_id: i64) []const u8 {
    if (payload.len < 2 or payload[0] != '{' or payload[payload.len - 1] != '}') return payload;
    if (std.mem.indexOf(u8, payload, "\"param_version\":") != null) return payload;
    var w: std.Io.Writer = .fixed(dst);
    w.writeAll(payload[0 .. payload.len - 1]) catch return payload;
    w.print(",\"param_version\":{d}}}", .{version_id}) catch return payload;
    return w.buffered();
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "max_drawdown is not a dynamic field and stays 0.10" {
    try testing.expect(!@hasField(Params, "max_drawdown"));
    try testing.expect(max_drawdown_locked.eql(d("0.10")));
    try testing.expectError(error.UnknownField, parseJson(testing.allocator, "{\"max_drawdown\":\"0.10\"}"));
}

test "defaults match shipped config, guardrails, stress and scheduler constants" {
    var cfg = try config.parse(testing.allocator, "");
    defer cfg.deinit();
    const p = fromConfig(&cfg);
    const shipped = Params{};
    try testing.expect(p.eql(shipped));
    const g = p.guardOf(Decimal.zero);
    const file = cfg.guardParams();
    try testing.expect(g.min_trade_equity_frac.eql(file.min_trade_equity_frac));
    try testing.expectEqual(g.daily_trade_cap, file.daily_trade_cap);
    try testing.expectEqual(g.reverse_cooldown_ms, file.reverse_cooldown_ms);
    try testing.expectEqual(g.macro_sell_requires_trend_break, file.macro_sell_requires_trend_break);
    try testing.expect(g.sell_exempt_drawdown.eql(file.sell_exempt_drawdown));
    const stress = stressOf(&cfg, p);
    const kernel = gate.defaultStressParams(&cfg);
    try testing.expect(stress.price_shock.eql(kernel.price_shock));
    try testing.expect(stress.exit_reserve.eql(kernel.exit_reserve));
    try testing.expectEqual(scheduler.volatility_window_ms, p.volatility_window_ms);
    try testing.expectEqual(scheduler.volatility_max_gap_ms, p.volatility_gap_ms);
    try testing.expectEqual(@as(u32, 50), p.trend_ma_period);
    try testing.expect(p.position_cap.eql(Decimal.one));
    try testing.expect(p.applyPositionCap(d("0.9")).eql(d("0.9")));
    try testing.expect(p.applyPositionCap(d("1.5")).eql(d("1.5")));
}

test "config drift names bootstrap fields and leaves the active row alone" {
    var matched = try config.parse(testing.allocator,
        \\[risk]
        \\guard_daily_trade_cap = 4
        \\[agent]
        \\event_price_move = 0.008
    );
    defer matched.deinit();
    var active = fromConfig(&matched);
    active.position_cap = d("0.8");
    active.price_shock = d("0.08");
    active.exit_reserve = d("1.00");
    active.trend_ma_period = 80;
    active.volatility_window_ms = 600_000;
    active.volatility_gap_ms = 60_000;
    var quiet: [128]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), configDrift(active, &matched, &quiet).len);

    var edited = try config.parse(testing.allocator,
        \\[risk]
        \\guard_daily_trade_cap = 8
        \\guard_macro_sell_trend_break = true
        \\[agent]
        \\event_price_move = 0.004
        \\event_price_drift = 0.03
    );
    defer edited.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "guard_daily_trade_cap,guard_macro_sell_trend_break,event_price_move,event_price_drift",
        configDrift(active, &edited, &buf),
    );
}

test "fromConfig copies the file and json round-trips" {
    var cfg = try config.parse(testing.allocator,
        \\[risk]
        \\guard_daily_trade_cap = 4
        \\guard_reverse_cooldown_ms = 7200000
        \\guard_min_trade_equity_frac = 0.08
        \\guard_macro_sell_trend_break = true
        \\guard_sell_exempt_drawdown = 0.02
        \\[agent]
        \\event_price_move = 0.008
        \\event_drawdown_step = 0.015
        \\event_price_drift = 0.03
    );
    defer cfg.deinit();
    const p = fromConfig(&cfg);
    try testing.expectEqual(@as(u32, 4), p.daily_trade_cap);
    try testing.expect(p.macro_sell_requires_trend_break);
    try testing.expect(p.event_price_move.eql(d("0.008")));
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.writeJson(&w);
    const back = try parseJson(testing.allocator, w.buffered());
    try testing.expect(back.eql(p));
}

test "validate enforces bounds, 20 percent step, 24h, and one-way knobs" {
    const base = Params{};
    const t0: i64 = 1_700_000_000_000;
    try testing.expectEqual(Reason.unchanged, validate(base, base, t0, t0).reason);

    var cap = base;
    cap.daily_trade_cap = 7;
    try testing.expectEqual(Reason.ok, validate(base, cap, t0 + day_ms, t0).reason);
    cap.daily_trade_cap = 8;
    const big = validate(base, cap, t0 + day_ms, t0);
    try testing.expectEqual(Reason.step_too_large, big.reason);
    try testing.expectEqualStrings("daily_trade_cap", big.field);

    var soon = base;
    soon.daily_trade_cap = 7;
    try testing.expectEqual(Reason.too_soon, validate(base, soon, t0 + day_ms - 1, t0).reason);
    try testing.expectEqual(Reason.ok, validate(base, soon, t0 + day_ms, 0).reason);

    var period = base;
    period.trend_ma_period = 10;
    try testing.expectEqual(Reason.out_of_bounds, validate(base, period, t0 + day_ms, t0).reason);

    var down = base;
    down.position_cap = d("0.8");
    try testing.expectEqual(Reason.ok, validate(base, down, t0 + day_ms, t0).reason);
    try testing.expect(down.applyPositionCap(d("0.9")).eql(d("0.8")));
    try testing.expect(down.applyPositionCap(d("1.2")).eql(d("1.2")));
    var up = base;
    up.position_cap = d("0.8");
    var raised = up;
    raised.position_cap = d("0.9");
    const raised_v = validate(up, raised, t0 + day_ms, t0);
    try testing.expectEqual(Reason.not_tighter, raised_v.reason);
    try testing.expectEqualStrings("position_cap", raised_v.field);

    var shock = base;
    shock.price_shock = d("0.06");
    try testing.expectEqual(Reason.ok, validate(base, shock, t0 + day_ms, t0).reason);
    var looser = shock;
    looser.price_shock = d("0.05");
    // 0.06 → 0.05 is within 20% and inside the absolute range, but less conservative.
    var mid = base;
    mid.price_shock = d("0.08");
    var eased = mid;
    eased.price_shock = d("0.07");
    try testing.expectEqual(Reason.not_tighter, validate(mid, eased, t0 + day_ms, t0).reason);

    var reserve = base;
    reserve.exit_reserve = d("0.60");
    try testing.expectEqual(Reason.ok, validate(base, reserve, t0 + day_ms, t0).reason);
    var thin = base;
    thin.exit_reserve = d("0.40");
    try testing.expectEqual(Reason.out_of_bounds, validate(base, thin, t0 + day_ms, t0).reason);

    var window = base;
    window.volatility_window_ms = 720_000;
    try testing.expectEqual(Reason.ok, validate(base, window, t0 + day_ms, t0).reason);
    window.volatility_window_ms = 750_000; // inside the 20% band, but not a whole minute
    try testing.expectEqual(Reason.out_of_bounds, validate(base, window, t0 + day_ms, t0).reason);

    var flipped = base;
    flipped.macro_sell_requires_trend_break = true;
    try testing.expectEqual(Reason.ok, validate(base, flipped, t0 + day_ms, t0).reason);
}

test "decision payload records the param version" {
    var buf: [128]u8 = undefined;
    const stamped = withParamVersion(&buf, "{\"action\":\"HOLD\",\"executed\":false}", 7);
    try testing.expectEqualStrings("{\"action\":\"HOLD\",\"executed\":false,\"param_version\":7}", stamped);
    var again: [160]u8 = undefined;
    try testing.expectEqualStrings(stamped, withParamVersion(&again, stamped, 9));
    try testing.expectEqualStrings("[]", withParamVersion(&buf, "[]", 1));
}

test "absolute bounds ignore step, direction and the 24h gate" {
    const base = Params{};
    try testing.expectEqual(Reason.ok, validateAbsolute(base).reason);
    var wide = base;
    wide.daily_trade_cap = 48;
    wide.position_cap = d("1");
    wide.price_shock = d("0.05");
    try testing.expectEqual(Reason.ok, validateAbsolute(wide).reason);
    var thin = base;
    thin.exit_reserve = d("0.40");
    try testing.expectEqual(Reason.out_of_bounds, validateAbsolute(thin).reason);
    try testing.expectEqualStrings("exit_reserve", validateAbsolute(thin).field);
    var odd = base;
    odd.volatility_window_ms = 750_000;
    try testing.expectEqual(Reason.out_of_bounds, validateAbsolute(odd).reason);
}

test "backtest reference shape is checked and not executed" {
    const ok = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true}";
    try validateBacktestRef(testing.allocator, ok);
    const with_extra = "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true,\"digest\":\"abc\",\"as_of_ms\":10}";
    try validateBacktestRef(testing.allocator, with_extra);
    try testing.expectError(error.Missing, validateBacktestRef(testing.allocator, ""));
    try testing.expectError(error.NotPassed, validateBacktestRef(testing.allocator, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":false}"));
    try testing.expectError(error.Schema, validateBacktestRef(testing.allocator, "{\"schema\":\"other\",\"id\":\"bt_ok\",\"passed\":true}"));
    try testing.expectError(error.Malformed, validateBacktestRef(testing.allocator, "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true,\"run\":1}"));
}

test "a full position cap leaves the prompt untouched" {
    const template = "propose target.btc` in [0, 1]. stop";
    var buf: [128]u8 = undefined;
    const same = renderSystemPrompt(&buf, template, .{});
    try testing.expectEqual(template.ptr, same.ptr);
    var lowered = Params{};
    lowered.position_cap = d("0.8");
    const rendered = renderSystemPrompt(&buf, template, lowered);
    try testing.expectEqualStrings("propose target.btc` in [0, 0.8]. stop", rendered);
}

test "scheduler adoption touches only filter knobs" {
    var sched = scheduler.Scheduler.init(.{ .base_interval_ms = 600_000, .price_move = d("0.005") });
    var p = Params{};
    p.event_price_move = d("0.006");
    p.volatility_window_ms = 720_000;
    adoptScheduler(&sched, p);
    try testing.expect(sched.params.price_move.eql(d("0.006")));
    try testing.expectEqual(@as(i64, 720_000), sched.params.volatility_window_ms);
    try testing.expectEqual(@as(i64, 600_000), sched.params.base_interval_ms);
}

test "diff lists only changed fields and locks the drawdown name" {
    var next = Params{};
    next.daily_trade_cap = 7;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDiff(&w, .{}, next);
    try testing.expectEqualStrings("[{\"field\":\"daily_trade_cap\",\"before\":6,\"after\":7}]", w.buffered());
    try testing.expect(rawLocksDrawdown("{\"max_drawdown\":\"0.2\"}"));
    try testing.expect(!rawLocksDrawdown("{\"daily_trade_cap\":6}"));
}
