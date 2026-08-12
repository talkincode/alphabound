#!/usr/bin/env bash
# Snapshot tool value / citation metrics on a remote host via sshx.
# Usage: HOST=my-host ./scripts/tool-value-report.sh
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/tool-value-report-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/tool-value-report.sh >/dev/null
sshx -h="$HOST" --json --timeout=60s "sudo bash /tmp/tool-value-report.sh"
