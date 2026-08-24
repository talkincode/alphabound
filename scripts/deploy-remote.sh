#!/usr/bin/env bash
# Deploy AlphaBound to a remote Linux x86_64 host via sshx.
# Requires: zig 0.16, sshx, optional local secrets.env
# Usage:
#   HOST=my-host ./scripts/deploy-remote.sh
#   HOST=my-host SECRETS_FILE=./secrets.other.env ./scripts/deploy-remote.sh
# SECRETS_FILE avoids shipping the default local secrets.env (another
# host's live OKX keys) to a different machine.
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
cp prompts/system.md prompts/reflection.md prompts/review.md prompts/periodic_review.md "$STAGE/etc/alphabound/prompts/"
cp deploy/alphabound.service "$STAGE/systemd/"
if [[ -f deploy/production.example.toml ]]; then
  cp deploy/production.example.toml "$STAGE/etc/alphabound/alphabound.toml"
else
  cp config/alphabound.toml "$STAGE/etc/alphabound/alphabound.toml"
fi

# Optional SECRETS_FILE avoids shipping the default local secrets.env
# (which may hold another host's live OKX keys) to a different machine.
# Empty OKX_* values are not packed: an upgrade must not clobber a live
# host's EnvironmentFile with placeholders. First install still seeds
# when the file has real keys. FORCE_SECRETS=1 is required to overwrite
# an existing remote secrets.env (see deploy/install-remote.sh).
SECRETS_FILE="${SECRETS_FILE:-}"
pack_secrets() {
  local src="$1"
  local dest="$STAGE/etc/alphabound/secrets.env"
  grep -E '^(OKX_|LLM_|OPENAI_|AZURE_|ALPHABOUND_)' "$src" > "$dest" || true
  chmod 600 "$dest"
  local key_len
  key_len="$(awk -F= '/^OKX_API_KEY=/{print length($2); exit}' "$dest")"
  key_len="${key_len:-0}"
  if [[ "$key_len" -eq 0 ]]; then
    rm -f "$dest"
    echo "[deploy] not packing secrets.env (OKX_API_KEY empty) — remote file will be kept"
    return 0
  fi
  echo "[deploy] packed secrets.env from $src (OKX_API_KEY len=$key_len)"
}

if [[ -n "$SECRETS_FILE" ]]; then
  if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "[deploy] SECRETS_FILE not found: $SECRETS_FILE" >&2
    exit 1
  fi
  pack_secrets "$SECRETS_FILE"
elif [[ -f "$ROOT/secrets.env" ]]; then
  pack_secrets "$ROOT/secrets.env"
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
  "sudo env FORCE_SECRETS=${FORCE_SECRETS:-} bash /tmp/alphabound-deploy/install.sh /tmp/alphabound-deploy"
sshx -h="$HOST" --json --timeout=30s \
  "rm -rf /tmp/alphabound-deploy /tmp/alphabound-deploy.tgz" || true
echo "[deploy] done — whitelist server egress IP on OKX if private balance fails"
