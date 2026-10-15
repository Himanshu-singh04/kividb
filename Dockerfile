# syntax=docker/dockerfile:1

# ── Stage 1: build ────────────────────────────────────────────────────────────
# Pinned to the same Debian release as the runtime stage below (bookworm) —
# `rust:1.89-slim` floats to whatever Debian release is current upstream
# (currently trixie/glibc 2.40+), which produces a binary that fails to
# start on the older bookworm-slim runtime ("GLIBC_2.38 not found") for any
# build that pulls in a dependency touching a newer glibc symbol version
# (observed with the `tls` feature's dependency chain).
FROM rust:1.89-slim-bookworm AS builder

WORKDIR /build

# Which Cargo features to build with — set per image variant via
# `docker build --build-arg KIVIDB_FEATURES=tls` (see .github/workflows/release.yml).
# Must be declared before both RUN cargo build steps below, including the
# dummy dependency-cache build, so the cached deps layer matches the feature
# set actually used by the real build.
ARG KIVIDB_FEATURES=""

# Cache dependencies separately from source — Docker layer cache trick.
# Copy only the manifest files first, build a dummy main, then replace with
# real source. This means `cargo build --release` is only re-run when
# Cargo.toml/Cargo.lock change, not on every source edit.
COPY Cargo.toml Cargo.lock ./
# On arm64, atomics as single instructions (LSE) and not as calls that choose
# at run time: it needs ARMv8.1, which every arm64 server has (a Raspberry
# Pi 4 has not). The same flags in both builds, or the second rebuilds the
# dependencies the first cached.
RUN mkdir src \
    && echo 'fn main() {}' > src/main.rs \
    && echo '' > src/lib.rs \
    && if [ "$(uname -m)" = aarch64 ]; then export RUSTFLAGS="-C target-feature=+lse"; fi \
    && cargo build --release ${KIVIDB_FEATURES:+--features "${KIVIDB_FEATURES}"} \
    && rm -f target/release/kividb target/release/deps/kividb*

# Now copy real source and build for real
COPY src ./src
RUN if [ "$(uname -m)" = aarch64 ]; then export RUSTFLAGS="-C target-feature=+lse"; fi \
    && cargo build --release ${KIVIDB_FEATURES:+--features "${KIVIDB_FEATURES}"}

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim

# `redis-tools` ships redis-cli (plus redis-benchmark and the redis-check-*
# utilities). It is here for debugging: `kubectl exec` into a kividb pod and
# talk to the server without needing a sidecar, a port-forward, or a
# throwaway client pod -- which is how Dragonfly ships its image too.
#
# bookworm's redis-tools is 7.0.15 exactly, matching the `redis_version` this
# server advertises in INFO, so redis-cli's own feature detection lines up
# with what the engine actually implements.
#
# Costs ~6.8 MB in the final image (measured on bookworm-slim, with
# ca-certificates already installed).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates redis-tools \
    && rm -rf /var/lib/apt/lists/*

# Non-root user — good practice for containers
RUN useradd -ms /bin/bash kividb
USER kividb
WORKDIR /home/kividb

COPY --from=builder /build/target/release/kividb /usr/local/bin/kividb

# KiviDB is licensed under the GNU Affero General Public License v3 (AGPL-3.0-only),
# as in the release tarballs and packages.
COPY LICENSE NOTICE /usr/share/doc/kividb/
LABEL org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.vendor="KIVIDB PRIVATE LIMITED" \
      org.opencontainers.image.source="https://github.com/kividbio/kividb"

EXPOSE 6380

ENTRYPOINT ["kividb"]
# A container is reached through its network, never from loopback: protected
# mode would turn every client away. As in Redis's image, it is off by default
# here; arguments of your own replace this, and with them it is on unless you
# set a password or a bind address.
CMD ["--protected-mode", "no"]