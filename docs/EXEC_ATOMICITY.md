# `MULTI`/`EXEC` and scripts run alone

A transaction's commands, and a script, run as one step: no other client's
command that could see their keys starts between two of them, reads
included. This page says how that is provided, and how the defect it
replaced was found.

## How it is provided

Every command enters a gate (`src/command_gate.rs`) for as long as it runs:
shared, so commands run side by side. `EXEC`, functions (`FCALL`,
`FCALL_RO`) and scripts that may touch any key enter it *alone*: they wait
for the commands in flight to finish, and hold new ones back until they are
done. That is the guarantee Redis gives by having one thread.

With `lua-parallel-scripts yes` (the default), a script whose `KEYS` all
carry one hash tag, once the server has seen it to be quick, takes the gate
shared plus a lock for its tag instead. It is held to keys of that tag, and
commands on that tag wait for it, so to every other client it is still one
step. Scripts with no keys, untagged keys or keys of two tags, and a
script's first run, go alone as above. [SCRIPTS.md](SCRIPTS.md) has the
details.

What it means for clients:

* Another client never sees a transaction half applied: an auditor reading
  two balances during a transfer reads them either before it or after it.
* A write from outside a transaction cannot land between `EXEC`'s check of
  its watched keys and its first command: the check is made inside the gate.
* While a script runs, other clients' commands that it holds back wait for
  it. They are told `BUSY` only once it has run longer than
  `lua-time-limit` (default 5 s), and then `SCRIPT KILL`, `FUNCTION KILL`
  and `SHUTDOWN` still get through.
* A slow transaction or script is paid for by every client it holds back,
  as in Redis. A command that blocks (`BLPOP` and the like) does not hold
  the gate while it waits, and inside a transaction or a script does not
  wait at all.

Tests: `tests/transaction.rs` (a reader never sees a transfer half done; a
write from outside cannot slip past `WATCH`), and in the e2e suite
`test_acid.py::TestFullACIDScenario::test_balance_transfer_acid` and
`TestAtomicity::test_multi_key_transfer_is_atomic`.

## What `WATCH` guarantees

`WATCH` / `MULTI` / `EXEC` used as optimistic locking is safe **between
transactions**: an `EXEC` whose transaction watches keys holds a lock from
before it checks whether a watched key was modified until its last queued
command has run, so of two transactions racing on the same watched key the
second always sees the first one's write and returns nil.

## The defect this replaced

Before 1.0.5, a transaction's commands could interleave with other clients'
commands. `test_acid.py::TestFullACIDScenario::test_balance_transfer_acid`
transfers 1000 from `bal:alice` to `bal:bob` in ten
`MULTI`/`DECRBY`/`INCRBY`/`EXEC` blocks while an auditor connection polls
`MGET bal:alice bal:bob`. Under RESP3 it failed every time:

```
AssertionError: Balance inconsistency observed during transfer: [(0, 900)]
```

The auditor saw money that had left one account and not yet arrived at the
other. `EXEC` had a lock-held fast path (`exec_fast_apply_sets`) that held
the shard locks across the whole block, but only for transactions made up
entirely of unconditional `SET key value`. Anything else was dispatched one
command at a time, each taking and releasing its own locks, and a concurrent
`MGET` could land in between. RESP2 usually passed, by timing rather than
protocol.

`WATCH` had the same gap: two transactions could both pass the check and
then both write. `test_order_processing_no_oversell` (ten buyers, a stock of
five) sold a sixth about once in twelve runs.

Holding the locks of every key a transaction touches would have needed a
consistent lock order across shards, and would not have covered scripts,
whose keys are not known in advance. The gate needs no knowledge of which
keys are touched, so it covers transactions, scripts and commands with no
keys alike.

To reproduce against a build:

```bash
cargo build --release --bin kividb
./target/release/kividb --port 6501 --io-model tokio &
cd tests/e2e && KIVI_EXTERNAL=1 KIVI_PORT=6501 KIVI_RESP=3 \
  pytest modules/test_acid.py::TestFullACIDScenario::test_balance_transfer_acid
```
