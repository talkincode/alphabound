//! Demo/live order execution chain (venue: OKX).
//!
//! Flow: tryDemoExecute → admit leg → persist intent → place → verify → settle
//! (poll / cancel-and-confirm) → authoritative refresh → re-admit next leg.
//!
//! Invariants (fail-closed, never blind-resend):
//!  * No order is sent before its PLANNED intent row is durable.
//!  * A write whose outcome is unknown is queried, never repeated; "the venue
//!    says it does not know the order" is an observation, not a cancellation.
//!  * A leg is terminal (filled / canceled-with-confirmation) before the next
//!    leg; every leg is admitted again on a fresh authoritative snapshot.
//!  * Local fill projections use the verified fill, never the order size, and
//!    never count as authoritative account data.
//!  * `unresolved_orders` mirrors the ledger: it clears only when no order row
//!    is left in a non-terminal state.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const state = @import("../core/state.zig");
const clock = @import("../core/clock.zig");
const config = @import("../config.zig");
const storage = @import("../storage/db.zig");
const okx_rest = @import("../exchange/okx/rest.zig");
const okx_trade = @import("okx_trade.zig");
const orders = @import("orders.zig");
const planner = @import("planner.zig");
const proposal = @import("../agent/proposal.zig");
const gate = @import("../risk/gate.zig");
const journal = @import("../observability/journal.zig");

const Decimal = dec.Decimal;
const logEventPayload = journal.logEventPayload;

pub const PortfolioRefresher = struct {
    context: *anyopaque,
    run_fn: *const fn (context: *anyopaque) bool,

    pub fn run(self: PortfolioRefresher) bool {
        return self.run_fn(self.context);
    }
};

pub const Timing = struct {
    /// Pause between verification queries while an order's state is unknown.
    query_retry_ms: u32 = 250,
    /// Verification queries after an uncertain outcome (bounded, never open-ended).
    query_attempts: u8 = 4,
    /// Cancel requests before a leg gives up and leaves the order unresolved.
    cancel_attempts: u8 = 3,
    /// Poll period while a limit order rests.
    poll_ms: u32 = 250,
    /// "Venue does not know this order" may be visibility lag for this long.
    absent_grace_ms: i64 = 60_000,
};

/// Process-wide timing; tests shrink it, production keeps the defaults.
pub var timing = Timing{};

pub const Intent = enum {
    /// Normal rebalance toward an admitted target weight.
    rebalance,
    /// FLATTENING / EXIT_ONLY risk exit: sell-only, gated by `exitAdmit`.
    emergency_exit,
};

pub const Options = struct {
    /// Target weight the caller originally requested; later legs are
    /// re-admitted against it on fresh snapshots. Defaults to the admitted weight.
    requested_weight: ?Decimal = null,
    intent: Intent = .rebalance,
    /// Set by the owner to stop waiting: the working order is canceled and
    /// confirmed, then execution returns.
    abort: ?*const std.atomic.Value(bool) = null,
};

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

fn decFmt(buf: []u8, v: Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

/// Borrowed handles for one execution pass.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    db: *storage.Db,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    abort: ?*const std.atomic.Value(bool) = null,

    fn aborted(self: *const Ctx) bool {
        const a = self.abort orelse return false;
        return a.load(.acquire);
    }

    fn sleepMs(self: *const Ctx, ms: u32) void {
        self.okx.http.io.sleep(.{ .nanoseconds = @as(i96, ms) * 1_000_000 }, .awake) catch {};
    }

    fn event(self: *const Ctx, event_type: []const u8, severity: []const u8, payload: []const u8) void {
        logEventPayload(self.events_repo, self.engine, event_type, "execution", severity, self.cfg, payload);
    }

    fn setAmbiguity(self: *const Ctx, present: bool) void {
        self.engine.submitSync(.{ .order_ambiguity = .{ .present = present } }, self.okx.http.io);
    }

    fn setLedger(self: *const Ctx, ok: bool) void {
        if (self.engine.snapshot().ledger_ok == ok) return;
        self.engine.submitSync(.{ .ledger_status = .{ .ok = ok } }, self.okx.http.io);
    }

    /// Number of order rows whose final state is not on record; null = ledger unreadable.
    fn openOrderCount(self: *const Ctx) ?usize {
        var rows: [8]storage.OpenOrderRow = undefined;
        return self.orders_repo.listNonTerminal(self.db, &rows) catch null;
    }

    /// Make the engine's ambiguity flag mirror the ledger.
    fn syncAmbiguity(self: *const Ctx) bool {
        const open = self.openOrderCount();
        const present = open == null or open.? > 0;
        self.setAmbiguity(present);
        return present;
    }
};

pub const ObsKind = enum {
    filled,
    partial,
    /// Resting, nothing filled yet.
    working,
    canceled,
    rejected,
    /// The venue says it does not know the order.
    absent,
    /// No usable answer (transport, throttling, auth, malformed).
    unverified,
};

