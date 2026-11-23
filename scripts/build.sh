#!/usr/bin/env bash
# Compile the Haskell application to WebAssembly and assemble the PWA in web/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v wasm32-wasi-ghc >/dev/null || {
  echo "error: wasm32-wasi-ghc not found. Run 'nix develop' first." >&2
  exit 1
}

mkdir -p web/dist
wasm32-wasi-cabal build
WASM="$(wasm32-wasi-cabal list-bin exe:time-tracking-wasm)"
cp "$WASM" web/dist/time-tracking.wasm

POSTLINK="$(wasm32-wasi-ghc --print-libdir)/post-link.mjs"
node "$POSTLINK" --input web/dist/time-tracking.wasm --output web/dist/time-tracking.js

python3 scripts/make-icons.py

echo
echo "Built web/dist/time-tracking.{wasm,js}"
echo "Serve the web/ directory with: ./scripts/serve.sh"
