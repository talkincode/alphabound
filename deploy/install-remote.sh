#!/bin/bash
# Runs ON the remote host (uploaded by scripts/deploy-remote.sh). Root required.
# Versioned deploy (AC-OPS5/OPS6):
#   /opt/alphabound/releases/<sha>-<ts>/alphabound   immutable releases
#   /opt/alphabound/current -> releases/...          atomic symlink switch
# Health-gated: if /health/ready fails after restart the symlink is rolled
# back to the previous release and the failure is recorded.
set -euo pipefail
ROOT="${1:-/tmp/alphabound-deploy}"

BASE=/opt/alphabound
RELEASES="$BASE/releases"
CURRENT="$BASE/current"
DATA_DIR=/var/lib/alphabound
KEEP_RELEASES="${KEEP_RELEASES:-5}"

echo "[install] alphabound on $(hostname)"
id -u alphabound >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" alphabound

mkdir -p "$RELEASES" "$BASE/ui/current" /etc/alphabound/prompts "$DATA_DIR"

DEPLOY_SHA="unknown"
[[ -f "$ROOT/DEPLOY_SHA" ]] && DEPLOY_SHA="$(cat "$ROOT/DEPLOY_SHA")"
TS="$(date -u +%Y%m%d%H%M%S)"
RELEASE_DIR="$RELEASES/${DEPLOY_SHA}-${TS}"

mkdir -p "$RELEASE_DIR"
install -m 0755 -o root -g root "$ROOT/opt/alphabound/current/alphabound" "$RELEASE_DIR/alphabound"
echo "[install] staged release $RELEASE_DIR"

# One-time migration: legacy layout had a real directory at $CURRENT.
PREV_TARGET=""
if [[ -L "$CURRENT" ]]; then
  PREV_TARGET="$(readlink -f "$CURRENT" || true)"
elif [[ -d "$CURRENT" ]]; then
  LEGACY="$RELEASES/legacy-$TS"
  mv "$CURRENT" "$LEGACY"
  PREV_TARGET="$LEGACY"
  echo "[install] migrated legacy $CURRENT -> $LEGACY"
fi

# Preserve live site config/bind on upgrade; only seed example on first install.
if [[ ! -f /etc/alphabound/alphabound.toml ]]; then
  install -m 0644 -o root -g root "$ROOT/etc/alphabound/alphabound.toml" /etc/alphabound/alphabound.toml
  echo "[install] seeded /etc/alphabound/alphabound.toml"
else
  echo "[install] keep existing /etc/alphabound/alphabound.toml"
fi

install -m 0644 -o root -g root "$ROOT/etc/alphabound/prompts/system.md" /etc/alphabound/prompts/system.md
install -m 0644 -o root -g root "$ROOT/etc/alphabound/prompts/reflection.md" /etc/alphabound/prompts/reflection.md

if [[ -f "$ROOT/etc/alphabound/secrets.env" ]]; then
  # Refresh secrets from deploy bundle when provided (local secrets.env filtered).
  install -m 0600 -o root -g alphabound "$ROOT/etc/alphabound/secrets.env" /etc/alphabound/secrets.env
else
  test -f /etc/alphabound/secrets.env || install -m 0600 -o root -g alphabound /dev/null /etc/alphabound/secrets.env
fi

chown -R alphabound:alphabound "$DATA_DIR"
chmod 750 "$DATA_DIR"

install -m 0644 -o root -g root "$ROOT/systemd/alphabound.service" /etc/systemd/system/alphabound.service
systemctl daemon-reload
systemctl enable alphabound

switch_release() {
  # Atomic switch: build the symlink aside, then rename over $CURRENT.
  ln -sfn "$1" "$CURRENT.tmp"
  mv -Tf "$CURRENT.tmp" "$CURRENT"
}

log_deploy() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$DATA_DIR/deploys.log"
  chown alphabound:alphabound "$DATA_DIR/deploys.log"
}

health_ready() {
  for _ in $(seq 1 15); do
    if curl -sS --max-time 2 http://127.0.0.1:8080/health/ready | grep -q '"ready"'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

switch_release "$RELEASE_DIR"
# Rolling-soak accounting: every deploy restart is recorded so the soak
# report can separate intentional restarts from crashes.
log_deploy "deploy sha=$DEPLOY_SHA release=$(basename "$RELEASE_DIR")"
systemctl restart alphabound

if health_ready; then
  echo "[install] health ready OK on $(basename "$RELEASE_DIR")"
else
  echo "[install] HEALTH FAILED on new release"
  if [[ -n "$PREV_TARGET" && -x "$PREV_TARGET/alphabound" ]]; then
    echo "[install] rolling back to $(basename "$PREV_TARGET")"
    switch_release "$PREV_TARGET"
    log_deploy "rollback-auto from=$(basename "$RELEASE_DIR") to=$(basename "$PREV_TARGET")"
    systemctl restart alphabound
    if health_ready; then
      echo "[install] ROLLED BACK OK to $(basename "$PREV_TARGET")"
    else
      echo "[install] ROLLBACK ALSO UNHEALTHY — manual intervention required"
    fi
  else
    echo "[install] no previous release to roll back to"
  fi
  exit 1
fi

# Prune old releases, newest KEEP_RELEASES kept; never delete the live target.
LIVE="$(readlink -f "$CURRENT")"
ls -1dt "$RELEASES"/*/ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  old="${old%/}"
  [[ "$(readlink -f "$old")" == "$LIVE" ]] && continue
  rm -rf "$old"
  echo "[install] pruned $(basename "$old")"
done

systemctl --no-pager -l status alphabound | head -12 || true

echo "[install] health"
curl -sS --max-time 3 http://127.0.0.1:8080/health/live || true
echo
curl -sS --max-time 3 http://127.0.0.1:8080/health/ready || true
echo
echo "[install] done"
