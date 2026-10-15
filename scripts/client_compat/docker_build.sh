#!/usr/bin/env bash
# Build a Linux KiviDB binary with Lua (BullMQ needs EVAL) inside Docker.
#
#   scripts/client_compat/docker_build.sh
#
# The repository is mounted read-only and copied to /work; the target dir and
# the cargo registry live on named volumes so rebuilds are incremental. The
# binary ends up at /target/release/kividb on the `kividb-target` volume, which
# docker_all.sh mounts into the server container.
#
# Environment: FEATURES (default "lua"), IMAGE (default rust:1.89-bookworm),
# DOCKER_DNS (a resolver for the build container, such as 1.1.1.1, where
# Docker's own does not resolve: the build installs cmake and clang).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
FEATURES=${FEATURES:-lua}
IMAGE=${IMAGE:-rust:1.89-bookworm}

# Git Bash on Windows rewrites "/work"-style arguments; turn that off and hand
# docker a native path.
export MSYS_NO_PATHCONV=1
if command -v cygpath >/dev/null 2>&1; then REPO=$(cygpath -w "$REPO"); fi

docker run --rm ${DOCKER_DNS:+--dns "$DOCKER_DNS"} \
  -v "$REPO:/src:ro" \
  -v kividb-target:/target \
  -v kividb-cargo-registry:/usr/local/cargo/registry \
  -v kividb-rustup:/usr/local/rustup \
  -e CARGO_TARGET_DIR=/target \
  -e CARGO_PROFILE_RELEASE_LTO=off \
  "$IMAGE" bash -c "
    set -e
    (command -v cmake && command -v clang) >/dev/null 2>&1 || \
      (apt-get update -qq && apt-get install -y -qq cmake clang >/dev/null)
    rm -rf /work && mkdir /work && cd /src && \
      tar --exclude=./target --exclude=./.git --exclude=./.claude -cf - . | tar -xf - -C /work
    cd /work
    cargo build --release --features '$FEATURES'
    ls -l /target/release/kividb
  " < /dev/null
