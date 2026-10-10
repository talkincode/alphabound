//! Tightening-only strategy guardrails for *voluntary* agent trades.
//!
//! These checks run after (never instead of) Risk Kernel admission and can only
//! veto a trade — they never raise a weight, relax the HWM x (1 - maxdd) floor,
//! shrink the exit reserve or bypass a fail-closed check. A vetoed proposal is
//! executed as HOLD. Forced risk exits (non-NORMAL risk mode, or a standing book
//! that already fails the stress boundary) are exempt so de-risking is never
//! slowed down. Pure and deterministic: shared by the daemon and `backtest`.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const Decimal = dec.Decimal;

pub const day_ms: i64 = 86_400_000;
pub const hour_ms: i64 = 3_600_000;
pub const TREND_MA_PERIOD: usize = 50;

pub const Side = enum { buy, sell };

pub const Params = struct {
    pub const default_min_trade_equity_frac = Decimal.fromRaw(5_000_000); // 0.05
    pub const default_daily_trade_cap: u32 = 6;
    pub const default_reverse_cooldown_ms: i64 = 4 * hour_ms;
    pub const default_sell_exempt_drawdown = Decimal.fromRaw(1_000_000); // 0.01

    /// Absolute floor on a voluntary trade's notional (0 disables).
    min_trade_notional: Decimal = Decimal.zero,
    /// Floor as a fraction of equity, i.e. the smallest weight move worth its fee.
    min_trade_equity_frac: Decimal = default_min_trade_equity_frac,
    /// Max voluntary decisions executed in any rolling 24h (0 disables).
    daily_trade_cap: u32 = default_daily_trade_cap,
    /// Min gap between a trade and the opposite-side trade that follows (0 disables).
    reverse_cooldown_ms: i64 = default_reverse_cooldown_ms,
    /// Opt-in: macro-driven sells need a daily close below the 50D SMA. Off by
    /// default because replay showed it trades a higher realized drawdown for
    /// return on a single episode (see docs/BACKTEST.md).
    macro_sell_requires_trend_break: bool = false,
    /// Sells are never slowed down once the book is at least this far below its
    /// high watermark (fraction, 0 = always exempt). The hard floor is unchanged.
    sell_exempt_drawdown: Decimal = default_sell_exempt_drawdown,

    pub const disabled: Params = .{
        .min_trade_equity_frac = Decimal.zero,
        .daily_trade_cap = 0,
        .reverse_cooldown_ms = 0,
        .macro_sell_requires_trend_break = false,
    };
};

/// Daily trend fact: last *completed* daily close versus the 50-bar SMA.
pub const Trend = struct {
    known: bool = false,
    daily_close: Decimal = Decimal.zero,
    sma: Decimal = Decimal.zero,

    pub fn broken(self: Trend) bool {
        return self.known and self.daily_close.lt(self.sma);
    }
};

/// Build a Trend from completed daily closes, newest first. Needs
/// `TREND_MA_PERIOD` bars; otherwise `known` stays false (fail-closed for macro sells).
pub fn trendFromCloses(closes_newest_first: []const Decimal) Trend {
    if (closes_newest_first.len < TREND_MA_PERIOD) return .{};
    var sum: i128 = 0;
    for (closes_newest_first[0..TREND_MA_PERIOD]) |c| sum += c.raw;
    return .{
        .known = true,
        .daily_close = closes_newest_first[0],
        .sma = Decimal.fromRaw(@divTrunc(sum, @as(i128, TREND_MA_PERIOD))),
    };
}

/// Voluntary trades observed in the trailing 24h.
pub const Recent = struct {
    decisions_24h: u32 = 0,
    last_side: ?Side = null,
    last_ms: i64 = 0,
};

pub const Input = struct {
    now_ms: i64,
    equity: Decimal,
    current_weight: Decimal,
    /// Weight the Risk Kernel admitted (already <= what the agent asked for).
    target_weight: Decimal,
    macro_driven: bool,
    trend: Trend,
    recent: Recent,
    /// Forced risk exit: non-NORMAL risk mode or held book fails stress.
    exempt: bool,
    /// Current drawdown from the high watermark as a fraction (0 when at HWM).
    drawdown: Decimal = Decimal.zero,
};

pub const Verdict = enum {
    allow,
    block_min_trade,
    block_daily_cap,
    block_reverse_cooldown,
    block_macro_sell,

    pub fn text(self: Verdict) []const u8 {
        return switch (self) {
            .allow => "allow",
            .block_min_trade => "min_trade",
            .block_daily_cap => "daily_cap",
            .block_reverse_cooldown => "reverse_cooldown",
            .block_macro_sell => "macro_sell_no_trend_break",
        };
    }
};

