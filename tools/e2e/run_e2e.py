#!/usr/bin/env python3
"""End-to-end drills: the real daemon binary against synthetic services.

Runs in OKX *simulated* mode (OKX_SIMULATED=1) with every endpoint pointed at a
local fake venue/model. No credentials, no network egress to a venue, no real
orders. Usage:  python3 tools/e2e/run_e2e.py [--bin zig-out/bin/alphabound] [scenario ...]
"""
import argparse
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import fake_services as fs  # noqa: E402

VENUE_PORT = 18791
WEB_PORT = 18792
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

CONFIG = """
[app]
environment = "e2e"
instance_id = "e2e"
[exchange]
provider = "okx"
instrument = "BTC-USDT"
mode = "demo"
rest_url = "http://127.0.0.1:{vp}"
poll_interval_ms = 500
[risk]
max_drawdown = 0.10
valuation = "conservative_liquidation"
allow_runtime_override = false
taker_fee_rate = 0.001
slippage_rate = 0.0005
initial_capital = 100.0
[agent]
provider = "openai"
model = "fake-model"
base_url = "http://127.0.0.1:{vp}/v1"
decision_timeout_ms = 120000
decision_interval_ms = 3600000
decision_min_interval_ms = 120000
enabled = true
llm_reflection = false
[review]
short_interval_ms = 0
long_interval_ms = 0
[audit]
interval_ms = 0
[storage]
path = "{db}"
wal = true
[web]
bind = "127.0.0.1:{wp}"
"""


class Daemon:
    def __init__(self, binpath, workdir, name="daemon"):
        self.bin = binpath
        self.dir = workdir
        self.db = os.path.join(workdir, "trading.db")
        self.cfg = os.path.join(workdir, "e2e.toml")
        self.logpath = os.path.join(workdir, name + ".log")
        with open(self.cfg, "w") as f:
            f.write(CONFIG.format(vp=VENUE_PORT, wp=WEB_PORT, db=self.db))
        self.proc = None

    def env(self):
        e = dict(os.environ)
        e.update({
            "OKX_API_KEY": "e2e-key", "OKX_API_SECRET": "e2e-secret", "OKX_API_PASSPHRASE": "e2e-pass",
            "OKX_SIMULATED": "1",
            "LLM_API_KEY": "e2e-llm-key", "LLM_API_URL": "http://127.0.0.1:%d/v1" % VENUE_PORT,
            "LLM_MODEL": "fake-model",
        })
        e.pop("OKX_REAL_MONEY_OK", None)
        return e

    def start(self, tag="run"):
        self.log = open(self.logpath + "." + tag, "wb")
        self.proc = subprocess.Popen([self.bin, "--config", self.cfg], env=self.env(), stdout=self.log,
                                     stderr=subprocess.STDOUT, cwd=self.dir)
        return self

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def kill9(self):
        if self.proc:
            self.proc.kill()
            self.proc.wait()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()

    def control(self, *args):
        subprocess.run([self.bin, "--config", self.cfg, "--control", *args], env=self.env(), cwd=self.dir,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def api(self, path):
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (WEB_PORT, path), timeout=3) as r:
            return json.loads(r.read())

    def events(self, etype=None):
        con = sqlite3.connect("file:%s?mode=ro" % self.db, uri=True, timeout=5)
        try:
            if etype:
                rows = con.execute("SELECT ts,type,payload_json FROM events WHERE type=? ORDER BY ts", (etype,)).fetchall()
            else:
                rows = con.execute("SELECT ts,type,payload_json FROM events ORDER BY ts").fetchall()
        finally:
            con.close()
        return rows

    def orders(self):
        con = sqlite3.connect("file:%s?mode=ro" % self.db, uri=True, timeout=5)
        try:
            return con.execute("SELECT client_order_id,side,qty,status FROM orders ORDER BY created_ts").fetchall()
        finally:
            con.close()


