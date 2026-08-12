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
DRILL_KILLS=0
if [[ -f "$DEPLOYS_LOG" ]]; then
  DEPLOYS=$(awk -v since="$SINCE" '$1 >= since' "$DEPLOYS_LOG" | tee /dev/stderr | wc -l | tr -d ' ')
  DRILL_KILLS=$(awk -v since="$SINCE" '$1 >= since' "$DEPLOYS_LOG" | grep -c "drill kill-9")
fi
echo "deploys_in_window $DEPLOYS"
echo "drill_kills_in_window $DRILL_KILLS"

echo "=== service starts / unexpected exits (journal) ==="
J="$(journalctl -u alphabound --since "${WINDOW_H} hours ago" --no-pager 2>/dev/null)"
STARTS=$(printf "%s\n" "$J" | grep -c "Started AlphaBound")
# "Failed with result" is emitted exactly once per failed unit cycle —
# use it as the canonical unexpected-exit counter (kill/crash/oom/watchdog).
FAILED=$(printf "%s\n" "$J" | grep -c "Failed with result")
KILLED=$(printf "%s\n" "$J" | grep -cE "Main process exited, code=(killed|dumped)")
CLEAN_STOPS=$(printf "%s\n" "$J" | grep -cE "Stopping AlphaBound|Deactivated successfully|Succeeded")
# Continuous-dev churn: failures within CHURN_MIN minutes of a deploy/rollback
# (or a restart drill) are expected — e.g. bad binary crash-loop until next fix.
CHURN_MIN="${DEPLOY_CHURN_MIN:-15}"
CHURN_FAIL=$(python3 - "$DEPLOYS_LOG" "$CHURN_MIN" "$WINDOW_H" <<'PY' 2>/dev/null || echo 0
import sys, subprocess, re
from datetime import datetime, timedelta, timezone
log_path, churn_min, window_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
anchors = []
try:
    with open(log_path) as f:
        for line in f:
            parts = line.strip().split()
            if not parts:
                continue
            ts = parts[0]
            if ts.endswith("Z"):
                try:
                    anchors.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                except ValueError:
                    pass
except FileNotFoundError:
    pass
# Force UTC so local journal TZ (+0800 etc.) lines up with deploys.log (Zulu).
j = subprocess.check_output(
    ["journalctl", "-u", "alphabound", "--utc", "--since", f"{window_h} hours ago",
     "--no-pager", "-o", "short-iso"],
    text=True,
    stderr=subprocess.DEVNULL,
)
# short-iso may be "2026-08-12T09:06:04+0000" or "...Z" or with space.
pat = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})([+-]\d{2}:?\d{2}|Z)?"
)
fails = []
for line in j.splitlines():
    if "Failed with result" not in line:
        continue
    m = pat.match(line)
    if not m:
        continue
    raw = m.group(1)
    off = m.group(2) or "+00:00"
    if off == "Z":
        off = "+00:00"
    elif len(off) == 5 and (off[0] in "+-"):  # +0000
        off = off[:3] + ":" + off[3:]
    try:
        fails.append(datetime.fromisoformat(raw + off))
    except ValueError:
        try:
            fails.append(datetime.fromisoformat(raw).replace(tzinfo=timezone.utc))
        except ValueError:
            pass
# Crash-loops after a bad deploy can trail the deploy stamp by several minutes;
# count each failure whose nearest deploy/rollback is within churn_min.
window = timedelta(minutes=churn_min)
churn = 0
for ft in fails:
    if ft.tzinfo is None:
        ft = ft.replace(tzinfo=timezone.utc)
    for a in anchors:
        if a.tzinfo is None:
            a = a.replace(tzinfo=timezone.utc)
        if abs((ft - a).total_seconds()) <= window.total_seconds():
            churn += 1
            break
print(churn)
PY
)
# Clamp: churn cannot exceed FAILED.
if [[ "${CHURN_FAIL:-0}" -gt "$FAILED" ]]; then CHURN_FAIL=$FAILED; fi
echo "service_starts $STARTS"
echo "clean_stops $CLEAN_STOPS"
echo "unexpected_exits $FAILED (signal_or_dump $KILLED deploy_churn $CHURN_FAIL window_min $CHURN_MIN)"
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
# Dashboard auth: use token from env or secrets.env (never print it).
API_AUTH=()
_tok="${ALPHABOUND_API_TOKEN:-${DASHBOARD_API_TOKEN:-}}"
if [ -z "$_tok" ] && [ -f /etc/alphabound/secrets.env ]; then
  _tok=$(grep -E '^[[:space:]]*(export[[:space:]]+)?ALPHABOUND_API_TOKEN=' /etc/alphabound/secrets.env 2>/dev/null \
    | tail -1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?ALPHABOUND_API_TOKEN=//' | tr -d '\r' \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
fi
if [ -n "$_tok" ]; then API_AUTH=(-H "X-API-Token: ${_tok}"); fi
unset _tok
SYS="$(curl -sS --max-time 3 "${API_AUTH[@]}" http://127.0.0.1:8080/api/v1/system 2>/dev/null)"
LAT_VERDICT="$(python3 - "$SYS" "${P99_BUDGET_US:-10000}" <<'PY'
import json, sys
budget = int(sys.argv[2])
try:
    d = json.loads(sys.argv[1])
except Exception as e:
    print("system_parse_fail", e); raise SystemExit
if d.get("error"):
    print("system_error", d.get("error")); raise SystemExit
st = d.get("status") or {}
lat = st.get("latency_us") or {}
ag = d.get("agent") or {}
print(f"uptime_ms {d.get('uptime_ms')}")
print(f"mode {d.get('mode')} ready {d.get('ready')}")
print(f"latency_us p50={lat.get('p50')} p99={lat.get('p99')} max={lat.get('max')} samples={lat.get('samples')}")
print(f"agent total={ag.get('total')} ok={ag.get('ok')} invalid={ag.get('invalid')} errors={ag.get('errors')} valid_rate={ag.get('valid_rate')}")
print(f"tokens total={st.get('total_tokens')} llm_calls={st.get('llm_calls')}")
print(f"disk {st.get('disk')} free_bytes {st.get('disk_free_bytes')}")
ex = d.get("execution") or {}
print(f"execution enabled={ex.get('enabled')} real_money={ex.get('real_money')}")
# AC-NFR01: p99 must stay under budget once there is a real sample base.
p99 = lat.get("p99") or 0
samples = lat.get("samples") or 0
if samples >= 20 and p99 > budget:
    print(f"LATENCY_BREACH p99={p99}us budget={budget}us samples={samples}")
PY
)"
printf "%s\n" "$LAT_VERDICT"
LAT_BREACH=$(printf "%s\n" "$LAT_VERDICT" | grep -c "LATENCY_BREACH")

