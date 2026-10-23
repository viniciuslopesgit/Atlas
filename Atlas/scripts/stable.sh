#!/bin/zsh
# Which stable version should be on main (rules in scripts/stable.py), and its promotion there.
#
#   ./Atlas/scripts/stable.sh                 report: state of each published version and the candidate
#   ./Atlas/scripts/stable.sh --apply         promotes the candidate to main; with no candidate, cleans main
#                                       if it has extra files (e.g. a Pull Request from dev made by hand)
#   ./Atlas/scripts/stable.sh --check 1.2.6   only the full check of that version, in a clean copy
#   ./Atlas/scripts/stable.sh --dry-run 1.2.9 rehearses the promotion of that version (checks included), without pushing anything
#
# main does not get dev's history: each stable version is an "Atlas X.Y.Z (stable version)" commit
# with the content of the X.Y.Z tag without the development files (.mainignore), through a Pull Request.
# First, the tag passes the full check in a clean copy and main's content builds and passes the self-test.
#
# STABLE_SOAK_HOURS=24  hours of observation after publication (default: 24).
# STABLE_APPROVE=X.Y.Z  approves the promotion of a new major version.
# In GitHub Actions (promote.yml), when Actions may not open Pull Requests, main is fast-forwarded instead.
set -e
cd "$(dirname "$0")/../.."   # the repository root
STABLE=Atlas/scripts/stable.py

