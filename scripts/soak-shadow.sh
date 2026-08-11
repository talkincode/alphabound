#!/usr/bin/env bash
# Short shadow soak: multi-tick run with agent once, then print stats + API snapshot.
# Usage: ./scripts/soak-shadow.sh [ticks=20]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TICKS="${1:-20}"
BIN="${BIN:-./zig-out/bin/alphabound}"
CFG="${CFG:-config/local.toml}"

if [[ ! -x "$BIN" ]]; then
  echo "[soak] building…"
  zig build
fi

if [[ -f ./secrets.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./secrets.env
  set +a
fi

LOG="${TMPDIR:-/tmp}/alphabound-soak-$$.log"
echo "[soak] ticks=$TICKS log=$LOG"
"$BIN" --config "$CFG" --agent-once --ticks "$TICKS" | tee "$LOG"

echo "[soak] --- agent-stats ---"
"$BIN" --config "$CFG" --agent-stats || true

# If a leftover server is not running, skip curl. Soak run exits after ticks.
if grep -q '\[reflect\]' "$LOG"; then
  echo "[soak] reflection lines:"
  grep '\[reflect\]' "$LOG" | tail -5
fi
if grep -q 'proposal ok' "$LOG"; then
  echo "[soak] proposals:"
  grep 'proposal ok' "$LOG" | tail -5
fi
if grep -q 'admit=' "$LOG"; then
  echo "[soak] admission:"
  grep 'admit=' "$LOG" | tail -5
fi
# Optional: if a long-running daemon is already up, print Gate2 thresholds.
if curl -fsS --max-time 2 http://127.0.0.1:8080/api/v1/system >/dev/null 2>&1; then
  echo "[soak] --- gate2-report ---"
  BASE_URL=http://127.0.0.1:8080 "$ROOT/scripts/gate2-report.sh" || true
fi
echo "[soak] done"
