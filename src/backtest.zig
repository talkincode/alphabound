//! Deterministic offline backtest: candles + decisions -> Risk Kernel admission
//! -> guardrails -> simulated execution with taker fee and slippage.
//!
//! No daemon, network, clock, RNG or LLM. Same inputs produce byte-identical
//! output. Limitations are listed in `docs/BACKTEST.md` and echoed in the JSON.
const std = @import("std");
const dec = @import("core/decimal.zig");
const admission = @import("risk/admission.zig");
const equity_mod = @import("risk/equity.zig");
const guard = @import("risk/guardrails.zig");

const Decimal = dec.Decimal;
const max_bytes = 64 * 1024 * 1024;
const day_ms = guard.day_ms;

pub const Bar = struct { ts: i64, open: Decimal, close: Decimal };
pub const DailyBar = struct { ts: i64, close: Decimal };
pub const Decision = struct { ts: i64, weight: Decimal, operator: bool = false, macro: bool = false };
pub const Flow = struct { ts: i64, cash: Decimal, btc: Decimal };

pub const SimConfig = struct {
    initial_cash: Decimal = Decimal.fromInt(1000),
    initial_btc: Decimal = Decimal.zero,
    fee_rate: Decimal = Decimal.fromRaw(100_000), // 0.001 taker
    slippage_rate: Decimal = Decimal.fromRaw(50_000), // 0.0005
    max_drawdown: Decimal = Decimal.fromRaw(10_000_000), // 0.10
    exit_reserve: Decimal = Decimal.fromRaw(50_000_000), // 0.50 USDT
    price_shock: Decimal = Decimal.fromRaw(5_000_000), // 0.05
    churn_window_ms: i64 = 2 * guard.hour_ms,
};

pub const Result = struct {
    policy: []const u8,
    start_equity: f64 = 0,
    end_equity: f64 = 0,
    twr_return: f64 = 0,
    hold_return: f64 = 0,
    alpha: f64 = 0,
    max_drawdown: f64 = 0,
    avg_weight: f64 = 0,
    trades: u32 = 0,
    buys: u32 = 0,
    sells: u32 = 0,
    fees_usdt: f64 = 0,
    turnover_usdt: f64 = 0,
    churn_reversals: u32 = 0,
    admission_rejects: u32 = 0,
    blocked_min_trade: u32 = 0,
    blocked_daily_cap: u32 = 0,
    blocked_reverse_cooldown: u32 = 0,
    blocked_macro_sell: u32 = 0,
    stress_breach_bars: u32 = 0,
    floor_breaches: u32 = 0,
    forced_exits: u32 = 0,
    halted: bool = false,
};

const Trade = struct { ts: i64, buy: bool };

fn f(x: Decimal) f64 {
    return x.toF64Lossy();
}

fn drawdownOf(equity: Decimal, hwm: Decimal) Decimal {
    if (!hwm.gt(Decimal.zero) or equity.gte(hwm)) return Decimal.zero;
    const frac = equity.div(hwm, .down) catch return Decimal.one;
    return Decimal.one.sub(frac) catch Decimal.zero;
}

fn conservative(cash: Decimal, btc: Decimal, bid: Decimal, c: SimConfig) !Decimal {
    return (try equity_mod.conservativeEquity(.{
        .cash_usdt = cash,
        .btc_total = btc,
        .liq_price = bid,
        .exit_costs = .{ .fee_rate = c.fee_rate, .slippage_rate = c.slippage_rate },
    })).equity;
}

/// Completed daily closes strictly before `ts`, newest first, into `out`.
fn trendAt(daily: []const DailyBar, ts: i64, out: []Decimal) guard.Trend {
    var hi: usize = 0;
    while (hi < daily.len and daily[hi].ts + day_ms <= ts) hi += 1;
    if (hi < guard.TREND_MA_PERIOD) return .{};
    var n: usize = 0;
    var i = hi;
    while (i > 0 and n < out.len) {
        i -= 1;
        out[n] = daily[i].close;
        n += 1;
    }
    return guard.trendFromCloses(out[0..n]);
}

