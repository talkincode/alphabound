#!/usr/bin/env bash
# Restart-reconcile drill via sshx (AC-GO1 / AC-NFR04).
# Restarts the daemon N times; each cycle must restore HWM from the DB,
# reload memories, and reach READY. Restarts are recorded in deploys.log
# so the rolling soak report books them as expected.
# Usage: HOST=my-host ./scripts/restart-drill.sh [CYCLES]
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
CYCLES="${1:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/restart-drill-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/restart-drill.sh >/dev/null
sshx -h="$HOST" --json --timeout=300s "sudo bash /tmp/restart-drill.sh $CYCLES"