pub const Observation = struct {
    kind: ObsKind = .unverified,
    /// Cumulative execution as the venue reports it.
    cum_qty: Decimal = Decimal.zero,
    avg_px: Decimal = Decimal.zero,
    fee: Decimal = Decimal.zero,
    fee_ccy_buf: [12]u8 = undefined,
    fee_ccy_len: usize = 0,
    /// Progress reached the ledger (order row and fill tranche).
    durable: bool = true,

    pub fn feeCcy(self: *const Observation) []const u8 {
        return self.fee_ccy_buf[0..self.fee_ccy_len];
    }

    pub fn isTerminal(self: Observation) bool {
        return self.kind == .filled or self.kind == .canceled or self.kind == .rejected;
    }
};

/// What the ledger knows about the order being observed.
pub const OrderRef = struct {
    cl_id: []const u8,
    decision_id: []const u8,
    side: []const u8,
    qty_s: []const u8,
    price_s: []const u8,
    created_ts: []const u8,
    created_ms: i64,
    /// False for orders this process did not place (cancel-all of foreign orders).
    persist: bool = true,
};

fn persistOrder(ctx: *const Ctx, ref: OrderRef, status: orders.OrderStatus, exchange_id: []const u8, price_s: []const u8) bool {
    if (!ref.persist) return true;
    var ts_buf: [32]u8 = undefined;
    const ts = clock.formatRfc3339Ms(nowMs(), &ts_buf) catch ref.created_ts;
    ctx.orders_repo.upsert(.{
        .client_order_id = ref.cl_id,
        .exchange_order_id = exchange_id,
        .decision_id = ref.decision_id,
        .side = ref.side,
        .qty = ref.qty_s,
        .price = price_s,
        .status = status.jsonName(),
        .created_ts = ref.created_ts,
        .updated_ts = ts,
    }) catch |err| {
        std.debug.print("[exec] order ledger write failed: {t}\n", .{err});
        var buf: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{{\"clOrdId\":\"{s}\",\"status\":\"{s}\",\"reason\":\"order_row_write_failed\"}}", .{ ref.cl_id, status.jsonName() }) catch "{}";
        ctx.event("ORDER_PERSIST_FAILED", "CRITICAL", p);
        ctx.setLedger(false);
        return false;
    };
    return true;
}

/// One verification query. Only a parsed venue answer changes order state.
pub fn observeOnce(ctx: *const Ctx, ref: OrderRef) Observation {
    var path_buf: [192]u8 = undefined;
    const path = okx_trade.formatQueryPath(&path_buf, ctx.cfg.instrument, ref.cl_id) catch return .{};
    const body = ctx.okx.getPrivate(path, nowMs()) catch return .{};
    defer ctx.gpa.free(body);

    const q = switch (okx_rest.lookupOrder(ctx.gpa, body)) {
        .absent => return .{ .kind = .absent },
        .failed => {
            var buf: [160]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{{\"clOrdId\":\"{s}\",\"token\":\"{s}\"}}", .{ ref.cl_id, okx_rest.classifyErrorBody(body) }) catch "{}";
            ctx.event("ORDER_QUERY_UNVERIFIED", "WARN", p);
            return .{};
        },
        .found => |q| q,
    };

    const st = okx_trade.mapOkxState(q.status());
    if (st == .unknown) return .{};

    var obs = Observation{
        .cum_qty = q.filled_qty,
        .avg_px = q.avg_price,
        .fee = q.fee,
    };
    const ccy = if (q.feeCcy().len > 0) q.feeCcy() else "USDT";
    @memcpy(obs.fee_ccy_buf[0..ccy.len], ccy);
    obs.fee_ccy_len = ccy.len;
    obs.kind = switch (st) {
        .filled => .filled,
        .partial => .partial,
        .canceled => .canceled,
        .rejected => .rejected,
        else => if (q.filled_qty.gt(Decimal.zero)) .partial else .working,
    };

    var fill_buf: [48]u8 = undefined;
    const fill_s = decFmt(&fill_buf, q.filled_qty);
    var avg_buf: [48]u8 = undefined;
    const avg_s = if (q.avg_price.gt(Decimal.zero)) decFmt(&avg_buf, q.avg_price) else ref.price_s;
    const row_ok = persistOrder(ctx, ref, st, q.exchangeOrderId(), avg_s);

    var fills_ok = true;
    if (q.filled_qty.gt(Decimal.zero) and ref.persist) {
        var ts_buf: [32]u8 = undefined;
        const ts = clock.formatRfc3339Ms(nowMs(), &ts_buf) catch ref.created_ts;
        _ = ctx.fills_repo.applyCumulative(ctx.db, .{
            .order_id = ref.cl_id,
            .cum_qty = q.filled_qty,
            .avg_price = q.avg_price,
            .cum_fee = q.fee,
            .fee_ccy = ccy,
            .ts = ts,
        }) catch |err| {
            fills_ok = false;
            std.debug.print("[exec] fill projection write failed: {t}\n", .{err});
            var fbuf: [160]u8 = undefined;
            const fp = std.fmt.bufPrint(&fbuf, "{{\"clOrdId\":\"{s}\",\"reason\":\"fill_row_write_failed\"}}", .{ref.cl_id}) catch "{}";
            ctx.event("FILL_PROJECTION_FAILED", "WARN", fp);
            ctx.setLedger(false);
        };
    }
    obs.durable = row_ok and fills_ok;

    var pbuf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"okx_state\":\"{s}\",\"status\":\"{s}\",\"filled\":\"{s}\",\"avgPx\":\"{s}\"}}",
        .{ ref.cl_id, q.status(), st.jsonName(), fill_s, avg_s },
    ) catch "{}";
    ctx.event("ORDER_QUERY", "INFO", payload);
    return obs;
}

/// Bounded verification: stops at the first venue statement about the order
/// that is not "unknown to me" (found), otherwise reports the last outcome.
pub fn observeBounded(ctx: *const Ctx, ref: OrderRef) Observation {
    var last = Observation{};
    var i: u8 = 0;
    while (i < timing.query_attempts) : (i += 1) {
        last = observeOnce(ctx, ref);
        switch (last.kind) {
            .absent, .unverified => {},
            else => return last,
        }
        if (i + 1 < timing.query_attempts) ctx.sleepMs(timing.query_retry_ms);
    }
    return last;
}

fn cancelOnce(ctx: *const Ctx, cl_id: []const u8, reason: []const u8) okx_rest.CancelOutcome {
    var cbuf: [192]u8 = undefined;
    const cbody = okx_trade.formatCancelBody(&cbuf, .{
        .inst_id = ctx.cfg.instrument,
        .client_order_id = cl_id,
    }) catch return .unknown;
    const outcome: okx_rest.CancelOutcome = blk: {
        const resp = ctx.okx.postPrivate("/api/v5/trade/cancel-order", cbody, nowMs()) catch break :blk .unknown;
        defer ctx.gpa.free(resp);
        break :blk okx_rest.classifyCancelResponse(ctx.gpa, resp);
    };
    var pbuf: [224]u8 = undefined;
    const p = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"reason\":\"{s}\",\"outcome\":\"{t}\"}}",
        .{ cl_id, reason, outcome },
    ) catch "{}";
    ctx.event("ORDER_CANCEL_SENT", "INFO", p);
    return outcome;
}

