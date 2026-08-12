#!/usr/bin/env bash
# Restore drill for a remote host via sshx (AC-OPS4).
# Picks the newest backup snapshot, copies it to a scratch path, and
# verifies it read-only with the production binary's --verify-db.
# Usage: HOST=my-host ./scripts/restore-drill.sh
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/restore-drill-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/restore-drill.sh >/dev/null
sshx -h="$HOST" --json --timeout=120s "sudo bash /tmp/restore-drill.sh"
