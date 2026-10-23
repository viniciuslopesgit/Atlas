#!/usr/bin/env bash
# Enables the repo's git hooks (.githooks/): commit-msg (Conventional Commits) and pre-push (isolated tests).
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
chmod +x "$ROOT"/.githooks/*
git -C "$ROOT" config core.hooksPath .githooks
echo "✔ Hooks enabled (core.hooksPath=.githooks)"
