#!/usr/bin/env bash
# Redis's own test suite, run against a KiviDB binary — one unit at a time.
#
#   scripts/redis_compat.sh <kividb-binary> <redis-checkout> [<output-dir>]
#
# Each unit of the suite gets a server of its own, started empty. The suite
# gives up on its whole run the moment one test stalls, and a unit that
# leaves the server in an odd state (a memory limit set and not reset, a
# client left blocked) takes the units after it down with it: run together,
# one bad test hid most of the suite — eleven units of ninety ran, and the
# number reported was whatever those eleven came to. Run apart, a unit that
# hangs or dies costs itself, and what is reported is the suite.
#
# Prints a line per unit and a total; writes the same as a table to
# <output-dir>/summary.md (and to $GITHUB_STEP_SUMMARY, under Actions), and
# each unit's full log to <output-dir>/<unit>.log.
#
# Environment:
#   UNITS         the units to run (default: unit/*.tcl and unit/type/*.tcl)
#   PORT          the port to run the server on (default 6399)
#   TEST_TIMEOUT  seconds without a test finishing before a unit is given up
#                 on (default 300)
#   UNIT_TIMEOUT  seconds a unit may take in all (default 900)
#   SERVER_ARGS   more arguments for the server
#
# Exits 0 whatever the tests did: it is a measurement. (1 if the port is
# already in use.)

set -u

BIN=$(readlink -f "${1:?usage: redis_compat.sh <kividb-binary> <redis-checkout> [<output-dir>]}")
SUITE=$(readlink -f "${2:?usage: redis_compat.sh <kividb-binary> <redis-checkout> [<output-dir>]}")
OUT=${3:-/tmp/redis-compat}
PORT=${PORT:-6399}
TEST_TIMEOUT=${TEST_TIMEOUT:-300}
UNIT_TIMEOUT=${UNIT_TIMEOUT:-900}

mkdir -p "$OUT"
OUT=$(readlink -f "$OUT")

# Tests that need what a server reached from outside cannot give them: a
# server the suite started itself (`external:skip`), Redis's DEBUG command,
# a replica, an RDB file on disk, a cluster. Everything else is run.
TAGS=(
  --tags -external:skip
  --tags -needs:debug
  --tags -needs:repl
  --tags -needs:save
  --tags -needs:pfdebug
  --tags -large-memory
  --tags -cluster:skip
  --tags -keysizes
)

cd "$SUITE" || exit 0
if [ -z "${UNITS:-}" ]; then
  UNITS=$(cd tests && ls unit/*.tcl unit/type/*.tcl | sed 's/\.tcl$//')
fi

listening() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

# The server shares its port with any other process that asks for it
# (SO_REUSEPORT): one left over from another run would take some of the
# suite's connections, and the results would mean nothing.
if listening; then
  echo "something is already listening on port $PORT; stop it, or set PORT" >&2
  exit 1
fi

server_pid=
start_server() {
  local dir
  dir=$(mktemp -d)
  (cd "$dir" && exec "$BIN" --port "$PORT" --loglevel error ${SERVER_ARGS:-}) > "$OUT/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 100); do
    listening && return 0
    sleep 0.1
  done
  return 1
}
stop_server() {
  [ -n "$server_pid" ] && kill -9 "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
  server_pid=
}
trap stop_server EXIT

count() { grep -ac "$1" "$2" 2>/dev/null || true; }

{
  echo "| unit | passed | failed | aborted | seconds |"
  echo "|---|---:|---:|---:|---:|"
} > "$OUT/summary.md"

total_ok=0 total_err=0 total_aborted=0
for unit in $UNITS; do
  log="$OUT/$(echo "$unit" | tr '/' '_').log"
  if ! start_server; then
    echo "$unit: the server did not start" | tee "$log"
    stop_server
    continue
  fi
  started=$(date +%s)
  timeout "$UNIT_TIMEOUT" ./runtest \
    --host 127.0.0.1 --port "$PORT" --singledb --ignore-encoding \
    --timeout "$TEST_TIMEOUT" --single "$unit" "${TAGS[@]}" > "$log" 2>&1
  seconds=$(( $(date +%s) - started ))

  ok=$(count '^\[ok\]' "$log")
  err=$(count '^\[err\]' "$log")
  # A unit that ends early — on an exception in the test code, or a test
  # that never finished — has tests after that point that were not run.
  aborted=$(( $(count '^\[exception\]' "$log") + $(count '^\[TIMEOUT\]' "$log") ))
  kill -0 "$server_pid" 2>/dev/null || { aborted=$((aborted + 1)); echo "[server died]" >> "$log"; }
  stop_server

  total_ok=$((total_ok + ok))
  total_err=$((total_err + err))
  total_aborted=$((total_aborted + aborted))
  printf '%-34s passed=%-4s failed=%-3s aborted=%-2s %ss\n' "$unit" "$ok" "$err" "$aborted" "$seconds"
  # Units with nothing in them for an external server are left out of the
  # table: most of the suite's ninety files are replication and cluster.
  if [ $((ok + err + aborted)) -gt 0 ]; then
    echo "| $unit | $ok | $err | $aborted | $seconds |" >> "$OUT/summary.md"
  fi
done

total="Redis test suite: $total_ok passed, $total_err failed, $total_aborted units ended early"
echo
echo "$total"
{
  echo "| **total** | **$total_ok** | **$total_err** | **$total_aborted** | |"
  echo
  echo "$total."
  if [ "$total_err" -gt 0 ]; then
    echo
    echo "<details><summary>Failed tests</summary>"
    echo
    echo '```'
    grep -ah '^\[err\]' "$OUT"/*.log | cut -c1-200
    echo '```'
    echo "</details>"
  fi
} >> "$OUT/summary.md"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "## Redis compatibility"; echo; cat "$OUT/summary.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
