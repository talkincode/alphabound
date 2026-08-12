#!/bin/bash
# AC-GO5 audit chain — runs ON the production host (root).
# Uses the live binary --verify-db against the trading DB (and newest backup).
set -euo pipefail

BIN=/opt/alphabound/current/alphabound
DB=/var/lib/alphabound/trading.db
FAIL=0

echo "=== AC-GO5 audit chain ==="
echo "host $(hostname -s) utc $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ ! -x "$BIN" ]]; then
  echo "FAIL missing binary $BIN"
  exit 1
fi
if [[ ! -f "$DB" ]]; then
  echo "FAIL missing db $DB"
  exit 1
fi

echo "=== live db ==="
# Run as service user so file perms match daemon.
if ! sudo -u alphabound "$BIN" --verify-db "$DB"; then
  echo "FAIL live verify-db"
  FAIL=$((FAIL + 1))
fi

echo "=== newest backup (if any) ==="
BAK="$(ls -1t /var/lib/alphabound/trading.db*.bak 2>/dev/null | head -1 || true)"
if [[ -n "$BAK" && -f "$BAK" ]]; then
  echo "backup $BAK"
  TMP="/tmp/alphabound-go5-$$.db"
  cp -a "$BAK" "$TMP"
  chown alphabound:alphabound "$TMP" 2>/dev/null || true
  if ! sudo -u alphabound "$BIN" --verify-db "$TMP"; then
    echo "FAIL backup verify-db"
    FAIL=$((FAIL + 1))
  fi
  rm -f "$TMP"
else
  echo "no backup found (skip)"
fi

echo "=== sqlite cross-checks (orders → decisions) ==="
python3 - "$DB" <<'PY' || FAIL=$((FAIL + 1))
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
c = db.cursor()
orders = c.execute("SELECT COUNT(*) FROM orders").fetchone()[0]
fills = c.execute("SELECT COUNT(*) FROM fills").fetchone()[0]
no_dec = c.execute(
    "SELECT COUNT(*) FROM orders WHERE decision_id IS NULL OR decision_id=''"
).fetchone()[0]
# Proposal event payload must mention decision_id for non-empty orders.
missing_prop = c.execute(
    """
    SELECT COUNT(*) FROM orders o
    WHERE o.decision_id != ''
      AND NOT EXISTS (
        SELECT 1 FROM events e
        WHERE e.type IN ('AGENT_PROPOSAL_OK','ADMIN_TARGET_WEIGHT')
          AND instr(e.payload_json, '"decision_id":"' || o.decision_id || '"') > 0
      )
    """
).fetchone()[0]
orphan_fills = c.execute(
    """
    SELECT COUNT(*) FROM fills f
    WHERE NOT EXISTS (
      SELECT 1 FROM orders o WHERE o.client_order_id = f.order_id
    )
    """
).fetchone()[0]
order_events = c.execute(
    "SELECT COUNT(*) FROM events WHERE type LIKE 'ORDER_%'"
).fetchone()[0]
print(f"orders {orders} fills {fills} order_events {order_events}")
print(f"orders_no_decision_id {no_dec}")
print(f"orders_missing_proposal {missing_prop} (op probes excluded)")
print(f"orphan_fills {orphan_fills}")
bad = no_dec + missing_prop + orphan_fills
if bad:
    print(f"FAIL cross-check count={bad}")
    sys.exit(1)
print("cross-check ok")
sys.exit(0)
PY

echo "=== verdict ==="
if [[ "$FAIL" -gt 0 ]]; then
  echo "GO5 FAIL checks=$FAIL"
  exit 1
fi
echo "GO5 PASS"
exit 0
