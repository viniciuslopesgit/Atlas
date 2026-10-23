#!/usr/bin/env bash
# Runs build + tests in an isolated environment:
#   - copy of the working tree (tracked + new files, without .build/dist) in a temporary folder
#   - its own HOME, TMPDIR and build folder — nothing from the local environment is reused
#   - macOS sandbox (sandbox-exec): no external network, and writes only inside the temporary folder
# The folder is deleted at the end. Exits non-zero if the build or any test fails.
#
#   test-isolated.sh            build + tests
#   test-isolated.sh --smoke    also runs the app in ATLAS_SMOKE_TEST mode
set -euo pipefail

REPO="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/atlas-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Isolated copy in $WORK"
mkdir -p "$WORK/src" "$WORK/home" "$WORK/tmp"
(cd "$REPO" && git ls-files -co --exclude-standard -z -- Atlas \
  | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
  | rsync -a --from0 --files-from=- ./ "$WORK/src/")

DEV=/Library/Developer/CommandLineTools/Library/Developer
SWIFT_ARGS=(--package-path "$WORK/src/Atlas" --scratch-path "$WORK/build" --disable-sandbox)
TEST_ARGS=()
if [ -d "$DEV/Frameworks/Testing.framework" ] && [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
  TEST_ARGS=(-Xswiftc -F"$DEV/Frameworks" -Xlinker -F"$DEV/Frameworks"
             -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi

# Sandbox: blocks remote network and limits writes to the temporary folder (plus devices and the compiler's caches).
PROFILE="$WORK/sandbox.sb"
cat > "$PROFILE" <<SB
(version 1)
(allow default)
(deny network-outbound (remote ip "*:*"))
(allow network-outbound (remote ip "localhost:*"))
(deny file-write*)
(allow file-write*
  (subpath "$WORK")
  (subpath "/dev")
  (subpath "/private/var/folders")
  (subpath "/private/tmp"))
SB

run() {
  env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$WORK/home" TMPDIR="$WORK/tmp/" \
      LANG=en_US.UTF-8 "$@"
}

SANDBOX=(sandbox-exec -f "$PROFILE")
command -v sandbox-exec >/dev/null || { echo "⚠️  sandbox-exec unavailable — running without the sandbox"; SANDBOX=(); }

# Expected noise: the sandbox stops SwiftPM from writing its caches in the real HOME.
quiet() { grep -vE "user-level cache|failed storing manifest|^\[[0-9]+/[0-9]+\]" || true; }

echo "▸ Build"
if ! run "${SANDBOX[@]}" swift build "${SWIFT_ARGS[@]}" > "$WORK/build.log" 2>&1; then
  echo "✘ Build failed"; quiet < "$WORK/build.log" | tail -40; exit 1
fi
quiet < "$WORK/build.log" | grep -E "error|warning:|Build complete" || true

echo "▸ Updater self-test"
run bash "$WORK/src/Atlas/scripts/updater.sh" --self-test

echo "▸ Tests"
run "${SANDBOX[@]}" swift test "${SWIFT_ARGS[@]}" ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} \
  > "$WORK/test.log" 2>&1 || true
grep -E "✘|error:|Test run with|failed" "$WORK/test.log" | quiet
grep -q "Test run with .* passed" "$WORK/test.log" || { echo "✘ Tests failed"; tail -40 "$WORK/test.log"; exit 1; }

if [ "${1:-}" = "--smoke" ]; then
  echo "▸ Smoke test"
  BIN="$(run swift build "${SWIFT_ARGS[@]}" --show-bin-path)/Atlas"
  run "${SANDBOX[@]}" env ATLAS_SMOKE_TEST=1 "$BIN" &
  pid=$!
  ( sleep 60; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!
  status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  (( status == 0 )) || { echo "✘ Smoke test failed (exit $status)"; exit 1; }
fi

echo "✔ Isolated tests passed"
