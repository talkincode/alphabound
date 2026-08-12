#!/bin/bash
# Runs ON the remote host (uploaded by kill9-drill.sh). Root required.
# AC-NFR04: SIGKILL the daemon; systemd must restart it and the state
# machine must reach READY (health/ready ok) within the budget.
set -euo pipefail
DATA_DIR=/var/lib/alphabound

echo "=== alphabound kill -9 drill $(date -u +%FT%TZ) ==="

PID="$(systemctl show -p MainPID --value alphabound)"
if [ -z "$PID" ] || [ "$PID" = "0" ]; then
  echo "KILL9 DRILL: FAIL (service not running)"
  exit 1
fi
echo "main_pid: $PID"

# Record BEFORE killing so the rolling soak report books this as expected.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) drill kill-9 pid=$PID" >> "$DATA_DIR/deploys.log"
chown alphabound:alphabound "$DATA_DIR/deploys.log"

START_TS=$(date +%s)
kill -9 "$PID"
echo "SIGKILL sent"

# systemd Restart=always / RestartSec=5: expect a new PID then READY.
NEW_PID=""
for _ in $(seq 1 20); do
  sleep 1
  NEW_PID="$(systemctl show -p MainPID --value alphabound)"
  if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "0" ] && [ "$NEW_PID" != "$PID" ]; then
    break
  fi
done
if [ -z "$NEW_PID" ] || [ "$NEW_PID" = "0" ] || [ "$NEW_PID" = "$PID" ]; then
  echo "KILL9 DRILL: FAIL (no restart within 20s)"
  exit 1
fi
echo "restarted_pid: $NEW_PID"

READY=""
for _ in $(seq 1 20); do
  if curl -sS --max-time 2 http://127.0.0.1:8080/health/ready | grep -q '"ready"'; then
    READY=yes
    break
  fi
  sleep 2
done
ELAPSED=$(( $(date +%s) - START_TS ))

echo "--- boot sequence after kill ---"
journalctl -u alphabound --since "@$START_TS" --no-pager 2>/dev/null \
  | grep -E "Started AlphaBound|BOOTING|RECONCILING|READY|state" | head -10 || true

if [ "$READY" = "yes" ]; then
  echo "KILL9 DRILL: PASS (recovered to READY in ${ELAPSED}s)"
  exit 0
fi
echo "KILL9 DRILL: FAIL (not ready after ${ELAPSED}s)"
exit 1
