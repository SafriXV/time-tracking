#!/usr/bin/env bash
# Local development server. http://localhost is a secure context, so the
# service worker and IndexedDB both work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8000}"
echo "Serving $ROOT/web at http://localhost:$PORT"
exec python3 -m http.server "$PORT" --directory "$ROOT/web"
