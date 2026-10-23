#!/bin/zsh
# Writes a version's Release notes from its section in the CHANGELOG:
# summary, installation instructions, the version's lists and the link to the history.
#   ./scripts/release_notes.sh [X.Y.Z] [--beta]
set -e
cd "$(dirname "$0")/.."
VERSION=${1:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)}
python3 -I - "$VERSION" "${2:-}" <<'PY'
import re, sys
v, beta = sys.argv[1], sys.argv[2] == "--beta"
repo = "https://github.com/viniciuslopesgit/Atlas"
s = open("../CHANGELOG.md", encoding="utf-8").read()
m = re.search(rf"^## \[{re.escape(v)}\][^\n]*\n(.*?)(?=^## \[|^\[\d|\Z)", s, re.M | re.S)
if not m:
    sys.exit(f"The CHANGELOG has no ## [{v}] section.")
body = m.group(1).strip()
cut = body.find("### ")
summary, lists = (body[:cut], body[cut:]) if cut >= 0 else (body, "")
if beta:
    print(f"> **Beta.** Becomes stable once it meets the [release criteria]({repo}/blob/dev/docs/RELEASE_CRITERIA.md). "
          f"For everyday use, prefer the [latest stable version]({repo}/releases/latest).")
    print()
print(summary.strip())
print(f"""
## Install

1. Download **Atlas-{v}.dmg** (under *Assets*), open it and drag Atlas to **Applications**.
2. The app is not notarized: on first launch, allow it in *System Settings ▸ Privacy & Security ▸ Open Anyway*.

Verify the file: `shasum -a 256 -c Atlas-{v}.dmg.sha256` in the folder where you downloaded both files.

macOS 14 or later · Apple silicon and Intel.
""")
if lists:
    print(re.sub(r"^### ", "## ", lists.strip(), flags=re.M))
    print()
print(f"Full history in the [CHANGELOG]({repo}/blob/dev/CHANGELOG.md).")
PY
