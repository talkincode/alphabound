//! Demo/live order execution chain (venue: OKX). Extracted from main.zig.
//!
//! Flow: tryDemoExecute → plan legs → placeDemoLeg → query/resolve, with
//! authoritative venue balance refresh between legs. Fail-closed: any
//! ambiguous order state marks order_ambiguity and stops replanning —
//! never blind-resend on a stale book.

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
const journal = @import("../observability/journal.zig");

const Decimal = dec.Decimal;
const logEventPayload = journal.logEventPayload;

fn nowMs() i64 {
    return clock.SystemClock.clock().wallMs();
}

fn decFmt(buf: []u8, v: Decimal) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    v.format(&w) catch return "0";
    return w.buffered();
}

pub fn tryDemoExecute(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    decision_id: []const u8,
    verdict_txt: []const u8,
    admitted_weight: Decimal,
    instrument: planner.Instrument,
    snap_in: state.PortfolioState,
    order_policy: proposal.OrderPolicy,
) []const u8 {
    if (!std.mem.eql(u8, verdict_txt, "APPROVE") and !std.mem.eql(u8, verdict_txt, "REDUCE")) {
        return "skipped_reject";
    }

    // LIMIT_ONLY → limit legs; LIMIT_OR_MARKET → market (demo default, fast fill).
    const prefer_limit = order_policy.type == .limit_only;
    const max_legs = okx_trade.max_replan_legs;
    var seq: u16 = 0;
    var last_note: []const u8 = "plan_hold";
    var snap = snap_in;
    var any_fill = false;

    while (seq < max_legs) : (seq += 1) {
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
            .admitted_btc_weight = admitted_weight,
            .instrument = instrument,
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

        if (seq > 0) {
            var rbuf: [192]u8 = undefined;
            var qbuf: [48]u8 = undefined;
            const q_s = decFmt(&qbuf, po.qty);
            const rp = std.fmt.bufPrint(
                &rbuf,
                "{{\"decision_id\":\"{s}\",\"seq\":{d},\"side\":\"{s}\",\"qty\":\"{s}\"}}",
                .{ decision_id, seq, po.side.jsonName(), q_s },
            ) catch "{\"replan\":true}";
            logEventPayload(events_repo, engine, "EXEC_REPLAN", "execution", "INFO", cfg, rp);
            std.debug.print("[exec] replan leg={d} side={s} qty={s}\n", .{ seq, po.side.jsonName(), q_s });
        }

        const pre_btc = snap.btc_total;
        const leg = placeDemoLeg(
            gpa,
            okx,
            cfg,
            engine,
            orders_repo,
            fills_repo,
            events_repo,
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
        last_note = leg;

        if (okx_trade.wantsResidualPlan(leg)) {
            any_fill = true;
            // Authoritative venue balances required before another leg.
            // If refresh fails, apply local fill once and STOP — never replan
            // on a stale zero book (that path triple-bought after API blips).
            if (!refreshDemoPortfolio(gpa, okx, engine)) {
                applyLocalFill(engine, po.side, po.qty, mark);
                logEventPayload(events_repo, engine, "EXEC_REFRESH_FAILED", "execution", "WARN", cfg, "{\"action\":\"stop_replan_local_fill\"}");
                return if (std.mem.eql(u8, leg, "filled")) "filled_refresh_failed" else "partial_refresh_failed";
            }
            snap = engine.snapshot();
            // If the venue book did not move in the trade direction after a
            // confirmed fill, the balance feed is lagging/wrong — stop rather
            // than replan the same delta again (idempotency guard; covers the
            // zero-book case and the stale-nonzero case alike).
            if (!okx_trade.bookMoved(po.side, pre_btc, snap.btc_total)) {
                applyLocalFill(engine, po.side, po.qty, mark);
                logEventPayload(events_repo, engine, "EXEC_BOOK_LAG", "execution", "WARN", cfg, "{\"action\":\"stop_replan_stale_book\"}");
                return if (std.mem.eql(u8, leg, "filled")) "filled_book_lag" else "partial_book_lag";
            }
            if (std.mem.eql(u8, leg, "filled")) {
                // If residual is dust, done; else continue for another leg.
                const mark2 = if (snap.mark_price.gt(Decimal.zero)) snap.mark_price else snap.bid_price;
                const eq2 = if (snap.conservative_equity.gt(Decimal.zero)) snap.conservative_equity else snap.cash_usdt;
                const more = planner.plan(.{
                    .cash_usdt = snap.cash_usdt,
                    .btc_total = snap.btc_total,
                    .equity = eq2,
                    .mark_price = mark2,
                    .admitted_btc_weight = admitted_weight,
                    .instrument = instrument,
                }) catch break;
                if (more == .hold) return "filled";
            }
            if (!okx_trade.canPlaceAnotherLeg(seq)) break;
            continue;
        }
        // Terminal non-success or ambiguous — stop (fail-closed, no blind resend).
        return leg;
    }

    if (any_fill and std.mem.eql(u8, last_note, "partial")) return "partial_max_legs";
    return last_note;
}

/// Apply private REST balances into the engine (demo only). Returns false on probe failure.
pub fn refreshDemoPortfolio(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    engine: *state.Engine,
) bool {
    const probe = okx_rest.probeBalance(okx, gpa, nowMs());
    switch (probe) {
        .ok => |b| {
            _ = engine.apply(.{ .reconcile_result = .{
                .ts_ms = nowMs(),
                .cash_usdt = b.usdt_cash,
                .btc_total = b.btc_cash,
                .btc_available = b.btc_avail,
                .hwm_from_db = engine.snapshot().high_watermark,
                .clean = true,
            } }) catch {};
            return true;
        },
        .err => return false,
    }
}

/// Best-effort book update from a known fill when venue balance refresh fails.
/// Used only to keep the engine off a false zero book — not a substitute for reconcile.
fn applyLocalFill(
    engine: *state.Engine,
    side: orders.Side,
    qty: Decimal,
    px: Decimal,
) void {
    if (!qty.gt(Decimal.zero) or !px.gt(Decimal.zero)) return;
    const notional = qty.mul(px, .up) catch return;
    const s0 = engine.snapshot();
    var cash = s0.cash_usdt;
    var btc = s0.btc_total;
    switch (side) {
        .buy => {
            cash = cash.sub(notional) catch return;
            btc = btc.add(qty) catch return;
        },
        .sell => {
            cash = cash.add(notional) catch return;
            btc = btc.sub(qty) catch return;
            if (btc.isNegative()) btc = Decimal.zero;
        },
    }
    _ = engine.apply(.{ .account_update = .{
        .ts_ms = nowMs(),
        .cash_usdt = cash,
        .btc_total = btc,
        .btc_available = btc,
    } }) catch {};
}

/// Single place + query/resolve leg. `seq` differentiates client_order_id on replans.
/// When `prefer_limit`, posts a limit at urgency-adjusted mark (tick-snapped).
fn placeDemoLeg(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    decision_id: []const u8,
    snap_version: u64,
    seq: u16,
    po: planner.PlannedOrder,
    mark: Decimal,
    instrument: planner.Instrument,
    prefer_limit: bool,
    urgency: Decimal,
    max_wait_ms: u32,
) []const u8 {
    var cl_buf: [32]u8 = undefined;
    const cl_id = orders.clientOrderId(&cl_buf, decision_id, snap_version, seq);

    var px_opt: ?Decimal = null;
    if (prefer_limit) {
        const max_passive = Decimal.parse("0.001") catch Decimal.zero; // 10 bps
        px_opt = planner.limitPriceFromMark(mark, instrument.tick_size, po.side, urgency, max_passive) catch null;
        if (px_opt == null) return "limit_price_error";
    }

    var body_buf: [384]u8 = undefined;
    const body = blk: {
        if (px_opt) |px| {
            break :blk okx_trade.formatPlaceLimitBody(&body_buf, .{
                .inst_id = cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .price = px,
                .client_order_id = cl_id,
            }) catch return "body_error";
        } else {
            break :blk okx_trade.formatPlaceMarketBody(&body_buf, .{
                .inst_id = cfg.instrument,
                .side = po.side,
                .qty = po.qty,
                .client_order_id = cl_id,
            }) catch return "body_error";
        }
    };

    var qty_buf: [48]u8 = undefined;
    const qty_s = decFmt(&qty_buf, po.qty);
    var price_buf: [48]u8 = undefined;
    const price_s: []const u8 = if (px_opt) |px| decFmt(&price_buf, px) else "market";
    const ts_now = nowMs();
    var ts_buf: [32]u8 = undefined;
    const ts = clock.formatRfc3339Ms(ts_now, &ts_buf) catch return "ts_error";

    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .exchange_order_id = "",
        .decision_id = decision_id,
        .side = po.side.jsonName(),
        .qty = qty_s,
        .price = price_s,
        .status = orders.OrderStatus.planned.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    var status = orders.OrderStatus.planned;
    status = orders.next(status, .submit) catch .submitted;

    const resp = okx.postPrivate("/api/v5/trade/order", body, ts_now) catch {
        status = orders.next(status, .timeout) catch .unknown;
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        orders_repo.upsert(.{
            .client_order_id = cl_id,
            .decision_id = decision_id,
            .side = po.side.jsonName(),
            .qty = qty_s,
            .price = price_s,
            .status = status.jsonName(),
            .created_ts = ts,
            .updated_ts = ts,
        }) catch {};
        _ = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        logEventPayload(events_repo, engine, "ORDER_UNKNOWN", "execution", "CRITICAL", cfg, "{\"reason\":\"http_timeout_or_error\"}");
        return "unknown_http";
    };
    defer gpa.free(resp);

    const ack = okx_rest.parseOrderAck(gpa, resp) catch {
        status = orders.next(status, .timeout) catch .unknown;
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        _ = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        return "unknown_parse";
    };

    if (!ack.s_code_ok) {
        status = orders.next(status, .reject_confirmed) catch .rejected;
        orders_repo.upsert(.{
            .client_order_id = cl_id,
            .exchange_order_id = ack.exchangeOrderId(),
            .decision_id = decision_id,
            .side = po.side.jsonName(),
            .qty = qty_s,
            .price = price_s,
            .status = status.jsonName(),
            .created_ts = ts,
            .updated_ts = ts,
        }) catch {};
        var rbuf: [288]u8 = undefined;
        const rp = std.fmt.bufPrint(
            &rbuf,
            "{{\"clOrdId\":\"{s}\",\"status\":\"REJECTED\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"seq\":{d}}}",
            .{ cl_id, po.side.jsonName(), qty_s, price_s, seq },
        ) catch "{\"status\":\"REJECTED\"}";
        logEventPayload(events_repo, engine, "ORDER_REJECTED", "execution", "WARN", cfg, rp);
        return "rejected";
    }

    status = orders.next(status, .ack) catch .acknowledged;
    const ex_id = ack.exchangeOrderId();
    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .exchange_order_id = ex_id,
        .decision_id = decision_id,
        .side = po.side.jsonName(),
        .qty = qty_s,
        .price = price_s,
        .status = status.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    var abuf: [360]u8 = undefined;
    const ap = std.fmt.bufPrint(
        &abuf,
        "{{\"clOrdId\":\"{s}\",\"ordId\":\"{s}\",\"side\":\"{s}\",\"qty\":\"{s}\",\"px\":\"{s}\",\"status\":\"ACKNOWLEDGED\",\"seq\":{d}}}",
        .{ cl_id, ex_id, po.side.jsonName(), qty_s, price_s, seq },
    ) catch "{\"status\":\"ACKNOWLEDGED\"}";
    logEventPayload(events_repo, engine, "ORDER_ACK", "execution", "INFO", cfg, ap);

    var resolved = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);

    // LIMIT_ONLY: do not leave working leaves when replan may fire.
    if (prefer_limit and std.mem.eql(u8, resolved, "partial")) {
        _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "partial_remainder", 0);
        resolved = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, po.side.jsonName(), qty_s, ts);
        if (std.mem.eql(u8, resolved, "canceled")) resolved = "partial";
        return resolved;
    }

    // Poll until terminal or max_wait, then cancel remainder (no stuck leaves).
    if (prefer_limit and isOpenOrderNote(resolved)) {
        resolved = waitOrCancelLimit(
            gpa,
            okx,
            cfg,
            engine,
            orders_repo,
            fills_repo,
            events_repo,
            decision_id,
            cl_id,
            po.side.jsonName(),
            qty_s,
            ts,
            max_wait_ms,
        );
    }
    return resolved;
}

