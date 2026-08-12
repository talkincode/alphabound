#!/usr/bin/env bash
# kill -9 crash-recovery drill via sshx (AC-NFR04).
# Records the drill in deploys.log (so the rolling soak report treats it as
# expected), SIGKILLs the daemon, then verifies systemd restarts it and the
# boot sequence reaches READY.
# Usage: HOST=my-host ./scripts/kill9-drill.sh
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/kill9-drill-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/kill9-drill.sh >/dev/null
sshx -h="$HOST" --json --timeout=120s "sudo bash /tmp/kill9-drill.sh"
