# Benchmark Results

**Branch:** `master` | **Commit:** `a0a5b149` | **Run:** [38881487579](https://github.com/kividbio/kividb/actions/runs/38881487579) | **Generated:** 2026-10-16 09:55 UTC

> Methodology: [memtier_benchmark](https://github.com/RedisLabs/memtier_benchmark) on an Azure Standard_D32ps_v5 (32 vCPU, arm64).
> Client on a separate Standard_D32ps_v5 in the same proximity placement group. Stores benchmarked sequentially,
> each using every core; memtier runs one thread per client core, 5 connections each.
> "KiviDB over TLS" is the `lua,tls` build measured over TLS.
> Full runbook: [kivi-benchmark](https://github.com/kividbio/kivi-benchmark)

## Results

| Test | KiviDB | Dragonfly v2.0.2 | Redis 8.10.2 | KiviDB vs Dragonfly | KiviDB vs Redis | KiviDB over TLS |
|------|-------|-----------------|----------|---------------------|-----------------|-----------------------|
| Pipelined write (`--ratio 1:0 -c 5 --pipeline=10`) | ~6.1M | ~2.4M | ~489K | 2.50x | 12.42x | ~311K |
| Pipelined read (`--ratio 0:1 -c 5 --pipeline=10`) | ~7.1M | ~4.5M | ~678K | 1.57x | 10.50x | ~650K |
| Mixed (`--ratio 1:1 -c 5 --pipeline=10`) | ~6.8M | ~4.3M | ~600K | 1.58x | 11.35x | ~375K |