pub fn evaluate(p: Params, in: Input) Verdict {
    if (in.exempt) return .allow;
    const delta = in.target_weight.sub(in.current_weight) catch return .allow;
    if (delta.isZero()) return .allow;
    const sell = delta.isNegative();
    // An underwater book may always de-risk; only dust is still filtered.
    const underwater_sell = sell and in.drawdown.gte(p.sell_exempt_drawdown);

    const notional = delta.abs().mul(in.equity, .down) catch return .block_min_trade;
    var floor = p.min_trade_notional;
    // Closing out or de-risking an underwater book only faces the absolute floor.
    const closing = sell and in.target_weight.isZero();
    if (!underwater_sell and !closing and p.min_trade_equity_frac.gt(Decimal.zero)) {
        const rel = in.equity.mul(p.min_trade_equity_frac, .down) catch Decimal.zero;
        floor = Decimal.max(floor, rel);
    }
    if (notional.lt(floor)) return .block_min_trade;

    if (!underwater_sell and p.daily_trade_cap != 0 and in.recent.decisions_24h >= p.daily_trade_cap)
        return .block_daily_cap;

    if (!underwater_sell and p.reverse_cooldown_ms > 0) {
        if (in.recent.last_side) |ls| {
            const opposite = (ls == .buy and sell) or (ls == .sell and !sell);
            if (opposite and in.now_ms - in.recent.last_ms < p.reverse_cooldown_ms)
                return .block_reverse_cooldown;
        }
    }

    if (!underwater_sell and p.macro_sell_requires_trend_break and sell and in.macro_driven and !in.trend.broken())
        return .block_macro_sell;

    return .allow;
}

/// Held-book stress posture during a HOLD (report-only; never gates execution).
/// `thin` = the standing position survives the 5% shock with less than this
/// fraction of equity to spare above the HWM floor.
pub const held_thin_headroom_frac = Decimal.fromRaw(1_500_000); // 0.015

pub const HeldAlert = enum {
    ok,
    thin,
    breach,

    pub fn text(self: HeldAlert) []const u8 {
        return switch (self) {
            .ok => "ok",
            .thin => "thin_headroom",
            .breach => "breach",
        };
    }
};

pub fn heldAlert(headroom: Decimal, equity: Decimal) HeldAlert {
    if (headroom.isNegative()) return .breach;
    if (equity.gt(Decimal.zero)) {
        const thin_below = equity.mul(held_thin_headroom_frac, .down) catch return .ok;
        if (headroom.lt(thin_below)) return .thin;
    }
    return .ok;
}

const macro_keywords = [_][]const u8{
    "macro",       "fomc",     "fed ",      "fed's",     "cpi",      "pce",      "nfp",
    "yield",       "tariff",   "inflation", "rate hike", "rate cut", "geopolit", "yen carry",
    "etf outflow", "etf flow", "powell",    "treasury",
    "宏观",
    "美联储",
    "加息",
    "降息",
    "地缘",
    "通胀",
    "关税",
};

fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, k| {
            if (std.ascii.toLower(hay[i + k]) != nc) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// True when any thesis line cites a macro/news driver. Deliberately broad:
/// a false positive only means a voluntary sell needs a trend break, which is a
/// tightening, and forced exits are exempt.
pub fn isMacroDriven(thesis: []const []const u8) bool {
    for (thesis) |line| {
        for (macro_keywords) |kw| if (containsFold(line, kw)) return true;
    }
    return false;
}

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn baseInput() Input {
    return .{
        .now_ms = 10 * day_ms,
        .equity = d("1000"),
        .current_weight = d("0.4"),
        .target_weight = d("0.3"),
        .macro_driven = false,
        .trend = .{ .known = true, .daily_close = d("90"), .sma = d("100") },
        .recent = .{},
        .exempt = false,
    };
}

test "plain trade passes" {
    try testing.expectEqual(Verdict.allow, evaluate(.{}, baseInput()));
}

test "min trade blocks dust but not a real move" {
    var in = baseInput();
    in.target_weight = d("0.395"); // 5 USDT < 1% of 1000
    try testing.expectEqual(Verdict.block_min_trade, evaluate(.{}, in));
    in.target_weight = d("0.4");
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in)); // no-op is never blocked
    var p = Params{ .min_trade_notional = d("50"), .min_trade_equity_frac = Decimal.zero };
    in.target_weight = d("0.37"); // 30 USDT < 50
    try testing.expectEqual(Verdict.block_min_trade, evaluate(p, in));
    p.min_trade_notional = d("10");
    try testing.expectEqual(Verdict.allow, evaluate(p, in));
}

test "daily cap" {
    var in = baseInput();
    in.recent.decisions_24h = 5;
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in));
    in.recent.decisions_24h = 6;
    try testing.expectEqual(Verdict.block_daily_cap, evaluate(.{}, in));
    try testing.expectEqual(Verdict.allow, evaluate(.{ .daily_trade_cap = 0 }, in));
}

