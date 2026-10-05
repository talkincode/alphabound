//! In-process OKX spot venue for failure-injection tests (no sockets, no keys).
//!
//! Plugged into `okx_rest.Client.transport`. It models just enough of the
//! v5 trade surface to exercise the order chain: placement, query, cancel,
//! pending list, balance and ticker, with scripted faults such as "accepted but
//! the response was lost" or "cancel rejected". Everything is synthetic.

const std = @import("std");
const dec = @import("../core/decimal.zig");
const auth = @import("../exchange/okx/auth.zig");
const rest = @import("../exchange/okx/rest.zig");
const clock = @import("../core/clock.zig");
const Decimal = dec.Decimal;

pub const OrderState = enum {
    live,
    partially_filled,
    filled,
    canceled,

    pub fn text(self: OrderState) []const u8 {
        return switch (self) {
            .live => "live",
            .partially_filled => "partially_filled",
            .filled => "filled",
            .canceled => "canceled",
        };
    }
};

pub const Order = struct {
    cl_id: []u8,
    ord_id: u64,
    buy: bool,
    market: bool,
    sz: Decimal,
    px: Decimal,
    state: OrderState = .live,
    acc_fill: Decimal = Decimal.zero,
    avg_px: Decimal = Decimal.zero,
    /// Fee paid (positive) and its currency; OKX reports it negated.
    fee_paid: Decimal = Decimal.zero,
    fee_ccy: []const u8 = "USDT",
    /// GET /trade/order answers "does not exist" this many times first.
    hidden_queries: u32 = 0,
};

pub const Action = enum {
    /// Request never reaches the venue; client sees a transport error.
    http_error,
    /// Venue applies the request, then the response is lost.
    drop_after_apply,
    /// Venue answers with a business error and applies nothing.
    api_error,
    /// Venue answers code 0 with an empty data list.
    empty_ok,
    /// Venue answers with `raw` verbatim and applies nothing.
    raw_body,
};

pub const Fault = struct {
    method: auth.Method,
    path: []const u8,
    /// 1-based index among calls matching method+path; 0 matches every call.
    nth: u32 = 1,
    action: Action,
    code: []const u8 = "50013",
    raw: []const u8 = "",
    seen: u32 = 0,
};

pub const FillMode = enum {
    /// Market orders fill completely and immediately.
    full,
    /// Market orders fill `fill_fraction` of size, then rest as partially filled.
    fraction,
    /// Nothing fills until the test calls `fillOrder`.
    none,
};

pub const Call = struct {
    method: auth.Method,
    path: []u8,
    body: []u8,
};

pub const CancelMode = enum { ok, reject };

