#!/bin/bash
set +e
echo "=== service ==="
systemctl is-active alphabound
systemctl is-enabled alphabound 2>/dev/null
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
