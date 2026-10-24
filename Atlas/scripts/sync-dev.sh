#!/bin/zsh
# Brings the local dev up to date with origin/dev before ship.sh chooses a version: CI pushes its own
# "chore(release): X.Y.Z" commits there, and a version chosen without them would repeat a published one.
# Fast-forward only; local changes not yet committed stay as they are. Stops with a message when dev
# has diverged or an incoming commit touches a file changed locally.
set -e
git fetch -q --tags origin dev || { echo "✗ Could not fetch origin/dev; check the connection and run again."; exit 1; }
git merge-base --is-ancestor origin/dev HEAD && exit 0
if ! git merge-base --is-ancestor HEAD origin/dev; then
    echo "✗ dev and origin/dev have diverged. Run: git pull --rebase origin dev, then ship again."
    exit 1
fi
git merge -q --ff-only origin/dev 2>/dev/null || {
    echo "✗ origin/dev changes files you also changed (often CHANGELOG.md or Info.plist). Commit or stash them, then ship again."
    exit 1
}
echo "✓ dev updated with origin/dev ($(git rev-parse --short HEAD) $(git log -1 --format=%s))"
