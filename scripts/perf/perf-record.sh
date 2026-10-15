#!/usr/bin/env bash
# Inside the server's container: sample the running server until told to stop.
graph=""
[ -n "${CALLGRAPH:-}" ] && graph="--call-graph dwarf,16384"
exec perf record -F 1999 -e cpu-clock $graph -o /tmp/perf.data -p "$(pidof kividb)" > /tmp/perf.log 2>&1
