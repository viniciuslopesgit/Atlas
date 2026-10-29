#!/bin/zsh
# Starts a built Atlas.app in self-test mode and checks what it prints:
#   scripts/selftest.sh [dist/Atlas.app] [log]
# The release binary starts with throwaway storage and in-memory secrets, opens its window and
# checks the code paths that protect credentials and files (ATLAS_SMOKE_TEST in AtlasApp.swift).
# check.sh --full runs it on the app it builds; CI also runs it on macOS 12 (ci.yml).
set -uo pipefail

APP=${1:-dist/Atlas.app}
OUT=${2:-$(mktemp -t atlas-selftest)}
fail() { print -P "%F{red}✗ $1%f" >&2; exit 1; }

RC=0
ATLAS_SMOKE_TEST=1 perl -e 'alarm shift; exec @ARGV' 120 $APP/Contents/MacOS/Atlas >$OUT 2>&1 || RC=$?
if [ $RC != 0 ]; then
    tail -20 $OUT
    SIG=""; (( RC > 128 && RC < 160 )) && SIG=" (signal $((RC - 128)))"
    [ $RC = 142 ] && SIG=" (2 min timeout)"
    fail "The self-test exited with code $RC$SIG (log in $OUT)."
fi
for expected in \
    "SigV4 reference signature: true" \
    "HCL strings cannot interpolate: true" \
    "S3 downloads stay in the chosen folder: true" \
    "SSM script quotes every argument: true" \
    "Secrets kept in memory only: true" \
    "SMOKE TEST OK"; do
    grep -qF -- "$expected" $OUT || fail "Self-test: missing \"$expected\" (see $OUT)."
done
print -P "%F{green}  ✓ window opened on $(sw_vers -productName) $(sw_vers -productVersion); 5 checks correct%f"
