#!/usr/bin/env bash
# Load OpenAI-compatible / Azure OpenAI credentials from macOS Keychain into secrets.env.
# Never prints secret values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/secrets.env}"

kc_get() {
  local service="$1"
  security find-generic-password -s "$service" -w 2>/dev/null || true
}

shell_quote() {
  local s=$1
  printf "'"
  printf '%s' "$s" | sed "s/'/'\\\\''/g"
  printf "'"
}

KEY="$(kc_get "LLM_API_KEY")"
[[ -z "$KEY" ]] && KEY="$(kc_get "OPENAI_API_KEY")"
[[ -z "$KEY" ]] && KEY="$(kc_get "AZURE_OPENAI_API_KEY")"

URL="$(kc_get "LLM_API_URL")"
[[ -z "$URL" ]] && URL="$(kc_get "OPENAI_BASE_URL")"
[[ -z "$URL" ]] && URL="$(kc_get "AZURE_OPENAI_API_URL")"
[[ -z "$URL" ]] && URL="$(kc_get "AZURE_OPENAI_ENDPOINT")"

MODEL="$(kc_get "LLM_MODEL")"
[[ -z "$MODEL" ]] && MODEL="$(kc_get "OPENAI_MODEL")"
[[ -z "$MODEL" ]] && MODEL="$(kc_get "AZURE_OPENAI_DEPLOYMENT")"
[[ -z "$MODEL" ]] && MODEL="$(kc_get "AZURE_OPENAI_MODEL")"

if [[ -z "$KEY" ]]; then
  echo "[keychain] missing LLM/OpenAI/Azure API key service" >&2
  exit 1
fi
if [[ -z "$URL" ]]; then
  echo "[keychain] missing API URL service (LLM_API_URL / AZURE_OPENAI_API_URL)" >&2
  exit 1
fi
if [[ -z "$MODEL" ]]; then
  # Azure v1 often still needs a deployment/model name from config/env.
  MODEL="${LLM_MODEL:-gpt-4o-mini}"
  echo "[keychain] model service absent — defaulting model=$MODEL (override with LLM_MODEL)" >&2
fi

# Merge into existing secrets.env if present (preserve OKX lines).
umask 077
tmp="$(mktemp "${TMPDIR:-/tmp}/alphabound-llm.XXXXXX")"
if [[ -f "$OUT" ]]; then
  # Drop previous LLM/OpenAI/Azure lines then append fresh.
  grep -Ev '^(LLM_API_KEY|LLM_API_URL|LLM_MODEL|OPENAI_API_KEY|OPENAI_BASE_URL|OPENAI_MODEL|AZURE_OPENAI_API_KEY|AZURE_OPENAI_API_URL|AZURE_OPENAI_ENDPOINT|AZURE_OPENAI_DEPLOYMENT|AZURE_OPENAI_MODEL)=' "$OUT" >"$tmp" || true
else
  : >"$tmp"
fi
{
  printf 'LLM_API_KEY=%s\n' "$(shell_quote "$KEY")"
  printf 'LLM_API_URL=%s\n' "$(shell_quote "$URL")"
  printf 'LLM_MODEL=%s\n' "$(shell_quote "$MODEL")"
} >>"$tmp"
mv -f "$tmp" "$OUT"
chmod 600 "$OUT"

echo "[keychain] wrote LLM_* into $OUT (mode 600)"
echo "[keychain] key_len=${#KEY} url_len=${#URL} model_len=${#MODEL}"
KEY=; URL=; MODEL=