pub fn run(
    gpa: std.mem.Allocator,
    c: SimConfig,
    name: []const u8,
    params: guard.Params,
    bars: []const Bar,
    daily: []const DailyBar,
    decisions: []const Decision,
    flows: []const Flow,
) !Result {
    var res = Result{ .policy = name };
    if (bars.len < 2) return error.NotEnoughBars;

    var cash = c.initial_cash;
    var btc = c.initial_btc;
    var hwm = try conservative(cash, btc, bars[0].open, c);
    var prev_close_eq = hwm;
    var index: f64 = 1.0;
    var peak: f64 = 1.0;
    var weight_sum: f64 = 0;
    var halted = false;
    var pending_flatten = false;
    var di: usize = 0;
    var fi: usize = 0;
    var trades: std.ArrayList(Trade) = .empty;
    defer trades.deinit(gpa);
    var agent_ts: std.ArrayList(i64) = .empty;
    defer agent_ts.deinit(gpa);
    var closes_buf: [guard.TREND_MA_PERIOD]Decimal = undefined;

    const stress = admission.StressParams{
        .price_shock = c.price_shock,
        .trade_fee_rate = c.fee_rate,
        .trade_slippage_rate = c.slippage_rate,
        .exit_costs = .{ .fee_rate = c.fee_rate, .slippage_rate = c.slippage_rate },
        .exit_reserve = c.exit_reserve,
    };
    res.start_equity = f(prev_close_eq);

    for (bars) |bar| {
        // External capital first: rescale HWM so a deposit is not profit.
        var flow_value = Decimal.zero;
        while (fi < flows.len and flows[fi].ts <= bar.ts) : (fi += 1) {
            const before = try conservative(cash, btc, bar.open, c);
            cash = try cash.add(flows[fi].cash);
            btc = try btc.add(flows[fi].btc);
            const after = try conservative(cash, btc, bar.open, c);
            hwm = try equity_mod.adjustHighWatermarkForFlow(hwm, before, after);
            flow_value = try flow_value.add(try after.sub(before));
        }

        if (pending_flatten and btc.gt(Decimal.zero)) {
            const t = try execute(c, &cash, &btc, bar.open, Decimal.zero, &res);
            if (t) |tr| try trades.append(gpa, .{ .ts = bar.ts, .buy = tr });
            res.forced_exits += 1;
            halted = true;
            pending_flatten = false;
        }

        while (di < decisions.len and decisions[di].ts <= bar.ts) : (di += 1) {
            const dc = decisions[di];
            if (halted) continue;
            const equity_now = try conservative(cash, btc, bar.open, c);
            const snap = admission.SnapshotView{
                .version = 1,
                .reconciled = true,
                .market_fresh = true,
                .account_fresh = true,
                .unresolved_orders = false,
                .risk_mode = .normal,
                .cash_usdt = cash,
                .btc_total = btc,
                .liq_price = bar.open,
                .mark_price = bar.open,
                .high_watermark = hwm,
            };
            const adm = try admission.admit(snap, .{ .snapshot_version = 1, .target_btc_weight = dc.weight }, c.max_drawdown, stress);
            const admitted: Decimal = switch (adm.verdict) {
                .approve => |w| w,
                .approve_reduced => |w| w,
                .reject => {
                    res.admission_rejects += 1;
                    continue;
                },
            };
            const held = try admission.heldExposure(snap, c.max_drawdown, stress);
            if (!dc.operator) {
                // Drop agent trades that left the rolling 24h window.
                var keep: usize = 0;
                for (agent_ts.items) |t| {
                    if (bar.ts - t < day_ms) {
                        agent_ts.items[keep] = t;
                        keep += 1;
                    }
                }
                agent_ts.shrinkRetainingCapacity(keep);
                var recent = guard.Recent{ .decisions_24h = @intCast(agent_ts.items.len) };
                if (trades.items.len > 0) {
                    const last = trades.items[trades.items.len - 1];
                    recent.last_side = if (last.buy) .buy else .sell;
                    recent.last_ms = last.ts;
                }
                const verdict = guard.evaluate(params, .{
                    .now_ms = bar.ts,
                    .equity = equity_now,
                    .drawdown = drawdownOf(equity_now, hwm),
                    .current_weight = held.weight,
                    .target_weight = admitted,
                    .macro_driven = dc.macro,
                    .trend = trendAt(daily, bar.ts, &closes_buf),
                    .recent = recent,
                    .exempt = held.breaches,
                });
                switch (verdict) {
                    .allow => {},
                    .block_min_trade => {
                        res.blocked_min_trade += 1;
                        continue;
                    },
                    .block_daily_cap => {
                        res.blocked_daily_cap += 1;
                        continue;
                    },
                    .block_reverse_cooldown => {
                        res.blocked_reverse_cooldown += 1;
                        continue;
                    },
                    .block_macro_sell => {
                        res.blocked_macro_sell += 1;
                        continue;
                    },
                }
            }
            if (try execute(c, &cash, &btc, bar.open, admitted, &res)) |buy| {
                try trades.append(gpa, .{ .ts = bar.ts, .buy = buy });
                if (!dc.operator) try agent_ts.append(gpa, bar.ts);
            }
        }

        // Mark at the close.
        const eq_mark = try cash.add(try btc.mul(bar.close, .down));
        const eq_cons = try conservative(cash, btc, bar.close, c);
        const base = try prev_close_eq.add(flow_value);
        if (base.gt(Decimal.zero)) index *= f(eq_cons) / f(base);
        prev_close_eq = eq_cons;
        if (index > peak) peak = index;
        const dd = 1.0 - index / peak;
        if (dd > res.max_drawdown) res.max_drawdown = dd;
        hwm = equity_mod.updateHighWatermark(hwm, eq_cons);
        if (eq_mark.gt(Decimal.zero)) weight_sum += f(try btc.mul(bar.close, .down)) / f(eq_mark);

        const snap_close = admission.SnapshotView{
            .version = 1,
            .reconciled = true,
            .market_fresh = true,
            .account_fresh = true,
            .unresolved_orders = false,
            .risk_mode = .normal,
            .cash_usdt = cash,
            .btc_total = btc,
            .liq_price = bar.close,
            .mark_price = bar.close,
            .high_watermark = hwm,
        };
        if (btc.gt(Decimal.zero) and !halted) {
            const held = try admission.heldExposure(snap_close, c.max_drawdown, stress);
            if (held.breaches) res.stress_breach_bars += 1;
            // Mirrors the daemon's hard drawdown boundary: flatten, then stay out.
            if (eq_cons.lt(held.floor)) {
                res.floor_breaches += 1;
                pending_flatten = true;
            }
        }
    }

    const last = bars[bars.len - 1];
    res.end_equity = f(prev_close_eq);
    res.twr_return = index - 1.0;
    res.hold_return = f(last.close) / f(bars[0].open) - 1.0;
    res.alpha = res.twr_return - res.hold_return;
    res.avg_weight = weight_sum / @as(f64, @floatFromInt(bars.len));
    res.halted = halted;
    var i: usize = 1;
    while (i < trades.items.len) : (i += 1) {
        const a = trades.items[i - 1];
        const b = trades.items[i];
        if (a.buy != b.buy and b.ts - a.ts <= c.churn_window_ms) res.churn_reversals += 1;
    }
    return res;
}