test "reverse cooldown only blocks the opposite side inside the window" {
    var in = baseInput();
    in.recent = .{ .last_side = .buy, .last_ms = in.now_ms - hour_ms };
    try testing.expectEqual(Verdict.block_reverse_cooldown, evaluate(.{}, in)); // sell after buy
    in.recent.last_side = .sell;
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in)); // same direction again
    in.recent = .{ .last_side = .buy, .last_ms = in.now_ms - 5 * hour_ms };
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in)); // window elapsed
}

test "macro sell needs a trend break; buys and technical sells are untouched" {
    const p = Params{ .macro_sell_requires_trend_break = true };
    var in = baseInput();
    in.macro_driven = true;
    in.trend = .{ .known = true, .daily_close = d("101"), .sma = d("100") };
    try testing.expectEqual(Verdict.block_macro_sell, evaluate(p, in));
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in)); // off by default
    in.trend = .{}; // unknown trend is fail-closed
    try testing.expectEqual(Verdict.block_macro_sell, evaluate(p, in));
    in.trend = .{ .known = true, .daily_close = d("99"), .sma = d("100") };
    try testing.expectEqual(Verdict.allow, evaluate(p, in));
    in.trend = .{ .known = true, .daily_close = d("101"), .sma = d("100") };
    in.target_weight = d("0.5"); // buy
    try testing.expectEqual(Verdict.allow, evaluate(p, in));
    in.target_weight = d("0.3");
    in.macro_driven = false;
    try testing.expectEqual(Verdict.allow, evaluate(p, in));
}

test "forced risk exits are exempt from every guardrail" {
    var in = baseInput();
    in.macro_driven = true;
    in.trend = .{ .known = true, .daily_close = d("101"), .sma = d("100") };
    in.recent = .{ .decisions_24h = 99, .last_side = .buy, .last_ms = in.now_ms };
    in.target_weight = d("0.399");
    try testing.expect(evaluate(.{}, in) != .allow);
    in.exempt = true;
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in));
}

test "underwater sells and full exits skip the relative floor, cap, cooldown and macro gate" {
    var in = baseInput();
    in.macro_driven = true;
    in.trend = .{ .known = true, .daily_close = d("101"), .sma = d("100") };
    in.recent = .{ .decisions_24h = 99, .last_side = .buy, .last_ms = in.now_ms - hour_ms };
    try testing.expect(evaluate(.{}, in) != .allow);
    in.drawdown = d("0.02");
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in));
    in.drawdown = Decimal.zero;
    in.current_weight = d("0.03");
    in.target_weight = Decimal.zero; // 30 USDT residual exit, below the 5% relative floor
    in.macro_driven = false;
    in.recent = .{};
    try testing.expectEqual(Verdict.allow, evaluate(.{}, in));
    var p = Params{};
    p.min_trade_notional = d("50"); // the absolute exchange floor still applies
    try testing.expectEqual(Verdict.block_min_trade, evaluate(p, in));
}

test "held book alert grades headroom against the floor" {
    try testing.expectEqual(HeldAlert.breach, heldAlert(d("-0.01"), d("1000")));
    try testing.expectEqual(HeldAlert.thin, heldAlert(d("10"), d("1000"))); // 1% < 1.5%
    try testing.expectEqual(HeldAlert.ok, heldAlert(d("15"), d("1000"))); // exactly 1.5%
    try testing.expectEqual(HeldAlert.ok, heldAlert(d("40"), d("1000")));
    try testing.expectEqual(HeldAlert.ok, heldAlert(d("5"), Decimal.zero)); // no equity basis: no thin call
}

test "disabled params never block" {
    var in = baseInput();
    in.macro_driven = true;
    in.recent = .{ .decisions_24h = 99, .last_side = .buy, .last_ms = in.now_ms };
    in.target_weight = d("0.399");
    in.trend = .{};
    try testing.expectEqual(Verdict.allow, evaluate(Params.disabled, in));
}

test "trend from closes" {
    var closes: [60]Decimal = undefined;
    for (&closes, 0..) |*c, i| c.* = Decimal.fromInt(@intCast(200 - @as(i64, @intCast(i)))); // newest highest
    const t = trendFromCloses(&closes);
    try testing.expect(t.known);
    try testing.expect(!t.broken());
    try testing.expect(!trendFromCloses(closes[0..49]).known);
    for (&closes, 0..) |*c, i| c.* = Decimal.fromInt(@intCast(100 + @as(i64, @intCast(i)))); // newest lowest
    try testing.expect(trendFromCloses(&closes).broken());
}

test "macro keyword scan" {
    try testing.expect(isMacroDriven(&.{ "technical thesis", "FOMC meeting risk elevated" }));
    try testing.expect(isMacroDriven(&.{"Macro intel is cautionary"}));
    try testing.expect(!isMacroDriven(&.{ "4H close below range low", "funding neutral" }));
}
