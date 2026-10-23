#!/bin/zsh
# Runs the whole test suite inside an isolated environment.
#
#   ./scripts/test-isolated.sh                    build the tests, prove the sandbox, run every test in it
#   ./scripts/test-isolated.sh --coverage         the same, with code coverage (used by check.sh)
#   ./scripts/test-isolated.sh --coverage-report  llvm-cov report of the last --coverage run
#   ./scripts/test-isolated.sh --skip-build       reuse the test build already done
#   ./scripts/test-isolated.sh --filter Security  only the suites or tests that match
#
# The tests run under sandbox-exec with a profile that denies the network (even localhost), denies
# osascript, sudo, security and open, and only lets them write in a temporary folder of their own and in
# .build. Their HOME and TMPDIR are inside that folder. Before the tests, the script confirms that the
# sandbox really blocks writing in the real home folder and the source tree and reaching the network:
# if it does not, it stops. The test binary runs on its own (the same runner swift test uses), so the
# sandbox only has to hold the tests, not the compiler and SwiftPM.
set -e
cd "$(dirname "$0")/.."
ROOT=$PWD
# Command Line Tools whose default SDK cannot build SwiftUI: use an older SDK installed next to it (sdk.sh).
if [ -z "$ATLAS_SDK_CHECKED" ]; then
    export ATLAS_SDK_CHECKED=1
    SDK=$(./scripts/sdk.sh); [ -n "$SDK" ] && export SDKROOT=$SDK
fi

ok()   { print -P "%F{green}  ✓%f $1"; }
fail() { print -P "%F{red}  ✗ $1%f"; exit 1; }

BUILD=1 COVERAGE=0 FILTER=()
while [ $# -gt 0 ]; do
    case $1 in
        --skip-build) BUILD=0 ;;
        --coverage) COVERAGE=1 ;;
        --coverage-report) COVERAGE=2 ;;
        --filter) FILTER=(--filter "$2"); shift ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

