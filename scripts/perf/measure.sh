#!/usr/bin/env bash
# Inside the container: instructions per command, whole server, pipelined.
#   measure.sh <tag>...
# For each tag and workload: start the server under callgrind with
# instrumentation off, warm up and load, switch instrumentation on for N
# pipelined commands, switch it off. Ir / N is the server's whole cost per
# command: read, parse, execute, reply, write.
# Env: N (100000), P (16), MODEL (tokio), PROFILE=<tag> prints that tag's
# hottest functions for each workload into /out/profile-<workload>.txt
set -u
N=${N:-100000} P=${P:-16} MODEL=${MODEL:-tokio} PORT=6400
mkdir -p /out

one() { # tag, label, redis-benchmark args...
  local tag=$1 label=$2; shift 2
  rm -rf /tmp/hp && mkdir -p /tmp/hp && cd /tmp/hp
  valgrind --tool=callgrind --instr-atstart=no --callgrind-out-file=/tmp/hp/out \
    "/target/perf-$tag/release/kividb" --port $PORT --bind 127.0.0.1 --io-model "$MODEL" \
    --threads 1 --loglevel warning > /tmp/hp/log 2>&1 &
  local vg=$!
  for _ in $(seq 240); do redis-cli -p $PORT ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done
  if ! redis-cli -p $PORT ping 2>/dev/null | grep -q PONG; then
    echo "$label $tag FAILED-TO-START"; tail -3 /tmp/hp/log; kill -9 $vg 2>/dev/null; return
  fi
  # Load and warm up: every key the measured run will touch exists.
  redis-benchmark -p $PORT -q -c 1 -P $P -r 10000 -n 20000 -d "$DSIZE" -t set > /dev/null 2>&1
  redis-benchmark -p $PORT -q -c 1 -P $P -r 10000 -n 2000 "$@" > /dev/null 2>&1
  callgrind_control -i on > /dev/null 2>&1
  redis-benchmark -p $PORT -q -c 1 -P $P -r 10000 -n "$N" "$@" > /dev/null 2>&1
  callgrind_control -i off > /dev/null 2>&1
  callgrind_control -d > /dev/null 2>&1
  redis-cli -p $PORT shutdown nosave > /dev/null 2>&1
  sleep 1; kill -TERM $vg 2>/dev/null; wait $vg 2>/dev/null
  local f total
  f=$(ls -S /tmp/hp/out* 2>/dev/null | head -1)
  total=$(callgrind_annotate "$f" 2>/dev/null | grep -m1 "PROGRAM TOTALS" | tr -d "," | awk '{print $1}')
  echo "$label $tag $(( ${total:-0} / N ))"
  if [ "${PROFILE:-}" = "$tag" ]; then
    callgrind_annotate --inclusive=no "$f" 2>/dev/null | sed -n '1,70p' | cut -c1-200 > "/out/profile-$label.txt"
  fi
}

for tag in "$@"; do
  DSIZE=100;  one "$tag" GET-100  -d 100  -t get
  DSIZE=100;  one "$tag" SET-100  -d 100  -t set
  DSIZE=1024; one "$tag" GET-1K   -d 1024 -t get
  DSIZE=1024; one "$tag" SET-1K   -d 1024 -t set
  DSIZE=100;  one "$tag" MIX-100  -d 100  -t set,get
done | tee /out/raw.txt
echo done