/// Cancel and keep verifying until the order is terminal or attempts run out.
/// The cancel response is only a hint; the query decides.
fn cancelAndConfirm(ctx: *const Ctx, ref: OrderRef, reason: []const u8) Observation {
    var obs = Observation{};
    var attempt: u8 = 0;
    while (attempt < timing.cancel_attempts) : (attempt += 1) {
        _ = cancelOnce(ctx, ref.cl_id, reason);
        obs = observeBounded(ctx, ref);
        if (obs.isTerminal()) return obs;
        ctx.sleepMs(timing.query_retry_ms);
    }
    var pbuf: [160]u8 = undefined;
    const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\",\"reason\":\"{s}\"}}", .{ ref.cl_id, reason }) catch "{}";
    ctx.event("ORDER_CANCEL_UNCONFIRMED", "CRITICAL", p);
    return obs;
}

const Settled = struct {
    obs: Observation,
    timed_out: bool = false,
};

/// Drive a freshly accepted (or uncertain) order to a terminal state.
fn settle(ctx: *const Ctx, ref: OrderRef, prefer_limit: bool, max_wait_ms: u32) Settled {
    var obs = observeBounded(ctx, ref);
    var timed_out = false;
    if (obs.kind == .working and prefer_limit) {
        const wait_cap_ms: u32 = if (max_wait_ms == 0) 30_000 else @min(max_wait_ms, 300_000);
        const deadline = nowMs() + @as(i64, wait_cap_ms);
        while (true) {
            if (ctx.aborted()) break;
            if (nowMs() >= deadline) {
                timed_out = true;
                break;
            }
            ctx.sleepMs(timing.poll_ms);
            const next = observeOnce(ctx, ref);
            switch (next.kind) {
                .unverified, .absent => continue,
                .working => {
                    obs = next;
                    continue;
                },
                else => {
                    obs = next;
                    break;
                },
            }
        }
    }
    if (obs.kind == .working or obs.kind == .partial) {
        const reason: []const u8 = if (ctx.aborted()) "aborted" else if (timed_out) "max_wait_ms" else "partial_remainder";
        obs = cancelAndConfirm(ctx, ref, reason);
    }
    return .{ .obs = obs, .timed_out = timed_out };
}

fn legNote(s: Settled) []const u8 {
    return switch (s.obs.kind) {
        .filled => "filled",
        .canceled => if (s.obs.cum_qty.gt(Decimal.zero)) "partial" else if (s.timed_out) "limit_timeout" else "canceled",
        .rejected => "rejected",
        .working, .partial => "cancel_unconfirmed",
        .absent, .unverified => "unverified",
    };
}

