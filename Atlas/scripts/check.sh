#!/bin/zsh
# Quality gate: everything that must pass before a commit, a push or a Release.
#
#   ./scripts/check.sh          quick (pre-commit): scripts, secrets, reviewed places, new tests,
#                               warning-free build, unit tests in an isolated sandbox, minimum coverage
#   ./scripts/check.sh --full   all of the above plus (pre-push, ship.sh, CI): version and CHANGELOG,
#                               universal signed dist/Atlas.app, and the self-test of the built app
#
# --staged   checks what is in the git index (used by the pre-commit hook)
#
# When the full check passes, it saves the fingerprint of the tested tree in .build/check-passed:
# a commit or push of that same content does not run everything again.
set -e
cd "$(dirname "$0")/.."      # the Swift package (Atlas/)
REPO=$(git rev-parse --show-toplevel)
# Command Line Tools whose default SDK cannot build SwiftUI: use an older SDK installed next to it (sdk.sh).
if [ -z "$ATLAS_SDK_CHECKED" ]; then
    export ATLAS_SDK_CHECKED=1
    SDK=$(./scripts/sdk.sh); [ -n "$SDK" ] && export SDKROOT=$SDK
fi

FULL=0 STAGED=0
for a in "$@"; do
    case $a in
        --full) FULL=1 ;;
        --staged) STAGED=1 ;;
        *) echo "Unknown option: $a"; exit 2 ;;
    esac
done

# Minimum line coverage (%) of the files that sign requests, hold secrets, write or delete files,
# run commands or decide what Terraform changes. Only goes up: lowering one needs a reason in the commit.
typeset -A MIN_COVERAGE=(
    AWS/SigV4.swift 95
    AWS/XNode.swift 95
    AWS/AWSClient.swift 85
    Storage/AccountStore.swift 35
    Services/S3Service.swift 30
    Services/SsmService.swift 50
    Services/IamService+Write.swift 60
    Terraform/Hcl.swift 90
    Terraform/GeneratedHcl.swift 85
    Terraform/EnvVarExtractor.swift 95
    Terraform/TerraformCLI.swift 85
    Terraform/TerraformProjects.swift 65
    Terraform/ImportDiscovery.swift 55
    Terraform/Stacks.swift 90
    Terraform/StacksModel.swift 45
    Views/FeedbackView.swift 15
)

# Code that reaches the network, the Keychain, runs programs, opens files or links, or moves and deletes
# files only lives in these files. A new place needs a review and an attack test in SecurityTests.swift.
typeset -A REVIEWED=(
    URLSession              "AWS/AWSClient.swift"
    SecItem                 "Storage/AccountStore.swift"
    'Process()'             "Terraform/TerraformCLI.swift App/AppState.swift"
    NSWorkspace.shared.open "Views/FeedbackView.swift Services/SsmService.swift"
    removeItem              "Terraform/StacksModel.swift Terraform/GeneratedHcl.swift Terraform/TerraformCLI.swift Views/IaCView.swift Services/S3Service.swift"
    moveItem                "Terraform/StacksModel.swift Terraform/GeneratedHcl.swift Terraform/TerraformCLI.swift Views/IaCView.swift Services/S3Service.swift"
    'unlink('               ""
    posix_spawn             ""
    '/bin/sh'               ""
)

STEP=0
step() { STEP=$((STEP + 1)); print -P "%B[$STEP] $1%b"; }
fail() { print -P "%F{red}✗ $1%f"; exit 1; }
ok() { print -P "%F{green}  ✓ $1%f"; }

# Files changed relative to HEAD, from the repository root (in the index with --staged; otherwise also untracked).
changed() {
    if [ $STAGED = 1 ]; then
        git -C "$REPO" diff --cached --name-only --diff-filter="$1"
    else
        git -C "$REPO" diff HEAD --name-only --diff-filter="$1"
        if [[ "$1" == *A* ]]; then git -C "$REPO" ls-files --others --exclude-standard; fi
    fi
}

# Fingerprint of the working tree as it would be committed (git add -A), without touching the real index.
worktree_hash() {
    local idx=$(mktemp)
    cp "$(git -C "$REPO" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || { rm -f "$idx"; GIT_INDEX_FILE=$idx git -C "$REPO" read-tree HEAD; }
    GIT_INDEX_FILE=$idx git -C "$REPO" add -A
    GIT_INDEX_FILE=$idx git -C "$REPO" write-tree
    rm -f "$idx"
}

START=$SECONDS
mkdir -p .build

step "Script syntax"
for f in scripts/*.sh "$REPO"/.githooks/*(N) "$REPO"/.claude/hooks/*(N); do
    case $(head -1 "$f") in
        *zsh*) zsh -n "$f" ;;
        *bash*|*/sh*) bash -n "$f" ;;
        *) fail "$f has no #!/bin/zsh or bash shebang." ;;
    esac || fail "Syntax error in $f"
    [ -x "$f" ] || fail "$f is not executable (chmod +x $f)."
done
ok "scripts and hooks"

