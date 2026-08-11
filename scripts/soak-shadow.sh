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
echo "[soak] done"
