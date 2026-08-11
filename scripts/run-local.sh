#!/usr/bin/env bash
# Local shadow verification:
#   1) load OKX keys from macOS Keychain into secrets.env (0600)
#   2) source secrets
#   3) run alphabound with config/local.toml
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p var
./scripts/load-okx-keychain.sh "$ROOT/secrets.env" || echo "[run-local] OKX keychain load skipped"
./scripts/load-llm-keychain.sh "$ROOT/secrets.env" || echo "[run-local] LLM keychain load skipped (set LLM_* manually)"

# shellcheck disable=SC1091
set -a
# secrets.env is shell-quoted; safe to source
source "$ROOT/secrets.env"
set +a

BIN="$ROOT/zig-out/bin/alphabound"
if [[ ! -x "$BIN" ]]; then
  echo "[run-local] building ReleaseSafe..."
  zig build -Doptimize=ReleaseSafe
fi

CFG="${ALPHABOUND_CONFIG:-config/local.toml}"
ARGS=(--config "$CFG")
if [[ "${1:-}" == "--self-check" ]]; then
  exec "$BIN" "${ARGS[@]}" --self-check
fi
if [[ "${1:-}" == "--agent-once" ]]; then
  shift
  exec "$BIN" "${ARGS[@]}" --agent-once "$@"
fi
if [[ "${1:-}" == "--ticks" ]]; then
  exec "$BIN" "${ARGS[@]}" --ticks "${2:-5}"
fi
exec "$BIN" "${ARGS[@]}" "$@"
