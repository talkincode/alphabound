#!/usr/bin/env bash
# Build or serve the AlphaBound mdBook handbook.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v mdbook >/dev/null 2>&1; then
  echo "error: mdbook not found in PATH" >&2
  echo "  macOS:  brew install mdbook" >&2
  echo "  cargo:  cargo install mdbook --locked" >&2
  echo "  CI:     see .github/workflows/docs.yml" >&2
  exit 127
fi

cmd="${1:-build}"

case "$cmd" in
  build|check)
    mdbook build
    echo "ok: handbook written to book/book/"
    ;;
  serve)
    exec mdbook serve --hostname 127.0.0.1 --port 3000
    ;;
  clean)
    rm -rf book/book
    echo "ok: cleaned book/book"
    ;;
  *)
    echo "usage: $0 [build|check|serve|clean]" >&2
    exit 2
    ;;
esac
