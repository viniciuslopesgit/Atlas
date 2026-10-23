#!/usr/bin/env bash
# Keeps /Applications/Atlas.app on the newest GitHub release (dev pre-releases included).
# Run by the LaunchAgent io.cloud-atlas.updater (see install-updater.sh); safe to run by hand.
#
#   updater.sh              check and install if a newer release exists
#   updater.sh --force      reinstall the newest release even if it is not newer
#   updater.sh --self-test  check the version comparison and exit
set -euo pipefail

REPO="${ATLAS_REPO:-viniciuslopesgit/Atlas}"
APP="${ATLAS_APP:-/Applications/Atlas.app}"
BUNDLE_ID="io.cloud-atlas.Atlas"
SIGN_IDENTITY="${ATLAS_SIGN_IDENTITY:-Atlas Local}"
SUPPORT="$HOME/Library/Application Support/Atlas/updater"
LOG="$HOME/Library/Logs/Atlas/updater.log"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Compares two versions X.Y.Z[-dev.N]. Prints -1, 0 or 1.
# A stable version is newer than any pre-release of the same X.Y.Z.
vercmp() {
  local a="$1" b="$2" ca cb pa pb i
  ca="${a%%-*}"; cb="${b%%-*}"
  IFS=. read -r -a xa <<< "$ca"; IFS=. read -r -a xb <<< "$cb"
  for i in 0 1 2; do
    (( 10#${xa[i]:-0} > 10#${xb[i]:-0} )) && { echo 1; return; }
    (( 10#${xa[i]:-0} < 10#${xb[i]:-0} )) && { echo -1; return; }
  done
  [[ "$a" == *-* ]] && pa="${a##*.}" || pa=""
  [[ "$b" == *-* ]] && pb="${b##*.}" || pb=""
  if [[ -z "$pa" && -z "$pb" ]]; then echo 0
  elif [[ -z "$pa" ]]; then echo 1
  elif [[ -z "$pb" ]]; then echo -1
  elif (( 10#$pa > 10#$pb )); then echo 1
  elif (( 10#$pa < 10#$pb )); then echo -1
  else echo 0; fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  fail=0
  check() { local got; got="$(vercmp "$1" "$2")"; [[ "$got" == "$3" ]] || { echo "✘ vercmp $1 $2 = $got (expected $3)"; fail=1; }; }
  check 2.0.0-dev.9 2.0.0-dev.10 -1
  check 2.0.0-dev.10 2.0.0 -1
  check 2.0.0 2.1.0-dev.1 -1
  check 2.1.0 2.0.9 1
  check 10.0.0 9.9.9 1
  check 2.0.0 2.0.0 0
  check 2.0.0-dev.3 2.0.0-dev.3 0
  check 1.0.1 2.0.0-dev.1 -1
  (( fail == 0 )) && echo "✔ updater self-test passed"
  exit "$fail"
fi

mkdir -p "$SUPPORT" "$(dirname "$LOG")"
exec >> "$LOG" 2>&1
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
state() { printf '{"lastCheck":"%s","result":"%s","latest":"%s"}\n' "$(date -u +%FT%TZ)" "$1" "${2:-}" > "$SUPPORT/state.json"; }

# Only one run at a time.
LOCK="$SUPPORT/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then rm -rf "$LOCK"; mkdir "$LOCK"; else exit 0; fi
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$LOCK"' EXIT

command -v gh >/dev/null || { log "gh not found"; state "error: gh not found"; exit 1; }

LATEST="$(gh release list --repo "$REPO" --limit 30 --exclude-drafts --json tagName --jq '.[].tagName' 2>>"$LOG" \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+(-dev\.[0-9]+)?$' \
  | { best=""; while read -r t; do [[ -z "$best" || "$(vercmp "$t" "$best")" == 1 ]] && best="$t"; done; echo "$best"; })" \
  || true
[[ -n "$LATEST" ]] || { log "could not list releases of $REPO"; state "error: could not list releases"; exit 1; }

INSTALLED=""
[[ -d "$APP" ]] && INSTALLED="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"

if [[ "${1:-}" != "--force" && -n "$INSTALLED" && "$(vercmp "$LATEST" "$INSTALLED")" != 1 ]]; then
  state "up to date" "$LATEST"
  exit 0
fi

log "updating ${INSTALLED:-(not installed)} → $LATEST"
gh release download "$LATEST" --repo "$REPO" --pattern "Atlas-$LATEST.zip" --dir "$WORK" \
  || { log "download failed"; state "error: download failed" "$LATEST"; exit 1; }
ditto -x -k "$WORK/Atlas-$LATEST.zip" "$WORK/unzipped"
NEW="$WORK/unzipped/Atlas.app"
[[ -x "$NEW/Contents/MacOS/Atlas" ]] || { log "archive has no Atlas.app"; state "error: bad archive" "$LATEST"; exit 1; }
xattr -cr "$NEW"

# Re-sign with the local identity so the Keychain keeps trusting the app across updates.
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$NEW" || { log "re-sign failed, keeping CI signature"; }
fi
codesign --verify --deep "$NEW" || { log "signature check failed"; state "error: invalid signature" "$LATEST"; exit 1; }

WAS_RUNNING=0
if pgrep -f "$APP/Contents/MacOS/Atlas" >/dev/null; then
  WAS_RUNNING=1
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -f "$APP/Contents/MacOS/Atlas" >/dev/null || break; sleep 1; done
  if pgrep -f "$APP/Contents/MacOS/Atlas" >/dev/null; then
    log "Atlas did not quit; will retry later"; state "waiting: Atlas is busy" "$LATEST"; exit 0
  fi
fi

# Swap: keep the old copy until the new one is in place.
BACKUP="$APP.previous"
rm -rf "$BACKUP"
[[ -d "$APP" ]] && mv "$APP" "$BACKUP"
if ditto "$NEW" "$APP"; then
  rm -rf "$BACKUP"
else
  log "install failed, restoring previous version"
  rm -rf "$APP"; [[ -d "$BACKUP" ]] && mv "$BACKUP" "$APP"
  state "error: install failed" "$LATEST"; exit 1
fi

log "installed $LATEST"
state "updated" "$LATEST"
osascript -e "display notification \"Atlas $LATEST is installed.\" with title \"Atlas updated\"" >/dev/null 2>&1 || true
(( WAS_RUNNING )) && open "$APP"
exit 0
