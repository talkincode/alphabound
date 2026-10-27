//! Reconcile asset quantities against confirmed fill facts, never against a
//! current-price wealth residual. Unexplained differences are quarantined;
//! they are NOT transfers and cannot rescale HWM or benchmark capital.
const std = @import("std");
const storage = @import("../storage/db.zig");
const dec = @import("decimal.zig");
const flow = @import("capital_flow.zig");
const D = dec.Decimal;
const key = "accounting_book_v1";
const Book = struct { balances: flow.Balances, fills: flow.Balances };

fn fillNet(db: *storage.Db) storage.DbError!flow.Balances {
    var q = try db.prepare("SELECT o.side,f.qty,f.price,f.fee,f.fee_ccy FROM fills f LEFT JOIN orders o ON o.client_order_id=f.order_id");
    defer q.finalize();
    var cash = D.zero;
    var btc = D.zero;
    while (try q.step()) {
        const qty = D.parse(q.columnText(1)) catch return error.StepFailed;
        const price = D.parse(q.columnText(2)) catch return error.StepFailed;
        const fee = D.parse(q.columnText(3)) catch return error.StepFailed;
        const value = qty.mul(price, .nearest) catch return error.StepFailed;
        if (std.mem.eql(u8, q.columnText(0), "buy")) {
            cash = cash.sub(value) catch return error.StepFailed;
            btc = btc.add(qty) catch return error.StepFailed;
        } else if (std.mem.eql(u8, q.columnText(0), "sell")) {
            cash = cash.add(value) catch return error.StepFailed;
            btc = btc.sub(qty) catch return error.StepFailed;
        } else return error.StepFailed;
        const ccy = q.columnText(4);
        if (std.mem.eql(u8, ccy, "USDT")) cash = cash.sub(fee) catch return error.StepFailed else if (std.mem.eql(u8, ccy, "BTC")) btc = btc.sub(fee) catch return error.StepFailed else if (!fee.isZero()) return error.StepFailed;
    }
    return .{ .cash_usdt = cash, .btc_total = btc };
}
fn parse(text: []const u8) storage.DbError!Book {
    var it = std.mem.splitScalar(u8, text, '|');
    if (!std.mem.eql(u8, it.next() orelse "", "v1")) return error.StepFailed;
    var v: [4]D = undefined;
    for (&v) |*value| value.* = D.parse(it.next() orelse return error.StepFailed) catch return error.StepFailed;
    if (it.next() != null) return error.StepFailed;
    return .{ .balances = .{ .cash_usdt = v[0], .btc_total = v[1] }, .fills = .{ .cash_usdt = v[2], .btc_total = v[3] } };
}
fn save(kv: *storage.KvRepo, book: Book, ts: []const u8) storage.DbError!void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "v1|{f}|{f}|{f}|{f}", .{ book.balances.cash_usdt, book.balances.btc_total, book.fills.cash_usdt, book.fills.btc_total }) catch return error.StepFailed;
    try kv.put(key, text, ts);
}

/// Caller owns a transaction: accepted balance and fill baseline commit
/// together. On mismatch keep the baseline, so polling/restart cannot silently
/// accept the unexplained delta. Legacy checkpoints are never guessed forward.
pub fn check(db: *storage.Db, kv: *storage.KvRepo, actual: flow.Balances, ts: []const u8) storage.DbError!bool {
    const net = try fillNet(db);
    var buf: [256]u8 = undefined;
    const book = if (try kv.getChecked(key, &buf)) |text| try parse(text) else blk: {
        var old_buf: [128]u8 = undefined;
        const old = if (try kv.getChecked("reconciled_balances", &old_buf)) |text|
            flow.parseBalances(text) catch return error.StepFailed
        else
            actual;
        const initial = Book{ .balances = old, .fills = net };
        try save(kv, initial, ts);
        break :blk initial;
    };
    const cash_delta = net.cash_usdt.sub(book.fills.cash_usdt) catch return error.StepFailed;
    const btc_delta = net.btc_total.sub(book.fills.btc_total) catch return error.StepFailed;
    const expected_cash = book.balances.cash_usdt.add(cash_delta) catch return error.StepFailed;
    const expected_btc = book.balances.btc_total.add(btc_delta) catch return error.StepFailed;
    const cash_error = actual.cash_usdt.sub(expected_cash) catch return error.StepFailed;
    const btc_error = actual.btc_total.sub(expected_btc) catch return error.StepFailed;
    // Decimal truncation only (0.0001 USDT / one satoshi), not a percentage
    // of equity that could hide meaningful loss. Never uses a market price.
    const matched = cash_error.abs().lte(D.fromRaw(10_000)) and btc_error.abs().lte(D.fromRaw(1));
    if (matched) try save(kv, .{ .balances = actual, .fills = net }, ts);
    return matched;
}

test "unexplained withdrawal remains quarantined on repeated reconcile" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    var kv = try storage.KvRepo.init(&db);
    defer kv.deinit();
    try std.testing.expect(try check(&db, &kv, .{ .cash_usdt = D.fromInt(100), .btc_total = D.zero }, "t"));
    for (0..3) |_| try std.testing.expect(!try check(&db, &kv, .{ .cash_usdt = D.fromInt(85), .btc_total = D.zero }, "t"));
}
test "a confirmed trade is explained without a price-based flow or HWM adjustment" {
    var db = try storage.Db.open(":memory:");
    defer db.close();
    var kv = try storage.KvRepo.init(&db);
    defer kv.deinit();
    try std.testing.expect(try check(&db, &kv, .{ .cash_usdt = D.fromInt(100), .btc_total = D.zero }, "t"));
    var orders = try storage.OrdersRepo.init(&db);
    defer orders.deinit();
    var fills = try storage.FillsRepo.init(&db);
    defer fills.deinit();
    try orders.upsert(.{ .client_order_id = "synthetic-order", .decision_id = "synthetic-decision", .side = "buy", .qty = "0.001", .price = "100000", .status = "FILLED", .created_ts = "t", .updated_ts = "t" });
    try fills.append(.{ .fill_id = "synthetic-fill", .order_id = "synthetic-order", .qty = "0.001", .price = "100000", .fee = "0", .fee_ccy = "USDT", .ts = "t" });
    const actual = flow.Balances{ .cash_usdt = D.zero, .btc_total = try D.parse("0.001") };
    try std.testing.expect(try check(&db, &kv, actual, "t"));
    try std.testing.expect(try check(&db, &kv, actual, "t")); // repeat is idempotent
}
