#!/usr/bin/env bash
# Renders design snapshots (dashboard and components, light and dark) with fixture data to PNG.
# Usage: scripts/snapshots.sh [output-folder]   (default: dist/snapshots)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/snapshots}"
swift build -q
ATLAS_SNAPSHOT="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || pwd)/$(basename "$OUT")" "$(swift build --show-bin-path)/Atlas"
