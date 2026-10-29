#!/bin/zsh
# Checks that a built Atlas.app can start on the oldest macOS it claims (LSMinimumSystemVersion, macOS 12):
#   scripts/min-os.sh [dist/Atlas.app]
# 1. Info.plist and Package.swift name the same minimum.
# 2. Every slice of the binary is built for that minimum (on CI; elsewhere a slice above it is only a warning,
#    since some Command Line Tools cannot back-deploy Intel builds, see build-app.sh).
# 3. A slice built for macOS 12 does not require a library that macOS 12 does not have: those are only linked weakly
#    (dyld skips a missing weak library and the code that uses it is behind `if #available`).
# CI runs it on the app it publishes, and starts that app on macOS 12 when a Mac with it is available (ci.yml).
set -euo pipefail

APP=${1:-dist/Atlas.app}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN=$APP/Contents/MacOS/Atlas
fail() { print -P "%F{red}✗ $1%f" >&2; exit 1; }
warn() { print -P "%F{yellow}  ⚠ $1%f" >&2; }

# Introduced after macOS 12: never a strong dependency of a slice that runs there.
NEWER=(
    /System/Library/Frameworks/Charts.framework
    /System/Library/Frameworks/SwiftData.framework
    /System/Library/Frameworks/Observation.framework
    /System/Library/Frameworks/TipKit.framework
    /usr/lib/swift/libswift_StringProcessing.dylib
    /usr/lib/swift/libswift_RegexParser.dylib
    /usr/lib/swift/libswiftObservation.dylib
    /usr/lib/swift/libswiftSynchronization.dylib
)

[ -x "$BIN" ] || fail "No binary at $BIN."
MIN=$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")
PKG=$(sed -nE 's/.*\.macOS\(\.v([0-9]+)(_([0-9]+))?\).*/\1.\3/p' "$ROOT/Package.swift"); PKG=${PKG%.}; [[ $PKG == *.* ]] || PKG=$PKG.0
[ "$MIN" = "$PKG" ] || fail "Info.plist asks for macOS $MIN but Package.swift builds for macOS $PKG."

for ARCH in $(lipo -archs "$BIN"); do
    SLICE=$(vtool -arch $ARCH -show-build "$BIN" | awk '/minos/ { print $2 }')
    if [ "$SLICE" != "$MIN" ]; then
        MSG="The $ARCH slice is built for macOS $SLICE, not $MIN."
        if [ -n "${CI:-}" ]; then fail "$MSG"; else warn "$MSG (local toolchain; CI builds it for $MIN)"; continue; fi
    fi
    STRONG=$(otool -arch $ARCH -l "$BIN" | awk '/cmd LC_/ { cmd = $2 } /^ *name / && cmd == "LC_LOAD_DYLIB" { print $2 }')
    for lib in $NEWER; do
        if print -r -- "$STRONG" | grep -q "^$lib"; then
            fail "The $ARCH slice requires $lib, which macOS $MIN does not have: use it only behind if #available."
        fi
    done
done
print -P "%F{green}  ✓ starts on macOS $MIN ($(lipo -archs "$BIN"); newer frameworks linked weakly)%f"