def ctl(endpoint, **body):
    req = urllib.request.Request("http://127.0.0.1:%d/_ctl/%s" % (VENUE_PORT, endpoint), data=json.dumps(body).encode(),
                                 method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def vstate():
    with urllib.request.urlopen("http://127.0.0.1:%d/_ctl/state" % VENUE_PORT, timeout=5) as r:
        return json.loads(r.read())


def wait_for(pred, timeout, what, interval=0.1):
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        try:
            last = pred()
            if last:
                return last
        except Exception as exc:  # noqa: BLE001
            last = exc
        time.sleep(interval)
    raise AssertionError("timeout (%.0fs) waiting for %s (last=%r)" % (timeout, what, last))


def web_ready(dm):
    return wait_for(lambda: dm.api("/api/v1/state").get("reconciled") is not None, 30, "daemon web api")


def evidence(name, msg):
    print("  [%s] %s" % (name, msg), flush=True)


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

def scenario_slow_model_risk_and_flatten(binpath, workdir):
    """P0-2 + P0-1: the model hangs for 40 s; the risk loop, CLI and a boundary
    flatten must all keep working, and the flatten must sell below the boundary."""
    ctl("reset")
    ctl("set", usdt="1000", btc="0.01", bid="100000", llm_delay_s=40, llm_action="HOLD")
    dm = Daemon(binpath, workdir, "slow").start()
    try:
        web_ready(dm)
        wait_for(lambda: vstate()["llm_active"] == 1, 20, "model call in flight")
        t0 = vstate()["ticker_gets"]
        time.sleep(5)
        dt = vstate()["ticker_gets"] - t0
        evidence("slow", "risk loop polled the market %d times in 5s while the model call hung" % dt)
        assert dt >= 6, "market polling stalled behind the model (%d polls)" % dt
        assert vstate()["llm_active"] == 1

        t1 = time.time()
        dm.control("pause")
        wait_for(lambda: dm.api("/api/v1/system").get("paused") is True, 5, "pause applied")
        evidence("slow", "pause command applied in %.1fs with the model still hanging" % (time.time() - t1))
        dm.control("resume")
        wait_for(lambda: dm.api("/api/v1/system").get("paused") is False, 5, "resume applied")

        # Crash the price through the drawdown boundary (HWM ~2000, equity -> ~1700).
        ctl("set", bid="70000")
        t2 = time.time()
        wait_for(lambda: dm.api("/api/v1/state").get("risk_mode") in ("FLATTENING", "HALTED"), 10, "flattening trigger")
        evidence("slow", "boundary breach detected in %.1fs: %s" % (time.time() - t2, dm.api("/api/v1/state").get("risk_mode")))
        wait_for(lambda: float(vstate()["btc"]) < 0.00001, 20, "position sold on the venue")
        st = vstate()
        evidence("slow", "venue after flatten: btc=%s sell_orders=%d buy_orders=%d model_still_hanging=%s" %
                 (st["btc"], st["sell_orders"], st["buy_orders"], st["llm_active"] == 1))
        assert st["sell_orders"] >= 1 and st["buy_orders"] == 0
        assert st["llm_active"] == 1, "model call finished early; drill is not proving anything"
        wait_for(lambda: dm.api("/api/v1/state").get("risk_mode") == "HALTED", 15, "HALTED after flatten completes")
        evidence("slow", "risk mode HALTED after the venue confirmed the position was gone")
    finally:
        dm.stop()


def scenario_lost_order_response(binpath, workdir):
    """P1-1/P1-2: the placement is accepted but the reply is lost; the daemon must
    query, not re-send, and end with exactly one order that is booked FILLED."""
    ctl("reset")
    ctl("set", usdt="1000", btc="0", bid="100000", llm_action="REBALANCE", llm_weight="0.5",
        llm_order_type="LIMIT_OR_MARKET", llm_delay_s=0)
    ctl("fault", method="POST", path="/trade/order", nth=1, action="drop_after_apply")
    dm = Daemon(binpath, workdir, "lost").start()
    try:
        web_ready(dm)
        wait_for(lambda: len(dm.orders()) >= 1 and dm.orders()[0][3] == "FILLED", 30, "order booked FILLED")
        time.sleep(2)
        st = vstate()
        evidence("lost", "venue saw %d placement call(s), %d order(s); ledger: %s" %
                 (st["post_order_calls"], len(st["orders"]), dm.orders()))
        assert st["post_order_calls"] == 1, "order was re-sent after a lost reply"
        assert len(st["orders"]) == 1
        wait_for(lambda: dm.api("/api/v1/state").get("unresolved_orders") is False, 15, "ambiguity cleared by verified fill")
    finally:
        dm.stop()


def scenario_restart_recovery(binpath, workdir):
    """P1-6: kill -9 while a limit order rests; the new process must cancel and
    verify it before trading, and place nothing new."""
    ctl("reset")
    ctl("set", usdt="1000", btc="0", bid="100000", llm_action="REBALANCE", llm_weight="0.5",
        llm_order_type="LIMIT_ONLY", llm_max_wait_ms=300000, fill_mode="none", llm_delay_s=0)
    dm = Daemon(binpath, workdir, "restart").start("a")
    try:
        web_ready(dm)
        wait_for(lambda: any(o["state"] == "live" for o in vstate()["orders"]), 30, "limit order resting on the venue")
        evidence("restart", "order resting: %s" % vstate()["orders"])
        dm.kill9()
        assert any(o["state"] == "live" for o in vstate()["orders"]), "order should survive the crash"
        ctl("set", llm_action="HOLD", fill_mode="full")
        posts_before = vstate()["post_order_calls"]
        dm2 = Daemon(binpath, workdir, "restart").start("b")
        try:
            web_ready(dm2)
            wait_for(lambda: all(o["state"] == "canceled" for o in vstate()["orders"]), 30, "orphan canceled by recovery")
            wait_for(lambda: dm2.api("/api/v1/state").get("unresolved_orders") is False, 30, "recovery completes")
            rec = [json.loads(p) for _, t, p in dm2.events("ORDER_RECOVERY")]
            evidence("restart", "ORDER_RECOVERY events: %s" % rec)
            assert rec and rec[-1].get("complete") is True
            time.sleep(2)
            assert vstate()["post_order_calls"] == posts_before, "new order placed during/after recovery"
            assert any(s == "CANCELED" for _, _, _, s in dm2.orders())
        finally:
            dm2.stop()
    finally:
        dm.stop()


def scenario_cancel_rejected_blocks_next_leg(binpath, workdir):
    """P1-3: partial fill, the cancel is rejected; no further leg may be sent and
    trading stays closed (unresolved) until recovery verifies the order."""
    ctl("reset")
    ctl("set", usdt="1000", btc="0", bid="100000", llm_action="REBALANCE", llm_weight="0.5",
        llm_order_type="LIMIT_ONLY", llm_max_wait_ms=1000, fill_mode="fraction", cancel_mode="reject", llm_delay_s=0)
    dm = Daemon(binpath, workdir, "cancelrej").start()
    try:
        web_ready(dm)
        wait_for(lambda: vstate()["post_cancel_calls"] >= 1, 40, "cancel attempts")
        time.sleep(3)
        st = vstate()
        evidence("cancelrej", "placements=%d cancels=%d orders=%s unresolved=%s" %
                 (st["post_order_calls"], st["post_cancel_calls"], st["orders"], dm.api("/api/v1/state").get("unresolved_orders")))
        assert st["post_order_calls"] == 1, "a second leg was sent behind an unconfirmed cancel"
        assert dm.api("/api/v1/state").get("unresolved_orders") is True
        ctl("set", cancel_mode="ok")
        wait_for(lambda: dm.api("/api/v1/state").get("unresolved_orders") is False, 45, "recovery cancels and verifies")
        wait_for(lambda: all(o["state"] in ("canceled", "filled") for o in vstate()["orders"]), 15, "venue clean")
    finally:
        dm.stop()


class _Keep:
    """Like TemporaryDirectory but leaves the files for post-mortem."""

    def __init__(self, base):
        os.makedirs(base, exist_ok=True)
        self.path = tempfile.mkdtemp(prefix="ab-e2e-", dir=base)

    def __enter__(self):
        return self.path

    def __exit__(self, *a):
        print("kept %s" % self.path)


SCENARIOS = {
    "slow_model": scenario_slow_model_risk_and_flatten,
    "lost_response": scenario_lost_order_response,
    "restart_recovery": scenario_restart_recovery,
    "cancel_rejected": scenario_cancel_rejected_blocks_next_leg,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out", "bin", "alphabound"))
    ap.add_argument("scenarios", nargs="*")
    args = ap.parse_args()
    names = args.scenarios or list(SCENARIOS)
    fs.serve(VENUE_PORT)
    failures = 0
    for name in names:
        keep = os.environ.get("E2E_KEEP")
        with (_Keep(keep) if keep else tempfile.TemporaryDirectory(prefix="ab-e2e-")) as wd:
            t0 = time.time()
            try:
                SCENARIOS[name](os.path.abspath(args.bin), wd)
                print("PASS %s (%.1fs)" % (name, time.time() - t0), flush=True)
            except Exception as exc:  # noqa: BLE001
                failures += 1
                print("FAIL %s: %s" % (name, exc), flush=True)
                for fn in sorted(os.listdir(wd)):
                    if fn.endswith(".log") or ".log." in fn:
                        print("--- tail of %s ---" % fn)
                        with open(os.path.join(wd, fn), errors="replace") as f:
                            print("".join(f.readlines()[-40:]))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
