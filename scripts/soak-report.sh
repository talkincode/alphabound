#!/usr/bin/env bash
# Rolling-soak acceptance report for a remote host via sshx.
# Continuous-development replacement for frozen 24h/7d soak runs:
# judge a rolling window where deploy restarts are expected and only
# unexpected exits fail the gate.
# Usage: HOST=my-host ./scripts/soak-report.sh [WINDOW_HOURS]
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
WINDOW_H="${1:-24}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/soak-report-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/soak-report.sh >/dev/null
sshx -h="$HOST" --json --timeout=90s "sudo bash /tmp/soak-report.sh $WINDOW_H"
