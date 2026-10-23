#!/usr/bin/env bash
# Packs dist/Atlas.app into dist/Atlas-X.Y.Z.dmg, the installer people download: the app next to a link to
# Applications, compressed (UDZO), checked with hdiutil verify.
#   scripts/make-dmg.sh            version from Resources/Info.plist
#   scripts/make-dmg.sh 2.5.0      a given version
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(scripts/version.sh)}
APP=dist/Atlas.app
OUT="dist/Atlas-$VERSION.dmg"
[ -d "$APP" ] || { echo "✗ $APP is missing: run scripts/build-app.sh first."; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/atlas-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Atlas.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -quiet -volname "Atlas $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
hdiutil verify -quiet "$OUT"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
