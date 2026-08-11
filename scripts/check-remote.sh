#!/usr/bin/env bash
# Snapshot AlphaBound health on a remote host via sshx.
# Usage: HOST=my-host ./scripts/check-remote.sh
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/check-remote-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/check-alphabound.sh >/dev/null
sshx -h="$HOST" --json --timeout=60s "sudo bash /tmp/check-alphabound.sh"
