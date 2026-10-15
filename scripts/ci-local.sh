#!/usr/bin/env bash
# Run CI's checks on this machine, without GitHub Actions minutes.
#
#   scripts/ci-local.sh quick           Linux fmt + clippy (what pre-push runs)
#   scripts/ci-local.sh full            everything ci.yml and
#                                       linux-verification.yml check
#   scripts/ci-local.sh full compat     ... plus Redis's own Tcl suite (long)
#   scripts/ci-local.sh <stage>...      lint msrv test build matrix compat
#
# Linux runs in Docker (the kividb-ci image, scripts/ci/Dockerfile), with
# io_uring allowed, because the default Linux I/O path (src/server_uring.rs)
# is not compiled at all on Windows or macOS: a clean Windows clippy says
# nothing about it, and the reverse holds for Windows-only code.
#
# Environment:
#   KIVIDB_CI_PULL=1   rebuild the image now (it is also rebuilt weekly, so
#                      clippy keeps up with the latest stable, as in CI)
#   KIVIDB_CI_LTO=on   release builds with LTO, as in CI (default off: much
#                      faster, and the checks do not depend on it)
#
# The working tree is checked as it is, uncommitted changes included.
# Caches: docker volumes kividb-cargo-registry, kividb-ci-target,
# kividb-ci-cache (logs/ holds the server logs of the last matrix run).

set -u
ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT" || exit 2
IMAGE=kividb-ci

case "${1:-full}" in
  quick) STAGES=(lint) ;;
  full) shift; STAGES=(lint msrv test build matrix "$@") ;;
  *) STAGES=("$@") ;;
esac

if ! docker info >/dev/null 2>&1; then
  echo "ci-local: Docker is not running; the Linux checks need it." >&2
  exit 3
fi

# Build the image if it is missing, asked for, a week old, or built from
# another version of scripts/ci/Dockerfile.
want=$(git hash-object scripts/ci/Dockerfile)
rebuild=${KIVIDB_CI_PULL:-0}
if ! created=$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null); then
  rebuild=1
elif [ "$(docker image inspect -f '{{index .Config.Labels "kividb.ci.dockerfile"}}' "$IMAGE")" != "$want" ]; then
  rebuild=1
elif age=$(( $(date +%s) - $(date -d "$created" +%s 2>/dev/null || date +%s) )); [ "$age" -gt 604800 ]; then
  rebuild=1
fi
if [ "$rebuild" = 1 ]; then
  echo "ci-local: building the $IMAGE image..."
  docker build --pull -q --label "kividb.ci.dockerfile=$want" -t "$IMAGE" - \
    < scripts/ci/Dockerfile >/dev/null || exit 2
fi

host_root=$ROOT
command -v cygpath >/dev/null 2>&1 && host_root=$(cygpath -w "$ROOT")

lto=off
[ "${KIVIDB_CI_LTO:-off}" = on ] && lto=fat

MSYS_NO_PATHCONV=1 exec docker run --rm \
  --security-opt seccomp=unconfined \
  -v "$host_root:/src:ro" \
  -v kividb-cargo-registry:/usr/local/cargo/registry \
  -v kividb-ci-target:/target \
  -v kividb-ci-cache:/cache \
  -e CARGO_TARGET_DIR=/target \
  -e CARGO_PROFILE_RELEASE_LTO=$lto \
  -e CI=true \
  "$IMAGE" bash /src/scripts/ci/linux-gate.sh "${STAGES[@]}"
