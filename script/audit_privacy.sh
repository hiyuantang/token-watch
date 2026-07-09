#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if rg --quiet 'com\.apple\.security\.network\.(client|server)' TokenWatch/TokenWatch.entitlements; then
  echo "Token Watch must not declare network entitlements." >&2
  exit 1
fi

if rg --quiet 'URLSession|URLRequest|NWConnection|NWPathMonitor|WebSocket|HTTPClient' TokenWatch --glob '*.swift'; then
  echo "Token Watch must not include networking APIs." >&2
  exit 1
fi

echo "Privacy audit passed: no network entitlements or networking APIs found."