step "Script tests"
python3 -I -m unittest discover -s scripts/tests >.build/check-scripts.log 2>&1 \
    || { tail -30 .build/check-scripts.log; fail "The script tests failed (scripts/tests)."; }
bash scripts/updater.sh --self-test >>.build/check-scripts.log 2>&1 \
    || { tail -10 .build/check-scripts.log; fail "updater.sh --self-test failed."; }
ok "$(grep -oE '^Ran [0-9]+ tests' .build/check-scripts.log | sed 's/^Ran/passed:/') (scripts/tests) and the updater self-test"

step "Secrets"
# AWS access key ids (AWS's documented EXAMPLE keys are allowed in fixtures) and private keys.
KEYS='A(KI|SI)A[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|aws_secret_access_key[[:space:]]*='
if [ $STAGED = 1 ]; then
    HITS=$(git -C "$REPO" diff --cached -U0 | grep -E '^\+' | grep -E "$KEYS" | grep -v EXAMPLE || true)
else
    HITS=$( { git -C "$REPO" grep -hE "$KEYS" -- . ':!*.md'; git -C "$REPO" diff HEAD | grep -E '^\+'; } | grep -E "$KEYS" | grep -v EXAMPLE || true)
fi
[ -z "$HITS" ] || { print -r -- "$HITS" | cut -c1-80 | sed 's/^/    /' | head -5; fail "An AWS key or private key is in the changes."; }
TRACKED=$(git -C "$REPO" ls-files | grep -E '(^|/)(\.env|.*\.env|.*\.pem|.*\.p12|credentials)$' || true)
[ -z "$TRACKED" ] || { print -r -- "$TRACKED"; fail "Secret files are tracked by git."; }
ok "no keys or secret files"

step "Tracked files"
IGNORED=$(git -C "$REPO" ls-files --cached --ignored --exclude-standard)
[ -z "$IGNORED" ] || { print -r -- "$IGNORED" | sed 's/^/    /' | head -20; fail "Files tracked by git that .gitignore excludes (git rm --cached <file>)."; }
grep -q "MIT License" "$REPO/LICENSE" 2>/dev/null || fail "LICENSE (MIT) is missing at the repository root."
ok "nothing ignored is tracked; MIT LICENSE present"

