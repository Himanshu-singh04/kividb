# Benchmark Results

**Branch:** `master` | **Commit:** `36a8266f` | **Run:** [38135295078](https://github.com/kividbio/kividb/actions/runs/38135295078) | **Generated:** 2026-10-11 11:36 UTC

> Methodology: [memtier_benchmark](https://github.com/RedisLabs/memtier_benchmark) on AWS Graviton3 c7gn.12xlarge (48 vCPU).
> Client on separate c7gn.16xlarge, same AZ. Stores benchmarked sequentially.
> The workflow is `.github/workflows/benchmark.yml`. The "vs" columns are throughput ratios.

## Results

| Test | KiviDB | Dragonfly v1.37 | Redis 8.6 | KiviDB vs Dragonfly | KiviDB vs Redis | KiviDB with all features |
|------|-------|-----------------|----------|---------------------|-----------------|-----------------------|
| Pipelined write (`--ratio 1:0 -c 5 --pipeline=10`) | ~13.0M | ~5.4M | ~732K | 2.41× | 17.69× | ~1.1M |
| Pipelined read (`--ratio 0:1 -c 5 --pipeline=10`) | ~15.6M | ~7.3M | ~942K | 2.14× | 16.60× | ~1.1M |
| Mixed (`--ratio 1:1 -c 5 --pipeline=10`) | ~19.9M | ~7.3M | ~887K | 2.71× | 22.46× | ~1.1M |
