#!/bin/zsh
# Tests, commits and pushes to dev, in this order. If a step fails, the following ones do not happen.
#
#   ./scripts/ship.sh "feat: message"           (new version) → full check → commit → push dev → beta Release
#   ./scripts/ship.sh "…" --no-release          commit and push only, never a new version
#   ./scripts/ship.sh "…" --install             … and installs the tested app in /Applications
#
# Versions are automatic: when the app changed after the published version, ship.sh bumps it
# (bump_version.sh --auto: patch, minor or major from the Conventional Commits, this one included) and writes
# its CHANGELOG section from the commits. To word the section yourself, run bump_version.sh first and edit it.
# When only docs, scripts or tests changed, there is no new version. After the push, CI
# (.github/workflows/ci.yml) runs the same full check on macOS 14 and 15 and publishes the X.Y.Z Release as a
# beta, with Atlas-X.Y.Z.zip and SHA256SUMS; promote.yml approves and publishes it as stable on main once it
# meets docs/RELEASE_CRITERIA.md.
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

# The version is chosen on top of what CI already published (its release commits on origin/dev).
./scripts/sync-dev.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
if [ $RELEASE = 1 ]; then
    if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
        APP_CHANGES=$(git -C "$REPO" diff --name-only "refs/tags/$VERSION" -- Atlas/Sources Atlas/Resources Atlas/Package.swift; \
                      git -C "$REPO" ls-files --others --exclude-standard -- Atlas/Sources Atlas/Resources)
        if [ -n "$APP_CHANGES" ]; then
            echo "• The app changed since $VERSION, which is already published: new version."
            PENDING_MESSAGE=$MSG ./scripts/bump_version.sh --auto
            VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
        else
            RELEASE=0
            echo "• The app did not change since $VERSION: commit and push only, no new version."
        fi
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