fn isOpenOrderNote(note: []const u8) bool {
    return std.mem.eql(u8, note, "acked") or
        std.mem.eql(u8, note, "open") or
        std.mem.eql(u8, note, "partial");
}

fn cancelDemoClOrd(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    events_repo: *storage.EventsRepo,
    cl_id: []const u8,
    reason: []const u8,
    wait_ms: u32,
) bool {
    var cbuf: [192]u8 = undefined;
    const cbody = okx_trade.formatCancelBody(&cbuf, .{
        .inst_id = cfg.instrument,
        .client_order_id = cl_id,
    }) catch return false;
    const resp = okx.postPrivate("/api/v5/trade/cancel-order", cbody, nowMs()) catch return false;
    defer gpa.free(resp);
    var pbuf: [224]u8 = undefined;
    const p = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"reason\":\"{s}\",\"wait_ms\":{d}}}",
        .{ cl_id, reason, wait_ms },
    ) catch "{\"reason\":\"cancel\"}";
    logEventPayload(events_repo, engine, "ORDER_CANCEL_SENT", "execution", "INFO", cfg, p);
    return true;
}

/// Poll order state until terminal or deadline; cancel if still working.
fn waitOrCancelLimit(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    decision_id: []const u8,
    cl_id: []const u8,
    side: []const u8,
    qty_s: []const u8,
    ts: []const u8,
    max_wait_ms: u32,
) []const u8 {
    const wait_cap_ms: u32 = if (max_wait_ms == 0) 30_000 else @min(max_wait_ms, 300_000);
    const deadline = nowMs() + @as(i64, wait_cap_ms);
    var last: []const u8 = "acked";

    while (nowMs() < deadline) {
        // Prefer the process Io clock (Zig 0.16); no Thread.sleep / posix.nanosleep.
        okx.http.io.sleep(.{ .nanoseconds = 250_000_000 }, .awake) catch {};
        last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
        if (std.mem.eql(u8, last, "partial")) {
            _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "partial_remainder", wait_cap_ms);
            last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
            if (std.mem.eql(u8, last, "canceled")) return "partial";
            return last;
        }
        if (!isOpenOrderNote(last)) return last;
    }

    _ = cancelDemoClOrd(gpa, okx, cfg, engine, events_repo, cl_id, "max_wait_ms", wait_cap_ms);
    last = queryAndResolveOrder(gpa, okx, cfg, engine, orders_repo, fills_repo, events_repo, decision_id, cl_id, side, qty_s, ts);
    if (std.mem.eql(u8, last, "filled") or std.mem.eql(u8, last, "partial")) return last;
    if (std.mem.eql(u8, last, "canceled")) return "limit_timeout";
    return last;
}

