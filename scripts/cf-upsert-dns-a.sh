#!/usr/bin/env bash
# Upsert a Cloudflare A record for AlphaBound public hostname.
# Requires a token with Zone.DNS Edit on the zone (read-only tokens get HTTP 403).
#
# Usage:
#   export CF_API_TOKEN=...          # or CLOUDFLARE_API_TOKEN
#   ./scripts/cf-upsert-dns-a.sh YOUR_DOMAIN ORIGIN_IPV4 [proxied=true|false]
#
# Example:
#   ./scripts/cf-upsert-dns-a.sh alphabound.example.com x.x.x.x true
set -euo pipefail

DOMAIN="${1:-}"
IP="${2:-}"
PROXIED="${3:-true}"
TOKEN="${CF_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"

if [[ -z "$DOMAIN" || -z "$IP" || -z "$TOKEN" ]]; then
  echo "usage: CF_API_TOKEN=... $0 FQDN IPV4 [proxied]" >&2
  exit 2
fi

AUTH=( -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" )
ZONE_JSON=$(curl -fsS "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN#*.}")
# Prefer exact zone match for multi-label names: walk parents
name="$DOMAIN"
ZONE_ID=""
while [[ "$name" == *.* ]]; do
  ZONE_JSON=$(curl -fsS "${AUTH[@]}" "https://api.cloudflare.com/client/v4/zones?name=${name}")
  ZONE_ID=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("success") and d.get("result") else "")' <<<"$ZONE_JSON")
  if [[ -n "$ZONE_ID" ]]; then
    break
  fi
  name="${name#*.}"
done
if [[ -z "$ZONE_ID" ]]; then
  # last try apex as given second label walk already did
  echo "error: zone not found or token lacks Zone.Read for $DOMAIN" >&2
  exit 1
fi

LIST=$(curl -fsS "${AUTH[@]}" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${DOMAIN}")
REC_ID=$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"][0]["id"] if d.get("success") and d.get("result") else "")' <<<"$LIST")

BODY=$(PROXIED="$PROXIED" DOMAIN="$DOMAIN" IP="$IP" python3 - <<'PY'
import json, os
print(json.dumps({
  "type": "A",
  "name": os.environ["DOMAIN"],
  "content": os.environ["IP"],
  "ttl": 1 if os.environ.get("PROXIED","true").lower()=="true" else 300,
  "proxied": os.environ.get("PROXIED","true").lower()=="true",
}))
PY
)

if [[ -n "$REC_ID" ]]; then
  curl -fsS -X PUT "${AUTH[@]}" \
    --data "$BODY" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${REC_ID}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("success"), d; print("updated", d["result"]["name"], d["result"]["content"], "proxied="+str(d["result"]["proxied"]))'
else
  curl -fsS -X POST "${AUTH[@]}" \
    --data "$BODY" \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("success"), d; print("created", d["result"]["name"], d["result"]["content"], "proxied="+str(d["result"]["proxied"]))'
fi