# With only the Command Line Tools (no Xcode), Swift Testing lives outside the default search paths.
DEV=/Library/Developer/CommandLineTools/Library/Developer
SWIFT_ARGS=()
if [ -d "$DEV/Frameworks/Testing.framework" ] && [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
    SWIFT_ARGS=(-Xswiftc -F"$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks"
                -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi
# Newer Command Line Tools keep the Swift Testing macros in a folder of their own.
TESTING_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ] && [ -d "$TESTING_PLUGINS" ]; then
    SWIFT_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi
BINDIR=$(swift build --show-bin-path)
# The native build system names the bundle after the package, the newer one (swiftbuild) after the target.
BIN=$BINDIR/AtlasPackageTests.xctest/Contents/MacOS/AtlasPackageTests
[ -x "$BIN" ] || [ ! -x "$BINDIR/AtlasTests.xctest/Contents/MacOS/AtlasTests" ] || BIN=$BINDIR/AtlasTests.xctest/Contents/MacOS/AtlasTests
PROFDATA=$ROOT/.build/coverage/atlas.profdata

if [ $COVERAGE = 2 ]; then
    [ -f "$PROFDATA" ] || fail "No coverage data: run ./scripts/test-isolated.sh --coverage first."
    exec xcrun llvm-cov report "$BIN" -instr-profile "$PROFDATA" -ignore-filename-regex='Tests/|\.build/'
fi

# 1. Build (outside the sandbox: the compiler needs its caches).
mkdir -p .build
if [ $BUILD = 1 ]; then
    COV=(); [ $COVERAGE = 1 ] && COV=(--enable-code-coverage)
    swift build --build-tests $COV $SWIFT_ARGS >.build/isolated-build.log 2>&1 \
        || { grep -E "error:" .build/isolated-build.log | head -20; tail -15 .build/isolated-build.log; fail "The tests do not build."; }
fi
HELPER=$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper
[ -x "$HELPER" ] || HELPER=$(find "$(xcode-select -p)" -maxdepth 9 -name swiftpm-testing-helper -type f 2>/dev/null | head -1)
[ -x "$BIN" ] || [ ! -x "$BINDIR/AtlasTests.xctest/Contents/MacOS/AtlasTests" ] || BIN=$BINDIR/AtlasTests.xctest/Contents/MacOS/AtlasTests
[ -x "$BIN" ] || fail "No test binary at $BIN (run without --skip-build)."
[ -x "$HELPER" ] || fail "No swiftpm-testing-helper next to swift."

# 2. Isolated environment.
ISO=$(mktemp -d "${TMPDIR:-/tmp}/atlas-isolated.XXXXXX")
ISO=$(cd -P "$ISO" && pwd -P)
trap 'rm -rf "$ISO"' EXIT
mkdir -p "$ISO/tmp" "$ISO/home" .build/coverage
PROFILE=$ISO/profile.sb
# Atomic saves (Data.write(options: .atomic)) go through the system's TemporaryItems folder: only that one.
SAVES=$(cd -P "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)/TemporaryItems
mkdir -p "$SAVES"
cat >"$PROFILE" <<EOF
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (literal "/private/var/run/syslog"))
(deny network-inbound)
(deny process-exec (literal "/usr/bin/osascript") (literal "/usr/bin/sudo") (literal "/usr/bin/security") (literal "/usr/bin/open"))
(deny file-write*)
(allow file-write*
    (subpath "$ISO/tmp") (subpath "$ISO/home") (subpath "$ROOT/.build") (subpath "$SAVES")
    (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (regex #"^/dev/fd/"))
EOF
JAIL=(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$ISO/home" TMPDIR="$ISO/tmp/" LANG=en_US.UTF-8
      ATLAS_SANDBOX=1 ATLAS_SANDBOX_ROOT="$ROOT" ATLAS_TEST_TMP="$ISO/tmp" DEVELOPER_DIR="$(xcode-select -p)"
      /usr/bin/sandbox-exec -f "$PROFILE")

# The isolation is checked, not assumed.
CANARY=$HOME/.atlas-isolated-canary-$$
"${JAIL[@]}" /usr/bin/touch "$CANARY" 2>/dev/null && { rm -f "$CANARY"; fail "The sandbox let a write through to $HOME."; }
"${JAIL[@]}" /usr/bin/touch "$ROOT/Package.swift" 2>/dev/null && fail "The sandbox let a write through to the source tree."
"${JAIL[@]}" /usr/bin/curl -sS -m 5 -o /dev/null https://github.com 2>/dev/null && fail "The sandbox let the network through."
"${JAIL[@]}" /usr/bin/osascript -e 'return 1' >/dev/null 2>&1 && fail "The sandbox let osascript run."
"${JAIL[@]}" /usr/bin/touch "$ISO/tmp/ok" || fail "The sandbox does not let the tests write in their own folder."
ok "isolated: no network, no osascript/sudo/security/open, writes only in its own folder and .build"

# 3. Every test, serially, inside the sandbox; 5 minutes at most (a test that hangs counts as a failure).
rm -f .build/coverage/*.profraw(N)
RC=0
"${JAIL[@]}" /usr/bin/env LLVM_PROFILE_FILE="$ROOT/.build/coverage/%p.profraw" \
    /usr/bin/perl -e 'alarm shift; exec @ARGV' 300 \
    "$HELPER" --test-bundle-path "$BIN" "$BIN" --testing-library swift-testing --no-parallel $FILTER || RC=$?
[ $RC = 0 ] || fail "Tests failed (exit $RC$([ $RC = 142 ] && echo ', 5 min timeout'))."

if [ $COVERAGE = 1 ]; then
    xcrun llvm-profdata merge -sparse .build/coverage/*.profraw(N) -o "$PROFDATA" || fail "Could not merge the coverage data."
fi
