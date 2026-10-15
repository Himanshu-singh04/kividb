#!/usr/bin/env bash
# BullMQ and Sidekiq against one Redis-compatible server: their own test
# suites, and an end-to-end soak of each.
#
#   scripts/client_compat/run.sh <host> <port> [step...]
#
# Steps (default: all four, in this order):
#   bullmq-suite   BullMQ's vitest suite (taskforcesh/bullmq, tag BULLMQ_TAG)
#   sidekiq-suite  Sidekiq's minitest suite (sidekiq/sidekiq, tag SIDEKIQ_TAG)
#   bullmq-soak    scripts/client_compat/soak/bullmq/soak.mjs
#   sidekiq-soak   scripts/client_compat/soak/sidekiq/soak.rb
#
# The clients run in Docker containers (kcc-node-<label>: node:22-bookworm,
# kcc-ruby-<label>: ruby:3.4-bookworm) joined to NETWORK, so <host> is a name or address as seen
# from that network (a container name on it, or host.docker.internal for a
# server on the Docker host). They are started on first use and reused; the
# checkouts and package caches live on the `kcc-src` volume.
#
# Environment:
#   NETWORK      docker network for the clients (default kcc; created if missing)
#   OUT          results directory (default ./client-compat-out/<label>)
#   LABEL        name for this server in file names (default <host>-<port>)
#   SIDEKIQ_DB   database the Sidekiq suite uses; it FLUSHDBs it (default 1)
#   N            soak size (default 5000 jobs per library)
#   RESTART_CMD  a host shell command that kills and restarts the server. When
#                set, each soak runs a second time and the command is run once
#                the soak is RESTART_AT percent done (default 40). The server
#                should run with `appendonly yes` for that run to mean anything.
#   RESTART_CONTAINER  shorthand for a server running in a container on
#                NETWORK: RESTART_CMD becomes `docker kill` (SIGKILL) + `docker
#                start` of that container, then waiting for PING.
#   KEEP=1       leave the client containers running afterwards
#
# BullMQ's suite assumes localhost:6379 in places; bullmq_suite.sh forwards
# localhost:6379 in the client container to <host>:<port> with socat.
#
# Writes <OUT>/summary.txt; full logs next to it. Exits 0 (it is a measurement).
set -uo pipefail
HOST=${1:?usage: run.sh <host> <port> [step...]}
PORT=${2:?usage: run.sh <host> <port> [step...]}
shift 2
STEPS=${*:-bullmq-suite sidekiq-suite bullmq-soak sidekiq-soak}
HERE=$(cd "$(dirname "$0")" && pwd)
NETWORK=${NETWORK:-kcc}
LABEL=${LABEL:-$HOST-$PORT}
OUT=${OUT:-$PWD/client-compat-out/$LABEL}
SIDEKIQ_DB=${SIDEKIQ_DB:-1}
N=${N:-5000}
RESTART_AT=${RESTART_AT:-40}
if [ -n "${RESTART_CONTAINER:-}" ] && [ -z "${RESTART_CMD:-}" ]; then
  RESTART_CMD="docker kill $RESTART_CONTAINER && docker start $RESTART_CONTAINER"
  # Bounded: a server that does not come back is a failure to report, not a
  # loop to sit in (it once sat in it for seven hours).
  RESTART_CMD+=" && for _ in \$(seq 300); do docker run --rm --network $NETWORK redis:8 redis-cli -h $HOST -p $PORT ping 2>/dev/null | grep -q PONG && exit 0; sleep 0.2; done; echo 'server did not come back'; exit 1"
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

export MSYS_NO_PATHCONV=1
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi; }
H_MOUNT="$(native "$HERE"):/h:ro"
O_MOUNT="$(native "$OUT"):/out"

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
# One pair of client containers per label, so runs against two servers can
# go side by side.
TAG=$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9_.-' '_')
NODE=kcc-node-$TAG
RUBY=kcc-ruby-$TAG
helper() { # name image
  docker rm -f "$1" >/dev/null 2>&1
  docker run -d --name "$1" --network "$NETWORK" -v kcc-src:/src -v "$H_MOUNT" -v "$O_MOUNT" "$2" sleep 86400 >/dev/null
}
helper "$NODE" node:22-bookworm
helper "$RUBY" ruby:3.4-bookworm
docker exec "$NODE" bash /h/fetch_suites.sh < /dev/null

SUMMARY=$OUT/summary.txt
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }
say "server $HOST:$PORT  ($(date -u +%FT%TZ))"

