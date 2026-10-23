#!/usr/bin/env bash
# Runs the unit tests. With only the Command Line Tools installed (no Xcode),
# Swift Testing lives outside the default search paths.
set -euo pipefail
cd "$(dirname "$0")/.."
# Command Line Tools whose default SDK cannot build SwiftUI: use an older SDK installed next to it (sdk.sh).
if [ -z "${ATLAS_SDK_CHECKED:-}" ]; then
    export ATLAS_SDK_CHECKED=1
    SDK=$(./scripts/sdk.sh); if [ -n "$SDK" ]; then export SDKROOT=$SDK; fi
fi
DEV=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$DEV/Frameworks/Testing.framework" ] && [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
  ARGS=(-Xswiftc -F"$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks"
        -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib")
  # Newer Command Line Tools keep the Swift Testing macros in a folder of their own.
  PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  if [ -d "$PLUGINS" ]; then ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS"); fi
  swift test "${ARGS[@]}" "$@"
else
  swift test "$@"
fi
