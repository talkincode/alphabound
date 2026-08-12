#!/usr/bin/env bash
# Manual rollback to the previous (or a named) release via sshx (AC-OPS6).
# Usage: HOST=my-host ./scripts/rollback-remote.sh [RELEASE_NAME]
#   no arg        -> roll back to the newest release that isn't live
#   RELEASE_NAME  -> e.g. abc1234-20260209101500 (a dir under releases/)
set -euo pipefail
HOST="${HOST:?set HOST to sshx host name}"
TARGET="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_SCRIPT="$ROOT/scripts/rollback-remote-inner.sh"

sshx -h="$HOST" --upload="$REMOTE_SCRIPT" --to=/tmp/rollback.sh >/dev/null
sshx -h="$HOST" --json --timeout=120s "sudo bash /tmp/rollback.sh $TARGET"
