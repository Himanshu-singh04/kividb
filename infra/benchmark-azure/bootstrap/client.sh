#!/bin/bash
# Benchmark client: memtier_benchmark from source + Rust (CI builds KiviDB
# from source here) + optional GitHub Actions self-hosted runner. create.sh
# puts the variables this reads above this script body.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-client.log) 2>&1

apt-get update -y
apt-get install -y build-essential autoconf automake libpcre3-dev \
  libevent-dev pkg-config zlib1g-dev libssl-dev git curl jq

# Same as the server: run flat-out instead of ramping up from idle.
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [[ -w "$gov" ]]; then echo performance > "$gov" || true; fi
done

sudo -u ubuntu -H bash << 'EOSU'
set -euo pipefail
cd /home/ubuntu

if [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
fi

if [[ ! -d /home/ubuntu/memtier_benchmark ]]; then
  git clone https://github.com/RedisLabs/memtier_benchmark
fi
cd /home/ubuntu/memtier_benchmark
git pull --ff-only || true
autoreconf -ivf
./configure
make -j"$(nproc)"
EOSU

cd /home/ubuntu/memtier_benchmark && make install
echo "memtier_benchmark: $(command -v memtier_benchmark)"

if [[ "$REGISTER_RUNNER" == "true" ]]; then
  # GitHub Actions self-hosted runner.
  # --ephemeral: the runner takes exactly one job, then deregisters itself.
  #
  # GitHub refuses registration from a runner older than a minimum it raises
  # every few months, so a pinned version goes stale: the machine boots, the
  # registration fails, and the job waits in the queue. "latest" reads the
  # current release from the releases page redirect (no token, no rate limit).
  if [[ "$RUNNER_VERSION" == "latest" ]]; then
    RUNNER_VERSION="$(curl -fsS --retry 5 --retry-delay 3 -o /dev/null -w '%{redirect_url}' \
      https://github.com/actions/runner/releases/latest | sed 's#.*/tag/v##')"
  fi
  if [[ ! "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: could not tell which actions/runner release to install (got '$RUNNER_VERSION')."
    exit 1
  fi
  echo "Installing actions/runner $RUNNER_VERSION"
  RUNNER_DIR=/home/ubuntu/actions-runner
  mkdir -p "$RUNNER_DIR"
  chown ubuntu:ubuntu "$RUNNER_DIR"

  sudo -u ubuntu -H env \
    RUNNER_DIR="$RUNNER_DIR" RUNNER_VERSION="$RUNNER_VERSION" \
    GITHUB_REPOSITORY="$GITHUB_REPOSITORY" RUNNER_TOKEN="$RUNNER_TOKEN" \
    RUNNER_NAME="$RUNNER_NAME" RUNNER_LABELS="$RUNNER_LABELS" \
    bash << 'EOSU2'
set -euo pipefail
cd "$RUNNER_DIR"
curl -fsSL --retry 5 --retry-delay 3 -o actions-runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-arm64-$RUNNER_VERSION.tar.gz"
tar xzf actions-runner.tar.gz
rm -f actions-runner.tar.gz

./config.sh --unattended \
  --url "https://github.com/$GITHUB_REPOSITORY" \
  --token "$RUNNER_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work _work \
  --ephemeral

nohup ./run.sh > /home/ubuntu/actions-runner.log 2>&1 &
disown
EOSU2

  echo "GitHub Actions runner configured and started (ephemeral, labels: $RUNNER_LABELS)."
fi

echo "Client user-data finished."
