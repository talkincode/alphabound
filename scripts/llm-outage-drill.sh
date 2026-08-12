#!/usr/bin/env bash
# LLM-outage drill (AC-NFR02 / AC-GO4 / AC-FD1), runs locally.
# Points the daemon at an unreachable LLM endpoint and verifies the risk
# loop keeps running, the agent degrades to HOLD, and the DB stays valid.
# Usage: ./scripts/llm-outage-drill.sh [TICKS]
set -euo pipefail
TICKS="${1:-6}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/alphabound"
WORK="$(mktemp -d /tmp/ab-llm-outage.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || { echo "build first: zig build"; exit 2; }

sed "s|path = \"var/trading.db\"|path = \"$WORK/trading.db\"|; s|127.0.0.1:18180|127.0.0.1:0|" \
  "$ROOT/config/local.toml" > "$WORK/config.toml"

echo "=== LLM outage drill: $TICKS ticks against unreachable endpoint ==="
set +e
LLM_API_KEY=test LLM_API_URL=http://127.0.0.1:9 LLM_MODEL=test \
  "$BIN" --config "$WORK/config.toml" --ticks "$TICKS" > "$WORK/run.log" 2>&1
RC=$?
set -e

TICKS_SEEN=$(grep -cE '^\[tick' "$WORK/run.log" || true)
HOLDS=$(grep -c 'LLM failed.*HOLD' "$WORK/run.log" || true)
CRASH=$(grep -cE 'panic|Segmentation' "$WORK/run.log" || true)

echo "exit=$RC ticks_seen=$TICKS_SEEN llm_fail_holds=$HOLDS crashes=$CRASH"
grep -E 'LLM failed|risk] mode|shutdown' "$WORK/run.log" | head -6

echo "--- post-run DB verification ---"
"$BIN" --verify-db "$WORK/trading.db" 2>&1 | tail -2

if [ "$RC" -eq 0 ] && [ "$TICKS_SEEN" -ge 1 ] && [ "$HOLDS" -ge 1 ] && [ "$CRASH" -eq 0 ]; then
  echo "LLM OUTAGE DRILL: PASS (risk loop survived, agent held, clean exit)"
  exit 0
fi
echo "LLM OUTAGE DRILL: FAIL"
exit 1