/// Project the verified fill of one leg onto the engine book when the venue
/// balance could not confirm it. Never fresh, never advances the HWM.
fn projectFill(ctx: *const Ctx, side: orders.Side, obs: Observation) void {
    if (!obs.cum_qty.gt(Decimal.zero) or !obs.avg_px.gt(Decimal.zero)) return;
    const s0 = ctx.engine.snapshot();
    const qty = obs.cum_qty;
    const notional = qty.mul(obs.avg_px, .up) catch return;
    const usdt_fee = if (std.mem.eql(u8, obs.feeCcy(), "USDT")) obs.fee else Decimal.zero;
    const btc_fee = if (std.mem.eql(u8, obs.feeCcy(), "BTC")) obs.fee else Decimal.zero;
    var cash = s0.cash_usdt;
    var btc = s0.btc_total;
    var avail = s0.btc_available;
    switch (side) {
        .buy => {
            cash = (cash.sub(notional) catch return).sub(usdt_fee) catch return;
            const got = qty.sub(btc_fee) catch return;
            btc = btc.add(got) catch return;
            avail = avail.add(got) catch return;
        },
        .sell => {
            cash = (cash.add(notional) catch return).sub(usdt_fee) catch return;
            const gone = qty.add(btc_fee) catch return;
            btc = btc.sub(gone) catch return;
            avail = avail.sub(gone) catch return;
        },
    }
    cash = Decimal.max(cash, Decimal.zero);
    btc = Decimal.max(btc, Decimal.zero);
    avail = Decimal.min(Decimal.max(avail, Decimal.zero), btc);
    ctx.engine.submitSync(.{ .account_projection = .{
        .ts_ms = nowMs(),
        .cash_usdt = cash,
        .btc_total = btc,
        .btc_available = avail,
    } }, ctx.okx.http.io);
}

const Leg = struct {
    note: []const u8,
    obs: Observation = .{},
};

