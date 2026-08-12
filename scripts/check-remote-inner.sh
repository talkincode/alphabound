#!/bin/bash
set +e
# Authenticated /api/v1/* when dashboard token is configured.
API_BASE="${API_BASE:-http://127.0.0.1:8080}"
API_AUTH=()
load_api_token() {
  local tok="${ALPHABOUND_API_TOKEN:-${DASHBOARD_API_TOKEN:-}}"
  if [ -z "$tok" ] && [ -f /etc/alphabound/secrets.env ]; then
    tok=$(grep -E '^[[:space:]]*(export[[:space:]]+)?ALPHABOUND_API_TOKEN=' /etc/alphabound/secrets.env 2>/dev/null \
      | tail -1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?ALPHABOUND_API_TOKEN=//' | tr -d '\r' \
      | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  fi
  if [ -n "$tok" ]; then
    API_AUTH=(-H "X-API-Token: ${tok}")
    echo "api_auth token"
  else
    echo "api_auth open"
  fi
}
api_get() {
  # $1 path e.g. /api/v1/system  $2 optional timeout
  curl -sS --max-time "${2:-5}" "${API_AUTH[@]}" "${API_BASE}$1"
}
load_api_token
echo "=== service ==="
systemctl is-active alphabound
systemctl is-enabled alphabound 2>/dev/null
echo "=== secrets hygiene (AC-SEC2) ==="
SEC_FAIL=0
if [ -f /etc/alphabound/secrets.env ]; then
  PERMS=$(stat -c '%a %U:%G' /etc/alphabound/secrets.env)
  echo "secrets.env $PERMS"
  case "$PERMS" in
    "600 root:alphabound"|"640 root:alphabound"|"600 root:root") ;;
    *) echo "SEC2 FAIL: unexpected perms/owner (want 600 root:alphabound)"; SEC_FAIL=1 ;;
  esac
else
  echo "secrets.env missing"
fi
# Secrets must never leak into data dir or backups.
LEAK=$(grep -rl "OKX_API\|API_KEY" /var/lib/alphabound/ 2>/dev/null | grep -v '\.db' | head -3)
if [ -n "$LEAK" ]; then echo "SEC2 FAIL: secret-like strings in data dir: $LEAK"; SEC_FAIL=1; else echo "data dir clean"; fi
# Backup content spot-check: actual secret VALUES must not be inside DB/backup bytes.
if [ -f /etc/alphabound/secrets.env ]; then
  BAK_LEAK=0
  while IFS='=' read -r k v; do
    case "$k" in
      OKX_API_KEY|OKX_API_SECRET|OKX_API_PASSPHRASE|LLM_API_KEY)
        [ -z "$v" ] && continue
        for f in /var/lib/alphabound/trading.db /var/lib/alphabound/trading.db.bak /var/lib/alphabound/trading.db-wal; do
          [ -f "$f" ] || continue
          if grep -qF -- "$v" "$f" 2>/dev/null; then echo "SEC2 FAIL: $k value present in $f"; BAK_LEAK=1; SEC_FAIL=1; fi
        done ;;
    esac
  done < /etc/alphabound/secrets.env
  [ "$BAK_LEAK" -eq 0 ] && echo "db+backup clean (no secret values)"
fi
[ "$SEC_FAIL" -eq 0 ] && echo "SEC2 OK"
echo "=== dashboard redaction (AC-SEC3) ==="
SEC3_FAIL=0
DUMP=$(for ep in system state "events?limit=200" decisions "orders?limit=50" "memories?limit=100" shadow; do
  api_get "/api/v1/$ep" 5; done 2>/dev/null)
if printf '%s' "$DUMP" | grep -q '"error":"unauthorized"'; then
  echo "SEC3 WARN: unauthorized responses (token missing/mismatch); redaction sample incomplete"
fi
if [ -f /etc/alphabound/secrets.env ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      OKX_API_KEY|OKX_API_SECRET|OKX_API_PASSPHRASE|LLM_API_KEY|ALPHABOUND_API_TOKEN)
        [ -z "$v" ] && continue
        if printf '%s' "$DUMP" | grep -qF -- "$v"; then echo "SEC3 FAIL: $k value in dashboard response"; SEC3_FAIL=1; fi ;;
    esac
  done < /etc/alphabound/secrets.env