/// Trade toward `target_weight`; returns true for a buy, false for a sell, null when nothing traded.
fn execute(c: SimConfig, cash: *Decimal, btc: *Decimal, open: Decimal, target_weight: Decimal, res: *Result) !?bool {
    const btc_value = try btc.mul(open, .down);
    const equity = try cash.add(btc_value);
    const target_value = try equity.mul(target_weight, .down);
    const delta = try target_value.sub(btc_value);
    if (delta.isZero()) return null;
    if (delta.isNegative()) {
        const want = try delta.abs().div(open, .down);
        const qty = Decimal.min(want, btc.*);
        if (!qty.gt(Decimal.zero)) return null;
        const px = try open.mul(try Decimal.one.sub(c.slippage_rate), .down);
        const gross = try qty.mul(px, .down);
        const fee = try gross.mul(c.fee_rate, .up);
        cash.* = try (try cash.add(gross)).sub(fee);
        btc.* = try btc.sub(qty);
        record(res, false, gross, fee);
        return false;
    }
    const k = try Decimal.one.add(try c.fee_rate.add(c.slippage_rate));
    const spend = Decimal.min(delta, try cash.div(k, .down));
    const px = try open.mul(try Decimal.one.add(c.slippage_rate), .up);
    const qty = try spend.div(px, .down);
    if (!qty.gt(Decimal.zero)) return null;
    const gross = try qty.mul(px, .up);
    const fee = try gross.mul(c.fee_rate, .up);
    cash.* = try (try cash.sub(gross)).sub(fee);
    btc.* = try btc.add(qty);
    record(res, true, gross, fee);
    return true;
}

