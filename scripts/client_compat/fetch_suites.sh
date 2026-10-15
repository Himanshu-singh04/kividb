#!/usr/bin/env bash
# Runs inside a container: clone the client libraries' own test suites into
# /src (a named volume) at pinned release tags. Idempotent.
set -euo pipefail
BULLMQ_TAG=${BULLMQ_TAG:-v6.3.11}
SIDEKIQ_TAG=${SIDEKIQ_TAG:-v8.1.7}
command -v git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null)
cd /src
fetch() { # dir url tag
  if [ -d "$1/.git" ] && [ "$(git -C "$1" describe --tags 2>/dev/null)" = "$3" ]; then return; fi
  rm -rf "$1"
  git -c advice.detachedHead=false clone -q --depth 1 -b "$3" "$2" "$1"
}
fetch bullmq https://github.com/taskforcesh/bullmq.git "$BULLMQ_TAG"
fetch sidekiq https://github.com/sidekiq/sidekiq.git "$SIDEKIQ_TAG"
echo "bullmq $(git -C bullmq describe --tags)  sidekiq $(git -C sidekiq describe --tags)"