fn queryAndResolveOrder(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    orders_repo: *storage.OrdersRepo,
    fills_repo: *storage.FillsRepo,
    events_repo: *storage.EventsRepo,
    decision_id: []const u8,
    cl_id: []const u8,
    side: []const u8,
    qty_s: []const u8,
    ts: []const u8,
) []const u8 {
    var path_buf: [192]u8 = undefined;
    const path = okx_trade.formatQueryPath(&path_buf, cfg.instrument, cl_id) catch return "query_path_error";
    const body = okx.getPrivate(path, nowMs()) catch {
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        return "query_http_error";
    };
    defer gpa.free(body);

    const q = okx_rest.parseOrderQuery(gpa, body) catch {
        // Empty data often means not found yet or never accepted.
        if (std.mem.indexOf(u8, body, "\"data\":[]") != null) {
            orders_repo.upsert(.{
                .client_order_id = cl_id,
                .decision_id = decision_id,
                .side = side,
                .qty = qty_s,
                .price = "market",
                .status = orders.OrderStatus.canceled.jsonName(),
                .created_ts = ts,
                .updated_ts = ts,
            }) catch {};
            _ = engine.apply(.{ .order_ambiguity = .{ .present = false } }) catch {};
            return "not_found_canceled";
        }
        _ = engine.apply(.{ .order_ambiguity = .{ .present = true } }) catch {};
        return "query_parse_error";
    };

    const st = okx_trade.mapOkxState(q.status());
    var fill_buf: [48]u8 = undefined;
    const fill_s = decFmt(&fill_buf, q.filled_qty);
    var avg_buf: [48]u8 = undefined;
    const avg_s = if (q.avg_price.gt(Decimal.zero)) decFmt(&avg_buf, q.avg_price) else "market";
    orders_repo.upsert(.{
        .client_order_id = cl_id,
        .exchange_order_id = q.exchangeOrderId(),
        .decision_id = decision_id,
        .side = side,
        .qty = qty_s,
        .price = avg_s,
        .status = st.jsonName(),
        .created_ts = ts,
        .updated_ts = ts,
    }) catch {};

    // Projection fill row when exchange reports cumulative filled qty.
    // Idempotent fill_id = clOrdId + "f0" (single aggregate for REST query path;
    // private WS multi-fill can mint f1/f2 later).
    if (q.filled_qty.gt(Decimal.zero)) {
        var fid_buf: [40]u8 = undefined;
        const fill_id = std.fmt.bufPrint(&fid_buf, "{s}f0", .{cl_id}) catch "fill0";
        var fee_buf: [48]u8 = undefined;
        const fee_s = decFmt(&fee_buf, q.fee);
        const fee_ccy = if (q.feeCcy().len > 0) q.feeCcy() else "USDT";
        fills_repo.append(.{
            .fill_id = fill_id,
            .order_id = cl_id,
            .price = avg_s,
            .qty = fill_s,
            .fee = fee_s,
            .fee_ccy = fee_ccy,
            .ts = ts,
        }) catch {};
    }

    if (st == .filled or st == .canceled or st == .rejected) {
        _ = engine.apply(.{ .order_ambiguity = .{ .present = false } }) catch {};
    } else if (st == .unknown or st == .partial or st == .acknowledged) {
        // Market orders usually fill quickly; leave ambiguity only for unknown.
        _ = engine.apply(.{ .order_ambiguity = .{ .present = st == .unknown } }) catch {};
    }

    var pbuf: [320]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &pbuf,
        "{{\"clOrdId\":\"{s}\",\"okx_state\":\"{s}\",\"status\":\"{s}\",\"filled\":\"{s}\",\"avgPx\":\"{s}\"}}",
        .{ cl_id, q.status(), st.jsonName(), fill_s, avg_s },
    ) catch "{}";
    logEventPayload(events_repo, engine, "ORDER_QUERY", "execution", "INFO", cfg, payload);

    return switch (st) {
        .filled => "filled",
        .partial => "partial",
        .canceled => "canceled",
        .rejected => "rejected",
        .acknowledged => "acked",
        else => "open",
    };
}