fn record(res: *Result, buy: bool, gross: Decimal, fee: Decimal) void {
    res.trades += 1;
    if (buy) res.buys += 1 else res.sells += 1;
    res.fees_usdt += f(fee);
    res.turnover_usdt += f(gross);
}

// ---------------------------------------------------------------------------
// CSV loading

const CsvError = error{ InvalidLine, InvalidTimestamp, InvalidNumber, NotSorted, EmptyInput, TooManyRows };

fn lineIter(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, text, '\n');
}

fn trimLine(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, " \r\t");
}

fn parseTs(s: []const u8) CsvError!i64 {
    return std.fmt.parseInt(i64, s, 10) catch error.InvalidTimestamp;
}

fn parseDec(s: []const u8) CsvError!Decimal {
    return Decimal.parseLossy(std.mem.trim(u8, s, " ")) catch error.InvalidNumber;
}

fn isHeader(line: []const u8) bool {
    return line.len > 0 and !std.ascii.isDigit(line[0]) and line[0] != '-';
}

/// `ts_ms,close` or OKX-style `ts_ms,open,high,low,close,...` (ascending).
pub fn parseBars(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Bar) {
    var out: std.ArrayList(Bar) = .empty;
    errdefer out.deinit(gpa);
    var it = lineIter(text);
    var prev: i64 = std.math.minInt(i64);
    while (it.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or isHeader(line)) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        const ts = try parseTs(cols.next() orelse return error.InvalidLine);
        var vals: [5]Decimal = undefined;
        var n: usize = 0;
        while (cols.next()) |col| : (n += 1) {
            if (n >= 4) break;
            vals[n] = try parseDec(col);
        }
        if (n == 0) return error.InvalidLine;
        // 1 value: close only. >=4 values: open,high,low,close.
        const open = vals[0];
        const close = if (n >= 4) vals[3] else vals[0];
        if (ts <= prev) return error.NotSorted;
        if (!close.gt(Decimal.zero) or !open.gt(Decimal.zero)) return error.InvalidNumber;
        prev = ts;
        try out.append(gpa, .{ .ts = ts, .open = open, .close = close });
    }
    if (out.items.len == 0) return error.EmptyInput;
    return out;
}

/// Daily bars; a trailing `confirmed` column of 0 marks the still-forming day.
pub fn parseDaily(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(DailyBar) {
    var out: std.ArrayList(DailyBar) = .empty;
    errdefer out.deinit(gpa);
    var it = lineIter(text);
    while (it.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or isHeader(line)) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        const ts = try parseTs(cols.next() orelse return error.InvalidLine);
        var vals: [8]?[]const u8 = [_]?[]const u8{null} ** 8;
        var n: usize = 0;
        while (cols.next()) |col| : (n += 1) {
            if (n >= 8) break;
            vals[n] = col;
        }
        const close_idx: usize = if (n >= 4) 3 else 0;
        const close = try parseDec(vals[close_idx] orelse return error.InvalidLine);
        if (n >= 6) {
            if (vals[5]) |conf| if (std.mem.eql(u8, std.mem.trim(u8, conf, " "), "0")) continue;
        }
        if (out.items.len > 0 and ts <= out.items[out.items.len - 1].ts) return error.NotSorted;
        try out.append(gpa, .{ .ts = ts, .close = close });
    }
    return out;
}

/// `ts_ms,target_weight[,source[,macro_driven]]`; source is `agent` (default) or `operator`.
pub fn parseDecisions(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Decision) {
    var out: std.ArrayList(Decision) = .empty;
    errdefer out.deinit(gpa);
    var it = lineIter(text);
    var prev: i64 = std.math.minInt(i64);
    while (it.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or isHeader(line)) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        const ts = try parseTs(cols.next() orelse return error.InvalidLine);
        const w = try parseDec(cols.next() orelse return error.InvalidLine);
        if (w.isNegative() or w.gt(Decimal.one)) return error.InvalidNumber;
        var dc = Decision{ .ts = ts, .weight = w };
        if (cols.next()) |src| dc.operator = std.mem.eql(u8, std.mem.trim(u8, src, " "), "operator");
        if (cols.next()) |m| dc.macro = std.mem.eql(u8, std.mem.trim(u8, m, " "), "1");
        if (ts < prev) return error.NotSorted;
        prev = ts;
        try out.append(gpa, dc);
    }
    return out;
}

