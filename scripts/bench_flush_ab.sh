#!/usr/bin/env bash
# Interleaved A/B benchmark so machine drift hits both builds equally.
# Reports the median of N rounds per metric.
#
# Usage: bench_flush_ab.sh [rounds]
set -uo pipefail

ROUNDS=${1:-5}
BASE=$HOME/kividb-baseline/target/release/kividb
PATCHED=$HOME/kividb-repro/target/release/kividb
SCRIPT=$(dirname "$0")/bench_flush_regression.sh
OUT=$(mktemp)

for round in $(seq 1 "$ROUNDS"); do
  for build in baseline patched; do
    case $build in
      baseline) BIN=$BASE;    PORT=$((6500 + round * 2)) ;;
      patched)  BIN=$PATCHED; PORT=$((6501 + round * 2)) ;;
    esac
    bash "$SCRIPT" "$build" "$BIN" "$PORT" 2>/dev/null | grep '^RESULT' >> "$OUT"
    echo "round $round $build done" >&2
  done
done

echo
echo "raw results:"
cat "$OUT"

echo
python3 - "$OUT" <<'PY'
import statistics, sys
from collections import defaultdict

COLS = ["set_fresh", "get_fresh", "incr_fresh", "set_post_flush", "get_post_flush", "flushdb_ms"]
data = defaultdict(lambda: defaultdict(list))
for line in open(sys.argv[1]):
    f = line.split()
    if len(f) != 8:
        continue
    for col, v in zip(COLS, f[2:]):
        data[col][f[1]].append(float(v))

print(f"{'metric':<18}{'baseline':>14}{'patched':>14}{'delta':>10}")
print("-" * 56)
for col in COLS:
    b = statistics.median(data[col]["baseline"])
    p = statistics.median(data[col]["patched"])
    d = (p - b) / b * 100 if b else 0.0
    print(f"{col:<18}{b:>14,.0f}{p:>14,.0f}{d:>9.1f}%")

print()
print("per-round spread (max-min as % of median), baseline only —")
print("anything smaller than this in the delta column is noise:")
for col in COLS:
    v = data[col]["baseline"]
    med = statistics.median(v)
    if med and len(v) > 1:
        print(f"  {col:<18}{(max(v) - min(v)) / med * 100:>6.1f}%")
PY
rm -f "$OUT"
