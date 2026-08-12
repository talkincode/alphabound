#!/bin/bash
# Runs ON the remote host (uploaded by rollback-remote.sh). Root required.
# Switches /opt/alphabound/current to a previous release and restarts.
set -euo pipefail
TARGET_NAME="${1:-}"

BASE=/opt/alphabound
CURRENT="$BASE/current"
RELEASES="$BASE/releases"
DATA_DIR=/var/lib/alphabound

LIVE="$(readlink -f "$CURRENT" || true)"
echo "live: $(basename "${LIVE:-none}")"

if [ -n "$TARGET_NAME" ]; then
  DEST="$RELEASES/$TARGET_NAME"
else
  DEST=""
  for d in $(ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's:/$::'); do
    [ "$(readlink -f "$d")" = "$LIVE" ] && continue
    DEST="$d"
    break
  done
fi

if [ -z "${DEST:-}" ] || [ ! -x "$DEST/alphabound" ]; then
  echo "ROLLBACK: FAIL (no usable release: ${DEST:-none})"
  ls -1dt "$RELEASES"/*/ 2>/dev/null | head -5 || true
  exit 1
fi

echo "rolling back to: $(basename "$DEST")"
ln -sfn "$DEST" "$CURRENT.tmp" && mv -Tf "$CURRENT.tmp" "$CURRENT"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rollback-manual from=$(basename "${LIVE:-none}") to=$(basename "$DEST")" >> "$DATA_DIR/deploys.log"
chown alphabound:alphabound "$DATA_DIR/deploys.log"
systemctl restart alphabound

for _ in $(seq 1 15); do
  if curl -sS --max-time 2 http://127.0.0.1:8080/health/ready | grep -q '"ready"'; then
    echo "ROLLBACK: PASS ($(basename "$DEST") ready)"
    exit 0
  fi
  sleep 2
done
echo "ROLLBACK: FAIL (health not ready on $(basename "$DEST"))"
exit 1
