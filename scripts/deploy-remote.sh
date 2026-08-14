#!/usr/bin/env bash
# Deploy AlphaBound to a remote Linux x86_64 host via sshx.
# Requires: zig 0.16, sshx, optional local secrets.env
# Usage: HOST=my-host ./scripts/deploy-remote.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${HOST:?set HOST to sshx host name}"
STAGE="${TMPDIR:-/tmp}/alphabound-deploy"
TAR="${TMPDIR:-/tmp}/alphabound-deploy.tgz"

echo "[deploy] cross-build x86_64-linux-musl ReleaseSafe"
cd "$ROOT"
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

rm -rf "$STAGE"
mkdir -p "$STAGE"/{opt/alphabound/current,etc/alphabound/prompts,systemd}
cp zig-out/bin/alphabound "$STAGE/opt/alphabound/current/"
cp prompts/system.md prompts/reflection.md prompts/review.md "$STAGE/etc/alphabound/prompts/"
cp deploy/alphabound.service "$STAGE/systemd/"
if [[ -f deploy/production.example.toml ]]; then
  cp deploy/production.example.toml "$STAGE/etc/alphabound/alphabound.toml"
else
  cp config/alphabound.toml "$STAGE/etc/alphabound/alphabound.toml"
fi

if [[ -f "$ROOT/secrets.env" ]]; then
  grep -E '^(OKX_|LLM_|OPENAI_|AZURE_|ALPHABOUND_)' "$ROOT/secrets.env" > "$STAGE/etc/alphabound/secrets.env" || true
  chmod 600 "$STAGE/etc/alphabound/secrets.env"
fi

cp deploy/install-remote.sh "$STAGE/install.sh"
chmod +x "$STAGE/install.sh"
git -C "$ROOT" rev-parse --short HEAD > "$STAGE/DEPLOY_SHA" 2>/dev/null || echo unknown > "$STAGE/DEPLOY_SHA"

COPYFILE_DISABLE=1 tar -C "$(dirname "$STAGE")" -czf "$TAR" "$(basename "$STAGE")"
echo "[deploy] upload -> $HOST"
sshx -h="$HOST" --upload="$TAR" --to=/tmp/alphabound-deploy.tgz
# Extract without sudo first (sshx sudo auto-fill is more reliable on a dedicated sudo step).
echo "[deploy] extract"
sshx -h="$HOST" --json --timeout=60s \
  "rm -rf /tmp/alphabound-deploy && tar xzf /tmp/alphabound-deploy.tgz -C /tmp"
echo "[deploy] install (sudo)"
sshx -h="$HOST" --json --timeout=180s \
  "sudo bash /tmp/alphabound-deploy/install.sh /tmp/alphabound-deploy"
sshx -h="$HOST" --json --timeout=30s \
  "rm -rf /tmp/alphabound-deploy /tmp/alphabound-deploy.tgz" || true
echo "[deploy] done — whitelist server egress IP on OKX if private balance fails"
