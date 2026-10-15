#!/usr/bin/env bash
# The whole comparison, in Docker: build KiviDB (Linux, --features lua), start
# it and a redis:8 baseline on one network, run run.sh against each (suites,
# steady soaks, and soaks with a SIGKILL + restart of the server, both servers
# with `appendonly yes`), then remove every container it started.
#
#   scripts/client_compat/docker_all.sh [step...]     (steps as for run.sh)
#
# Environment: OUT (default ./client-compat-out), SKIP_BUILD=1, N, REDIS_IMAGE
# (default redis:8), KIVIDB_ARGS (extra server arguments).
#
# KiviDB runs with --security-opt seccomp=unconfined so it gets io_uring, the
# I/O model production uses on Linux; the server log's "I/O model" line is
# copied into the summary.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export MSYS_NO_PATHCONV=1
OUT=${OUT:-$PWD/client-compat-out}
REDIS_IMAGE=${REDIS_IMAGE:-redis:8}
export NETWORK=kcc
mkdir -p "$OUT"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  bash "$HERE/docker_build.sh" > "$OUT/build.log" 2>&1 < /dev/null || { echo "build failed: $OUT/build.log"; exit 1; }
fi

cleanup() { docker rm -f kcc-kividb kcc-redis >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
docker network inspect $NETWORK >/dev/null 2>&1 || docker network create $NETWORK >/dev/null

docker run -d --name kcc-kividb --network $NETWORK --security-opt seccomp=unconfined \
  -v kividb-target:/target:ro -w /data --entrypoint /target/release/kividb rust:1.89-bookworm \
  --port 6379 --aof --dir /data --update-check no --protected-mode no ${KIVIDB_ARGS:-} >/dev/null
docker run -d --name kcc-redis --network $NETWORK "$REDIS_IMAGE" \
  redis-server --appendonly yes --appendfsync everysec --save "" >/dev/null

wait_up() { # container
  for _ in $(seq 1 100); do
    docker run --rm --network $NETWORK redis:8 redis-cli -h "$1" ping 2>/dev/null | grep -q PONG && return 0
    sleep 0.3
  done
  echo "$1 did not come up"; docker logs "$1" | tail -20; exit 1
}
wait_up kcc-kividb
wait_up kcc-redis
{
  echo "KiviDB: $(docker run --rm --network $NETWORK redis:8 redis-cli -h kcc-kividb info server | grep -E '^(kividb_version|redis_version)' | tr -d '\r' | tr '\n' ' ')"
  docker logs kcc-kividb 2>&1 | grep -i 'I/O model' | head -1
  echo "Redis: $(docker run --rm --network $NETWORK redis:8 redis-cli -h kcc-redis info server | grep -E '^redis_version' | tr -d '\r')"
} | tee "$OUT/servers.txt"

# The two servers are measured one after the other: the suites are timing
# sensitive and share the machine.
for s in kividb redis; do
  LABEL=$s OUT="$OUT/$s" RESTART_CONTAINER=kcc-$s \
    bash "$HERE/run.sh" "kcc-$s" 6379 "$@"
done
docker logs kcc-kividb > "$OUT/kividb/server.log" 2>&1

# BullMQ: the tests that fail on KiviDB and pass on Redis (and the reverse).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
OUT=$(cd "$OUT" && pwd)
{
  for cfg in "" "-ioredis"; do
    echo "== BullMQ$cfg: KiviDB vs Redis"
    docker run --rm -v "$(native "$OUT"):/out" -v "$(native "$HERE"):/h:ro" node:22-bookworm-slim \
      node /h/vitest_compare.js "/out/kividb/bullmq-kividb$cfg.json" "/out/redis/bullmq-redis$cfg.json"
  done
  echo "== Sidekiq: failing on KiviDB / on Redis"
  grep -E '#test.* = [FE]$' "$OUT/kividb/sidekiq-kividb.log" 2>/dev/null | sed 's/^/  kividb: /'
  grep -E '#test.* = [FE]$' "$OUT/redis/sidekiq-redis.log" 2>/dev/null | sed 's/^/  redis:  /'
} > "$OUT/compare.txt" 2>&1
echo
cat "$OUT/servers.txt" "$OUT/kividb/summary.txt" "$OUT/redis/summary.txt" "$OUT/compare.txt"
