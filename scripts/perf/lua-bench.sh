#!/usr/bin/env bash
# BullMQ against one server, and what the server says a script call cost:
# jobs a second, and usec_per_call of EVALSHA from commandstats.
#
#   scripts/perf/lua-bench.sh <tag>...     tags built with FEATURES=lua, or "redis"
#
# By default the server gets one CPU (as the smallest cloud instance has)
# and an AOF fsynced every second, and one BullMQ process drives one queue
# from a node container on other CPUs, using the checkout on the kcc-src
# volume that scripts/client_compat keeps. One server at a time.
#
# Environment:
#   N=20000            jobs per phase, per queue
#   SERVER_CPUS=2      the CPUs the server may use (a cpuset: "2", "0-3")
#   THREADS=1          the server's --threads
#   QUEUES=1           BullMQ processes, each with a queue and a hash tag of
#                      its own; the figures printed are their sum
#   CLIENT_CPUS=4-9    the CPUs the BullMQ processes share
#   KIVIDB_ARGS=       more server arguments ("--lua-parallel-scripts true")
#   KIVIDB_AOF=        set empty to run without the AOF
#   PERF=1             sample the server with perf while the benchmark runs
#                      (image kividb-ci-perf: the valgrind image with
#                      linux-perf added); where the time went is left in
#                      target/perf/perf-<tag>.txt. PERF_CALLGRAPH=1 adds who
#                      called what.
#   PROFILE=1          run the server under callgrind instead (small N);
#                      target/perf/callgrind-<tag>.out is left to annotate.
set -u
REPO=$(git rev-parse --show-toplevel)
HERE="$REPO/scripts/perf"
OUT="$REPO/target/perf"
N=${N:-20000} SERVER_CPUS=${SERVER_CPUS:-${SERVER_CPU:-2}} CLIENT_CPUS=${CLIENT_CPUS:-4-9}
THREADS=${THREADS:-1} QUEUES=${QUEUES:-1}
NET=kperf
export MSYS_NO_PATHCONV=1
native() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
mkdir -p "$OUT"
docker network inspect $NET >/dev/null 2>&1 || docker network create $NET >/dev/null
cli() { docker run --rm --network $NET redis:8 redis-cli -h kperf-server "$@"; }

for tag in "$@"; do
  docker rm -f kperf-server >/dev/null 2>&1
  if [ "$tag" = redis ]; then
    docker run -d --name kperf-server --network $NET --cpuset-cpus "$SERVER_CPUS" redis:8 \
      redis-server --appendonly yes --appendfsync everysec --save "" >/dev/null
  else
    wrap=""
    [ -n "${PROFILE:-}" ] && wrap="valgrind --tool=callgrind --callgrind-out-file=/out/callgrind-$tag.out"
    image=kividb-ci-valgrind
    [ -n "${PERF:-}" ] && image=kividb-ci-perf
    docker run -d --name kperf-server --network $NET --cpuset-cpus "$SERVER_CPUS" ${PERF:+--privileged} \
      --security-opt seccomp=unconfined -v kividb-ci-target:/target:ro -v "$(native "$OUT"):/out" \
      -v "$(native "$HERE"):/perf:ro" -w /data \
      "$image" bash -c "mkdir -p /data && cd /data && exec $wrap /target/perf-$tag/release/kividb --port 6379 --bind 0.0.0.0 ${KIVIDB_AOF---aof} --dir /data --threads $THREADS --update-check no --loglevel warning ${KIVIDB_ARGS:-}" >/dev/null
  fi
  for _ in $(seq 200); do cli ping 2>/dev/null | grep -q PONG && break; sleep 0.3; done
  if [ -n "${PERF:-}" ] && [ "$tag" != redis ]; then
    docker exec -d -e CALLGRAPH="${PERF_CALLGRAPH:-}" kperf-server bash /perf/perf-record.sh
  fi
  rm -f "$OUT"/lua-queue-*.txt
  for queue in $(seq "$QUEUES"); do
    docker rm -f "kperf-client-$queue" >/dev/null 2>&1
    # Bounded: a server that has stopped answering must not leave this, and
    # whoever started it, waiting for ever.
    timeout "${BENCH_TIMEOUT:-600}" docker run --rm --name "kperf-client-$queue" --network $NET --cpuset-cpus "$CLIENT_CPUS" -v kcc-src:/src:ro -v "$(native "$HERE"):/perf:ro" \
      -e REDIS_URL=redis://kperf-server:6379 -e LABEL="$tag" -e N="$N" -e TAG="q$queue" \
      -e PRODUCERS=8 -e WORKERS=8 -e CONCURRENCY=100 \
      node:22-bookworm bash -c 'mkdir -p /tmp/nm && ln -s /src/bullmq /tmp/nm/bullmq && NODE_PATH=/tmp/nm:/src/bullmq/node_modules node /perf/bullmq-bench.cjs' 2>&1 \
      | grep -aE "^(RESULT|ERR)" | tail -1 > "$OUT/lua-queue-$queue.txt" &
  done
  wait
  for queue in $(seq "$QUEUES"); do docker rm -f "kperf-client-$queue" >/dev/null 2>&1; done
  jobs=$(cat "$OUT"/lua-queue-*.txt | python "$HERE/sum-queues.py")
  stats=$(cli info commandstats | tr -d '\r' | grep -aE "^cmdstat_(evalsha|eval):" | sed -E 's/cmdstat_([a-z]+):calls=([0-9]+),usec=[0-9]+,usec_per_call=([0-9.]+).*/\1 calls=\2 usec_per_call=\3/' | tr '\n' ' ')
  cpu=$(cli info cpu | tr -d '\r' | grep -aE "^used_cpu_(user|sys):" | tr '\n' ' ')
  echo "$tag cpus=$SERVER_CPUS threads=$THREADS queues=$QUEUES ${KIVIDB_ARGS:+[$KIVIDB_ARGS] }$jobs  $stats $cpu" | tee -a "$OUT/lua-results.txt"
  if [ -n "${PERF:-}" ] && [ "$tag" != redis ]; then
    docker exec -e CALLGRAPH="${PERF_CALLGRAPH:-}" -e TAG="$tag" -e LINES="${PERF_LINES:-120}" kperf-server bash /perf/perf-report.sh
  fi
  docker rm -f kperf-server >/dev/null 2>&1
done
