#!/usr/bin/env bash
# Builds Atlas.app (release) into Atlas/dist/, with the version in Resources/Info.plist.
#   UNIVERSAL=0 scripts/build-app.sh    only this Mac's architecture (faster during development)
#   SKIP_BUILD=1                        reuse the binaries already built
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Atlas.app"
UNIVERSAL="${UNIVERSAL:-1}"
cd "$ROOT"
# Command Line Tools whose default SDK cannot build SwiftUI: use an older SDK installed next to it (sdk.sh).
if [ -z "${ATLAS_SDK_CHECKED:-}" ]; then
    export ATLAS_SDK_CHECKED=1
    SDK=$(./scripts/sdk.sh); if [ -n "$SDK" ]; then export SDKROOT=$SDK; fi
fi

if [ "$UNIVERSAL" = 1 ]; then
  # Apple silicon + Intel. Without full Xcode there is no multiple --arch: one build per triple, joined by lipo.
  BINS=()
  # A build folder per architecture: newer SwiftPM writes every triple to the same Products folder.
  for ARCH in arm64 x86_64; do
    ARGS=(-c release --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH")
    [ "${SKIP_BUILD:-0}" = 1 ] || swift build "${ARGS[@]}"
    BINS+=("$(swift build "${ARGS[@]}" --show-bin-path)/Atlas")
  done
else
  [ "${SKIP_BUILD:-0}" = 1 ] || swift build -c release
  BINS=("$(swift build -c release --show-bin-path)/Atlas")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Atlas"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon (.icns) from the iconset, which has a drawing for each size (scripts/make-icon.swift draws it)
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature (SIGN_IDENTITY="Developer ID Application: …" to distribute)
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Atlas"))"
