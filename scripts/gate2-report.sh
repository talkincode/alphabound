#!/usr/bin/env bash
# Evaluate Gate 2 shadow thresholds from a running daemon's /api/v1/system.
#
# Usage:
#   ./scripts/gate2-report.sh
#   BASE_URL=http://127.0.0.1:8080 ./scripts/gate2-report.sh
#   MIN_SAMPLES=20 ./scripts/gate2-report.sh
#
# Exit 0 = all enforced checks pass (or sample too small → WARN only).
# Exit 1 = hard fail (unreachable API or thresholds breached with enough samples).
# Exit 2 = usage / dependency error.
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
MIN_SAMPLES="${MIN_SAMPLES:-20}"
MIN_VALID_RATE="${MIN_VALID_RATE:-80}"
MAX_INVALID_RATE="${MAX_INVALID_RATE:-10}"

if ! command -v curl >/dev/null 2>&1; then
  echo "[gate2] curl required" >&2
  exit 2
fi

SYS_JSON="$(curl -fsS --max-time 5 "${BASE_URL}/api/v1/system" 2>/dev/null)" || {
  echo "[gate2] FAIL unreachable ${BASE_URL}/api/v1/system"
  exit 1
}

LIVE="$(curl -fsS --max-time 3 "${BASE_URL}/health/live" 2>/dev/null || true)"
READY="$(curl -fsS --max-time 3 "${BASE_URL}/health/ready" 2>/dev/null || true)"

python3 - "$SYS_JSON" "$LIVE" "$READY" "$MIN_SAMPLES" "$MIN_VALID_RATE" "$MAX_INVALID_RATE" <<'PY'
import json, sys

raw, live, ready = sys.argv[1], sys.argv[2], sys.argv[3]
min_samples = int(sys.argv[4])
min_valid = float(sys.argv[5])
max_invalid = float(sys.argv[6])

try:
    s = json.loads(raw)
except Exception as e:
    print(f"[gate2] FAIL system json: {e}")
    sys.exit(1)

agent = s.get("agent") or {}
total = int(agent.get("total") or 0)
ok = int(agent.get("ok") or 0)
invalid = int(agent.get("invalid") or 0)
errors = int(agent.get("errors") or 0)
valid_rate = float(agent.get("valid_rate") or 0.0)
tools = int(agent.get("tool_calls") or 0)
paused = bool(s.get("paused", False))
mode = s.get("mode") or s.get("exchange_mode") or "?"

invalid_rate = (100.0 * invalid / total) if total else 0.0

print("=== Gate 2 report ===")
print(f"health.live={live!r} health.ready={ready!r}")
print(f"mode={mode} paused={paused}")
print(
    f"agent total={total} ok={ok} invalid={invalid} errors={errors} "
    f"valid_rate={valid_rate:.1f}% invalid_rate={invalid_rate:.1f}% tool_calls={tools}"
)

fails = []
warns = []

if live.strip() not in ("ok", "OK", '{"status":"ok"}', "alive") and "live" not in live.lower() and live.strip() != "true":
    # Accept plain "ok" or any non-empty 2xx body from health/live.
    if not live.strip():
        fails.append("health/live empty")

if not ready.strip():
    warns.append("health/ready empty")

if paused:
    warns.append("daemon paused (agent loop stopped)")

if total < min_samples:
    warns.append(f"sample size {total} < {min_samples} (thresholds not enforced yet)")
else:
    if valid_rate < min_valid:
        fails.append(f"valid_rate {valid_rate:.1f}% < {min_valid}%")
    if invalid_rate > max_invalid:
        fails.append(f"invalid_rate {invalid_rate:.1f}% > {max_invalid}%")

print("--- checks ---")
for w in warns:
    print(f"WARN  {w}")
for f in fails:
    print(f"FAIL  {f}")
if not warns and not fails:
    print("OK    all checks green")

print("--- next ---")
print("1. Keep shadow soak ≥24h; re-run this script")
print("2. Confirm private REST balance (no ip_whitelist errors in journal)")
print("3. Spot-check Dashboard/API for secret leakage")
print("4. Demo keys ready → Phase 3 order path")

sys.exit(1 if fails else 0)
PY