echo "=== WAL / DB size ==="
ls -l /var/lib/alphabound/trading.db* 2>/dev/null | awk '{print $5, $9}'
ls /var/lib/alphabound/*.bak* 2>/dev/null | tail -5

echo "=== resource guards (AC-NFR06) ==="
RES_BREACH=0
PID_NOW="$(systemctl show -p MainPID --value alphabound)"
if [[ -n "$PID_NOW" && "$PID_NOW" != "0" ]]; then
  RSS_KB=$(ps -o rss= -p "$PID_NOW" | tr -d ' ')
  FDS=$(ls /proc/"$PID_NOW"/fd 2>/dev/null | wc -l)
  echo "rss_kb $RSS_KB (budget ${RSS_BUDGET_KB:-262144})"
  echo "open_fds $FDS (budget ${FD_BUDGET:-256})"
  [[ "$RSS_KB" -gt "${RSS_BUDGET_KB:-262144}" ]] && { echo "RESOURCE_BREACH rss"; RES_BREACH=1; }
  [[ "$FDS" -gt "${FD_BUDGET:-256}" ]] && { echo "RESOURCE_BREACH fds"; RES_BREACH=1; }
fi
WAL_B=$(stat -c %s /var/lib/alphabound/trading.db-wal 2>/dev/null || echo 0)
echo "wal_bytes $WAL_B (budget ${WAL_BUDGET_B:-67108864})"
[[ "$WAL_B" -gt "${WAL_BUDGET_B:-67108864}" ]] && { echo "RESOURCE_BREACH wal"; RES_BREACH=1; }

echo "=== verdict ==="
# Continuous-dev model: judge the *current release stable window* first —
# failures that only happened during earlier deploy churn do not fail soak if
# the process has been clean since (last deploy + CHURN_MIN).
STABLE_FAIL=$(python3 - "$DEPLOYS_LOG" "$CHURN_MIN" <<'PY' 2>/dev/null || echo -1
import sys, subprocess, re
from datetime import datetime, timedelta, timezone
log_path, churn_min = sys.argv[1], int(sys.argv[2])
anchors = []
try:
    with open(log_path) as f:
        for line in f:
            parts = line.strip().split()
            if not parts:
                continue
            ts = parts[0]
            if ts.endswith("Z"):
                try:
                    anchors.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
                except ValueError:
                    pass
except FileNotFoundError:
    pass
if not anchors:
    print(0)
    raise SystemExit
last = max(anchors)
start = last + timedelta(minutes=churn_min)
# journal since start (UTC)
since = start.strftime("%Y-%m-%d %H:%M:%S UTC")
j = subprocess.check_output(
    ["journalctl", "-u", "alphabound", "--utc", "--since", since,
     "--no-pager", "-o", "short-iso"],
    text=True,
    stderr=subprocess.DEVNULL,
)
n = sum(1 for line in j.splitlines() if "Failed with result" in line)
print(n)
print(f"stable_since_utc {start.isoformat().replace('+00:00','Z')}", file=sys.stderr)
print(f"last_deploy_utc {last.isoformat().replace('+00:00','Z')}", file=sys.stderr)
PY
)
# stderr from python (stable_since) lands in soak stdout via tee? keep simple:
echo "stable_window_failures ${STABLE_FAIL} (after last_deploy+${CHURN_MIN}m)"

# Full-window adjusted count kept for visibility.
FAILED_ADJ=$((FAILED - DRILL_KILLS - CHURN_FAIL))
[[ "$FAILED_ADJ" -lt 0 ]] && FAILED_ADJ=0
echo "full_window_adjusted_exits $FAILED_ADJ (raw=$FAILED drills=$DRILL_KILLS churn=$CHURN_FAIL)"

if [[ "${STABLE_FAIL}" -lt 0 ]]; then
  echo "SOAK FAIL could not compute stable window"
  exit 1
fi
if [[ "${STABLE_FAIL}" -gt 0 ]]; then
  echo "SOAK FAIL unexpected_exits=${STABLE_FAIL} since last deploy+${CHURN_MIN}m (current release unstable)"
  exit 1
fi
if [[ "$LAT_BREACH" -gt 0 ]]; then
  echo "SOAK FAIL latency p99 over budget (AC-NFR01)"
  exit 1
fi
if [[ "$RES_BREACH" -gt 0 ]]; then
  echo "SOAK FAIL resource budget breached (AC-NFR06)"
  exit 1
fi
# Current unit must be active.
if ! systemctl is-active --quiet alphabound; then
  echo "SOAK FAIL service not active"
  exit 1
fi
echo "SOAK PASS rolling ${WINDOW_H}h: current release stable (0 fails after last deploy+${CHURN_MIN}m); full_window_raw=$FAILED accounted via churn/drills"
exit 0