# Blocks until the server answers PING (a restarted server may take a while
# to load its AOF).
wait_ping() {
  local i
  for i in $(seq 1 600); do
    docker run --rm --network "$NETWORK" redis:8 redis-cli -h "$HOST" -p "$PORT" ping 2>/dev/null | grep -q PONG && return 0
    sleep 0.5
  done
  echo "server $HOST:$PORT does not answer PING" >&2
}

# Waits for a soak's progress file to reach RESTART_AT percent, then runs
# RESTART_CMD once. Gives up when <file>.done appears (the soak ended).
chaos() { # progress-file
  local f=$1 done total
  while sleep 0.2; do
    [ -f "$f.done" ] && return
    [ -f "$f" ] || continue
    read -r done total < "$f" 2>/dev/null || continue
    [ -n "${total:-}" ] && [ "$total" -gt 0 ] || continue
    if [ $((done * 100 / total)) -ge "$RESTART_AT" ]; then
      echo "$(date -u +%T) restarting server at $done/$total: $RESTART_CMD" >> "$OUT/restarts.log"
      bash -c "$RESTART_CMD" >> "$OUT/restarts.log" 2>&1 < /dev/null
      echo "$(date -u +%T) server back" >> "$OUT/restarts.log"
      touch "$f.restarted"
      return
    fi
  done
}

soak() { # bullmq|sidekiq  tag  extra-env...
  local lib=$1 tag=$2; shift 2
  local log="$OUT/soak-$lib-$tag.log" pf="/out/progress-$lib-$tag" cpid=
  rm -f "$OUT/progress-$lib-$tag" "$OUT/progress-$lib-$tag.done" "$OUT/progress-$lib-$tag.restarted"
  wait_ping
  if [ -n "${RESTART_WITH:-}" ]; then chaos "$OUT/progress-$lib-$tag" & cpid=$!; fi
  if [ "$lib" = bullmq ]; then
    docker exec -e REDIS_HOST="$HOST" -e REDIS_PORT="$PORT" -e N="$N" -e PROGRESS_FILE="$pf" "$@" \
      "$NODE" bash /h/soak/run_bullmq.sh > "$log" 2>&1 < /dev/null
  else
    docker exec -e REDIS_URL="redis://$HOST:$PORT/0" -e N="$N" -e PROGRESS_FILE="$pf" "$@" \
      "$RUBY" bash /h/soak/run_sidekiq.sh > "$log" 2>&1 < /dev/null
  fi
  local rc=$?
  # Let a restart that has begun finish before anything else talks to the
  # server; a soak that ended before RESTART_AT stops the watcher.
  touch "$OUT/progress-$lib-$tag.done"
  if [ -n "$cpid" ]; then
    wait "$cpid"
    [ -f "$OUT/progress-$lib-$tag.restarted" ] || say "  (soak $lib $tag ended before the restart point)"
  fi
  wait_ping
  say "  soak $lib $tag: $([ $rc = 0 ] && echo PASS || echo FAIL)  $(grep -E '^\{' "$log" | tail -1)"
  grep -E '^(FAIL|note):' "$log" | sed 's/^/      /' | tee -a "$SUMMARY" >/dev/null
}

for step in $STEPS; do
  case $step in
    bullmq-suite)
      docker exec "$NODE" bash /h/bullmq_suite.sh "$HOST" "$PORT" "$LABEL" < /dev/null
      for f in "$OUT/bullmq-$LABEL.json" "$OUT/bullmq-$LABEL-ioredis.json"; do
        [ -f "$f" ] && say "  $(basename "$f" .json): $(docker exec "$NODE" node /h/vitest_summary.js "/out/$(basename "$f")")"
      done
      ;;
    sidekiq-suite)
      docker exec "$RUBY" bash /h/sidekiq_suite.sh "redis://$HOST:$PORT/$SIDEKIQ_DB" "$LABEL" < /dev/null > /dev/null
      say "  sidekiq-$LABEL: $(grep -E '^[0-9]+ runs' "$OUT/sidekiq-$LABEL.log" | tail -1)"
      grep -E '^[^ ].*#test.* = [FE]$' "$OUT/sidekiq-$LABEL.log" | sed 's/^/      /' | tee -a "$SUMMARY" >/dev/null
      ;;
    bullmq-soak | sidekiq-soak)
      lib=${step%-soak}
      RESTART_WITH= soak "$lib" steady
      if [ -n "${RESTART_CMD:-}" ]; then
        RESTART_WITH=1 soak "$lib" restart -e ALLOW_REEXEC=1 -e TIMEOUT_MS=600000 -e TIMEOUT_S=600
      fi
      ;;
    *) echo "unknown step: $step" >&2 ;;
  esac
done

if [ "${KEEP:-0}" != 1 ]; then docker rm -f "$NODE" "$RUBY" >/dev/null 2>&1; fi
echo "results in $OUT"
