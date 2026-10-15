#!/usr/bin/env bash
# Point git at the repository's hooks (.githooks/): formatting on commit,
# clippy on this OS and on Linux on push. Run once per clone.
set -e
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true
echo "Hooks installed (core.hooksPath = .githooks)."
echo "Before merging a PR, run the full gate: scripts/ci-local.sh full"