step "Reviewed places"
for api in ${(k)REVIEWED}; do
    for f in $(grep -rlF -- "$api" Sources/Atlas || true); do
        rel=${f#Sources/Atlas/}
        [[ " ${REVIEWED[$api]} " == *" $rel "* ]] || fail "$rel uses $api outside the reviewed places (REVIEWED in scripts/check.sh)."
    done
done
# Tests never use the real Keychain, the real network or the user's folders.
grep -rnE 'KeychainSecretStore\(|URLSession\.shared|homeDirectoryForCurrentUser|NSHomeDirectory\(' Tests/AtlasTests \
    && fail "A test uses the real Keychain, network or home folder (use InMemorySecretStore, MockURLProtocol and temporary folders)."
grep -rn 'temporaryDirectory' Tests/AtlasTests | grep -v 'MockNetwork.swift' \
    && fail "A test writes in the system's temporary folder: use TestTemp.root (it is the sandbox's folder)."
ok "network, Keychain, processes and file deletion only in the reviewed files"

step "New features come with tests"
NEW_SOURCES=(${(f)"$(changed A | grep -E '^Atlas/Sources/.*\.swift$' | sort -u)"})
if [ ${#NEW_SOURCES} -gt 0 ]; then
    TESTS_TOUCHED=$(changed AM | grep -cE '^Atlas/Tests/.*\.swift$' || true)
    if [ "$TESTS_TOUCHED" = 0 ] && [ "$ALLOW_NO_TESTS" != 1 ]; then
        print "  New files without any new or changed test in Tests/:"
        for f in $NEW_SOURCES; do print "    $f"; done
        fail "Add tests in Tests/AtlasTests (or, for interface-only code, ALLOW_NO_TESTS=1)."
    fi
    ok "${#NEW_SOURCES} new file(s), with tests"
else
    ok "no new files in Sources"
fi

step "Warning-free build"
if ! swift build -Xswiftc -warnings-as-errors >.build/check-build-debug.log 2>&1; then
    grep -E "(warning|error):" .build/check-build-debug.log | sort -u | head -30
    fail "The build failed or has warnings (log in .build/check-build-debug.log)."
fi
ok "debug, warnings treated as errors"

step "Unit tests (isolated sandbox)"
# Every test runs inside a sandbox with no network that only writes in its own temporary folder;
# the sandbox is proven to hold before the tests run (scripts/test-isolated.sh).
LOG=.build/check-tests.log
# On failure, show each issue (file:line and the failed expectation) before the tail: CI only keeps this output.
./scripts/test-isolated.sh --coverage >$LOG 2>&1 || {
    grep -E 'recorded an issue|✘ Test .* failed' $LOG | sed -E 's/^/    /' || true
    tail -15 $LOG; fail "Some tests are failing (full log in $LOG)."; }
grep 'isolated:' $LOG | sed -E 's/^[^i]*/    /'
ok "$(grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites?' $LOG | tail -1 | sed 's/Test run with/passed:/')"
grep -E 'cannot write outside its folder' $LOG | grep -q '✔' || fail "The isolation test did not pass inside the sandbox."
# Skipped tests are not failures, but they are not evidence either: always show them.
SKIPPED=$(grep -E 'Test .* skipped' $LOG | sed -E 's/^[^T]*Test /Test /' || true)
[ -z "$SKIPPED" ] || { print -P "%F{yellow}  ⚠ skipped on this machine:%f"; print -r -- "$SKIPPED" | sed 's/^/      /'; }

step "Minimum coverage"
REPORT=$(./scripts/test-isolated.sh --coverage-report)
LOW=0
for file min in ${(kv)MIN_COVERAGE}; do
    pct=$(print -r -- "$REPORT" | awk -v f="$file" '$1 == f { gsub("%", "", $10); print int($10) }')
    if [ -z "$pct" ]; then
        print -P "%F{red}    $file is not in the coverage report%f"; LOW=1
    elif (( pct < min )); then
        print -P "%F{red}    $file: $pct% (minimum $min%)%f"; LOW=1
    fi
done
[ $LOW = 0 ] || fail "Coverage below the minimum."
TOTAL=$(print -r -- "$REPORT" | awk '$1 == "TOTAL" { print $10 }')
ok "${#MIN_COVERAGE} critical files above their minimum (total line coverage ${TOTAL%\%}%%)"

if [ $FULL = 1 ]; then
    step "Version and CHANGELOG"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
    [[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "CFBundleShortVersionString \"$VERSION\" is not X.Y.Z."
    [[ $BUILD =~ '^[0-9]+$' ]] || fail "CFBundleVersion \"$BUILD\" is not a number."
    plutil -lint -s Resources/Info.plist || fail "Resources/Info.plist is invalid."
    CHANGELOG=$REPO/CHANGELOG.md
    grep -q "^## \[$VERSION\]" $CHANGELOG || fail "The CHANGELOG has no ## [$VERSION] section (./scripts/bump_version.sh)."
    ./scripts/release_notes.sh "$VERSION" >/dev/null || fail "Could not generate the Release notes."
    SECTION=$(awk -v v="## [$VERSION]" 'index($0, v) == 1 { on = 1; next } /^## \[|^\[[0-9]/ { on = 0 } on' $CHANGELOG)
    print -r -- "$SECTION" | grep -qE 'RELEASE SUMMARY|^- *$' && fail "The ## [$VERSION] section of the CHANGELOG is not filled in."
    print -r -- "$SECTION" | grep -qE '^- .+' || fail "The ## [$VERSION] section of the CHANGELOG lists no changes."
    grep -q "^\[$VERSION\]: " $CHANGELOG || fail "The CHANGELOG has no [$VERSION]: link at the end."
    # A published version is never rebuilt with different content: the app changed, so the version must too.
    if git -C "$REPO" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
        APP_CHANGES=$(git -C "$REPO" diff --name-only "refs/tags/$VERSION" -- Atlas/Sources Atlas/Resources Atlas/Package.swift; \
                      git -C "$REPO" ls-files --others --exclude-standard -- Atlas/Sources Atlas/Resources)
        if [ -n "$APP_CHANGES" ] && [ "$GITHUB_EVENT_NAME" = pull_request ]; then
            # A Pull Request gets its version after the merge (the version job in ci.yml).
            print -P "%F{yellow}  ⚠ $VERSION is already published: the new version is created when this is merged.%f"
        elif [ -n "$APP_CHANGES" ]; then
            print -r -- "$APP_CHANGES" | head -5 | sed 's/^/    /'
            fail "$VERSION is already published and the app changed since: ./scripts/ship.sh creates the new version (or ./scripts/bump_version.sh)."
        fi
    fi
    ok "$VERSION ($BUILD) in the CHANGELOG"

    step "Build dist/Atlas.app"
    ./scripts/build-app.sh >.build/check-build.log 2>&1 || { tail -30 .build/check-build.log; fail "build-app.sh failed."; }
    APP=dist/Atlas.app
    ARCHS=$(lipo -archs $APP/Contents/MacOS/Atlas)
    [[ $ARCHS == *arm64* && $ARCHS == *x86_64* ]] || fail "The binary is not universal ($ARCHS)."
    codesign --verify --deep --strict $APP 2>/dev/null || fail "Invalid signature."
    [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)" = "$VERSION" ] \
        || fail "The built app's version is not $VERSION."
    ok "universal ($ARCHS), signed, version $VERSION"

    step "Self-test of the built app"
    # The release binary starts with throwaway storage and in-memory secrets, opens its window and
    # checks the code paths that protect credentials and files (ATLAS_SMOKE_TEST in AtlasApp.swift).
    OUT=.build/check-selftest.log
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
    ok "window opened; 5 checks correct"

    worktree_hash >.build/check-passed
fi

KIND=quick; [ $FULL = 1 ] && KIND=full
print -P "%F{green}%B✓ $KIND check passed in $((SECONDS - START)) s.%b%f"
