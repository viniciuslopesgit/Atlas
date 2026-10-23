#!/usr/bin/env bash
# Works out the version from Conventional Commits since the last stable tag (X.Y.Z).
#
#   version.sh            current stable version (last tag)
#   version.sh --next     next stable version
#   version.sh --dev      next version as a pre-release: X.Y.Z-dev.N
#   version.sh --build    build number (total commit count)
#   version.sh --notes    release notes since the last tag (Markdown)
#   version.sh --notes A..B   release notes for a commit range (used by changelog.sh)
#
# Rules: "type!:" or "BREAKING CHANGE" → major · feat → minor · fix/perf → patch.
# Commits of other types (docs, chore, ci…) produce a patch when there is no feat/fix.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

last_tag() {
  git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' HEAD 2>/dev/null || echo ""
}

TAG="$(last_tag)"
RANGE="${TAG:+$TAG..}HEAD"
BASE="${TAG:-0.0.0}"

commits() { git rev-list --no-merges "$RANGE"; }

bump_level() {
  local level=0 subject body
  for sha in $(commits); do
    subject="$(git log -1 --format=%s "$sha")"
    body="$(git log -1 --format=%b "$sha")"
    if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]] || [[ "$body" == *"BREAKING CHANGE"* ]]; then
      echo 3; return
    elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
      level=2
    elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]] && (( level < 1 )); then
      level=1
    elif (( level < 1 )); then
      level=1
    fi
  done
  echo "$level"
}

next_version() {
  local major minor patch level
  IFS=. read -r major minor patch <<<"$BASE"
  level="$(bump_level)"
  case "$level" in
    3) echo "$((major + 1)).0.0" ;;
    2) echo "$major.$((minor + 1)).0" ;;
    1) echo "$major.$minor.$((patch + 1))" ;;
    *) echo "$BASE" ;;
  esac
}

notes() {
  local breaking="" feats="" fixes="" others="" subject body line
  for sha in $(commits); do
    subject="$(git log -1 --format=%s "$sha")"
    body="$(git log -1 --format=%b "$sha")"
    line="- ${subject#*: } (\`$(git log -1 --format=%h "$sha")\`)"$'\n'
    if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]] || [[ "$body" == *"BREAKING CHANGE"* ]]; then
      breaking+="$line"
    elif [[ "$subject" =~ ^feat ]]; then
      feats+="$line"
    elif [[ "$subject" =~ ^(fix|perf) ]]; then
      fixes+="$line"
    else
      others+="- $subject"$'\n'
    fi
  done
  [[ -n "$breaking" ]] && printf '### Breaking changes\n%s\n' "$breaking"
  [[ -n "$feats" ]] && printf '### New features\n%s\n' "$feats"
  [[ -n "$fixes" ]] && printf '### Fixes\n%s\n' "$fixes"
  [[ -n "$others" ]] && printf '### Other changes\n%s\n' "$others"
  return 0
}

case "${1:-}" in
  "")       echo "$BASE" ;;
  --next)   next_version ;;
  --dev)
    count="$(commits | wc -l | tr -d ' ')"
    if (( count == 0 )); then echo "$BASE"; else echo "$(next_version)-dev.$count"; fi ;;
  --build)  git rev-list --count HEAD ;;
  --notes)  [[ -n "${2:-}" ]] && RANGE="$2"; notes ;;
  *) echo "Usage: $0 [--next|--dev|--build|--notes]" >&2; exit 2 ;;
esac
