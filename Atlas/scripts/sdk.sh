#!/bin/zsh
# Prints the macOS SDK to build with when the default one cannot build SwiftUI with this toolchain, or nothing.
# Some Command Line Tools ship a newer SDK whose SwiftUI needs a compiler plugin (SwiftUIMacros) that only
# Xcode has; an older SDK installed next to it still works. Scripts use it as SDKROOT=${SDKROOT:-$(sdk.sh)}.
PROBE='import SwiftUI
struct V: View { @State var x = 0; var body: some View { EmptyView() } }'
builds() { print -r -- "$PROBE" | SDKROOT=$1 xcrun swiftc -typecheck - >/dev/null 2>&1; }
[ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ] || exit 0
builds "" && exit 0
for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(N) | sort -rV); do
    builds "$sdk" && { print -r -- "$sdk"; exit 0; }
done
exit 0