fi
printf '%s' "$DUMP" | grep -qE 'sk-[A-Za-z0-9]{16}' && { echo "SEC3 FAIL: sk- style token in dashboard responses"; SEC3_FAIL=1; }
[ "$SEC3_FAIL" -eq 0 ] && echo "SEC3 OK (dashboard responses free of secret values)"
echo "=== health ==="
curl -sS --max-time 3 "${API_BASE}/health/live"; echo
curl -sS --max-time 3 "${API_BASE}/health/ready"; echo
echo "=== system ==="
api_get /api/v1/system 3; echo
echo "=== state ==="
api_get /api/v1/state 3; echo
echo "=== decisions (AGENT_PROPOSAL_OK sample) ==="
DEC=$(api_get /api/v1/decisions 5)
python3 -c '
import json,sys
raw=sys.argv[1] if len(sys.argv)>1 else "[]"
try:
  d=json.loads(raw)
except Exception as e:
  print("decisions_parse_fail", e, "len", len(raw)); sys.exit(0)
if isinstance(d, dict):
  if d.get("error"):
    print("decisions_error", d.get("error")); sys.exit(0)
  d = d.get("items") or d.get("events") or d.get("decisions") or []
if not isinstance(d, list):
  print("decisions_unexpected_type", type(d).__name__); sys.exit(0)
props=[x for x in d if isinstance(x, dict) and x.get("type")=="AGENT_PROPOSAL_OK"]
print("proposal_ok_in_window", len(props), "agent_events", len(d))
for x in props[:5]:
  p=x.get("payload") or {}
  if isinstance(p, str):
    try: p=json.loads(p)
    except Exception: p={}
  print(x.get("ts"), p.get("decision_id"), p.get("action"),
        "conf="+str(p.get("confidence")), "w="+str(p.get("target_btc_weight")))
' "$DEC"
echo "=== orders exchange_id sample ==="
ORD=$(api_get "/api/v1/orders?limit=20" 5)
python3 -c '
import json,sys
raw=sys.argv[1] if len(sys.argv)>1 else "[]"
try:
  d=json.loads(raw)
except Exception as e:
  print("orders_parse_fail", e); sys.exit(0)
if isinstance(d, dict):
  if d.get("error"):
    print("orders_error", d.get("error")); sys.exit(0)
  d = d.get("orders") or d.get("items") or []
if not isinstance(d, list):
  print("orders_unexpected_type", type(d).__name__); sys.exit(0)
n=len(d); filled=0; with_xid=0
for o in d:
  if not isinstance(o, dict):
    continue
  st=(o.get("status") or o.get("state") or "").lower()
  xid=o.get("exchange_order_id") or o.get("exchange_id") or ""
  if st in ("filled","partial","partially_filled","acked","acknowledged","live"):
    filled += 1
    if str(xid).strip():
      with_xid += 1
print("orders", n, "terminal_or_open", filled, "with_exchange_id", with_xid)
' "$ORD"
echo "=== disk / llm (from system.status) ==="
api_get /api/v1/system 3 | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin)
  if d.get("error"):
    print("system_error", d.get("error")); raise SystemExit
  s=d.get("status") or {}
  print("disk", s.get("disk"), "free_bytes", s.get("disk_free_bytes"))
  print("llm", s.get("llm"), s.get("llm_detail"))
  print("mode", d.get("mode"), "ready", d.get("ready"), "uptime_ms", d.get("uptime_ms"))
  ex=d.get("execution") or {}
  print("execution enabled", ex.get("enabled"), "real_money", ex.get("real_money"))
except Exception as e:
  print("system_parse_fail", e)
' 2>/dev/null || echo "system_status_unavailable"
echo "=== journal (15m) counters ==="
J=$(journalctl -u alphabound --since "15 min ago" --no-pager 2>/dev/null)
echo "proposal_ok $(printf "%s\n" "$J" | grep -c "proposal ok" || true)"
echo "reflect_ok $(printf "%s\n" "$J" | grep -c "reflect].*ok" || true)"
echo "llm_fail $(printf "%s\n" "$J" | grep -c "LLM failed" || true)"
echo "llm_timeout $(printf "%s\n" "$J" | grep -c "timeout budget_ms" || true)"
echo "disk_events $(printf "%s\n" "$J" | grep -c "\[disk\]" || true)"
echo "ip_whitelist $(printf "%s\n" "$J" | grep -c "ip_whitelist" || true)"
echo "backup_ok $(printf "%s\n" "$J" | grep -c "backup] ok" || true)"
echo "=== egress ip (add to OKX whitelist if ip_whitelist>0) ==="
curl -sS --max-time 5 https://api.ipify.org || curl -sS --max-time 5 https://ifconfig.me || echo unknown
echo
echo "=== process ==="
ps -o pid,etime,rss,cmd -C alphabound 2>/dev/null || ps aux | grep "[a]lphabound" | head -3
exit 0
