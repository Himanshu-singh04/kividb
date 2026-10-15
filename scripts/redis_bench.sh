#!/usr/bin/env bash
# Run redis-benchmark across the command surface against one server binary.
#
#   redis_bench.sh <binary> <io-model|redis> <requests> <out.csv>
#
# Pass `redis` as the second argument to benchmark a real `redis-server` with
# the identical workload — that is what makes the numbers comparable, since
# both arms then run the same commands, keyspace, pipeline depth and client
# count on the same machine.
#
# Emits redis-benchmark's own CSV, concatenated across command groups, with a
# header row. Starting/stopping the server is handled here so the caller can
# treat this as a pure "binary in, numbers out" step.
set -euo pipefail

BIN=${1:?binary}
IO_MODEL=${2:-tokio}
REQUESTS=${3:-100000}
OUT=${4:?output csv}

# `redis` selects a real redis-server, which has no --io-model flag and needs
# persistence turned off explicitly to match how kividb is started here.
SERVER_KIND=kividb
if [ "$IO_MODEL" = "redis" ]; then
  SERVER_KIND=redis
fi

# Overridable so successive arms in one job do not collide. They used to share
# 7777: the previous server had exited its script (and its EXIT trap had run)
# but had not yet released the socket, so the next arm hit
# "bind: Address already in use" and the whole step failed.
PORT=${BENCH_PORT:-7777}
CLIENTS=50
PIPELINE=16
DATASIZE=32

# Command groups redis-benchmark knows natively. Deliberately broad: the point
# of this benchmark is to cover what a SET/GET-only workload cannot.
TESTS="ping,set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,spop,zadd,zpopmin,lrange_100,lrange_300,lrange_600,mset"

# Belt and braces alongside the distinct ports: if anything is still holding
# this port, say so here rather than letting the server fail to bind and be
# reported as "did not become reachable", which points at the wrong thing.
for _ in $(seq 1 30); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
    break
  fi
  exec 3<&- 2>/dev/null || true
  echo "  port $PORT still in use, waiting..."
  sleep 1
done

echo "Starting $BIN ($SERVER_KIND, io-model=$IO_MODEL) on :$PORT"
LOG="/tmp/bench-server-$IO_MODEL.log"
if [ "$SERVER_KIND" = redis ]; then
  # Persistence off on both arms: an RDB/AOF write landing mid-run would show
  # up as a throughput dip on whichever arm happened to trigger it.
  "$BIN" --port "$PORT" --bind 127.0.0.1 --loglevel warning \
    --save '' --appendonly no > "$LOG" 2>&1 &
else
  chmod +x "$BIN"
  "$BIN" --port "$PORT" --bind 127.0.0.1 --loglevel error --io-model "$IO_MODEL" \
    > "$LOG" 2>&1 &
fi
SERVER_PID=$!
# `kill 0` is not enough — a uring server that fails to init can leave the
# process up but not listening, so wait on the port instead.
#
# Cleanup waits for the process to actually go away before returning, then
# escalates. Returning while it is still shutting down is what let the next
# arm race it for the port.
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$SERVER_PID" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -9 "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  if redis-cli -p "$PORT" ping >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! redis-cli -p "$PORT" ping >/dev/null 2>&1; then
  echo "::error::$SERVER_KIND did not become reachable (io-model=$IO_MODEL)"
  cat "$LOG" || true
  exit 1
fi

# Record what actually answered, so a report can never misattribute numbers to
# the wrong server.
redis-cli -p "$PORT" info server 2>/dev/null \
  | grep -iE "^(redis_version|kividb_version|server_name)" || true

echo '"test","rps","avg_latency_ms","min_latency_ms","p50_latency_ms","p95_latency_ms","p99_latency_ms","max_latency_ms"' > "$OUT"

# `-r` is what makes redis-benchmark substitute __rand_int__. Without it the
# literal token goes on the wire and typed commands reject it ("value is not a
# valid float"), so it must be present on every run using the placeholder.
KEYSPACE=100000

# Built-in command groups.
redis-benchmark -p "$PORT" -n "$REQUESTS" -c "$CLIENTS" -P "$PIPELINE" -d "$DATASIZE" \
  -r "$KEYSPACE" -t "$TESTS" --csv | tail -n +2 >> "$OUT"

# Seed the structures the read-side benchmarks below target. Without this they
# would measure the missing-key path, which is a different and much cheaper
# code path than the one worth watching for regressions.
echo "Seeding data for read-side benchmarks"
redis-cli -p "$PORT" del hbench sbench zbench >/dev/null
for i in $(seq 1 200); do
  echo "hset hbench f$i v$i"
  echo "sadd sbench m$i"
  echo "zadd zbench $i m$i"
  echo "set key:$i v$i"
done | redis-cli -p "$PORT" --pipe >/dev/null 2>&1

# Commands redis-benchmark has no built-in test for. `-n` is reduced for the
# heavier ones so the job stays inside its time budget.
run_custom() {
  local name=$1; shift
  local n=$1; shift
  echo "  custom: $name"
  local line
  line=$(redis-benchmark -p "$PORT" -n "$n" -c "$CLIENTS" -P "$PIPELINE" \
           -r "$KEYSPACE" --csv "$@" | tail -n +2)
  if [ -z "$line" ]; then
    echo "::error::custom benchmark '$name' produced no output"
    exit 1
  fi
  # redis-benchmark labels custom runs with the full command; relabel to a
  # stable short name so A/B comparison can line rows up across runs.
  echo "\"$name\",${line#*,}" >> "$OUT"
}

run_custom "zrangebyscore"     "$((REQUESTS/2))" zrangebyscore zbench 10 100
run_custom "zrange_withscores" "$((REQUESTS/2))" zrange zbench 0 20 WITHSCORES
run_custom "hgetall"           "$((REQUESTS/2))" hgetall hbench
run_custom "smembers"          "$((REQUESTS/2))" smembers sbench
run_custom "xadd"              "$((REQUESTS/2))" xadd xbench '*' field value
run_custom "publish"           "$REQUESTS"       publish chan payload
run_custom "mget"              "$((REQUESTS/2))" mget key:1 key:2 key:3 key:4
run_custom "exists"            "$REQUESTS"       exists key:__rand_int__
run_custom "ttl"               "$REQUESTS"       ttl key:__rand_int__

echo "Wrote $OUT"
