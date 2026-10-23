#!/usr/bin/env bash
# The version lives in Atlas/Resources/Info.plist and only changes through scripts/bump_version.sh.
#
#   version.sh            current version (CFBundleShortVersionString)
#   version.sh --last     last published version (newest X.Y.Z tag)
#   version.sh --suggest  patch, minor or major, from the Conventional Commits since the last tag
#   version.sh --notes    Keep a Changelog lists drafted from those commits (bump_version.sh prefills them)
#
# Rules for --suggest: "type!:" or "BREAKING CHANGE" → major · feat → minor · anything else → patch.
set -euo pipefail

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

last_tag() {
  git tag --list '[0-9]*.[0-9]*.[0-9]*' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}
TAG="$(last_tag)"
RANGE="${TAG:+$TAG..}HEAD"
commits() { git rev-list --no-merges "$RANGE"; }
breaking() { [[ "$1" =~ ^[a-z]+(\([^\)]*\))?!: ]] || [[ "$2" == *"BREAKING CHANGE"* ]]; }

suggest() {
  local level=patch subject body
  for sha in $(commits); do
    subject="$(git log -1 --format=%s "$sha")"; body="$(git log -1 --format=%b "$sha")"
    if breaking "$subject" "$body"; then echo major; return; fi
    [[ "$subject" =~ ^feat(\([^\)]*\))?: ]] && level=minor
  done
  echo "$level"
}

# Drafts: one line per commit, under the Keep a Changelog heading its type maps to.
notes() {
  local added="" changed="" fixed="" subject body text
  for sha in $(commits); do
    subject="$(git log -1 --format=%s "$sha")"; body="$(git log -1 --format=%b "$sha")"
    text="${subject#*: }"; text="$(printf '%s' "${text:0:1}" | tr '[:lower:]' '[:upper:]')${text:1}"
    if [[ "$subject" =~ ^feat ]] && ! breaking "$subject" "$body"; then added+="- $text"$'\n'
    elif [[ "$subject" =~ ^(fix|perf) ]]; then fixed+="- $text"$'\n'
    elif [[ "$subject" =~ ^(docs|test|ci|chore|style|build)(\(|:) ]]; then :
    else changed+="- $text"$'\n'
    fi
  done
  [[ -n "$added" ]] && printf '### Added\n%s\n' "$added"
  [[ -n "$changed" ]] && printf '### Changed\n%s\n' "$changed"
  [[ -n "$fixed" ]] && printf '### Fixed\n%s\n' "$fixed"
  return 0
}

case "${1:-}" in
  "")        /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Atlas/Resources/Info.plist ;;
  --last)    echo "${TAG:-0.0.0}" ;;
  --next)    "$0" ;;   # the next Release is the version in Info.plist (kept for older promote.yml on main)
  --suggest) suggest ;;
  --notes)   [[ -n "${2:-}" ]] && RANGE="$2"; notes ;;
  *) echo "Usage: $0 [--last|--suggest|--notes [A..B]]" >&2; exit 2 ;;
esac
