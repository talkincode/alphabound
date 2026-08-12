#!/bin/bash
# Runs ON the remote host (uploaded by restart-drill.sh). Root required.
# AC-GO1: after each restart the daemon must restore HWM from SQLite,
# reload memories, reconcile, and reach READY.
set -euo pipefail
CYCLES="${1:-3}"
DATA_DIR=/var/lib/alphabound

echo "=== alphabound restart-reconcile drill x$CYCLES $(date -u +%FT%TZ) ==="

PASS=0
for i in $(seq 1 "$CYCLES"); do
  echo "--- cycle $i ---"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) drill restart cycle=$i" >> "$DATA_DIR/deploys.log"
  T0=$(date +%s)
  systemctl restart alphabound

  READY=""
  for _ in $(seq 1 20); do
    if curl -sS --max-time 2 http://127.0.0.1:8080/health/ready | grep -q '"ready"'; then
      READY=yes
      break
    fi
    sleep 2
  done
  ELAPSED=$(( $(date +%s) - T0 ))

  BOOT="$(journalctl -u alphabound --since "@$T0" --no-pager 2>/dev/null)"
  HWM_LINE="$(printf "%s\n" "$BOOT" | grep -o "restored HWM.*" | head -1 || true)"
  MEM_LINE="$(printf "%s\n" "$BOOT" | grep -o "memories loaded count=[0-9]*" | head -1 || true)"
  REC_LINE="$(printf "%s\n" "$BOOT" | grep -oE "\[reconcile\][^\"]*" | head -1 || true)"

  echo "ready=$READY in ${ELAPSED}s"
  echo "hwm: ${HWM_LINE:-MISSING}"
  echo "memories: ${MEM_LINE:-MISSING}"
  echo "reconcile: ${REC_LINE:-none (no private keys)}"

  if [ "$READY" = "yes" ] && [ -n "$HWM_LINE" ] && [ -n "$MEM_LINE" ]; then
    PASS=$((PASS + 1))
  else
    echo "cycle $i: FAIL"
  fi
done

chown alphabound:alphabound "$DATA_DIR/deploys.log"

echo "--- result ---"
if [ "$PASS" -eq "$CYCLES" ]; then
  echo "RESTART DRILL: PASS ($PASS/$CYCLES cycles restored HWM + memories + READY)"
  exit 0
fi
echo "RESTART DRILL: FAIL ($PASS/$CYCLES)"
exit 1