pub fn tryDemoExecute(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    db: *storage.Db,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    portfolio_refresher: PortfolioRefresher,
    decision_id: []const u8,
    verdict_txt: []const u8,
    admitted_weight: Decimal,
    instrument: planner.Instrument,
    snap_in: state.PortfolioState,
    order_policy: proposal.OrderPolicy,
    opts: Options,
) []const u8 {
    const exit_mode = opts.intent == .emergency_exit;
    if (!exit_mode and !std.mem.eql(u8, verdict_txt, "APPROVE") and !std.mem.eql(u8, verdict_txt, "REDUCE")) {
        return "skipped_reject";
    }
    const ctx = Ctx{
        .gpa = gpa,
        .okx = okx,
        .cfg = cfg,
        .engine = engine,
        .db = db,
        .orders_repo = orders_repo,
        .fills_repo = fills_repo,
        .events_repo = events_repo,
        .abort = opts.abort,
    };

    // LIMIT_ONLY → limit legs; LIMIT_OR_MARKET → market (demo default, fast fill).
    const prefer_limit = !exit_mode and order_policy.type == .limit_only;
    const requested = opts.requested_weight orelse admitted_weight;
    const max_legs = okx_trade.max_replan_legs;
    var seq: u16 = 0;
    var last_note: []const u8 = "plan_hold";
    var snap = snap_in;
    var weight = admitted_weight;
    var first_side: ?orders.Side = null;
    var any_fill = false;
    var last_filled = false;

    while (seq < max_legs) : (seq += 1) {
        if (ctx.aborted()) {
            ctx.event("EXEC_ABORTED", "WARN", "{\"phase\":\"before_leg\"}");
            return if (any_fill) "partial_aborted" else "aborted";
        }
        // Never stack a new order on one whose outcome the ledger does not know.
        if (ctx.openOrderCount()) |open| {
            if (open > 0) {
                ctx.setAmbiguity(true);
                ctx.event("EXEC_BLOCKED", "WARN", "{\"reason\":\"unresolved_orders_in_ledger\"}");
                return if (any_fill) (if (last_filled) "filled_unresolved_orders" else "partial_unresolved_orders") else "unresolved_orders";
            }
        } else {
            ctx.setAmbiguity(true);
            return "ledger_unreadable";
        }

        var sell_cap: ?Decimal = null;
        if (exit_mode) {
            switch (gate.exitAdmit(snap, nowMs())) {
                .approve => |a| sell_cap = a.max_sell_qty,
                .reject => |r| {
                    var pbuf: [160]u8 = undefined;
                    const p = std.fmt.bufPrint(&pbuf, "{{\"seq\":{d},\"reason\":\"{s}\"}}", .{ seq, @tagName(r) }) catch "{}";
                    ctx.event("EXEC_EXIT_REJECTED", "WARN", p);
                    return if (any_fill) (if (last_filled) "filled_exit_rejected" else "partial_exit_rejected") else "skipped_exit_reject";
                },
            }
            weight = Decimal.zero;
        } else if (seq > 0) {
            // Every later leg is a new risk decision on a fresh snapshot.
            const adm = gate.shadowAdmit(snap, snap.version, requested, cfg, nowMs());
            if (!std.mem.eql(u8, adm.verdict_txt, "APPROVE") and !std.mem.eql(u8, adm.verdict_txt, "REDUCE")) {
                var pbuf: [200]u8 = undefined;
                const p = std.fmt.bufPrint(&pbuf, "{{\"seq\":{d},\"verdict\":\"{s}\",\"reason\":\"{s}\"}}", .{ seq, adm.verdict_txt, adm.reason_txt }) catch "{}";
                ctx.event("EXEC_REPLAN_REJECTED", "WARN", p);
                return if (last_filled) "filled_readmit_rejected" else "partial_readmit_rejected";
            }
            weight = adm.admitted_weight;
        }

        const mark = if (snap.mark_price.gt(Decimal.zero)) snap.mark_price else snap.bid_price;
        const equity = if (snap.conservative_equity.gt(Decimal.zero))
            snap.conservative_equity
        else
            snap.cash_usdt;

        const planned = planner.plan(.{
            .cash_usdt = snap.cash_usdt,
            .btc_total = snap.btc_total,
            .equity = equity,
            .mark_price = mark,
            .admitted_btc_weight = weight,
            .instrument = instrument,
            // Band only gates the opening leg; seq>0 legs finish an already
            // admitted delta after partial fills.
            .min_weight_delta = if (seq == 0 and !exit_mode) cfg.min_rebalance_weight_delta else Decimal.zero,
            .max_sell_qty = sell_cap,
        }) catch return if (seq == 0) "plan_error" else last_note;

        const po = switch (planned) {
            .hold => {
                if (seq == 0) {
                    logEventPayload(events_repo, engine, "EXEC_HOLD", "execution", "INFO", cfg, "{\"reason\":\"dust_or_zero_delta\"}");
                    return "plan_hold";
                }
                // Residual below instrument mins after partial(s).
                logEventPayload(events_repo, engine, "EXEC_REPLAN_HOLD", "execution", "INFO", cfg, "{\"reason\":\"residual_dust\"}");
                return if (any_fill) "partial_then_hold" else last_note;
            },
            .order => |o| o,
        };
        if (exit_mode and po.side != .sell) return "exit_buy_refused";
        if (first_side) |fs| {
            if (fs != po.side) {
                ctx.event("EXEC_REPLAN_REJECTED", "WARN", "{\"reason\":\"direction_flip\"}");
                return if (last_filled) "filled_direction_flip" else "partial_direction_flip";
            }
        }
        first_side = po.side;

        if (seq > 0) {
            var rbuf: [192]u8 = undefined;
            var qbuf: [48]u8 = undefined;
            const q_s = decFmt(&qbuf, po.qty);
            const rp = std.fmt.bufPrint(
                &rbuf,
                "{{\"decision_id\":\"{s}\",\"seq\":{d},\"side\":\"{s}\",\"qty\":\"{s}\"}}",
                .{ decision_id, seq, po.side.jsonName(), q_s },
            ) catch "{\"replan\":true}";
            ctx.event("EXEC_REPLAN", "INFO", rp);
            std.debug.print("[exec] replan leg={d} side={s} qty={s}\n", .{ seq, po.side.jsonName(), q_s });
        }

        const pre_btc = snap.btc_total;
        const leg = placeLeg(
            &ctx,
            decision_id,
            snap.version,
            seq,
            po,
            mark,
            instrument,
            prefer_limit,
            order_policy.urgency,
            order_policy.max_wait_ms,
        );
        last_note = leg.note;

        if (okx_trade.wantsResidualPlan(leg.note)) {
            any_fill = true;
            last_filled = std.mem.eql(u8, leg.note, "filled");
            // Authoritative venue balances required before another leg. If the
            // refresh fails, project the *verified* fill once and STOP — never
            // replan on a stale book (that path triple-bought after API blips).
            if (!portfolio_refresher.run()) {
                projectFill(&ctx, po.side, leg.obs);
                ctx.event("EXEC_REFRESH_FAILED", "WARN", "{\"action\":\"stop_replan_projected_fill\"}");
                _ = ctx.syncAmbiguity();
                return if (last_filled) "filled_refresh_failed" else "partial_refresh_failed";
            }
            snap = engine.snapshot();
            // If the venue book did not move in the trade direction after a
            // confirmed fill, the balance feed is lagging/wrong — stop rather
            // than replan the same delta again (idempotency guard).
            if (!okx_trade.bookMoved(po.side, pre_btc, snap.btc_total)) {
                projectFill(&ctx, po.side, leg.obs);
                ctx.event("EXEC_BOOK_LAG", "WARN", "{\"action\":\"stop_replan_stale_book\"}");
                _ = ctx.syncAmbiguity();
                return if (last_filled) "filled_book_lag" else "partial_book_lag";
            }
            if (last_filled) {
                // If residual is dust, done; else continue for another leg.
                const mark2 = if (snap.mark_price.gt(Decimal.zero)) snap.mark_price else snap.bid_price;
                const eq2 = if (snap.conservative_equity.gt(Decimal.zero)) snap.conservative_equity else snap.cash_usdt;
                const more = planner.plan(.{
                    .cash_usdt = snap.cash_usdt,
                    .btc_total = snap.btc_total,
                    .equity = eq2,
                    .mark_price = mark2,
                    .admitted_btc_weight = weight,
                    .instrument = instrument,
                    .max_sell_qty = if (exit_mode) snap.btc_available else null,
                }) catch break;
                if (more == .hold) return "filled";
            }
            if (!okx_trade.canPlaceAnotherLeg(seq)) break;
            continue;
        }
        // Terminal non-success or ambiguous — stop (fail-closed, no blind resend).
        return leg.note;
    }

    if (any_fill and std.mem.eql(u8, last_note, "partial")) return "partial_max_legs";
    return last_note;
}

