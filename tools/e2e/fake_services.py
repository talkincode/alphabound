"""Synthetic OKX-like venue + OpenAI-compatible model for end-to-end drills.

Everything here is fake: no network egress, no credentials, no real money.
One threaded HTTP server serves:
  /api/v5/...          a tiny spot venue (balance, ticker, orders, cancel)
  /v1/chat/completions a scripted model (latency + canned proposal)
  /_ctl/...            test control and inspection (state, faults, knobs)
"""
import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


def d(x):
    from decimal import Decimal
    return Decimal(str(x))


class Venue:
    def __init__(self):
        self.lock = threading.RLock()
        self.reset()

    def reset(self):
        from decimal import Decimal
        with self.lock:
            self.usdt = Decimal("1000")
            self.btc = Decimal("0")
            self.bid = Decimal("100000")
            self.ask = Decimal("100000")
            self.fee = Decimal("0.001")
            self.fill_mode = "full"  # full | fraction | none
            self.fill_fraction = Decimal("0.5")
            self.cancel_mode = "ok"  # ok | reject
            self.orders = {}
            self.calls = []
            self.faults = []
            self.ticker_gets = 0
            self.next_ord = 312000000000000001
            self.llm_delay_s = 0.0
            self.llm_action = "HOLD"
            self.llm_weight = "0.5"
            self.llm_order_type = "LIMIT_OR_MARKET"
            self.llm_max_wait_ms = 120000
            self.llm_calls = 0
            self.llm_active = 0

    # -- helpers ------------------------------------------------------------
    def locked_btc(self):
        from decimal import Decimal
        t = Decimal("0")
        for o in self.orders.values():
            if o["buy"] or o["state"] not in ("live", "partially_filled"):
                continue
            t += o["sz"] - o["acc"]
        return t

    def apply_fill(self, o, qty, px):
        qty = min(qty, o["sz"] - o["acc"])
        if qty <= 0:
            return
        notional = qty * px
        prev = o["avg"] * o["acc"]
        o["acc"] += qty
        o["avg"] = (prev + notional) / o["acc"]
        if o["buy"]:
            fee = qty * self.fee
            self.usdt -= notional
            self.btc += qty - fee
            o["fee"] += fee
            o["fee_ccy"] = "BTC"
        else:
            fee = notional * self.fee
            self.btc -= qty
            self.usdt += notional - fee
            o["fee"] += fee
            o["fee_ccy"] = "USDT"
        o["state"] = "filled" if o["acc"] >= o["sz"] else "partially_filled"

    def state(self):
        with self.lock:
            return {
                "usdt": str(self.usdt),
                "btc": str(self.btc),
                "bid": str(self.bid),
                "ticker_gets": self.ticker_gets,
                "llm_calls": self.llm_calls,
                "llm_active": self.llm_active,
                "orders": [
                    {"clOrdId": k, "state": o["state"], "side": "buy" if o["buy"] else "sell",
                     "sz": str(o["sz"]), "acc": str(o["acc"]), "ordType": o["type"]}
                    for k, o in self.orders.items()
                ],
                "post_order_calls": sum(1 for c in self.calls if c[0] == "POST" and "/trade/order" in c[1]),
                "post_cancel_calls": sum(1 for c in self.calls if c[0] == "POST" and "cancel-order" in c[1]),
                "sell_orders": sum(1 for o in self.orders.values() if not o["buy"]),
                "buy_orders": sum(1 for o in self.orders.values() if o["buy"]),
            }


V = Venue()


def envelope(code="0", msg="", data=None):
    return json.dumps({"code": code, "msg": msg, "data": data if data is not None else []})


