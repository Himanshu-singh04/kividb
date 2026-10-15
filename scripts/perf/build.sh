#!/usr/bin/env bash
# Inside the kividb-ci-valgrind container: build one tree.
#   build.sh <tag> <rev|WORK>     WORK = the mounted working tree as it is
# The binary lands in /target/perf-<tag>/release/kividb.
# LTO=fat for the real profile (slow); default off for iteration.
# FEATURES=lua (or lua,tls) for another variant.
set -eu
TAG=$1 REV=$2
RUSTUP_TOOLCHAIN=$(rustup default | cut -d" " -f1); export RUSTUP_TOOLCHAIN
git config --global --add safe.directory /src
rm -rf "/w-$TAG" && mkdir -p "/w-$TAG"
if [ "$REV" = WORK ]; then
  (cd /src && git ls-files -z --cached --others --exclude-standard | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) | tar -xf - -C "/w-$TAG"
else
  (cd /src && git archive "$REV") | tar -xf - -C "/w-$TAG"
fi
cd "/w-$TAG"
export CARGO_PROFILE_RELEASE_LTO=${LTO:-off}
[ "${LTO:-off}" = off ] && export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_PROFILE_RELEASE_DEBUG=1
start=$(date +%s)
CARGO_TARGET_DIR="/target/perf-$TAG" cargo build -q --release ${OFFLINE---offline} ${FEATURES:+--features "$FEATURES"} 2>&1 | tail -5
echo "built $TAG ($REV, lto=${LTO:-off}) in $(( $(date +%s) - start )) s"
ls -la "/target/perf-$TAG/release/kividb"