pub const Fake = struct {
    gpa: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    /// Pinned venue clock; null follows the wall clock so freshness checks pass.
    now_ms: ?i64 = null,
    bid: Decimal = Decimal.fromInt(100_000),
    ask: Decimal = Decimal.fromInt(100_000),
    usdt: Decimal = Decimal.fromInt(1_000),
    btc: Decimal = Decimal.zero,
    fee_rate: Decimal = Decimal.fromRaw(100_000), // 0.001
    /// When set, GET /account/balance serves this stale view instead of truth.
    balance_view: ?struct { usdt: Decimal, btc: Decimal } = null,
    fill_mode: FillMode = .full,
    fill_fraction: Decimal = Decimal.fromRaw(50_000_000),
    cancel_mode: CancelMode = .ok,
    /// Orders created from now on stay invisible to GET this many times.
    new_order_hidden_queries: u32 = 0,
    orders: std.ArrayList(Order) = .empty,
    calls: std.ArrayList(Call) = .empty,
    faults: std.ArrayList(Fault) = .empty,
    next_ord_id: u64 = 312_000_000_000_000_001,

    fn nowMsVal(self: *const Fake) i64 {
        return self.now_ms orelse clock.SystemClock.clock().wallMs();
    }

    pub fn init(gpa: std.mem.Allocator) Fake {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Fake) void {
        for (self.orders.items) |o| self.gpa.free(o.cl_id);
        self.orders.deinit(self.gpa);
        for (self.calls.items) |c| {
            self.gpa.free(c.path);
            self.gpa.free(c.body);
        }
        self.calls.deinit(self.gpa);
        self.faults.deinit(self.gpa);
    }

    pub fn transport(self: *Fake) rest.Transport {
        return .{ .context = self, .fetch_fn = fetchThunk };
    }

    pub fn client(self: *Fake, io: std.Io) rest.Client {
        var c = rest.Client.init(self.gpa, io, "https://fake.invalid", .{
            .api_key = "test-key",
            .secret_key = "test-secret",
            .passphrase = "test-pass",
        });
        c.transport = self.transport();
        return c;
    }

    fn lock(self: *Fake) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Fake) void {
        self.mutex.unlock();
    }

    pub fn addFault(self: *Fake, f: Fault) !void {
        try self.faults.append(self.gpa, f);
    }

    pub fn clearFaults(self: *Fake) void {
        self.faults.clearRetainingCapacity();
    }

    /// Number of recorded requests whose method matches and path contains `needle`.
    pub fn countCalls(self: *Fake, method: auth.Method, needle: []const u8) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (c.method == method and std.mem.indexOf(u8, c.path, needle) != null) n += 1;
        }
        return n;
    }

    pub fn findOrder(self: *Fake, cl_id: []const u8) ?*Order {
        for (self.orders.items) |*o| {
            if (std.mem.eql(u8, o.cl_id, cl_id)) return o;
        }
        return null;
    }

    pub fn lastOrder(self: *Fake) ?*Order {
        if (self.orders.items.len == 0) return null;
        return &self.orders.items[self.orders.items.len - 1];
    }

    /// Put a resting order on the book as if another client placed it. An empty
    /// `cl_id` models an order without a client id.
    pub fn injectOrder(self: *Fake, cl_id: []const u8, buy: bool, sz: Decimal, px: Decimal) !void {
        self.lock();
        defer self.unlock();
        const id_copy = try self.gpa.dupe(u8, cl_id);
        errdefer self.gpa.free(id_copy);
        const ord_id = self.next_ord_id;
        self.next_ord_id += 1;
        try self.orders.append(self.gpa, .{
            .cl_id = id_copy,
            .ord_id = ord_id,
            .buy = buy,
            .market = false,
            .sz = sz,
            .px = px,
        });
    }

    /// Venue-side fill of `qty` at `px` (late / partial fills driven by tests).
    pub fn fillOrder(self: *Fake, cl_id: []const u8, qty: Decimal, px: Decimal) !void {
        self.lock();
        defer self.unlock();
        const o = self.findOrder(cl_id) orelse return error.NoSuchOrder;
        try self.applyFill(o, qty, px);
    }

    fn applyFill(self: *Fake, o: *Order, qty_in: Decimal, px: Decimal) !void {
        const remaining = try o.sz.sub(o.acc_fill);
        const qty = Decimal.min(qty_in, remaining);
        if (!qty.gt(Decimal.zero)) return;
        const notional = try qty.mul(px, .down);
        const prev_notional = try o.avg_px.mul(o.acc_fill, .down);
        o.acc_fill = try o.acc_fill.add(qty);
        o.avg_px = try (try prev_notional.add(notional)).div(o.acc_fill, .down);
        if (o.buy) {
            const fee = try qty.mul(self.fee_rate, .up);
            self.usdt = try self.usdt.sub(notional);
            self.btc = try self.btc.add(try qty.sub(fee));
            o.fee_paid = try o.fee_paid.add(fee);
            o.fee_ccy = "BTC";
        } else {
            const fee = try notional.mul(self.fee_rate, .up);
            self.btc = try self.btc.sub(qty);
            self.usdt = try self.usdt.add(try notional.sub(fee));
            o.fee_paid = try o.fee_paid.add(fee);
            o.fee_ccy = "USDT";
        }
        o.state = if (o.acc_fill.gte(o.sz)) .filled else .partially_filled;
    }

    fn fetchThunk(ctx: *anyopaque, gpa: std.mem.Allocator, method: auth.Method, url: []const u8, body: []const u8) rest.Error![]u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = gpa;
        return self.handle(method, url, body);
    }

    fn handle(self: *Fake, method: auth.Method, url: []const u8, body: []const u8) rest.Error![]u8 {
        self.lock();
        defer self.unlock();
        const at = std.mem.indexOf(u8, url, "/api/v5") orelse return rest.Error.HttpFailed;
        const path = url[at..];
        self.record(method, path, body) catch return rest.Error.OutOfMemory;

        var apply_then_drop = false;
        for (self.faults.items) |*f| {
            if (f.method != method or std.mem.indexOf(u8, path, f.path) == null) continue;
            f.seen += 1;
            if (f.nth != 0 and f.seen != f.nth) continue;
            switch (f.action) {
                .http_error => return rest.Error.HttpFailed,
                .api_error => return self.errBody(f.code, "injected"),
                .empty_ok => return self.dupe("{\"code\":\"0\",\"msg\":\"\",\"data\":[]}"),
                .raw_body => return self.dupe(f.raw),
                .drop_after_apply => apply_then_drop = true,
            }
            break;
        }

        const resp = self.route(method, path, body) catch |err| switch (err) {
            error.OutOfMemory => return rest.Error.OutOfMemory,
            else => return rest.Error.HttpFailed,
        };
        if (apply_then_drop) {
            self.gpa.free(resp);
            return rest.Error.HttpFailed;
        }
        return resp;
    }

    fn record(self: *Fake, method: auth.Method, path: []const u8, body: []const u8) !void {
        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        const b = try self.gpa.dupe(u8, body);
        errdefer self.gpa.free(b);
        try self.calls.append(self.gpa, .{ .method = method, .path = p, .body = b });
    }

    fn dupe(self: *Fake, s: []const u8) ![]u8 {
        return self.gpa.dupe(u8, s) catch rest.Error.OutOfMemory;
    }

    fn errBody(self: *Fake, code: []const u8, msg: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{{\"code\":\"{s}\",\"msg\":\"{s}\",\"data\":[]}}", .{ code, msg }) catch rest.Error.OutOfMemory;
    }

    fn route(self: *Fake, method: auth.Method, path: []const u8, body: []const u8) ![]u8 {
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/public/time")) {
            return std.fmt.allocPrint(self.gpa, "{{\"code\":\"0\",\"msg\":\"\",\"data\":[{{\"ts\":\"{d}\"}}]}}", .{self.nowMsVal()});
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/market/ticker")) {
            return std.fmt.allocPrint(
                self.gpa,
                "{{\"code\":\"0\",\"msg\":\"\",\"data\":[{{\"instId\":\"BTC-USDT\",\"last\":\"{f}\",\"bidPx\":\"{f}\",\"askPx\":\"{f}\",\"ts\":\"{d}\"}}]}}",
                .{ self.bid, self.bid, self.ask, self.nowMsVal() },
            );
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/public/instruments")) {
            return self.dupe("{\"code\":\"0\",\"msg\":\"\",\"data\":[{\"instId\":\"BTC-USDT\",\"tickSz\":\"0.1\",\"lotSz\":\"0.00000001\",\"minSz\":\"0.00001\",\"state\":\"live\"}]}");
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/account/config")) {
            return self.dupe("{\"code\":\"0\",\"msg\":\"\",\"data\":[{\"perm\":\"read_only,trade\"}]}");
        }
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/account/balance")) return self.balanceBody();
        if (method == .POST and std.mem.startsWith(u8, path, "/api/v5/trade/order")) return self.place(body);
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/trade/order?")) return self.queryOrder(path);
        if (method == .POST and std.mem.startsWith(u8, path, "/api/v5/trade/cancel-order")) return self.cancel(body);
        if (method == .GET and std.mem.startsWith(u8, path, "/api/v5/trade/orders-pending")) return self.pending();
        return self.errBody("50404", "unknown endpoint");
    }

    fn lockedBtc(self: *Fake) !Decimal {
        var locked = Decimal.zero;
        for (self.orders.items) |o| {
            if (o.buy or (o.state != .live and o.state != .partially_filled)) continue;
            locked = try locked.add(try o.sz.sub(o.acc_fill));
        }
        return locked;
    }

    fn balanceBody(self: *Fake) ![]u8 {
        const usdt = if (self.balance_view) |v| v.usdt else self.usdt;
        const btc = if (self.balance_view) |v| v.btc else self.btc;
        const avail_btc = if (self.balance_view != null) btc else try btc.sub(try self.lockedBtc());
        return std.fmt.allocPrint(
            self.gpa,
            "{{\"code\":\"0\",\"msg\":\"\",\"data\":[{{\"details\":[{{\"ccy\":\"USDT\",\"cashBal\":\"{f}\",\"availBal\":\"{f}\"}},{{\"ccy\":\"BTC\",\"cashBal\":\"{f}\",\"availBal\":\"{f}\"}}]}}]}}",
            .{ usdt, usdt, btc, avail_btc },
        );
    }

    fn place(self: *Fake, body: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return self.errBody("50000", "bad body");
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.errBody("50000", "bad body"),
        };
        const cl_id = jsonStr(obj, "clOrdId") orelse return self.errBody("50000", "clOrdId");
        if (self.findOrder(cl_id) != null) {
            return self.sCodeBody("1", cl_id, "", "51016", "Client order ID already exists");
        }
        const side = jsonStr(obj, "side") orelse "buy";
        const ord_type = jsonStr(obj, "ordType") orelse "market";
        const sz = Decimal.parse(jsonStr(obj, "sz") orelse "0") catch Decimal.zero;
        const px = Decimal.parse(jsonStr(obj, "px") orelse "0") catch Decimal.zero;
        const buy = std.mem.eql(u8, side, "buy");
        const market = std.mem.eql(u8, ord_type, "market");
        const fill_px = if (market) (if (buy) self.ask else self.bid) else px;

        const cost = try sz.mul(fill_px, .up);
        if (buy and cost.gt(self.usdt)) {
            return self.sCodeBody("1", cl_id, "", "51008", "Insufficient balance");
        }
        if (!buy and sz.gt(try self.btc.sub(try self.lockedBtc()))) {
            return self.sCodeBody("1", cl_id, "", "51008", "Insufficient balance");
        }

        const id_copy = try self.gpa.dupe(u8, cl_id);
        errdefer self.gpa.free(id_copy);
        const ord_id = self.next_ord_id;
        self.next_ord_id += 1;
        try self.orders.append(self.gpa, .{
            .cl_id = id_copy,
            .ord_id = ord_id,
            .buy = buy,
            .market = market,
            .sz = sz,
            .px = px,
            .hidden_queries = self.new_order_hidden_queries,
        });
        const o = &self.orders.items[self.orders.items.len - 1];
        switch (self.fill_mode) {
            .full => if (market) try self.applyFill(o, sz, fill_px),
            .fraction => try self.applyFill(o, try sz.mul(self.fill_fraction, .down), fill_px),
            .none => {},
        }
        var ord_buf: [24]u8 = undefined;
        const ord_s = std.fmt.bufPrint(&ord_buf, "{d}", .{ord_id}) catch unreachable;
        return self.sCodeBody("0", cl_id, ord_s, "0", "");
    }

    fn sCodeBody(self: *Fake, top: []const u8, cl_id: []const u8, ord_id: []const u8, s_code: []const u8, s_msg: []const u8) ![]u8 {
        return std.fmt.allocPrint(
            self.gpa,
            "{{\"code\":\"{s}\",\"msg\":\"\",\"data\":[{{\"clOrdId\":\"{s}\",\"ordId\":\"{s}\",\"sCode\":\"{s}\",\"sMsg\":\"{s}\"}}]}}",
            .{ top, cl_id, ord_id, s_code, s_msg },
        );
    }

    fn queryParam(path: []const u8, key: []const u8) ?[]const u8 {
        const q = std.mem.indexOfScalar(u8, path, '?') orelse return null;
        var it = std.mem.splitScalar(u8, path[q + 1 ..], '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq], key)) return kv[eq + 1 ..];
        }
        return null;
    }

    fn queryOrder(self: *Fake, path: []const u8) ![]u8 {
        const cl_id = queryParam(path, "clOrdId") orelse return self.errBody("51000", "clOrdId");
        const o = self.findOrder(cl_id) orelse return self.errBody("51603", "Order does not exist");
        if (o.hidden_queries > 0) {
            o.hidden_queries -= 1;
            return self.errBody("51603", "Order does not exist");
        }
        return std.fmt.allocPrint(
            self.gpa,
            "{{\"code\":\"0\",\"msg\":\"\",\"data\":[{{\"clOrdId\":\"{s}\",\"ordId\":\"{d}\",\"state\":\"{s}\",\"accFillSz\":\"{f}\",\"avgPx\":\"{f}\",\"fee\":\"-{f}\",\"feeCcy\":\"{s}\",\"sz\":\"{f}\"}}]}}",
            .{ o.cl_id, o.ord_id, o.state.text(), o.acc_fill, o.avg_px, o.fee_paid, o.fee_ccy, o.sz },
        );
    }

    fn cancel(self: *Fake, body: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch return self.errBody("50000", "bad body");
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return self.errBody("50000", "bad body"),
        };
        const cl_id = jsonStr(obj, "clOrdId") orelse "";
        const by_ord = jsonStr(obj, "ordId") orelse "";
        if (cl_id.len == 0 and by_ord.len == 0) return self.errBody("50000", "clOrdId/ordId");
        const found: ?*Order = blk: {
            if (cl_id.len > 0) break :blk self.findOrder(cl_id);
            for (self.orders.items) |*cand| {
                var ob: [24]u8 = undefined;
                const txt = std.fmt.bufPrint(&ob, "{d}", .{cand.ord_id}) catch continue;
                if (std.mem.eql(u8, txt, by_ord)) break :blk cand;
            }
            break :blk null;
        };
        const o = found orelse return self.sCodeBody("1", cl_id, "", "51400", "Order does not exist");
        if (o.state == .filled or o.state == .canceled) {
            return self.sCodeBody("1", cl_id, "", "51402", "Cancellation failed as the order is already completed");
        }
        if (self.cancel_mode == .reject) {
            return self.sCodeBody("1", cl_id, "", "50013", "System is busy");
        }
        o.state = .canceled;
        var ord_buf: [24]u8 = undefined;
        const ord_s = std.fmt.bufPrint(&ord_buf, "{d}", .{o.ord_id}) catch unreachable;
        return self.sCodeBody("0", cl_id, ord_s, "0", "");
    }

    fn pending(self: *Fake) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "{\"code\":\"0\",\"msg\":\"\",\"data\":[");
        var first = true;
        for (self.orders.items) |o| {
            if (o.state != .live and o.state != .partially_filled) continue;
            if (!first) try out.append(self.gpa, ',');
            first = false;
            const item = try std.fmt.allocPrint(self.gpa, "{{\"clOrdId\":\"{s}\",\"ordId\":\"{d}\",\"instId\":\"BTC-USDT\"}}", .{ o.cl_id, o.ord_id });
            defer self.gpa.free(item);
            try out.appendSlice(self.gpa, item);
        }
        try out.appendSlice(self.gpa, "]}");
        return out.toOwnedSlice(self.gpa);
    }
};

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const testing = std.testing;

test "fake venue fills a market buy and charges base-currency fee" {
    var fake = Fake.init(testing.allocator);
    defer fake.deinit();
    var c = fake.client(testing.io);
    defer c.deinit();
    const resp = try c.postPrivate(
        "/api/v5/trade/order",
        "{\"instId\":\"BTC-USDT\",\"tdMode\":\"cash\",\"side\":\"buy\",\"ordType\":\"market\",\"sz\":\"0.001\",\"clOrdId\":\"ab01\",\"tgtCcy\":\"base_ccy\"}",
        0,
    );
    defer testing.allocator.free(resp);
    const ack = try rest.parseOrderAck(testing.allocator, resp);
    try testing.expect(ack.s_code_ok);
    const o = fake.findOrder("ab01").?;
    try testing.expectEqual(OrderState.filled, o.state);
    try testing.expect(fake.btc.eql(try Decimal.parse("0.000999")));
    try testing.expect(fake.usdt.eql(Decimal.fromInt(900)));
}