/// `ts_ms,cash_delta,btc_delta`.
pub fn parseFlows(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(Flow) {
    var out: std.ArrayList(Flow) = .empty;
    errdefer out.deinit(gpa);
    var it = lineIter(text);
    while (it.next()) |raw| {
        const line = trimLine(raw);
        if (line.len == 0 or isHeader(line)) continue;
        var cols = std.mem.splitScalar(u8, line, ',');
        const ts = try parseTs(cols.next() orelse return error.InvalidLine);
        const cash = try parseDec(cols.next() orelse return error.InvalidLine);
        const b = try parseDec(cols.next() orelse return error.InvalidLine);
        try out.append(gpa, .{ .ts = ts, .cash = cash, .btc = b });
    }
    return out;
}

/// UTC-day buckets derived from the candle series; the last (partial) day is dropped.
pub fn dailyFromBars(gpa: std.mem.Allocator, bars: []const Bar) !std.ArrayList(DailyBar) {
    var out: std.ArrayList(DailyBar) = .empty;
    errdefer out.deinit(gpa);
    var cur: i64 = -1;
    for (bars) |b| {
        const day = @divFloor(b.ts, day_ms);
        if (day != cur) {
            try out.append(gpa, .{ .ts = day * day_ms, .close = b.close });
            cur = day;
        } else {
            out.items[out.items.len - 1].close = b.close;
        }
    }
    if (out.items.len > 0) _ = out.pop();
    return out;
}

/// Stand-in for the LLM: re-evaluate every `interval_ms`, hold 0.6 above the
/// 50D SMA and 0.2 below. A proxy for the harness, not a model of agent behaviour.
pub fn ruleDecisions(gpa: std.mem.Allocator, bars: []const Bar, daily: []const DailyBar, interval_ms: i64) !std.ArrayList(Decision) {
    var out: std.ArrayList(Decision) = .empty;
    errdefer out.deinit(gpa);
    var buf: [guard.TREND_MA_PERIOD]Decimal = undefined;
    var next_ts = bars[0].ts;
    for (bars) |b| {
        if (b.ts < next_ts) continue;
        next_ts = b.ts + interval_ms;
        const t = trendAt(daily, b.ts, &buf);
        if (!t.known) continue;
        const w = if (t.daily_close.gt(t.sma)) Decimal.fromRaw(60_000_000) else Decimal.fromRaw(20_000_000);
        try out.append(gpa, .{ .ts = b.ts, .weight = w });
    }
    return out;
}

// ---------------------------------------------------------------------------
// Output

const limitations = [_][]const u8{
    "Decisions are replayed, not re-generated: recorded agent decisions did not see the counterfactual book, so vetoing a trade can make later absolute targets act on a different position.",
    "Execution fills at the next bar open plus fixed slippage and 0.1% taker fee; no order book, partial fills, queueing, limit orders or latency.",
    "Bar granularity bounds what is observable: intrabar drawdown and intrabar stress breaches are not seen.",
    "Risk floor and stress use the production admission code; the daemon's state machine (EXIT_ONLY/FLATTENING timing, operator reset) is approximated as flatten-then-halt at the next bar.",
    "Macro flags come from thesis keywords when a thesis was recorded and are absent otherwise; the rule agent has no macro view.",
    "A single sample path: results are evidence for this period only, not a forecast.",
};

fn writeResult(out: *std.Io.Writer, r: Result, last: bool) !void {
    try out.print(
        "    {{\"policy\":\"{s}\",\"start_equity\":{d:.4},\"end_equity\":{d:.4},\"twr_return\":{d:.6},\"hold_return\":{d:.6},\"alpha\":{d:.6}," ++
            "\"max_drawdown\":{d:.6},\"avg_weight\":{d:.4},\"trades\":{d},\"buys\":{d},\"sells\":{d},\"fees_usdt\":{d:.4},\"turnover_usdt\":{d:.2}," ++
            "\"churn_reversals\":{d},\"admission_rejects\":{d},\"blocked\":{{\"min_trade\":{d},\"daily_cap\":{d},\"reverse_cooldown\":{d},\"macro_sell\":{d}}}," ++
            "\"stress_breach_bars\":{d},\"floor_breaches\":{d},\"forced_exits\":{d},\"halted\":{s}}}{s}\n",
        .{
            r.policy,            r.start_equity,             r.end_equity,                      r.twr_return,
            r.hold_return,       r.alpha,                    r.max_drawdown,                    r.avg_weight,
            r.trades,            r.buys,                     r.sells,                           r.fees_usdt,
            r.turnover_usdt,     r.churn_reversals,          r.admission_rejects,               r.blocked_min_trade,
            r.blocked_daily_cap, r.blocked_reverse_cooldown, r.blocked_macro_sell,              r.stress_breach_bars,
            r.floor_breaches,    r.forced_exits,             if (r.halted) "true" else "false", if (last) "" else ",",
        },
    );
}

fn usage() void {
    std.debug.print(
        \\usage: zig build backtest -- --candles FILE [--decisions FILE | --agent rule] [options]
        \\  --candles FILE            ts_ms,close  or  ts_ms,open,high,low,close,...  (ascending)
        \\  --decisions FILE          ts_ms,target_weight[,agent|operator[,macro 0|1]]
        \\  --agent rule              built-in 50D-SMA rule proxy instead of --decisions
        \\  --daily FILE              completed daily bars for the 50D trend (default: derived from candles)
        \\  --flows FILE              ts_ms,cash_delta,btc_delta external capital flows
        \\  --initial-cash N          default 1000
        \\  --initial-btc N           BTC already held at the first bar (default 0)
        \\  --fee R --slippage R      defaults 0.001 / 0.0005
        \\  --min-trade-notional N    baseline/guarded absolute floor (default 10)
        \\  --daily-cap N --cooldown-hours H --min-trade-frac R   guardrail overrides
        \\  --sell-exempt-dd R        sells are never slowed once drawdown >= R (default 0.01)
        \\  --macro-gate              enable the macro-sell trend-break gate (off by default)
        \\  --policy recorded|baseline|guarded|all   default all
        \\  --churn-window-hours H    reversal window (default 2)
        \\
    , .{});
}

const Args = struct {
    candles: ?[]const u8 = null,
    decisions: ?[]const u8 = null,
    daily: ?[]const u8 = null,
    flows: ?[]const u8 = null,
    rule: bool = false,
    policy: []const u8 = "all",
    sim: SimConfig = .{},
    min_notional: Decimal = Decimal.fromInt(10),
    guarded: guard.Params = .{},
};

fn parseArgs(it: *std.process.Args.Iterator) !Args {
    var a = Args{};
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--candles")) {
            a.candles = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--decisions")) {
            a.decisions = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--daily")) {
            a.daily = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--flows")) {
            a.flows = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--agent")) {
            const v = it.next() orelse return error.MissingValue;
            if (!std.mem.eql(u8, v, "rule")) return error.UnknownAgent;
            a.rule = true;
        } else if (std.mem.eql(u8, arg, "--policy")) {
            a.policy = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--initial-btc")) {
            a.sim.initial_btc = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--initial-cash")) {
            a.sim.initial_cash = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--fee")) {
            a.sim.fee_rate = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--slippage")) {
            a.sim.slippage_rate = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--min-trade-notional")) {
            a.min_notional = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--min-trade-frac")) {
            a.guarded.min_trade_equity_frac = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--sell-exempt-dd")) {
            a.guarded.sell_exempt_drawdown = try Decimal.parse(it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--macro-gate")) {
            a.guarded.macro_sell_requires_trend_break = true;
        } else if (std.mem.eql(u8, arg, "--daily-cap")) {
            a.guarded.daily_trade_cap = try std.fmt.parseInt(u32, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--cooldown-hours")) {
            a.guarded.reverse_cooldown_ms = (try std.fmt.parseInt(i64, it.next() orelse return error.MissingValue, 10)) * guard.hour_ms;
        } else if (std.mem.eql(u8, arg, "--churn-window-hours")) {
            a.sim.churn_window_ms = (try std.fmt.parseInt(i64, it.next() orelse return error.MissingValue, 10)) * guard.hour_ms;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArgument;
        }
    }
    a.guarded.min_trade_notional = a.min_notional;
    return a;
}

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    const args = parseArgs(&it) catch |err| {
        if (err == error.HelpRequested) {
            usage();
            return 0;
        }
        std.debug.print("error: {s}\n", .{@errorName(err)});
        usage();
        return 2;
    };
    const candles_path = args.candles orelse {
        usage();
        return 2;
    };
    if ((args.decisions == null) == !args.rule) {
        std.debug.print("error: pass exactly one of --decisions or --agent rule\n", .{});
        return 2;
    }
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();

    const ctext = try cwd.readFileAlloc(init.io, candles_path, gpa, .limited(max_bytes));
    defer gpa.free(ctext);
    var bars = try parseBars(gpa, ctext);
    defer bars.deinit(gpa);

    var daily = if (args.daily) |p| blk: {
        const t = try cwd.readFileAlloc(init.io, p, gpa, .limited(max_bytes));
        defer gpa.free(t);
        break :blk try parseDaily(gpa, t);
    } else try dailyFromBars(gpa, bars.items);
    defer daily.deinit(gpa);

    var decisions = if (args.decisions) |p| blk: {
        const t = try cwd.readFileAlloc(init.io, p, gpa, .limited(max_bytes));
        defer gpa.free(t);
        break :blk try parseDecisions(gpa, t);
    } else try ruleDecisions(gpa, bars.items, daily.items, 4 * guard.hour_ms);
    defer decisions.deinit(gpa);

    var flows: std.ArrayList(Flow) = .empty;
    defer flows.deinit(gpa);
    if (args.flows) |p| {
        const t = try cwd.readFileAlloc(init.io, p, gpa, .limited(max_bytes));
        defer gpa.free(t);
        flows = try parseFlows(gpa, t);
    }

    var baseline_params = guard.Params.disabled;
    baseline_params.min_trade_notional = args.min_notional;
    const specs = [_]struct { name: []const u8, p: guard.Params }{
        .{ .name = "recorded", .p = guard.Params.disabled },
        .{ .name = "baseline", .p = baseline_params },
        .{ .name = "guarded", .p = args.guarded },
    };

    var buffer: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &fw.interface;
    try out.print("{{\n  \"tool\":\"alphabound-backtest\",\n  \"bars\":{d},\"decisions\":{d},\"flows\":{d},\n", .{ bars.items.len, decisions.items.len, flows.items.len });
    try out.print("  \"period_ms\":[{d},{d}],\n  \"fee_rate\":\"{d:.4}\",\"slippage_rate\":\"{d:.4}\",\n  \"results\":[\n", .{
        bars.items[0].ts, bars.items[bars.items.len - 1].ts, f(args.sim.fee_rate), f(args.sim.slippage_rate),
    });
    var emitted: usize = 0;
    var total: usize = 0;
    for (specs) |s| {
        if (std.mem.eql(u8, args.policy, "all") or std.mem.eql(u8, args.policy, s.name)) total += 1;
    }
    for (specs) |s| {
        if (!(std.mem.eql(u8, args.policy, "all") or std.mem.eql(u8, args.policy, s.name))) continue;
        const r = try run(gpa, args.sim, s.name, s.p, bars.items, daily.items, decisions.items, flows.items);
        emitted += 1;
        try writeResult(out, r, emitted == total);
    }
    if (total == 0) {
        std.debug.print("error: unknown --policy {s}\n", .{args.policy});
        return 2;
    }
    try out.writeAll("  ],\n  \"limitations\":[\n");
    for (limitations, 0..) |l, i| {
        try out.print("    \"{s}\"{s}\n", .{ l, if (i + 1 == limitations.len) "" else "," });
    }
    try out.writeAll("  ]\n}\n");
    try out.flush();
    return 0;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

fn synthBars(gpa: std.mem.Allocator, n: usize, f_price: *const fn (usize) i64) !std.ArrayList(Bar) {
    var out: std.ArrayList(Bar) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = Decimal.fromInt(f_price(i));
        try out.append(gpa, .{ .ts = @as(i64, @intCast(i)) * 15 * 60_000, .open = p, .close = p });
    }
    return out;
}