/// Single place + settle leg. `seq` differentiates client_order_id on replans.
/// When `prefer_limit`, posts a limit at urgency-adjusted mark (tick-snapped).
fn placeLeg(
    ctx: *const Ctx,
    decision_id: []const u8,
    snap_version: u64,
    seq: u16,
    po: planner.PlannedOrder,
    mark: Decimal,
    instrument: planner.Instrument,
    prefer_limit: bool,
    urgency: Decimal,
    max_wait_ms: u32,
) Leg {
    var cl_buf: [32]u8 = undefined;
    const cl_id = orders.clientOrderId(&cl_buf, decision_id, snap_version, seq);

    var px_opt: ?Decimal = null;
    if (prefer_limit) {
        const max_passive = Decimal.parse("0.001") catch Decimal.zero; // 10 bps
        px_opt = planner.limitPriceFromMark(mark, instrument.tick_size, po.side, urgency, max_passive) catch null;
        if (px_opt == null) return .{ .note = "limit_price_error" };
    }

    var body_buf: [384]u8 = undefined;
    const body = blk: {
        if (px_opt) |px| {
            break :blk okx_trade.formatPlaceLimitBody(&body_buf, .{
                .inst_id = ctx.cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .price = px,
                .client_order_id = cl_id,
            }) catch return .{ .note = "body_error" };
        } else {
            break :blk okx_trade.formatPlaceMarketBody(&body_buf, .{
                .inst_id = ctx.cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .client_order_id = cl_id,
            }) catch return .{ .note = "body_error" };
        }
    };

    var qty_buf: [48]u8 = undefined;
    const qty_s = decFmt(&qty_buf, po.qty);
    var price_buf: [48]u8 = undefined;
    const price_s: []const u8 = if (px_opt) |px| decFmt(&price_buf, px) else "market";
    const ts_now = nowMs();
    var ts_buf: [32]u8 = undefined;
    const ts = clock.formatRfc3339Ms(ts_now, &ts_buf) catch return .{ .note = "ts_error" };

    const ref = OrderRef{
        .cl_id = cl_id,
        .decision_id = decision_id,
        .side = po.side.jsonName(),
        .qty_s = qty_s,
        .price_s = price_s,
        .created_ts = ts,
        .created_ms = ts_now,
    };

    // The intent must be recoverable before the venue can possibly see it.
    if (!persistOrder(ctx, ref, .planned, "", price_s)) {
        var pbuf: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\",\"reason\":\"intent_not_durable\"}}", .{cl_id}) catch "{}";
        ctx.event("ORDER_INTENT_PERSIST_FAILED", "CRITICAL", p);
        return .{ .note = "intent_persist_failed" };
    }
    ctx.setLedger(true);

    const resp = ctx.okx.postPrivate("/api/v5/trade/order", body, ts_now) catch {
        // Unknown outcome: the order may be on the book. Record, then query.
        ctx.setAmbiguity(true);
        _ = persistOrder(ctx, ref, .unknown, "", price_s);
        ctx.event("ORDER_UNKNOWN", "CRITICAL", "{\"reason\":\"http_timeout_or_error\"}");
        const s = settle(ctx, ref, prefer_limit, max_wait_ms);
        _ = ctx.syncAmbiguity();
        return finishUncertain(s, "unknown_http");
    };
    defer ctx.gpa.free(resp);

    switch (okx_rest.classifyPlaceResponse(ctx.gpa, resp)) {
        .rejected => |r| {
            _ = persistOrder(ctx, ref, .rejected, "", price_s);
            var rbuf: [288]u8 = undefined;
            const rp = std.fmt.bufPrint(
                &rbuf,
                "{{\"clOrdId\":\"{s}\",\"status\":\"REJECTED\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"seq\":{d},\"code\":\"{s}\"}}",
                .{ cl_id, po.side.jsonName(), qty_s, price_s, seq, r.code() },
            ) catch "{\"status\":\"REJECTED\"}";
            ctx.event("ORDER_REJECTED", "WARN", rp);
            _ = ctx.syncAmbiguity();
            return .{ .note = "rejected" };
        },
        .unknown => {
            ctx.setAmbiguity(true);
            _ = persistOrder(ctx, ref, .unknown, "", price_s);
            ctx.event("ORDER_UNKNOWN", "CRITICAL", "{\"reason\":\"unparseable_ack\"}");
            const s = settle(ctx, ref, prefer_limit, max_wait_ms);
            _ = ctx.syncAmbiguity();
            return finishUncertain(s, "unknown_parse");
        },
        .accepted => |ack| {
            const ex_id = ack.exchangeOrderId();
            if (!persistOrder(ctx, ref, .acknowledged, ex_id, price_s)) {
                // On the venue but not on record: stay unresolved until the
                // ledger can follow it (restart recovery sees the PLANNED row).
                ctx.setAmbiguity(true);
            }
            var abuf: [360]u8 = undefined;
            const ap = std.fmt.bufPrint(
                &abuf,
                "{{\"clOrdId\":\"{s}\",\"ordId\":\"{s}\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"status\":\"ACKNOWLEDGED\",\"seq\":{d}}}",
                .{ cl_id, ex_id, po.side.jsonName(), qty_s, price_s, seq },
            ) catch "{\"status\":\"ACKNOWLEDGED\"}";
            ctx.event("ORDER_ACK", "INFO", ap);

            const s = settle(ctx, ref, prefer_limit, max_wait_ms);
            _ = ctx.syncAmbiguity();
            return .{ .note = legNote(s), .obs = s.obs };
        },
    }
}

