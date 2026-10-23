#!/usr/bin/env bash
# Enables the repository's git hooks (.githooks/), once per clone:
#   pre-commit  quick check (Atlas/scripts/check.sh --staged)
#   commit-msg  Conventional Commits
#   pre-push    full check of exactly what is pushed; main only gets the verified stable version
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
chmod +x "$ROOT"/.githooks/*
git -C "$ROOT" config core.hooksPath .githooks
echo "✔ Hooks enabled (core.hooksPath=.githooks)"
