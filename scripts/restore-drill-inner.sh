#!/usr/bin/env bash
# Runs ON the remote host (uploaded by restore-drill.sh). Root required.
# AC-OPS4 restore drill:
#   1. locate the newest backup snapshot next to the production DB
#   2. copy it to a scratch path (never touches the live DB)
#   3. verify it read-only with the deployed binary: --verify-db
#   4. report PASS/FAIL and clean up
set -euo pipefail

DATA_DIR="${DATA_DIR:-/var/lib/alphabound}"
BIN="${BIN:-/opt/alphabound/current/alphabound}"
DB="$DATA_DIR/trading.db"
SCRATCH="$(mktemp /tmp/restore-drill.XXXXXX.db)"
trap 'rm -f "$SCRATCH"' EXIT

echo "=== alphabound restore drill $(date -u +%FT%TZ) ==="

# Newest snapshot wins: hourly/daily rotations plus the .bak latest pointer.
CANDIDATE="$(ls -1t "$DB".hourly.*.bak "$DB".daily.*.bak "$DB".bak 2>/dev/null | head -1 || true)"
if [ -z "$CANDIDATE" ]; then
  echo "RESTORE DRILL: FAIL (no backup snapshot found in $DATA_DIR)"
  exit 1
fi

AGE_S=$(( $(date +%s) - $(stat -c %Y "$CANDIDATE") ))
SIZE=$(stat -c %s "$CANDIDATE")
echo "snapshot: $CANDIDATE"
echo "age_s: $AGE_S  size_bytes: $SIZE"

cp "$CANDIDATE" "$SCRATCH"

if "$BIN" --verify-db "$SCRATCH" 2>&1; then
  # Freshness gate: hourly rotation means a healthy snapshot is < 2h old.
  if [ "$AGE_S" -gt 7200 ]; then
    echo "RESTORE DRILL: WARN (snapshot verifiable but ${AGE_S}s old > 7200s)"
    exit 0
  fi
  echo "RESTORE DRILL: PASS"
  exit 0
fi

echo "RESTORE DRILL: FAIL (verify-db rejected $CANDIDATE)"
exit 1