fn flatPrice(_: usize) i64 {
    return 100;
}

fn wavePrice(i: usize) i64 {
    return if (i % 2 == 0) 100 else 101;
}

test "flat market: fees are the only loss, and fees are exactly 0.1% of notional" {
    const gpa = testing.allocator;
    var bars = try synthBars(gpa, 40, flatPrice);
    defer bars.deinit(gpa);
    const decs = [_]Decision{.{ .ts = 0, .weight = d("0.5") }};
    const r = try run(gpa, .{ .slippage_rate = Decimal.zero }, "t", guard.Params.disabled, bars.items, &.{}, &decs, &.{});
    try testing.expectEqual(@as(u32, 1), r.trades);
    try testing.expectApproxEqAbs(r.turnover_usdt * 0.001, r.fees_usdt, 1e-6);
    try testing.expect(r.twr_return < 0);
    try testing.expectApproxEqAbs(@as(f64, 0), r.hold_return, 1e-12);
}

test "deterministic: two runs are identical" {
    const gpa = testing.allocator;
    var bars = try synthBars(gpa, 60, wavePrice);
    defer bars.deinit(gpa);
    const decs = [_]Decision{ .{ .ts = 0, .weight = d("0.4") }, .{ .ts = 20 * 15 * 60_000, .weight = d("0.1") } };
    const a = try run(gpa, .{}, "t", guard.Params.disabled, bars.items, &.{}, &decs, &.{});
    const b = try run(gpa, .{}, "t", guard.Params.disabled, bars.items, &.{}, &decs, &.{});
    try testing.expectEqualDeep(a, b);
}