/// A leg that started from an uncertain placement: if verification produced a
/// definitive result report it normally, otherwise surface the uncertainty.
fn finishUncertain(s: Settled, fallback: []const u8) Leg {
    return switch (s.obs.kind) {
        .absent, .unverified => .{ .note = fallback, .obs = s.obs },
        else => .{ .note = legNote(s), .obs = s.obs },
    };
}

fn nonTerminalStatus(status: []const u8) bool {
    return !(std.mem.eql(u8, status, "FILLED") or std.mem.eql(u8, status, "CANCELED") or std.mem.eql(u8, status, "REJECTED"));
}

fn orderStatusOnRecord(ctx: *const Ctx, cl_id: []const u8, out: *[16]u8) ?[]const u8 {
    var stmt = ctx.db.prepare("SELECT status FROM orders WHERE client_order_id = ?1") catch return null;
    defer stmt.finalize();
    stmt.bindText(1, cl_id) catch return null;
    const has = stmt.step() catch return null;
    if (!has) return null;
    const txt = stmt.columnText(0);
    const n = @min(txt.len, out.len);
    @memcpy(out[0..n], txt[0..n]);
    return out[0..n];
}

fn idInList(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| {
        if (std.mem.eql(u8, x, id)) return true;
    }
    return false;
}

pub const RecoveryReport = struct {
    examined: usize = 0,
    resolved: usize = 0,
    /// Orders still resting that recovery canceled and confirmed.
    canceled: usize = 0,
    unresolved: usize = 0,
    /// Pending venue orders this ledger has no live record of.
    foreign: usize = 0,
    /// Venue pending list was read completely.
    scan_ok: bool = false,
    /// Ledger and venue agree: trading may resume.
    complete: bool = false,
};

/// Align the ledger with the venue after a restart (or any doubt): resolve
/// every non-terminal order row against the venue, cancel what is still
/// resting, and compare the pending list against the ledger. Sets the engine's
/// ambiguity flag from the outcome; new trading stays closed until `complete`.
pub fn recoverOrders(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    db: *storage.Db,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
) RecoveryReport {
    const ctx = Ctx{
        .gpa = gpa,
        .okx = okx,
        .cfg = cfg,
        .engine = engine,
        .db = db,
        .orders_repo = orders_repo,
        .fills_repo = fills_repo,
        .events_repo = events_repo,
    };
    var report = RecoveryReport{};
    var rows: [64]storage.OpenOrderRow = undefined;
    const open = orders_repo.listNonTerminal(db, &rows) catch {
        ctx.setAmbiguity(true);
        return report;
    };
    report.examined = open;
    const more_rows_exist = open == rows.len;

    var pend_ids: [32][]const u8 = undefined;
    var pend_backing: [2048]u8 = undefined;
    var pending_ok = false;
    var pending_unnamed: usize = 0;
    var pending_truncated = false;
    var pending_n: usize = 0;
    scan: {
        var path_buf: [160]u8 = undefined;
        const path = okx_trade.formatPendingPath(&path_buf, cfg.instrument) catch break :scan;
        const body = okx.getPrivate(path, nowMs()) catch break :scan;
        defer gpa.free(body);
        const scan = okx_rest.parsePendingOrders(gpa, body, &pend_ids, &pend_backing);
        pending_ok = scan.ok;
        pending_unnamed = scan.unnamed;
        pending_truncated = scan.truncated;
        pending_n = scan.n;
    }
    report.scan_ok = pending_ok and !pending_truncated;

    for (rows[0..open]) |row| {
        const ref = OrderRef{
            .cl_id = row.client_order_id.get(),
            .decision_id = row.decision_id.get(),
            .side = row.side.get(),
            .qty_s = row.qty.get(),
            .price_s = "market",
            .created_ts = row.created_ts.get(),
            .created_ms = clock.parseRfc3339Ms(row.created_ts.get()) catch nowMs(),
        };
        var obs = observeBounded(&ctx, ref);
        if (obs.kind == .working or obs.kind == .partial) {
            obs = cancelAndConfirm(&ctx, ref, "recovery");
            if (obs.isTerminal()) report.canceled += 1;
        }
        if (obs.isTerminal() and obs.durable) {
            report.resolved += 1;
            continue;
        }
        if (obs.kind == .absent and pending_ok and !pending_truncated and
            !idInList(pend_ids[0..pending_n], ref.cl_id) and
            nowMs() - ref.created_ms >= timing.absent_grace_ms)
        {
            // Old enough that visibility lag cannot explain it, and not resting.
            if (persistOrder(&ctx, ref, .canceled, "", ref.price_s)) {
                var pbuf: [160]u8 = undefined;
                const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\",\"reason\":\"unknown_to_venue_after_grace\"}}", .{ref.cl_id}) catch "{}";
                ctx.event("ORDER_RESOLVED_NOT_FOUND", "WARN", p);
                report.resolved += 1;
                continue;
            }
        }
        report.unresolved += 1;
        var pbuf: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\",\"observation\":\"{t}\"}}", .{ ref.cl_id, obs.kind }) catch "{}";
        ctx.event("ORDER_RECOVERY_PENDING", "CRITICAL", p);
    }

    // Pending orders the ledger does not own (placed elsewhere, or a lost
    // intent) keep trading closed until an operator cancels them.
    if (report.scan_ok) {
        var still_pending: [32][]const u8 = undefined;
        var still_backing: [2048]u8 = undefined;
        var rescan_ok = false;
        var unnamed: usize = 0;
        var n_still: usize = 0;
        rescan: {
            var path_buf: [160]u8 = undefined;
            const path = okx_trade.formatPendingPath(&path_buf, cfg.instrument) catch break :rescan;
            const body = okx.getPrivate(path, nowMs()) catch break :rescan;
            defer gpa.free(body);
            const scan = okx_rest.parsePendingOrders(gpa, body, &still_pending, &still_backing);
            rescan_ok = scan.ok and !scan.truncated;
            unnamed = scan.unnamed;
            n_still = scan.n;
        }
        if (!rescan_ok) {
            report.scan_ok = false;
        } else {
            report.foreign += unnamed;
            for (still_pending[0..n_still]) |id| {
                var st_buf: [16]u8 = undefined;
                const known = orderStatusOnRecord(&ctx, id, &st_buf);
                if (known == null or !nonTerminalStatus(known.?)) {
                    report.foreign += 1;
                } else {
                    // Recorded as live but still resting after cancel attempts.
                    report.unresolved += 1;
                }
            }
        }
    }
    if (report.foreign > 0) {
        var pbuf: [160]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "{{\"foreign_pending\":{d},\"action\":\"operator_cancel_all_required\"}}", .{report.foreign}) catch "{}";
        ctx.event("ORDER_FOREIGN_PENDING", "CRITICAL", p);
    }

    report.complete = report.scan_ok and !more_rows_exist and report.unresolved == 0 and report.foreign == 0 and
        (ctx.openOrderCount() orelse 1) == 0;
    ctx.setAmbiguity(!report.complete);
    var pbuf: [256]u8 = undefined;
    const p = std.fmt.bufPrint(
        &pbuf,
        "{{\"examined\":{d},\"resolved\":{d},\"canceled\":{d},\"unresolved\":{d},\"foreign\":{d},\"scan_ok\":{},\"complete\":{}}}",
        .{ report.examined, report.resolved, report.canceled, report.unresolved, report.foreign, report.scan_ok, report.complete },
    ) catch "{}";
    ctx.event("ORDER_RECOVERY", if (report.complete) "INFO" else "CRITICAL", p);
    return report;
}

