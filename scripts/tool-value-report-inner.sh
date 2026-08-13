#!/usr/bin/env bash
# Run on the host (or via tool-value-report.sh). Reads trading.db read-only.
set -euo pipefail
DB="${ALPHABOUND_DB:-/var/lib/alphabound/trading.db}"
python3 - <<'PY' "$DB"
import json, re, sys, sqlite3, collections
db = sys.argv[1]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
print("=== tool_calls by tool ===")
rows = c.execute("SELECT tool, COUNT(*) FROM tool_calls GROUP BY 1 ORDER BY 2 DESC").fetchall()
for t, n in rows:
    print(f"{t}\t{n}")
total_tc = sum(n for _, n in rows) or 1
deriv = next((n for t, n in rows if t == "market.derivatives"), 0)
ticker = next((n for t, n in rows if t == "market.ticker"), 0)
print(f"derivatives_vs_ticker_ratio\t{deriv / ticker if ticker else 0:.3f}")

print("\n=== AGENT_PROPOSAL_OK citation (last 120) ===")
keys = {
    "funding": re.compile(r"funding", re.I),
    "oi": re.compile(r"\boi\b|open[_ ]?interest|oi_ccy|oi_contracts", re.I),
    "long_short": re.compile(r"long[_ -]?short|ls_ratio|long_short_ratio", re.I),
    "taker": re.compile(r"taker", re.I),
    "basis": re.compile(r"basis", re.I),
    "indicator": re.compile(r"\brsi\b|\batr\b|\bsma\b|\bema\b|bollinger|donchian|realized vol", re.I),
    "onchain": re.compile(r"mempool|sat/vB|fee[s]?_sat|difficulty|retarget|on[- ]?chain", re.I),
    "sentiment": re.compile(r"fear|greed|sentiment", re.I),
}
any_pat = re.compile(
    r"funding|open[_ ]?interest|\boi\b|long[_ -]?short|taker|basis_bps|basis",
    re.I,
)
rows = c.execute(
    """
    SELECT payload_json FROM events
    WHERE type='AGENT_PROPOSAL_OK'
    ORDER BY ts DESC LIMIT 120
    """
).fetchall()
n = len(rows)
hit_any = 0
hit_rebal = 0
rebal_n = 0
per = collections.Counter()
for (pj,) in rows:
    s = pj or ""
    try:
        obj = json.loads(s)
    except Exception:
        obj = {}
    action = (obj.get("action") or "").upper()
    thesis = obj.get("thesis") or []
    if isinstance(thesis, list):
        blob = " ".join(str(x) for x in thesis) + " " + s
    else:
        blob = s
    if action == "REBALANCE":
        rebal_n += 1
    matched = False
    for k, pat in keys.items():
        if pat.search(blob):
            per[k] += 1
            matched = True
    if any_pat.search(blob):
        hit_any += 1
        if action == "REBALANCE":
            hit_rebal += 1
print(f"proposals_sampled\t{n}")
print(f"citation_any\t{hit_any}\trate\t{(hit_any/n if n else 0):.3f}")
print(f"rebalance_sampled\t{rebal_n}")
print(f"rebalance_citation\t{hit_rebal}\trate\t{(hit_rebal/rebal_n if rebal_n else 0):.3f}")
for k in keys:
    print(f"hit_{k}\t{per[k]}")
print("\n=== note ===")
print("Target after L1: derivatives_vs_ticker_ratio≈1.0; rebalance_citation≥0.30")
PY
