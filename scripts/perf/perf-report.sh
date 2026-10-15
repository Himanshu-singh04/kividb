#!/usr/bin/env bash
# Inside the server's container: stop the sampling and write where the time
# went to /out/perf-<tag>.txt.
pkill -INT perf
sleep 3
graph="--no-children"
[ -n "${CALLGRAPH:-}" ] && graph="--children"
perf report -i /tmp/perf.data --stdio $graph --sort symbol -g none --percent-limit 0.4 2>/dev/null \
  | grep -v '^$' | grep -v '^#' | cut -c1-200 | head -"${LINES:-120}" > "/out/perf-$TAG.txt"
wc -l "/out/perf-$TAG.txt"
