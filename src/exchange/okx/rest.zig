//! OKX REST client (§4.4): typed wrappers over /api/v5 endpoints.
//! Response *parsing* is pure and fully tested offline; the network layer is
//! a thin std.http.Client wrapper. All numeric fields stay Decimal strings
//! until parsed with core.decimal — floats never touch money.

const std = @import("std");
const auth = @import("auth.zig");
const dec = @import("../../core/decimal.zig");
const limits = @import("../../security/limits.zig");
const Decimal = dec.Decimal;

pub const Error = error{
    HttpFailed,
    ApiError, // envelope code != "0"
    MalformedResponse,
    OutOfMemory,
};

/// Every OKX v5 response: {"code":"0","msg":"","data":[...]}.
/// Returns the `data` array; ApiError when code != "0".
pub fn unwrapEnvelope(parsed: std.json.Value) Error!std.json.Array {
    const obj = switch (parsed) {
        .object => |o| o,
        else => return Error.MalformedResponse,
    };
    const code = obj.get("code") orelse return Error.MalformedResponse;
    const code_str = switch (code) {
        .string => |s| s,
        else => return Error.MalformedResponse,
    };
    if (!std.mem.eql(u8, code_str, "0")) return Error.ApiError;
    const data = obj.get("data") orelse return Error.MalformedResponse;
    return switch (data) {
        .array => |a| a,
        else => Error.MalformedResponse,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const v = obj.get(key) orelse return Error.MalformedResponse;
    return switch (v) {
        .string => |s| s,
        else => Error.MalformedResponse,
    };
}

fn getDecimal(obj: std.json.ObjectMap, key: []const u8) Error!Decimal {
    const s = try getString(obj, key);
    return Decimal.parse(s) catch Error.MalformedResponse;
}

fn firstObject(data: std.json.Array) Error!std.json.ObjectMap {
    if (data.items.len == 0) return Error.MalformedResponse;
    return switch (data.items[0]) {
        .object => |o| o,
        else => Error.MalformedResponse,
    };
}

// -- Typed responses --------------------------------------------------------

pub const ServerTime = struct { ts_ms: i64 };

pub fn parseServerTime(gpa: std.mem.Allocator, body: []const u8) Error!ServerTime {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    const ts_str = try getString(obj, "ts");
    const ts = std.fmt.parseInt(i64, ts_str, 10) catch return Error.MalformedResponse;
    return .{ .ts_ms = ts };
}

pub const InstrumentInfo = struct {
    tick_size: Decimal,
    lot_size: Decimal,
    min_size: Decimal,
    state_live: bool,
};

pub fn parseInstrument(gpa: std.mem.Allocator, body: []const u8) Error!InstrumentInfo {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    return .{
        .tick_size = try getDecimal(obj, "tickSz"),
        .lot_size = try getDecimal(obj, "lotSz"),
        .min_size = try getDecimal(obj, "minSz"),
        .state_live = std.mem.eql(u8, try getString(obj, "state"), "live"),
    };
}

pub const Ticker = struct {
    ts_ms: i64,
    bid: Decimal,
    ask: Decimal,
    last: Decimal,
};

pub fn parseTicker(gpa: std.mem.Allocator, body: []const u8) Error!Ticker {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    const ts_str = try getString(obj, "ts");
    return .{
        .ts_ms = std.fmt.parseInt(i64, ts_str, 10) catch return Error.MalformedResponse,
        .bid = try getDecimal(obj, "bidPx"),
        .ask = try getDecimal(obj, "askPx"),
        .last = try getDecimal(obj, "last"),
    };
}

/// One OHLCV bar from /api/v5/market/candles (array rows).
pub const Candle = struct {
    ts_ms: i64,
    open: Decimal,
    high: Decimal,
    low: Decimal,
    close: Decimal,
    vol: Decimal,
};

/// Parse candles envelope into `out`; returns count written (newest-first as OKX).
pub fn parseCandles(gpa: std.mem.Allocator, body: []const u8, out: []Candle) Error!usize {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    var n: usize = 0;
    for (data.items) |item| {
        if (n >= out.len) break;
        const row = switch (item) {
            .array => |a| a,
            else => return Error.MalformedResponse,
        };
        if (row.items.len < 6) return Error.MalformedResponse;
        const ts_s = switch (row.items[0]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        const o_s = switch (row.items[1]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        const h_s = switch (row.items[2]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        const l_s = switch (row.items[3]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        const c_s = switch (row.items[4]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        const v_s = switch (row.items[5]) {
            .string => |s| s,
            else => return Error.MalformedResponse,
        };
        out[n] = .{
            .ts_ms = std.fmt.parseInt(i64, ts_s, 10) catch return Error.MalformedResponse,
            .open = Decimal.parse(o_s) catch return Error.MalformedResponse,
            .high = Decimal.parse(h_s) catch return Error.MalformedResponse,
            .low = Decimal.parse(l_s) catch return Error.MalformedResponse,
            .close = Decimal.parse(c_s) catch return Error.MalformedResponse,
            .vol = Decimal.parse(v_s) catch return Error.MalformedResponse,
        };
        n += 1;
    }
    return n;
}

pub const Balance = struct {
    usdt_cash: Decimal,
    usdt_avail: Decimal,
    btc_cash: Decimal,
    btc_avail: Decimal,
};

/// Parses /api/v5/account/balance: data[0].details[] per currency.
pub fn parseBalance(gpa: std.mem.Allocator, body: []const u8) Error!Balance {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    const details_v = obj.get("details") orelse return Error.MalformedResponse;
    const details = switch (details_v) {
        .array => |a| a,
        else => return Error.MalformedResponse,
    };
    var out = Balance{
        .usdt_cash = Decimal.zero,
        .usdt_avail = Decimal.zero,
        .btc_cash = Decimal.zero,
        .btc_avail = Decimal.zero,
    };
    for (details.items) |item| {
        const detail = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const ccy = getString(detail, "ccy") catch continue;
        if (std.mem.eql(u8, ccy, "USDT")) {
            out.usdt_cash = try getDecimal(detail, "cashBal");
            out.usdt_avail = try getDecimal(detail, "availBal");
        } else if (std.mem.eql(u8, ccy, "BTC")) {
            out.btc_cash = try getDecimal(detail, "cashBal");
            out.btc_avail = try getDecimal(detail, "availBal");
        }
    }
    return out;
}

pub const OrderAck = struct {
    exchange_order_id_buf: [32]u8 = undefined,
    exchange_order_id_len: usize = 0,
    s_code_ok: bool,

    pub fn exchangeOrderId(self: *const OrderAck) []const u8 {
        return self.exchange_order_id_buf[0..self.exchange_order_id_len];
    }
};

/// Parses /api/v5/trade/order POST ack. Per-item sCode "0" = accepted.
pub fn parseOrderAck(gpa: std.mem.Allocator, body: []const u8) Error!OrderAck {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    const ord_id = try getString(obj, "ordId");
    const s_code = try getString(obj, "sCode");
    var ack = OrderAck{ .s_code_ok = std.mem.eql(u8, s_code, "0") };
    if (ord_id.len > ack.exchange_order_id_buf.len) return Error.MalformedResponse;
    @memcpy(ack.exchange_order_id_buf[0..ord_id.len], ord_id);
    ack.exchange_order_id_len = ord_id.len;
    return ack;
}

pub const OrderQuery = struct {
    status_buf: [24]u8 = undefined,
    status_len: usize = 0,
    filled_qty: Decimal,
    avg_price: Decimal,

    pub fn status(self: *const OrderQuery) []const u8 {
        return self.status_buf[0..self.status_len];
    }
};

/// Parses /api/v5/trade/order GET (state: live/partially_filled/filled/canceled).
pub fn parseOrderQuery(gpa: std.mem.Allocator, body: []const u8) Error!OrderQuery {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    const obj = try firstObject(data);
    const state = try getString(obj, "state");
    const acc_fill = try getString(obj, "accFillSz");
    const avg_px = try getString(obj, "avgPx");
    var q = OrderQuery{
        .filled_qty = if (acc_fill.len == 0) Decimal.zero else Decimal.parse(acc_fill) catch return Error.MalformedResponse,
        .avg_price = if (avg_px.len == 0) Decimal.zero else Decimal.parse(avg_px) catch return Error.MalformedResponse,
    };
    if (state.len > q.status_buf.len) return Error.MalformedResponse;
    @memcpy(q.status_buf[0..state.len], state);
    q.status_len = state.len;
    return q;
}

// -- Network layer -----------------------------------------------------------

pub const Client = struct {
    http: std.http.Client,
    gpa: std.mem.Allocator,
    base_url: []const u8,
    creds: ?auth.Credentials,
    /// Set true when using OKX demo trading (adds x-simulated-trading: 1).
    simulated: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base_url: []const u8, creds: ?auth.Credentials) Client {
        return .{
            .http = .{ .allocator = gpa, .io = io },
            .gpa = gpa,
            .base_url = base_url,
            .creds = creds,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    /// GET a public endpoint; returns response body (caller frees).
    pub fn getPublic(self: *Client, path: []const u8) ![]u8 {
        return self.request(.GET, path, "", false);
    }

    /// Signed GET (账户/订单查询).
    pub fn getPrivate(self: *Client, path: []const u8, now_ms: i64) ![]u8 {
        return self.requestSigned(.GET, path, "", now_ms);
    }

    /// Signed POST with JSON body (下单/撤单).
    pub fn postPrivate(self: *Client, path: []const u8, body: []const u8, now_ms: i64) ![]u8 {
        return self.requestSigned(.POST, path, body, now_ms);
    }

    fn requestSigned(self: *Client, method: auth.Method, path: []const u8, body: []const u8, now_ms: i64) ![]u8 {
        const creds = self.creds orelse return Error.HttpFailed;
        var hs = auth.HeaderSet{};
        hs.build(creds, now_ms, method, path, body);
        var headers_buf: [5]std.http.Header = .{
            .{ .name = "OK-ACCESS-KEY", .value = creds.api_key },
            .{ .name = "OK-ACCESS-SIGN", .value = hs.signature },
            .{ .name = "OK-ACCESS-TIMESTAMP", .value = hs.timestamp },
            .{ .name = "OK-ACCESS-PASSPHRASE", .value = creds.passphrase },
            .{ .name = "x-simulated-trading", .value = "1" },
        };
        const headers: []const std.http.Header = if (self.simulated) headers_buf[0..5] else headers_buf[0..4];
        return self.fetchRaw(method, path, body, headers);
    }

    fn request(self: *Client, method: auth.Method, path: []const u8, body: []const u8, signed: bool) ![]u8 {
        _ = signed;
        return self.fetchRaw(method, path, body, &.{});
    }

    fn fetchRaw(self: *Client, method: auth.Method, path: []const u8, body: []const u8, extra_headers: []const std.http.Header) ![]u8 {
        return self.fetchRawOnce(method, path, body, extra_headers) catch |err| {
            if (err != Error.HttpFailed) return err;
            // Zig may re-offer a half-closed pooled TLS socket after a blip; drop the
            // pool and retry once so the daemon does not stay wedged until restart.
            std.debug.print("[okx] transport_failed; reset_http_retry path={s}\n", .{path});
            self.resetHttp();
            return self.fetchRawOnce(method, path, body, extra_headers);
        };
    }

    fn fetchRawOnce(self: *Client, method: auth.Method, path: []const u8, body: []const u8, extra_headers: []const std.http.Header) ![]u8 {
        var url_buf: [512]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ self.base_url, path }) catch return Error.HttpFailed;

        // AC-SEC5: fixed-capacity sink — a hostile/broken gateway cannot balloon memory.
        const sink = self.gpa.alloc(u8, limits.max_okx_response_bytes) catch return Error.OutOfMemory;
        defer self.gpa.free(sink);
        var fixed_writer: std.Io.Writer = .fixed(sink);

        const result = self.http.fetch(.{
            .location = .{ .url = url },
            .method = if (method == .GET) .GET else .POST,
            .payload = if (body.len > 0) body else null,
            .response_writer = &fixed_writer,
            .extra_headers = extra_headers,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            // Prefer fresh sockets for long-running daemons; OKX gateways idle-close.
            .keep_alive = false,
        }) catch |err| {
            if (err == error.WriteFailed) {
                std.debug.print("[okx] response_too_large cap={d} path={s}\n", .{ limits.max_okx_response_bytes, path });
                return Error.HttpFailed;
            }
            std.debug.print("[okx] transport_failed err={s} path={s}\n", .{ @errorName(err), path });
            return Error.HttpFailed;
        };

        // Return body even on non-2xx: OKX auth/IP errors are JSON {code,msg}.
        const received = fixed_writer.buffered();
        if (received.len == 0 and result.status != .ok) {
            return Error.HttpFailed;
        }
        return self.gpa.dupe(u8, received) catch Error.OutOfMemory;
    }

    fn resetHttp(self: *Client) void {
        const io = self.http.io;
        const allocator = self.http.allocator;
        self.http.deinit();
        self.http = .{ .allocator = allocator, .io = io };
    }
};

/// Map OKX error body to a short stable log token (no secrets).
pub fn classifyErrorBody(body: []const u8) []const u8 {
    if (std.mem.indexOf(u8, body, "50110") != null) return "ip_whitelist";
    if (std.mem.indexOf(u8, body, "50113") != null) return "invalid_sign";
    if (std.mem.indexOf(u8, body, "50111") != null) return "invalid_key";
    if (std.mem.indexOf(u8, body, "50119") != null) return "invalid_passphrase";
    if (std.mem.indexOf(u8, body, "50102") != null) return "timestamp";
    if (std.mem.indexOf(u8, body, "\"code\"") != null) return "api_error";
    return "http_or_network";
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn d(s: []const u8) Decimal {
    return Decimal.parse(s) catch unreachable;
}

test "unwrap envelope rejects non-zero code" {
    const body =
        \\{"code":"51008","msg":"insufficient balance","data":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectError(Error.ApiError, unwrapEnvelope(parsed.value));
}

test "parse server time" {
    const body =
        \\{"code":"0","msg":"","data":[{"ts":"1607418537715"}]}
    ;
    const t = try parseServerTime(testing.allocator, body);
    try testing.expectEqual(@as(i64, 1607418537715), t.ts_ms);
}

test "parse instrument BTC-USDT" {
    const body =
        \\{"code":"0","msg":"","data":[{"instId":"BTC-USDT","tickSz":"0.1","lotSz":"0.00000001","minSz":"0.00001","state":"live"}]}
    ;
    const info = try parseInstrument(testing.allocator, body);
    try testing.expect(info.tick_size.eql(d("0.1")));
    try testing.expect(info.lot_size.eql(d("0.00000001")));
    try testing.expect(info.min_size.eql(d("0.00001")));
    try testing.expect(info.state_live);
}

test "parse ticker" {
    const body =
        \\{"code":"0","msg":"","data":[{"instId":"BTC-USDT","last":"99123.4","bidPx":"99123.3","askPx":"99123.5","ts":"1786264264482"}]}
    ;
    const t = try parseTicker(testing.allocator, body);
    try testing.expectEqual(@as(i64, 1786264264482), t.ts_ms);
    try testing.expect(t.bid.eql(d("99123.3")));
    try testing.expect(t.ask.eql(d("99123.5")));
    try testing.expect(t.bid.lt(t.ask));
}

test "parse candles array rows" {
    const body =
        \\{"code":"0","msg":"","data":[
        \\  ["1700000000000","100","110","90","105","12.5","0","0","1"],
        \\  ["1699996400000","98","101","97","100","8","0","0","1"]
        \\]}
    ;
    var out: [4]Candle = undefined;
    const n = try parseCandles(testing.allocator, body, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(i64, 1700000000000), out[0].ts_ms);
    try testing.expect(out[0].close.eql(d("105")));
    try testing.expect(out[1].open.eql(d("98")));
}

test "parse balance extracts USDT and BTC details" {
    const body =
        \\{"code":"0","msg":"","data":[{"details":[
        \\  {"ccy":"USDT","cashBal":"87.5","availBal":"37.5"},
        \\  {"ccy":"BTC","cashBal":"0.0005","availBal":"0.0005"},
        \\  {"ccy":"ETH","cashBal":"0","availBal":"0"}
        \\]}]}
    ;
    const b = try parseBalance(testing.allocator, body);
    try testing.expect(b.usdt_cash.eql(d("87.5")));
    try testing.expect(b.usdt_avail.eql(d("37.5")));
    try testing.expect(b.btc_cash.eql(d("0.0005")));
    try testing.expect(b.btc_avail.eql(d("0.0005")));
}

test "parse order ack" {
    const body =
        \\{"code":"0","msg":"","data":[{"ordId":"312269865356374016","clOrdId":"ab00112233","sCode":"0","sMsg":""}]}
    ;
    const ack = try parseOrderAck(testing.allocator, body);
    try testing.expect(ack.s_code_ok);
    try testing.expectEqualStrings("312269865356374016", ack.exchangeOrderId());
}

test "parse order query filled" {
    const body =
        \\{"code":"0","msg":"","data":[{"state":"filled","accFillSz":"0.0001","avgPx":"100000.1"}]}
    ;
    const q = try parseOrderQuery(testing.allocator, body);
    try testing.expectEqualStrings("filled", q.status());
    try testing.expect(q.filled_qty.eql(d("0.0001")));
    try testing.expect(q.avg_price.eql(d("100000.1")));
}

/// Extract up to `out.len` client order ids from orders-pending response.
pub fn parsePendingClOrdIds(gpa: std.mem.Allocator, body: []const u8, out: [][]const u8, backing: []u8) Error!usize {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return Error.MalformedResponse;
    defer parsed.deinit();
    const data = try unwrapEnvelope(parsed.value);
    var n: usize = 0;
    var w: usize = 0;
    for (data.items) |item| {
        if (n >= out.len) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const cl = getString(obj, "clOrdId") catch continue;
        if (cl.len == 0) continue;
        if (w + cl.len > backing.len) break;
        @memcpy(backing[w .. w + cl.len], cl);
        out[n] = backing[w .. w + cl.len];
        w += cl.len;
        n += 1;
    }
    return n;
}

test "parse pending clOrdIds" {
    const body =
        \\{"code":"0","msg":"","data":[
        \\  {"clOrdId":"abaaa","ordId":"1"},
        \\  {"clOrdId":"abbbb","ordId":"2"}
        \\]}
    ;
    var ids: [4][]const u8 = undefined;
    var backing: [64]u8 = undefined;
    const n = try parsePendingClOrdIds(testing.allocator, body, &ids, &backing);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("abaaa", ids[0]);
    try testing.expectEqualStrings("abbbb", ids[1]);
}

test "parse order query with empty avgPx" {
    const body =
        \\{"code":"0","msg":"","data":[{"state":"live","accFillSz":"","avgPx":""}]}
    ;
    const q = try parseOrderQuery(testing.allocator, body);
    try testing.expectEqualStrings("live", q.status());
    try testing.expect(q.filled_qty.isZero());

    const body2 =
        \\{"code":"0","msg":"","data":[{"state":"partially_filled","accFillSz":"0.0004","avgPx":"99120.5"}]}
    ;
    const q2 = try parseOrderQuery(testing.allocator, body2);
    try testing.expectEqualStrings("partially_filled", q2.status());
    try testing.expect(q2.filled_qty.eql(d("0.0004")));
}

test "malformed bodies fail closed" {
    try testing.expectError(Error.MalformedResponse, parseServerTime(testing.allocator, "not json"));
    try testing.expectError(Error.MalformedResponse, parseServerTime(testing.allocator, "{}"));
    try testing.expectError(Error.MalformedResponse, parseTicker(testing.allocator,
        \\{"code":"0","data":[{"bidPx":"1","askPx":"2","ts":"notanum","last":"1"}]}
    ));
}
