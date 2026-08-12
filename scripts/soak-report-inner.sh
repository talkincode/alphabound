#!/bin/bash
# Rolling-soak report — runs ON the production host (root).
# Continuous development means the binary is redeployed often; instead of a
# frozen 24h/7d run, acceptance is judged on a rolling window:
#   PASS = zero unexpected exits (crash/oom/watchdog) in the window;
#          deploy-driven restarts (recorded in deploys.log) are expected.
# Usage: soak-report-inner.sh [WINDOW_HOURS]
set +e
WINDOW_H="${1:-24}"
SINCE="$(date -u -d "-${WINDOW_H} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${WINDOW_H}"H +%Y-%m-%dT%H:%M:%SZ)"
DEPLOYS_LOG=/var/lib/alphabound/deploys.log

echo "=== rolling soak window ==="
echo "window_hours $WINDOW_H since_utc $SINCE now_utc $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "=== deploys in window (expected restarts) ==="
DEPLOYS=0
if [[ -f "$DEPLOYS_LOG" ]]; then
  DEPLOYS=$(awk -v since="$SINCE" '$1 >= since' "$DEPLOYS_LOG" | tee /dev/stderr | wc -l | tr -d ' ')
fi
echo "deploys_in_window $DEPLOYS"

echo "=== service starts / unexpected exits (journal) ==="
J="$(journalctl -u alphabound --since "${WINDOW_H} hours ago" --no-pager 2>/dev/null)"
STARTS=$(printf "%s\n" "$J" | grep -c "Started AlphaBound")
FAILED=$(printf "%s\n" "$J" | grep -cE "Failed with result|Main process exited, code=(killed|dumped)|oom-kill|Watchdog timeout")
CLEAN_STOPS=$(printf "%s\n" "$J" | grep -cE "Stopping AlphaBound|Deactivated successfully|Succeeded")
echo "service_starts $STARTS"
echo "clean_stops $CLEAN_STOPS"
echo "unexpected_exits $FAILED"
printf "%s\n" "$J" | grep -E "Failed with result|code=(killed|dumped)|oom-kill|Watchdog timeout" | tail -5

echo "=== error counters (window) ==="
echo "llm_fail $(printf "%s\n" "$J" | grep -c "LLM failed")"
echo "llm_timeout $(printf "%s\n" "$J" | grep -c "timeout budget_ms")"
echo "ip_whitelist $(printf "%s\n" "$J" | grep -c "ip_whitelist")"
echo "disk_events $(printf "%s\n" "$J" | grep -c "\[disk\]")"
echo "backup_ok $(printf "%s\n" "$J" | grep -c "backup] ok")"
echo "backup_failed $(printf "%s\n" "$J" | grep -c "BACKUP_FAILED\|backup] failed")"

echo "=== current process / latency ==="
systemctl is-active alphabound
ps -o pid,etime,rss --no-headers -C alphabound 2>/dev/null | head -1
SYS="$(curl -sS --max-time 3 http://127.0.0.1:8080/api/v1/system 2>/dev/null)"
python3 - "$SYS" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("system_parse_fail", e); raise SystemExit
st = d.get("status") or {}
lat = st.get("latency_us") or {}
ag = d.get("agent") or {}
print(f"uptime_ms {d.get('uptime_ms')}")
print(f"latency_us p50={lat.get('p50')} p99={lat.get('p99')} max={lat.get('max')} samples={lat.get('samples')}")
print(f"agent total={ag.get('total')} ok={ag.get('ok')} invalid={ag.get('invalid')} errors={ag.get('errors')} valid_rate={ag.get('valid_rate')}")
print(f"tokens total={st.get('total_tokens')} llm_calls={st.get('llm_calls')}")
print(f"disk {st.get('disk')} free_bytes {st.get('disk_free_bytes')}")
PY

echo "=== WAL / DB size ==="
ls -l /var/lib/alphabound/trading.db* 2>/dev/null | awk '{print $5, $9}'
ls /var/lib/alphabound/*.bak* 2>/dev/null | tail -5

echo "=== verdict ==="
if [[ "$FAILED" -gt 0 ]]; then
  echo "SOAK FAIL unexpected_exits=$FAILED in ${WINDOW_H}h window"
  exit 1
fi
EXTRA=$((STARTS - DEPLOYS))
if [[ "$EXTRA" -gt 1 ]]; then
  # One extra start can be the window edge (boot before the first deploy record).
  echo "SOAK WARN starts=$STARTS deploys=$DEPLOYS — investigate non-deploy restarts"
  exit 0
fi
echo "SOAK PASS rolling ${WINDOW_H}h: no unexpected exits; restarts accounted for by deploys"
exit 0