/// Cancel pending trading orders (shadow: no-op count 0).
/// `allowed` is main's venue-authorization policy result.
pub fn adminCancelAll(
    gpa: std.mem.Allocator,
    okx: *okx_rest.Client,
    cfg: *const config.Config,
    engine: *state.Engine,
    events_repo: *storage.EventsRepo,
    allowed: bool,
) usize {
    if (!allowed) return 0;

    var path_buf: [160]u8 = undefined;
    const path = okx_trade.formatPendingPath(&path_buf, cfg.instrument) catch return 0;
    const body = okx.getPrivate(path, nowMs()) catch return 0;
    defer gpa.free(body);

    var ids: [32][]const u8 = undefined;
    var backing: [1024]u8 = undefined;
    const n = okx_rest.parsePendingClOrdIds(gpa, body, &ids, &backing) catch 0;
    var canceled: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var cbuf: [192]u8 = undefined;
        const cbody = okx_trade.formatCancelBody(&cbuf, .{
            .inst_id = cfg.instrument,
            .client_order_id = ids[i],
        }) catch continue;
        if (okx.postPrivate("/api/v5/trade/cancel-order", cbody, nowMs())) |resp| {
            defer gpa.free(resp);
            canceled += 1;
            var pbuf: [160]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{{\"clOrdId\":\"{s}\"}}", .{ids[i]}) catch "{}";
            logEventPayload(events_repo, engine, "ORDER_CANCEL_SENT", "execution", "INFO", cfg, p);
        } else |_| {}
    }
    return canceled;
}
