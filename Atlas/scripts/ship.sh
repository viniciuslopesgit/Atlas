#!/bin/zsh
# Tests, commits and pushes to dev, in this order. If a step fails, the following ones do not happen.
#
#   ./scripts/ship.sh "feat: message"           full check → commit → push dev → GitHub publishes the beta
#   ./scripts/ship.sh "docs: …" --no-release    commit and push only (the app did not change: no new version)
#   ./scripts/ship.sh "…" --install             … and installs the tested app in /Applications
#
# Each Release needs a new version: first ./scripts/bump_version.sh [patch|minor|major] and rewrite its
# section in the CHANGELOG. After the push, CI (.github/workflows/ci.yml) runs the same full check on
# macOS 14 and 15 and publishes the X.Y.Z Release as a beta, with Atlas-X.Y.Z.zip and SHA256SUMS.
# promote.yml makes it stable on main once it meets docs/RELEASE_CRITERIA.md.
# The commit includes every change in the folder (git add -A), which are exactly the ones that were tested.
set -e
cd "$(dirname "$0")/.."
REPO=$(git rev-parse --show-toplevel)

MSG="" RELEASE=1 INSTALL=0
for a in "$@"; do
    case $a in
        --install) INSTALL=1 ;;
        --no-release) RELEASE=0 ;;
        -*) echo "Unknown option: $a"; exit 2 ;;
        *) [ -z "$MSG" ] && MSG=$a || { echo "Only one commit message, in quotes."; exit 2; } ;;
    esac
done
[ -n "$MSG" ] || { echo "Usage: ./scripts/ship.sh \"type: message\" [--no-release] [--install]"; exit 2; }

BRANCH=$(git branch --show-current)
[ "$BRANCH" = dev ] || { echo "✗ ship.sh publishes from the dev branch (you are on \"$BRANCH\")."; exit 1; }
[ -z "$(git ls-files --unmerged)" ] || { echo "✗ There are unresolved conflicts."; exit 1; }
[ "$(git config core.hooksPath)" = ".githooks" ] || ./scripts/install-hooks.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
if [ $RELEASE = 1 ]; then
    git fetch -q --tags origin 2>/dev/null || true
    if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
        echo "✗ Version $VERSION has already been published. Bump it: ./scripts/bump_version.sh [patch|minor|major]"
        echo "  and rewrite its section in the CHANGELOG (or use --no-release when the app did not change)."
        exit 1
    fi
fi
echo "• Branch: dev · version $VERSION"

# 1. Tests. Nothing is committed or pushed if they fail.
./scripts/check.sh --full

# 2. Commit of the content that was just tested.
git -C "$REPO" add -A
if [ "$(cat .build/check-passed)" != "$(git -C "$REPO" write-tree)" ]; then
    echo "✗ The folder changed during the check. Run ./scripts/ship.sh again."
    exit 1
fi
if git -C "$REPO" diff --cached --quiet; then
    echo "• Nothing new to commit; the last commit is already the one that was tested."
else
    git -C "$REPO" commit -q -m "$MSG"
    echo "✓ Commit $(git rev-parse --short HEAD): ${MSG%%$'\n'*}"
fi

# 3. Push to dev (the pre-push hook confirms it is the tested content).
git push -q -u origin dev
echo "✓ Pushed to origin/dev"
if [ $RELEASE = 1 ]; then
    echo "• GitHub Actions now checks it on macOS 14 and 15 and publishes Atlas $VERSION as a beta:"
    echo "  https://github.com/viniciuslopesgit/Atlas/actions/workflows/ci.yml"
fi

# 4. Optional: installs the tested app in /Applications, without rebuilding.
if [ $INSTALL = 1 ]; then
    pgrep -xq Atlas && osascript -e 'tell application id "io.cloud-atlas.Atlas" to quit' && sleep 2
    rm -rf /Applications/Atlas.app.previous
    [ -d /Applications/Atlas.app ] && mv /Applications/Atlas.app /Applications/Atlas.app.previous
    ditto dist/Atlas.app /Applications/Atlas.app && rm -rf /Applications/Atlas.app.previous
    echo "✓ Installed in /Applications/Atlas.app"
fi
echo "✓ Done."
