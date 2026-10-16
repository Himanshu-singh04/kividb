#!/bin/bash
# Benchmark server: OS prep + warm Dragonfly and Redis binaries. create.sh
# puts the variables this reads above this script body. CI ships its own
# KiviDB build and can upgrade Dragonfly/Redis, so this only needs to get close.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-server.log) 2>&1

apt-get update -y
apt-get install -y wget redis-server

systemctl stop redis-server || true
systemctl disable redis-server || true

cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 65535
* hard nofile 65535
LIMITS

sysctl -w net.core.somaxconn=65535 || true
grep -q '^net.core.somaxconn' /etc/sysctl.conf || echo 'net.core.somaxconn = 65535' >> /etc/sysctl.conf

# Run flat-out from the first request instead of ramping up from idle.
# Best-effort: most Azure sizes do not expose cpufreq to the guest at all.
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [[ -w "$gov" ]]; then echo performance > "$gov" || true; fi
done

sudo -u ubuntu -H env DRAGONFLY_VERSION="$DRAGONFLY_VERSION" bash << 'EOSU'
set -euo pipefail
cd /home/ubuntu
mkdir -p /home/ubuntu/kividb

if [[ ! -x /home/ubuntu/dragonfly-aarch64 ]]; then
  echo "Downloading Dragonfly $DRAGONFLY_VERSION..."
  wget -q "https://github.com/dragonflydb/dragonfly/releases/download/$DRAGONFLY_VERSION/dragonfly-aarch64.tar.gz" \
    -O dragonfly-aarch64.tar.gz
  tar -xzf dragonfly-aarch64.tar.gz
  chmod +x dragonfly-aarch64
  rm -f dragonfly-aarch64.tar.gz
fi
echo "Dragonfly ready."
EOSU

echo "Server user-data finished."