def scode(top, cl, ordid, sc, sm):
    return envelope(top, "", [{"clOrdId": cl, "ordId": ordid, "sCode": sc, "sMsg": sm}])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, body, status=200):
        raw = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def _drop(self):
        # Simulate a lost response: close without answering.
        self.close_connection = True
        try:
            self.connection.shutdown(2)
        except OSError:
            pass
        self.connection.close()

    def do_GET(self):
        self._route("GET", b"")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        self._route("POST", body)

    def _route(self, method, body):
        u = urlparse(self.path)
        path = u.path
        if path.startswith("/_ctl/"):
            return self._ctl(method, path, body)
        if path.startswith("/v1/chat/completions"):
            return self._llm(body)
        with V.lock:
            full = self.path
            V.calls.append((method, full, body.decode(errors="ignore")))
            fault = None
            for f in V.faults:
                if f["method"] == method and f["path"] in full:
                    f["seen"] = f.get("seen", 0) + 1
                    if f.get("nth", 1) in (0, f["seen"]):
                        fault = f
                        break
            if fault:
                a = fault["action"]
                if a == "http_error":
                    return self._drop()
                if a == "api_error":
                    return self._send(envelope(fault.get("code", "50013"), "injected"))
                if a == "empty_ok":
                    return self._send(envelope("0", "", []))
                if a == "raw_body":
                    return self._send(fault.get("raw", ""))
            resp = self._venue(method, u, body)
            if fault and fault["action"] == "drop_after_apply":
                return self._drop()
            return self._send(resp)

    def _venue(self, method, u, body):
        path = u.path
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        now = int(time.time() * 1000)
        if path == "/api/v5/public/time":
            return envelope("0", "", [{"ts": str(now)}])
        if path == "/api/v5/public/instruments":
            return envelope("0", "", [{"instId": "BTC-USDT", "tickSz": "0.1", "lotSz": "0.00000001", "minSz": "0.00001", "state": "live"}])
        if path == "/api/v5/market/ticker":
            V.ticker_gets += 1
            return envelope("0", "", [{"instId": "BTC-USDT", "last": str(V.bid), "bidPx": str(V.bid), "askPx": str(V.ask), "ts": str(now)}])
        if path == "/api/v5/account/config":
            return envelope("0", "", [{"perm": "read_only,trade"}])
        if path == "/api/v5/account/balance":
            avail = V.btc - V.locked_btc()
            return envelope("0", "", [{"details": [
                {"ccy": "USDT", "cashBal": str(V.usdt), "availBal": str(V.usdt)},
                {"ccy": "BTC", "cashBal": str(V.btc), "availBal": str(avail)}]}])
        if path == "/api/v5/trade/order" and method == "POST":
            return self._place(json.loads(body or b"{}"))
        if path == "/api/v5/trade/order" and method == "GET":
            o = V.orders.get(q.get("clOrdId", ""))
            if not o:
                return envelope("51603", "Order does not exist", [])
            return envelope("0", "", [{
                "clOrdId": q["clOrdId"], "ordId": str(o["id"]), "state": o["state"],
                "accFillSz": str(o["acc"]), "avgPx": str(o["avg"]),
                "fee": "-" + str(o["fee"]), "feeCcy": o["fee_ccy"], "sz": str(o["sz"])}])
        if path == "/api/v5/trade/cancel-order":
            req = json.loads(body or b"{}")
            cl = req.get("clOrdId", "")
            o = V.orders.get(cl)
            if not o:
                return scode("1", cl, "", "51400", "Order does not exist")
            if o["state"] in ("filled", "canceled"):
                return scode("1", cl, "", "51402", "already completed")
            if V.cancel_mode == "reject":
                return scode("1", cl, "", "50013", "System is busy")
            o["state"] = "canceled"
            return scode("0", cl, str(o["id"]), "0", "")
        if path == "/api/v5/trade/orders-pending":
            return envelope("0", "", [{"clOrdId": k, "ordId": str(o["id"]), "instId": "BTC-USDT"}
                                      for k, o in V.orders.items() if o["state"] in ("live", "partially_filled")])
        return envelope("50404", "unknown endpoint")

    def _place(self, req):
        from decimal import Decimal
        cl = req.get("clOrdId", "")
        if cl in V.orders:
            return scode("1", cl, "", "51016", "Client order ID already exists")
        buy = req.get("side") == "buy"
        market = req.get("ordType") == "market"
        sz = Decimal(req.get("sz", "0"))
        px = Decimal(req.get("px", "0") or "0")
        fill_px = (V.ask if buy else V.bid) if market else px
        if buy and sz * fill_px > V.usdt:
            return scode("1", cl, "", "51008", "Insufficient balance")
        if not buy and sz > V.btc - V.locked_btc():
            return scode("1", cl, "", "51008", "Insufficient balance")
        oid = V.next_ord
        V.next_ord += 1
        o = {"id": oid, "buy": buy, "type": req.get("ordType"), "sz": sz, "px": px, "state": "live",
             "acc": Decimal("0"), "avg": Decimal("0"), "fee": Decimal("0"), "fee_ccy": "USDT"}
        V.orders[cl] = o
        if V.fill_mode == "full" and market:
            V.apply_fill(o, sz, fill_px)
        elif V.fill_mode == "fraction":
            V.apply_fill(o, sz * V.fill_fraction, fill_px)
        return scode("0", cl, str(oid), "0", "")

    # -- model --------------------------------------------------------------
    def _llm(self, body):
        with V.lock:
            V.llm_calls += 1
            V.llm_active += 1
            delay = V.llm_delay_s
            action, weight = V.llm_action, V.llm_weight
            otype, wait = V.llm_order_type, V.llm_max_wait_ms
        try:
            text = body.decode(errors="ignore")
            time.sleep(delay)
            m = re.search(r'snapshot_version\\*"\s*:\s*(\d+)', text)
            version = int(m.group(1)) if m else 1
            prop = {
                "decision_id": "dec_e2e_%d" % int(time.time() * 1000),
                "snapshot_version": version,
                "action": action,
                "confidence": 0.7,
                "thesis": ["scripted e2e proposal"],
                "invalid_if": ["scripted"],
                "review_after": "PT1H",
            }
            if action == "REBALANCE":
                prop["target"] = {"type": "portfolio_weight", "btc": float(weight)}
                prop["order_policy"] = {"type": otype, "urgency": 1.0, "max_wait_ms": wait}
            else:
                prop["target"] = {"type": "portfolio_weight", "btc": 0}
            if '"reduce_eval_required":true' in text:
                prop["reduce_eval"] = {"verdict": "keep", "reason": "scripted keep reason"}
            if '"add_eval_required":true' in text:
                prop["add_eval"] = {"verdict": "stay", "reason": "scripted stay reason"}
            out = {"choices": [{"message": {"role": "assistant", "content": json.dumps(prop)}}],
                   "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}}
            self._send(json.dumps(out))
        finally:
            with V.lock:
                V.llm_active -= 1

    # -- control ------------------------------------------------------------
    def _ctl(self, method, path, body):
        from decimal import Decimal
        with V.lock:
            if path == "/_ctl/state":
                return self._send(json.dumps(V.state()))
            if path == "/_ctl/calls":
                return self._send(json.dumps(V.calls[-400:]))
            req = json.loads(body or b"{}")
            if path == "/_ctl/reset":
                V.reset()
            elif path == "/_ctl/set":
                for k, v in req.items():
                    if k in ("usdt", "btc", "bid", "ask", "fee", "fill_fraction"):
                        setattr(V, k, Decimal(str(v)))
                        if k == "bid" and "ask" not in req:
                            V.ask = Decimal(str(v))
                    else:
                        setattr(V, k, v)
            elif path == "/_ctl/fault":
                V.faults.append(req)
            elif path == "/_ctl/clear_faults":
                V.faults = []
            elif path == "/_ctl/fill":
                o = V.orders[req["clOrdId"]]
                V.apply_fill(o, Decimal(str(req["qty"])), Decimal(str(req["px"])))
            return self._send(json.dumps({"ok": True}))


def serve(port):
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


if __name__ == "__main__":
    import sys
    p = int(sys.argv[1]) if len(sys.argv) > 1 else 18790
    serve(p)
    print("fake services on 127.0.0.1:%d" % p, flush=True)
    while True:
        time.sleep(3600)
