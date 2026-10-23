#!/usr/bin/env bash
# Installs the automatic updater on this Mac: every new release of viniciuslopesgit/Atlas
# (dev pre-releases included) replaces /Applications/Atlas.app within ~10 minutes.
#
#   install-updater.sh              install (or refresh) the LaunchAgent and update now
#   install-updater.sh --uninstall  remove the LaunchAgent (keeps the installed app)
set -euo pipefail

LABEL="io.cloud-atlas.updater"
SUPPORT="$HOME/Library/Application Support/Atlas/updater"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
IDENTITY="Atlas Local"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✔ Updater removed (Atlas.app and the '$IDENTITY' certificate were kept)"
  exit 0
fi

command -v gh >/dev/null || { echo "✘ Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✘ Run 'gh auth login' first (the repo is private)"; exit 1; }

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Atlas"
install -m 0755 "$(dirname "$0")/updater.sh" "$SUPPORT/updater.sh"

# Local code-signing identity: a stable signature keeps Keychain access across updates.
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "▸ Creating the '$IDENTITY' code-signing certificate in the login keychain"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  PASS="$(openssl rand -hex 16)"
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$TMP/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
    -passout "pass:$PASS" -out "$TMP/id.p12"
  security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign \
    || echo "⚠️  Could not import the certificate; updates will be ad-hoc signed (Keychain will ask again after each update)"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SUPPORT/updater.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Atlas/updater.log</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "▸ Checking for a new version now…"
/bin/bash "$SUPPORT/updater.sh" || true
tail -3 "$HOME/Library/Logs/Atlas/updater.log" 2>/dev/null || true
echo "✔ Updater installed: checks every 10 minutes (log: ~/Library/Logs/Atlas/updater.log)"
