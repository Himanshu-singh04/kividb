#!/usr/bin/env bash
# Inside the container: throughput of builds side by side on several
# threads, where instruction counts say nothing — lock and allocator
# contention only show when threads really run at once.
#   contention.sh <tag>...
# Rounds alternate between the builds so drift in the machine hits both.
# Env: THREADS (8), ROUNDS (3), N (3000000)
set -u
THREADS=${THREADS:-8} ROUNDS=${ROUNDS:-3} N=${N:-3000000} PORT=6400
echo "cpus=$(nproc) server-threads=$THREADS"
bench() { # tag, label, redis-benchmark args...
  local tag=$1 label=$2; shift 2
  "/target/perf-$tag/release/kividb" --port $PORT --bind 127.0.0.1 --threads "$THREADS" --loglevel warning > /tmp/c.log 2>&1 &
  local pid=$!
  for _ in $(seq 100); do redis-cli -p $PORT ping 2>/dev/null | grep -q PONG && break; sleep 0.1; done
  redis-benchmark -p $PORT -q --threads 4 -c 64 -P 16 -r 1000000 -n 1000000 -t set -d "$DSIZE" > /dev/null 2>&1
  local rps
  rps=$(redis-benchmark -p $PORT -q --threads 4 -c 64 -P 16 -r 1000000 -n "$N" "$@" 2>/dev/null | tr '\r' '\n' | grep -a "requests per second" | tail -1 | sed -E 's/.*: ([0-9.]+) requests.*/\1/')
  kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "$label $tag ${rps%.*}"
}
for round in $(seq "$ROUNDS"); do
  for tag in "$@"; do
    DSIZE=1024; bench "$tag" SET-1K  -t set -d 1024
    DSIZE=100;  bench "$tag" SET-100 -t set -d 100
    DSIZE=1024; bench "$tag" GET-1K  -t get -d 1024
    DSIZE=100;  bench "$tag" GET-100 -t get -d 100
  done
done | tee /out/contention.txt
echo "--- median of $ROUNDS"
sort /out/contention.txt | awk '{ k=$1" "$2; n[k]++; v[k,n[k]]=$3 } END { for (k in n) { c=n[k]; for(i=1;i<=c;i++) a[i]=v[k,i]; for(i=1;i<=c;i++) for(j=i+1;j<=c;j++) if (a[j]<a[i]) {t=a[i];a[i]=a[j];a[j]=t}; print k, a[int((c+1)/2)] } }' | sort
