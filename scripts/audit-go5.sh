#!/usr/bin/env bash
# AC-GO5 audit chain on a remote host via sshx.
# Usage: HOST=my-host ./scripts/audit-go5.sh
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/audit-go5-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/audit-go5.sh >/dev/null
sshx -h="$HOST" --json --timeout=120s "sudo bash /tmp/audit-go5.sh"
