#!/bin/bash
set +e
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
  curl -sS --max-time 5 "http://127.0.0.1:8080/api/v1/$ep"; done 2>/dev/null)
if [ -f /etc/alphabound/secrets.env ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      OKX_API_KEY|OKX_API_SECRET|OKX_API_PASSPHRASE|LLM_API_KEY)
        [ -z "$v" ] && continue
        if printf '%s' "$DUMP" | grep -qF -- "$v"; then echo "SEC3 FAIL: $k value in dashboard response"; SEC3_FAIL=1; fi ;;
    esac
  done < /etc/alphabound/secrets.env
fi
printf '%s' "$DUMP" | grep -qE 'sk-[A-Za-z0-9]{16}' && { echo "SEC3 FAIL: sk- style token in dashboard responses"; SEC3_FAIL=1; }
[ "$SEC3_FAIL" -eq 0 ] && echo "SEC3 OK (dashboard responses free of secret values)"
echo "=== health ==="
curl -sS --max-time 3 http://127.0.0.1:8080/health/live; echo
curl -sS --max-time 3 http://127.0.0.1:8080/health/ready; echo
echo "=== system ==="
curl -sS --max-time 3 http://127.0.0.1:8080/api/v1/system; echo
echo "=== state ==="
curl -sS --max-time 3 http://127.0.0.1:8080/api/v1/state; echo
echo "=== decisions (AGENT_PROPOSAL_OK sample) ==="
DEC=$(curl -sS --max-time 5 http://127.0.0.1:8080/api/v1/decisions)
python3 -c '
import json,sys
raw=sys.argv[1] if len(sys.argv)>1 else "[]"
try:
  d=json.loads(raw)
except Exception as e:
  print("decisions_parse_fail", e, "len", len(raw)); sys.exit(0)
props=[x for x in d if x.get("type")=="AGENT_PROPOSAL_OK"]
print("proposal_ok_in_window", len(props), "agent_events", len(d))
for x in props[:5]:
  p=x.get("payload") or {}
  print(x.get("ts"), p.get("decision_id"), p.get("action"),
        "conf="+str(p.get("confidence")), "w="+str(p.get("target_btc_weight")))
' "$DEC"
echo "=== disk / llm (from system.status) ==="
curl -sS --max-time 3 http://127.0.0.1:8080/api/v1/system | python3 -c '
import json,sys
try:
  d=json.load(sys.stdin)
  s=d.get("status") or {}
  print("disk", s.get("disk"), "free_bytes", s.get("disk_free_bytes"))
  print("llm", s.get("llm"), s.get("llm_detail"))
  print("risk_hint mode", d.get("mode"), "ready", d.get("ready"), "uptime_ms", d.get("uptime_ms"))
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
