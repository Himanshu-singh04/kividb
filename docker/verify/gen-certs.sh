#!/usr/bin/env sh
# Generates a self-signed cert/key pair for the TLS variants under test.
# Idempotent — skips generation if the files already exist.
set -eu

cd "$(dirname "$0")"
mkdir -p certs

if [ -f certs/server.crt ] && [ -f certs/server.key ]; then
    echo "certs/server.crt + certs/server.key already exist, skipping"
    exit 0
fi

# MSYS_NO_PATHCONV: on Git-Bash/Windows, MSYS mangles leading-slash args
# like "/CN=..." into Windows paths — this disables that for this command
# only. No effect on Linux/macOS.
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout certs/server.key -out certs/server.crt \
    -days 3 -subj "/CN=kividb-verify" \
    -addext "subjectAltName=DNS:kividb-tls,DNS:kividb-full,DNS:localhost,IP:127.0.0.1"

# World-readable — the kividb container runs as a non-root, non-host-matching
# UID (see Dockerfile: `USER kividb`), so the mounted key must stay readable
# by any UID. Fine for a throwaway dev-verification cert; never do this for
# a real deployment key.
chmod 644 certs/server.key certs/server.crt

echo "generated certs/server.crt + certs/server.key"