test "guardrails veto churn: alternating decisions are cut by the cooldown and the cap" {
    const gpa = testing.allocator;
    var bars = try synthBars(gpa, 200, wavePrice);
    defer bars.deinit(gpa);
    var decs: std.ArrayList(Decision) = .empty;
    defer decs.deinit(gpa);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try decs.append(gpa, .{ .ts = @as(i64, @intCast(i)) * 15 * 60_000, .weight = if (i % 2 == 0) d("0.5") else d("0.1") });
    }
    const loose = try run(gpa, .{}, "loose", guard.Params.disabled, bars.items, &.{}, decs.items, &.{});
    const tight = try run(gpa, .{}, "tight", .{}, bars.items, &.{}, decs.items, &.{});
    try testing.expect(loose.trades > tight.trades);
    try testing.expect(loose.fees_usdt > tight.fees_usdt);
    try testing.expect(tight.blocked_reverse_cooldown > 0);
    try testing.expect(tight.churn_reversals < loose.churn_reversals);
}

test "hard drawdown boundary still flattens under guardrails" {
    const gpa = testing.allocator;
    var bars: std.ArrayList(Bar) = .empty;
    defer bars.deinit(gpa);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const p: i64 = if (i < 5) 100 else 100 - @as(i64, @intCast(i - 5)) * 3;
        try bars.append(gpa, .{ .ts = @as(i64, @intCast(i)) * 15 * 60_000, .open = Decimal.fromInt(@max(p, 1)), .close = Decimal.fromInt(@max(p, 1)) });
    }
    const decs = [_]Decision{.{ .ts = 0, .weight = d("0.9") }};
    const r = try run(gpa, .{}, "t", .{}, bars.items, &.{}, &decs, &.{});
    try testing.expect(r.forced_exits == 1);
    try testing.expect(r.halted);
}

test "csv parsing" {
    const gpa = testing.allocator;
    var bars = try parseBars(gpa, "ts_ms,open,high,low,close,volume\n1000,10,11,9,10.5,1\n2000,10.5,11,10,10.2,1\n");
    defer bars.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), bars.items.len);
    try testing.expect(bars.items[0].close.eql(d("10.5")));
    try testing.expectError(error.NotSorted, parseBars(gpa, "2000,1\n1000,1\n"));
    var decs = try parseDecisions(gpa, "ts_ms,target_weight,source,macro_driven\n1,0.3,agent,1\n2,0.2,operator,0\n");
    defer decs.deinit(gpa);
    try testing.expect(decs.items[0].macro and !decs.items[0].operator);
    try testing.expect(decs.items[1].operator);
    try testing.expectError(error.InvalidNumber, parseDecisions(gpa, "1,1.5\n"));
}