pub const CancelAllReport = struct {
    listed: bool = false,
    canceled: usize = 0,
    remaining: usize = 0,
    /// Venue pending list is empty and the ledger holds no open rows.
    verified_clear: bool = false,
};

/// Cancel every working order on the instrument and verify the result.
/// `allowed` is main's venue-authorization policy result.
pub fn cancelAllVerified(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    db: *storage.Db,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    allowed: bool,
) CancelAllReport {
    var report = CancelAllReport{};
    if (!allowed) return report;
    const ctx = Ctx{
        .gpa = gpa,
        .okx = okx,
        .cfg = cfg,
        .engine = engine,
        .db = db,
        .orders_repo = orders_repo,
        .fills_repo = fills_repo,
        .events_repo = events_repo,
    };

    var ids: [32][]const u8 = undefined;
    var backing: [2048]u8 = undefined;
    var path_buf: [160]u8 = undefined;
    const path = okx_trade.formatPendingPath(&path_buf, cfg.instrument) catch return report;
    const body = okx.getPrivate(path, nowMs()) catch return report;
    const scan = okx_rest.parsePendingOrders(gpa, body, &ids, &backing);
    gpa.free(body);
    if (!scan.ok) return report;
    report.listed = true;

    for (ids[0..scan.n]) |id| {
        var st_buf: [16]u8 = undefined;
        const known = orderStatusOnRecord(&ctx, id, &st_buf);
        var ts_buf: [32]u8 = undefined;
        const ts = clock.formatRfc3339Ms(nowMs(), &ts_buf) catch "";
        const ref = OrderRef{
            .cl_id = id,
            .decision_id = "operator_cancel_all",
            .side = "buy",
            .qty_s = "0",
            .price_s = "market",
            .created_ts = ts,
            .created_ms = nowMs(),
            // Orders without a ledger row are not ours to rewrite.
            .persist = known != null,
        };
        const obs = cancelAndConfirm(&ctx, ref, "operator_cancel_all");
        if (obs.isTerminal()) report.canceled += 1;
    }

    // Verify against the venue again; only a clean list proves anything.
    var after_ids: [32][]const u8 = undefined;
    var after_backing: [2048]u8 = undefined;
    var after_ok = false;
    var after_n: usize = 0;
    var after_unnamed: usize = 0;
    after: {
        const body2 = okx.getPrivate(path, nowMs()) catch break :after;
        defer gpa.free(body2);
        const scan2 = okx_rest.parsePendingOrders(gpa, body2, &after_ids, &after_backing);
        after_ok = scan2.ok and !scan2.truncated;
        after_n = scan2.n;
        after_unnamed = scan2.unnamed;
    }
    report.remaining = after_n + after_unnamed;
    const ledger_open = ctx.openOrderCount();
    report.verified_clear = after_ok and report.remaining == 0 and !scan.truncated;
    if (report.verified_clear and ledger_open != null and ledger_open.? == 0) {
        ctx.setAmbiguity(false);
    } else {
        report.verified_clear = false;
        ctx.setAmbiguity(true);
    }
    return report;
}
