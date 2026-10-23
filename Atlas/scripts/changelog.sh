#!/usr/bin/env bash
# Keeps CHANGELOG.md (repository root) in step with the stable tags.
#
#   changelog.sh --release X.Y.Z   adds the section for X.Y.Z (commits since the last stable tag) on top
#   changelog.sh --rebuild         regenerates the whole file from every stable tag
#   changelog.sh --check           fails if a stable tag has no section
#
# Run by promote.yml before tagging; never edit the generated sections by hand.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
FILE="CHANGELOG.md"
VERSION_SH="Atlas/scripts/version.sh"
REPO_URL="https://github.com/${GITHUB_REPOSITORY:-viniciuslopesgit/Atlas}"

header() {
  cat <<'H'
# Changelog

Every stable release of Atlas. Generated from [Conventional Commits](https://www.conventionalcommits.org)
by `Atlas/scripts/changelog.sh` when `dev` is promoted to `main`; development builds (`X.Y.Z-dev.N`)
are listed only on the [releases page](https://github.com/viniciuslopesgit/Atlas/releases).

H
}

stable_tags() { git tag --sort=-v:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true; }

# section VERSION DATE RANGE
section() {
  local notes
  notes="$("$VERSION_SH" --notes "$3")"
  printf '## [%s](%s/releases/tag/%s) — %s\n\n' "$1" "$REPO_URL" "$1" "$2"
  if [[ -n "$notes" ]]; then printf '%s\n\n' "${notes%$'\n'}"; else printf '_No changes._\n\n'; fi
}

case "${1:-}" in
  --release)
    VERSION="${2:?usage: changelog.sh --release X.Y.Z}"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a stable version: $VERSION" >&2; exit 2; }
    if [[ -f "$FILE" ]] && grep -q "^## \[$VERSION\]" "$FILE"; then echo "$VERSION is already in $FILE"; exit 0; fi
    LAST="$(stable_tags | head -1)"
    NEW="$(section "$VERSION" "$(date -u +%F)" "${LAST:+$LAST..}HEAD")"
    OLD=""
    [[ -f "$FILE" ]] && OLD="$(awk 'f||/^## \[/{f=1; print}' "$FILE")"
    { header; printf '%s\n\n' "$NEW"; [[ -n "$OLD" ]] && printf '%s\n' "$OLD"; } > "$FILE.tmp"
    mv "$FILE.tmp" "$FILE"
    ;;
  --rebuild)
    TAGS=($(stable_tags))
    {
      header
      for i in "${!TAGS[@]}"; do
        t="${TAGS[$i]}"; prev="${TAGS[$((i + 1))]:-}"
        section "$t" "$(git log -1 --format=%cs "$t")" "${prev:+$prev..}$t"
      done
    } > "$FILE.tmp"
    mv "$FILE.tmp" "$FILE"
    ;;
  --check)
    missing=0
    for t in $(stable_tags); do grep -q "^## \[$t\]" "$FILE" 2>/dev/null || { echo "✘ $FILE has no section for $t"; missing=1; }; done
    (( missing == 0 )) && echo "✔ $FILE covers every stable tag"
    exit "$missing"
    ;;
  *) echo "Usage: $0 --release X.Y.Z | --rebuild | --check" >&2; exit 2 ;;
esac