APPLY=0 CHECK="" DRY=""
while [ $# -gt 0 ]; do
    case $1 in
        --apply) APPLY=1 ;;
        --check) CHECK=${2#v}; shift ;;
        --dry-run) DRY=${2#v}; shift ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

gh auth status >/dev/null 2>&1 || { echo "✗ gh is not signed in to GitHub (gh auth login)."; exit 1; }

TMP=$(mktemp -d)
WORKTREES=()
cleanup() {
    for w in $WORKTREES; do git worktree remove --force "$w" 2>/dev/null; done
    true
}
trap cleanup EXIT

json() { python3 -I -c "import json,sys; print(json.load(sys.stdin)[\"$1\"] or '')"; }

# Full check of the tag's exact commit, in a clean copy (no local changes or caches).
verify_tag() {
    local version=$1 sha=$(git rev-parse "refs/tags/$1^{commit}")
    git cat-file -e "${sha}:Atlas/scripts/check.sh" 2>/dev/null \
        || { echo "✗ $version predates the test system: it cannot be verified automatically."; return 1; }
    local wt=$TMP/tag-$version
    git worktree add -q --detach "$wt" "$sha"; WORKTREES+=($wt)
    echo "• Verifying $version in a clean copy (builds everything from scratch; a few minutes)…"
    if ! (cd "$wt" && ./Atlas/scripts/check.sh --full >"$wt.log" 2>&1); then
        tail -25 "$wt.log"
        echo "✗ $version failed the full check (log in $wt.log)."
        return 1
    fi
    echo "✓ $version passed the full check."
}

# main's tree for a version: the tag's, without the .mainignore paths (the list in force on dev).
main_tree() {
    local tag=$1 idx=$TMP/index-$1
    GIT_INDEX_FILE=$idx git read-tree "refs/tags/$tag"
    python3 -I $STABLE excluded "refs/tags/$tag" >"$TMP/excluded-$1"
    if [ -s "$TMP/excluded-$1" ]; then
        # -f: the temporary index comes from the tag, so it may differ from both HEAD and the working folder;
        # --cached only touches that index, never the files.
        GIT_INDEX_FILE=$idx git rm -r -q -f --cached --pathspec-from-file="$TMP/excluded-$1" >/dev/null
    fi
    GIT_INDEX_FILE=$idx git write-tree
}

# main's content must build on its own (without tests or development scripts) and pass the self-test.
verify_main_commit() {
    local version=$1 commit=$2 wt=$TMP/main-$1
    # Only the development files may be missing; nothing else may differ from the tag.
    local other=$(git diff --name-status "refs/tags/$version" "$commit" | grep -v '^D' || true)
    [ -z "$other" ] || { echo "✗ The main commit differs from the tag in more than the development files:"; print -r -- "$other"; return 1; }
    git worktree add -q --detach "$wt" "$commit"; WORKTREES+=($wt)
    echo "• Building main's content for $version (without development files)…"
    if ! (cd "$wt" && ./Atlas/scripts/build-app.sh >"$wt.log" 2>&1); then
        tail -25 "$wt.log"; echo "✗ main's content for $version does not build (log in $wt.log)."; return 1
    fi
    local app=$wt/Atlas/dist/Atlas.app out=$wt.selftest
    codesign --verify --deep --strict "$app" 2>/dev/null || { echo "✗ main's app has an invalid signature."; return 1; }
    ATLAS_SMOKE_TEST=1 perl -e 'alarm shift; exec @ARGV' 120 "$app/Contents/MacOS/Atlas" >"$out" 2>&1 \
        || { tail -20 "$out"; echo "✗ The self-test of main's app failed."; return 1; }
    for expected in "SigV4 reference signature: true" "HCL strings cannot interpolate: true" \
                    "S3 downloads stay in the chosen folder: true" "SSM script quotes every argument: true" \
                    "Secrets kept in memory only: true" "SMOKE TEST OK"; do
        grep -qF -- "$expected" "$out" || { echo "✗ main self-test: missing \"$expected\" (see $out)."; return 1; }
    done
    echo "✓ main's content builds, is signed and passes the self-test."
}

# Takes the version to main through a Pull Request. $2 describes the reason. $3 = stable: only then does the
# Release become "Latest" (cleaning main keeps a version that may not meet the criteria). With --dry-run, stops before pushing.
promote() {
    local version=$1 why=$2 kind=${3:-stable} tag=$1
    git fetch -q origin main
    local tree=$(main_tree "$version")
    if [ "$tree" = "$(git rev-parse 'origin/main^{tree}')" ]; then
        echo "• main already has $version with only the essential files."; return 0
    fi
    verify_tag "$version"
    local commit=$(printf 'Atlas %s (stable version)\n\n%s\nContent of the %s tag from dev, without the development files (.mainignore).\n' \
        "$version" "$why" "$tag" | git commit-tree "$tree" -p origin/main)
    verify_main_commit "$version" "$commit"
    if [ -n "$DRY" ]; then
        echo "✓ Rehearsal: commit $commit would be pushed to main ($(wc -l <"$TMP/excluded-$version" | tr -d ' ') development files removed)."
        git ls-tree -r --name-only "$commit" >"$TMP/main-files"
        echo "  Files on main: $(wc -l <"$TMP/main-files" | tr -d ' ') (list in $TMP/main-files)"
        return 0
    fi

    mkdir -p Atlas/.build
    print -r -- "$tree" >Atlas/.build/stable-verified   # the pre-push hook only lets this tree be pushed to main
    local branch=stable/$tag
    git push -q -f origin "${commit}:refs/heads/${branch}"
    local removed=$(wc -l <"$TMP/excluded-$version" | tr -d ' ')
    local body="$why

- Content of the \`$tag\` tag, without $removed development files (list in \`.mainignore\` on dev).
- The tag passed \`Atlas/scripts/check.sh --full\` in a clean copy; main's content builds, is signed and passes the self-test.

$(python3 -I $STABLE | sed 's/^/    /')"
    local title="$([ "$kind" = stable ] && echo "Stable version: Atlas " || echo "Clean main: Atlas ")$version"
    local url
    if url=$(gh pr create --base main --head "$branch" --title "$title" --body "$body" 2>"$TMP/pr.err"); then
        echo "✓ Pull Request: $url"
        gh pr merge "$url" --merge --delete-branch
    elif [ -n "$GITHUB_ACTIONS" ] && grep -q "not permitted to create" "$TMP/pr.err"; then
        # The repository does not let Actions open Pull Requests: the commit's parent is origin/main,
        # so pushing it is a fast-forward (and fails if main moved meanwhile).
        echo "• GitHub Actions may not open Pull Requests here: fast-forwarding main to the verified commit."
        git push -q origin "${commit}:refs/heads/main"
        git push -q origin --delete "$branch" || true
    else
        cat "$TMP/pr.err"; return 1
    fi
    git fetch -q origin main
    if [ "$(git rev-parse 'origin/main^{tree}')" = "$tree" ]; then
        echo "✓ main now has Atlas $version, with only the essential files."
        if [ "$kind" = stable ]; then
            # The Release stops being a beta and becomes "Latest" (the one the README says to download).
            gh release edit "$tag" --prerelease=false --latest >/dev/null
            echo "✓ Release $tag marked as stable (Latest)."
        else
            echo "• Release $tag left as it is: it does not meet the stability criteria yet."
        fi
    else
        echo "⚠️  main was updated, but its content is not the expected one: review with git diff $commit origin/main."
        return 1
    fi
}

if [ -n "$DRY" ]; then
    git rev-parse -q --verify "refs/tags/$DRY" >/dev/null || { echo "✗ There is no $DRY tag."; exit 1; }
    promote "$DRY" "Rehearsal of the promotion of **Atlas $DRY**."
    exit 0
fi

if [ -n "$CHECK" ]; then
    git rev-parse -q --verify "refs/tags/$CHECK" >/dev/null || { echo "✗ There is no $CHECK tag."; exit 1; }
    verify_tag "$CHECK"
    exit 0
fi

python3 -I $STABLE
[ $APPLY = 1 ] || exit 0

REPORT=$(python3 -I $STABLE --json)
CANDIDATE=$(print -r -- "$REPORT" | json candidate)
MAIN=$(print -r -- "$REPORT" | json main)
if [ -n "$CANDIDATE" ]; then
    promote "$CANDIDATE" "Promotes **Atlas $CANDIDATE** to stable version."
elif [ -n "$MAIN" ] && git cat-file -e "refs/tags/${MAIN}:.mainignore" 2>/dev/null; then
    # No new version: confirms that main has only the essential files of the version already there.
    promote "$MAIN" "Cleans main: keeps **Atlas $MAIN**, with only the essential files to build it." cleanup
elif [ -n "$MAIN" ]; then
    echo "• Nothing to promote. $MAIN on main predates the main with only essential files:"
    echo "  main will be cleaned when the next stable version is promoted."
else
    echo "• Nothing to promote."
fi
