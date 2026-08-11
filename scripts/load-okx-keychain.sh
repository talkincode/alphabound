#!/usr/bin/env bash
# Load OKX API credentials from macOS Keychain into the environment / secrets.env.
# Never prints secret values. Service names match common Keychain items:
#   OKX_API_KEY, OKX_API_SECRET, "OKX_API_ Passphrase" (legacy space) | OKX_API_PASSPHRASE
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/secrets.env}"

kc_get() {
  local service="$1"
  security find-generic-password -s "$service" -w 2>/dev/null || true
}

KEY="$(kc_get "OKX_API_KEY")"
SECRET="$(kc_get "OKX_API_SECRET")"
PASS="$(kc_get "OKX_API_PASSPHRASE")"
if [[ -z "${PASS}" ]]; then
  PASS="$(kc_get "OKX_API_ Passphrase")"
fi
if [[ -z "${PASS}" ]]; then
  PASS="$(kc_get "OKX_API_PASSPHRASE")"
fi

missing=0
[[ -n "$KEY" ]] || { echo "[keychain] missing service OKX_API_KEY" >&2; missing=1; }
[[ -n "$SECRET" ]] || { echo "[keychain] missing service OKX_API_SECRET" >&2; missing=1; }
[[ -n "$PASS" ]] || { echo "[keychain] missing passphrase service (OKX_API_PASSPHRASE or 'OKX_API_ Passphrase')" >&2; missing=1; }
if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

# Quote values so shell metacharacters in passphrase (e.g. &) are safe to source.
shell_quote() {
  # single-quote with embedded ' -> '\'' 
  local s=$1
  printf "'"
  printf '%s' "$s" | sed "s/'/'\\\\''/g"
  printf "'"
}

umask 077
tmp="$(mktemp "${TMPDIR:-/tmp}/alphabound-secrets.XXXXXX")"
{
  printf 'OKX_API_KEY=%s\n' "$(shell_quote "$KEY")"
  printf 'OKX_API_SECRET=%s\n' "$(shell_quote "$SECRET")"
  printf 'OKX_API_PASSPHRASE=%s\n' "$(shell_quote "$PASS")"
} >"$tmp"
mv -f "$tmp" "$OUT"
chmod 600 "$OUT"

# Length-only confirmation (no values).
echo "[keychain] wrote $OUT (mode 600)"
echo "[keychain] OKX_API_KEY len=${#KEY} OKX_API_SECRET len=${#SECRET} OKX_API_PASSPHRASE len=${#PASS}"

# If sourced: export into current shell without printing values.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  export OKX_API_KEY="$KEY"
  export OKX_API_SECRET="$SECRET"
  export OKX_API_PASSPHRASE="$PASS"
  echo "[keychain] exported OKX_* into current shell"
fi

# Scrub locals in this process
KEY=; SECRET=; PASS=
