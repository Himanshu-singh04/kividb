#!/usr/bin/env bash
# A/B throughput check for the flush memory-reclamation change.
#
# For each binary it measures:
#   fresh   - SET/GET throughput on a server that has never been flushed
#   refill  - SET throughput immediately after a FLUSHDB of a large keyspace
#             (the case where the old code silently benefited from the hash
#             tables it failed to release)
#   flush   - wall time of the FLUSHDB itself, which now also runs malloc_trim
#
# Usage: bench_flush_regression.sh <label> <binary> [port]
set -uo pipefail

LABEL=${1:?label}
BIN=${2:?binary}
PORT=${3:-6410}
KEYS=${KEYS:-1000000}
REQS=${REQS:-1000000}
WORK=$(mktemp -d)

CLI="redis-cli -p $PORT"

cleanup() { kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

( cd "$WORK" && "$BIN" --port "$PORT" >server.log 2>&1 & )
for _ in $(seq 1 60); do
  [ "$($CLI ping 2>/dev/null)" = "PONG" ] && break
  sleep 0.5
done
PID=$(pgrep -f "$BIN --port $PORT" | head -1)

bench() { # <test> -> ops/sec
  redis-benchmark -p "$PORT" -t "$1" -n "$REQS" -r "$KEYS" -P 16 -c 50 -q 2>/dev/null \
    | awk '/requests per second/ {
             for (i = 1; i <= NF; i++)
               if ($i == "requests") { print $(i-1); exit }
           }'
}

echo "=== $LABEL ($BIN) ==="

SET_FRESH=$(bench set)
GET_FRESH=$(bench get)
INCR_FRESH=$(bench incr)
DBSIZE_BEFORE=$($CLI dbsize)

START=$(date +%s%N)
$CLI flushdb >/dev/null
END=$(date +%s%N)
FLUSH_MS=$(( (END - START) / 1000000 ))

SET_REFILL=$(bench set)
GET_REFILL=$(bench get)

printf '%s\n' "keys before flush : $DBSIZE_BEFORE"
printf '%s\n' "flushdb wall time : ${FLUSH_MS} ms"
printf '%s\n' "set   fresh       : $SET_FRESH ops/sec"
printf '%s\n' "get   fresh       : $GET_FRESH ops/sec"
printf '%s\n' "incr  fresh       : $INCR_FRESH ops/sec"
printf '%s\n' "set   post-flush  : $SET_REFILL ops/sec"
printf '%s\n' "get   post-flush  : $GET_REFILL ops/sec"

# machine-readable line for the comparison table
echo "RESULT $LABEL $SET_FRESH $GET_FRESH $INCR_FRESH $SET_REFILL $GET_REFILL $FLUSH_MS"
