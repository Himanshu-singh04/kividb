# The image scripts/ci-local.sh runs the Linux checks in: what the GitHub
# runners have, so a local run and CI agree. Built locally as `kividb-ci`
# (no build context needed) and refreshed weekly, so `stable` here keeps up
# with the latest stable CI lints with.
FROM rust:latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cmake clang git netcat-openbsd procps python3 python3-venv redis-tools tcl tcllib \
 && rm -rf /var/lib/apt/lists/*

# clippy/rustfmt for the image's toolchain (the latest stable when the image
# was built; linux-gate.sh uses it in place of rust-toolchain.toml's
# `stable`), and 1.89, the toolchain the product Dockerfile builds with:
# newer std APIs compile on one and not the other.
RUN rustup component add clippy rustfmt \
 && rustup toolchain install 1.89.0 --profile minimal
