"""
Compares a real vector-db-benchmark (redis/vector-db-benchmark, Rust tool) run of kividb
AND Redis, on the same host/instance, against
benchmarks/vector-baseline.json. Fails (non-zero exit) if either:

  (a) kividb's own numbers regressed vs. its historical baseline
      ("kividb_absolute" gate -- generous tolerance, since absolute
      numbers vary across CI instance types over time), or
  (b) kividb's competitive ratio against Redis (computed
      fresh from this run, same instance, same moment -- much less noisy
      than (a)) dropped below the floor in "kividb_vs_redis_ratio".

Reads the tool's own two native output files per engine (found in its
--host-relative `results/` directory, one directory per engine to avoid
filename collisions when both experiments share a dataset name):

  - `<experiment>-<dataset>-upload-*.json` (most recent by mtime): ingestion.
  - `<experiment>-<dataset>-summary.json`: search, from the flat
    `search_results` array, grouped by the `ef` runtime value (a
    config-fixed knob). The tool's own `--repetitions` (default 3) already
    reports only the best-RPS run per search config, so no extra best-of-N
    reduction is needed here beyond collapsing parallel=1/parallel=100
    entries at the same `ef` down to the higher-RPS one (parallel=100, by
    construction of this workflow's engines-files).

Usage:
    python compare_vector_baseline.py \
        --kividb-experiment kividb-glove25 --kividb-results-dir PATH \
        --redis-experiment redis-glove25 --redis-results-dir PATH \
        --dataset glove-25-angular [--baseline PATH] [--summary-out PATH]

Exit code 0 = no regression. Exit code 1 = at least one gate failed.
Exit code 2 = usage/file error.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys


def _latest(paths: list[pathlib.Path]) -> pathlib.Path | None:
    return max(paths, key=lambda p: p.stat().st_mtime) if paths else None


def load_tool_results(results_dir: pathlib.Path, experiment: str, dataset: str) -> dict:
    """Returns {"ingest": {...}, "search_by_ef": {ef: {...}}}."""
    upload_path = _latest(list(results_dir.glob(f"{experiment}-{dataset}-upload-*.json")))
    if upload_path is None:
        raise FileNotFoundError(
            f"no {experiment}-{dataset}-upload-*.json in {results_dir} "
            "(did the run include the upload/configure stage?)"
        )
    upload_data = json.loads(upload_path.read_text())
    ingest = {
        "upload_time_s": upload_data["results"]["upload_time"],
        "total_time_s": upload_data["results"]["total_time"],
    }

    summary_path = results_dir / f"{experiment}-{dataset}-summary.json"
    if not summary_path.exists():
        raise FileNotFoundError(f"missing {summary_path}")
    summary = json.loads(summary_path.read_text())

    search_by_ef: dict[int, dict] = {}
    for run in summary.get("search_results", []):
        ef = run.get("ef")
        if ef is None:
            continue
        candidate = {
            "rps": run["rps"],
            "p50_ms": run["p50_time"] * 1000,
            "p95_ms": run["p95_time"] * 1000,
            "precision": run["mean_precisions"],
        }
        if ef not in search_by_ef or candidate["rps"] > search_by_ef[ef]["rps"]:
            search_by_ef[ef] = candidate

    if not search_by_ef:
        raise ValueError(f"no search results with an `ef` param found in {summary_path}")

    return {"ingest": ingest, "search_by_ef": search_by_ef}


def _get(d: dict, dotted_key: str):
    """search_by_ef is keyed by int; dotted_key parts are always strings."""
    cur = d
    for part in dotted_key.split("."):
        if not isinstance(cur, dict):
            return None
        if part in cur:
            cur = cur[part]
        elif part.isdigit() and int(part) in cur:
            cur = cur[int(part)]
        else:
            return None
    return cur


def compare_absolute(gates: dict, kividb_results: dict) -> list[dict]:
    rows = []
    for metric_key, spec in gates.items():
        if metric_key.startswith("_"):
            continue
        base_val = spec["baseline"]
        tolerance_pct = spec["tolerance_pct"]
        direction = spec["regression_if"]

        actual = _get(kividb_results, metric_key)
        if actual is None:
            rows.append({"check": f"kividb.{metric_key}", "baseline": base_val, "actual": None,
                         "delta_pct": None, "status": "MISSING"})
            continue

        delta_pct = (actual - base_val) / base_val * 100 if base_val else 0.0
        if direction == "below":
            regressed = actual < base_val * (1 - tolerance_pct / 100)
        elif direction == "above":
            regressed = actual > base_val * (1 + tolerance_pct / 100)
        else:
            raise ValueError(f"{metric_key}: unknown regression_if {direction!r}")

        rows.append({
            "check": f"kividb.{metric_key}", "baseline": base_val, "actual": actual,
            "delta_pct": delta_pct, "status": "REGRESSED" if regressed else "ok",
        })
    return rows


def compare_ratio(gates: dict, kividb_results: dict, redis_results: dict) -> list[dict]:
    rows = []
    for metric_key, spec in gates.items():
        if metric_key.startswith("_"):
            continue
        kividb_val = _get(kividb_results, metric_key)
        redis_val = _get(redis_results, metric_key)
        min_ratio = spec["min_ratio"]
        kind = spec["kind"]

        if kividb_val is None or redis_val is None:
            rows.append({"check": f"ratio.{metric_key}", "min_ratio": min_ratio, "actual": None,
                         "status": "MISSING"})
            continue

        if kind == "kividb_over_redis":
            ratio = kividb_val / redis_val if redis_val else float("inf")
        elif kind == "redis_over_kividb":
            ratio = redis_val / kividb_val if kividb_val else float("inf")
        else:
            raise ValueError(f"{metric_key}: unknown kind {kind!r}")

        regressed = ratio < min_ratio
        rows.append({
            "check": f"ratio.{metric_key}", "min_ratio": min_ratio, "actual": round(ratio, 3),
            "kividb": kividb_val, "redis": redis_val,
            "status": "REGRESSED" if regressed else "ok",
        })
    return rows


def render_markdown(abs_rows: list[dict], ratio_rows: list[dict]) -> str:
    lines = ["### kividb vs its own baseline", "",
             "| Check | Baseline | Actual | Delta | Status |", "|---|---:|---:|---:|---|"]
    for r in abs_rows:
        if r["actual"] is None:
            lines.append(f"| `{r['check']}` | {r['baseline']} | -- | -- | MISSING |")
            continue
        sign = "+" if r["delta_pct"] >= 0 else ""
        lines.append(f"| `{r['check']}` | {r['baseline']} | {round(r['actual'], 4)} | "
                     f"{sign}{r['delta_pct']:.1f}% | {r['status']} |")

    lines += ["", "### kividb vs Redis (this run, same instance)", "",
              "| Check | kividb | redis | Ratio | Floor | Status |",
              "|---|---:|---:|---:|---:|---|"]
    for r in ratio_rows:
        if r["actual"] is None:
            lines.append(f"| `{r['check']}` | -- | -- | -- | {r['min_ratio']} | MISSING |")
            continue
        lines.append(f"| `{r['check']}` | {round(r['kividb'], 3)} | {round(r['redis'], 3)} | "
                     f"{r['actual']} | {r['min_ratio']} | {r['status']} |")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kividb-experiment", required=True)
    ap.add_argument("--kividb-results-dir", type=pathlib.Path, required=True)
    ap.add_argument("--redis-experiment", required=True)
    ap.add_argument("--redis-results-dir", type=pathlib.Path, required=True)
    ap.add_argument("--dataset", required=True, help="e.g. glove-25-angular")
    ap.add_argument("--baseline", type=pathlib.Path,
                     default=pathlib.Path(__file__).parents[3] / "benchmarks" / "vector-baseline.json")
    ap.add_argument("--summary-out", type=pathlib.Path, default=None)
    ap.add_argument("--dump-results-json", type=pathlib.Path, default=None,
                     help="Write {kividb: {...}, redis: {...}} here (used by update-baseline)")
    args = ap.parse_args()

    if not args.baseline.exists():
        print(f"::error::baseline file not found: {args.baseline}", file=sys.stderr)
        return 2

    try:
        kividb_results = load_tool_results(args.kividb_results_dir, args.kividb_experiment, args.dataset)
        redis_results = load_tool_results(args.redis_results_dir, args.redis_experiment, args.dataset)
    except (FileNotFoundError, ValueError, KeyError) as e:
        print(f"::error::failed to load benchmark results: {e}", file=sys.stderr)
        return 2

    if args.dump_results_json:
        def dumpable(r):
            return {"ingest": r["ingest"], "search_by_ef": {str(k): v for k, v in r["search_by_ef"].items()}}
        args.dump_results_json.write_text(json.dumps(
            {"kividb": dumpable(kividb_results), "redis": dumpable(redis_results)}, indent=2))

    baseline = json.loads(args.baseline.read_text())
    abs_gates = {**baseline["gates"]["kividb_absolute"]}
    for k in list(abs_gates.keys()):
        if k.startswith("_"):
            continue
        abs_gates[k] = {**abs_gates[k], "baseline": _get(baseline["kividb"], k)}
    ratio_gates = baseline["gates"]["kividb_vs_redis_ratio"]

    abs_rows = compare_absolute(abs_gates, kividb_results)
    ratio_rows = compare_ratio(ratio_gates, kividb_results, redis_results)
    any_regression = any(r["status"] == "REGRESSED" for r in abs_rows + ratio_rows)

    table = render_markdown(abs_rows, ratio_rows)
    print("\nVector benchmark vs. baseline:\n")
    print(table)
    print()

    if args.summary_out:
        header = "## Vector benchmark results\n\n"
        if any_regression:
            header += "**Regression detected** — see REGRESSED rows below.\n\n"
        with open(args.summary_out, "a", encoding="utf-8") as f:
            f.write(header + table + "\n")

    if any_regression:
        print("RESULT: regression detected against benchmarks/vector-baseline.json", file=sys.stderr)
        return 1

    print("RESULT: no regression")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
