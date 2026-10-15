#!/usr/bin/env bash
# Inside a node container: install the BullMQ soak's dependencies (cached on
# /src) and run it. Environment is passed through to soak.mjs.
set -euo pipefail
W=/src/soak-bullmq
mkdir -p "$W"
cp /h/soak/bullmq/soak.mjs /h/soak/bullmq/package.json "$W/"
cd "$W"
if [ ! -d node_modules/bullmq ] || ! grep -q '"version": "6.3.11"' node_modules/bullmq/package.json; then
  npm install --no-audit --no-fund --loglevel=error > /dev/null
fi
exec node soak.mjs
