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
  # macOS 12 needs the Swift 5.6 compatibility library; some Command Line Tools ship it without an Intel slice, and
  # that slice then targets macOS 13, whose Swift runtime needs none. CI's Xcode builds both for macOS 12 (min-os.sh).
  COMPAT56="$(dirname "$(xcrun -f swiftc)")/../lib/swift/macosx/libswiftCompatibility56.a"
  for ARCH in arm64 x86_64; do
    MIN=12.0
    if [ -f "$COMPAT56" ] && ! lipo -archs "$COMPAT56" | tr ' ' '\n' | grep -qx "$ARCH"; then
      MIN=13.0; echo "warning: this toolchain cannot back-deploy $ARCH to macOS 12.0: that slice targets macOS $MIN" >&2
    fi
    ARGS=(-c release --triple "$ARCH-apple-macosx$MIN" --scratch-path ".build/$ARCH")
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
