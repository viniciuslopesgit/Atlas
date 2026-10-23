#!/bin/zsh
# Claude Code Stop hook: does not let Claude finish with unpublished work.
# Project rule (CLAUDE.md): rigorous tests and, if they pass, commit and push to dev.
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}" || exit 0
INPUT=$(cat)
# If it was already blocked once in this answer (e.g. failing tests), lets it finish to avoid a loop.
[ "$(print -r -- "$INPUT" | /usr/bin/jq -r '.stop_hook_active // false')" = true ] && exit 0
CHANGES=$(git status --porcelain 2>/dev/null)
git fetch -q origin dev 2>/dev/null
UNPUSHED=$(git log --oneline origin/dev..dev 2>/dev/null)
[ -z "$CHANGES" ] && [ -z "$UNPUSHED" ] && exit 0
REASON="There is unpublished work in Atlas (mandatory rule in CLAUDE.md). If the app changed, bump the version (Atlas/scripts/bump_version.sh [patch|minor|major]) and rewrite its CHANGELOG section; then run Atlas/scripts/ship.sh \"<type>: <message>\" (add --no-release when the app did not change): rigorous tests → commit → push to dev → beta Release. If the tests fail, fix and repeat; never --no-verify. If you cannot solve it, explain to the user what failed.
Uncommitted changes:
${CHANGES:-(none)}
Commits not yet pushed to origin/dev:
${UNPUSHED:-(none)}"
/usr/bin/jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
