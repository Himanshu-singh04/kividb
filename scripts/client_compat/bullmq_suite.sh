#!/usr/bin/env bash
# Runs inside a node:22 container: BullMQ's own vitest suite against a server.
#
#   bullmq_suite.sh <host> <port> <label> [vitest args / file filters...]
#
# /src/bullmq is the checkout (fetch_suites.sh); results go to
# /out/bullmq-<label>[-ioredis].{log,json}.
#
# The suite assumes Redis at localhost:6379 in several places (sandboxed
# processes, connection tests, `new IORedis(redisHost)` without a port), as on
# its CI. So unless <host> is already localhost:6379, a forwarder (forward.js) is
# started on localhost:6379 and the suite is pointed there. Run one suite per
# client container at a time.
#
# Runs two configs, as `yarn coverage` on BullMQ's CI does: the default one
# (adapter-agnostic, ioredis factory) and vitest.ioredis.config.ts
# (connection, sandboxed processes, worker.ioredis) minus tests/cluster.test.ts,
# which needs a Redis Cluster.
set -uo pipefail
HOST=${1:?host}
PORT=${2:?port}
LABEL=${3:?label}
shift 3
cd /src/bullmq
if [ ! -f dist/cjs/classes/main.js ]; then
  corepack enable >/dev/null 2>&1 || true
  {
    yarn install --ignore-engines --frozen-lockfile --non-interactive
    yarn build
  } > /out/bullmq-install.log 2>&1 || { echo "bullmq install/build failed"; tail -30 /out/bullmq-install.log; exit 1; }
fi
if [ "$HOST:$PORT" != "localhost:6379" ] && [ "$HOST:$PORT" != "127.0.0.1:6379" ]; then
  pkill -f "forward.js 6379" 2>/dev/null
  node "$(dirname "$0")/forward.js" 6379 "$HOST" "$PORT" &
  up=0
  for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/6379) 2>/dev/null && { up=1; break; }; sleep 0.1; done
  # Without the forwarder every test fails with ECONNREFUSED: say so instead.
  [ $up = 1 ] || { echo "could not forward localhost:6379 to $HOST:$PORT"; exit 1; }
fi
export REDIS_HOST=localhost REDIS_PORT=6379 CI=1
npx vitest run --no-file-parallelism --reporter=verbose --reporter=json \
  --outputFile.json=/out/bullmq-$LABEL.json "$@" > /out/bullmq-$LABEL.log 2>&1 < /dev/null
echo "default config exit=$?"
if [ $# -eq 0 ]; then
  npx vitest run --no-file-parallelism --config vitest.ioredis.config.ts \
    --exclude tests/cluster.test.ts --reporter=verbose --reporter=json \
    --outputFile.json=/out/bullmq-$LABEL-ioredis.json > /out/bullmq-$LABEL-ioredis.log 2>&1 < /dev/null
  echo "ioredis config exit=$?"
fi
pkill -f "forward.js 6379" 2>/dev/null
exit 0
