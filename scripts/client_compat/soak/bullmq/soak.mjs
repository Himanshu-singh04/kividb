// End-to-end soak for BullMQ against a Redis-compatible server.
//
//   REDIS_HOST=... REDIS_PORT=... N=5000 node soak.mjs
//
// One process runs the producers and a worker. The workload:
//   - N plain jobs, of which ~15% are delayed (0-3 s) and ~15% fail their
//     first one or two attempts and are retried with exponential backoff;
//   - FLOWS parent/child flows (3 children each; the parent checks it sees
//     all three children's return values);
//   - one job scheduler (repeatable job) firing every 250 ms, limited to
//     TICKS iterations.
//
// Checks, at the end:
//   - every job's handler *succeeded* exactly once (a success counted twice
//     means a job was completed twice; a missing one means a job was lost);
//   - no job ended up failed;
//   - the scheduler fired exactly TICKS times;
//   - the queue's keys are empty: no waiting/active/delayed/completed/...
//     entries and no job hashes left (jobs are removed on completion).
//
// Progress (successes so far / expected) is written to PROGRESS_FILE, if set,
// so an outside script can restart the server mid-run (run.sh does).
// Executions beyond the first success are reported separately as
// "re-executions": after a server crash BullMQ is at-least-once, so a re-run
// of a job whose completion was lost is allowed only when ALLOW_REEXEC=1.
//
// Exit status 0 = all checks passed.
import { Queue, Worker, FlowProducer } from 'bullmq';
import IORedis from 'ioredis';
import { writeFileSync } from 'node:fs';

const host = process.env.REDIS_HOST || '127.0.0.1';
const port = Number(process.env.REDIS_PORT || 6379);
const N = Number(process.env.N || 5000);
const FLOWS = Number(process.env.FLOWS || 100);
const TICKS = Number(process.env.TICKS || 10);
const CONCURRENCY = Number(process.env.CONCURRENCY || 50);
const TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 300000);
const ALLOW_REEXEC = process.env.ALLOW_REEXEC === '1';
const PROGRESS_FILE = process.env.PROGRESS_FILE;
const qname = process.env.QUEUE || `soak-${Date.now()}`;
const prefix = 'bull';

const conn = () => new IORedis({ host, port, maxRetriesPerRequest: null, enableOfflineQueue: true });
const connection = conn();
const queue = new Queue(qname, { connection, prefix });
const flow = new FlowProducer({ connection: conn(), prefix });

const successes = new Map(); // key -> count of successful handler runs
const executions = new Map(); // key -> count of handler starts
let ticks = 0;
const failedEvents = [];
const bump = (m, k) => m.set(k, (m.get(k) || 0) + 1);

const expectedKeys = [];
for (let i = 0; i < N; i++) expectedKeys.push(`job:${i}`);
for (let f = 0; f < FLOWS; f++) {
  expectedKeys.push(`parent:${f}`);
  for (let c = 0; c < 3; c++) expectedKeys.push(`child:${f}:${c}`);
}
const expectedTotal = expectedKeys.length + TICKS;

const worker = new Worker(
  qname,
  async job => {
    const d = job.data;
    if (d.kind === 'tick') {
      ticks++;
      return 'tick';
    }
    bump(executions, d.key);
    if (d.failTimes && job.attemptsMade < d.failTimes) {
      throw new Error(`planned failure ${job.attemptsMade + 1}/${d.failTimes}`);
    }
    if (d.kind === 'parent') {
      const vals = Object.values(await job.getChildrenValues());
      if (vals.length !== 3 || !vals.every(v => v && v.startsWith(`child:${d.f}:`))) {
        throw new Error(`parent ${d.f} saw children ${JSON.stringify(vals)}`);
      }
    }
    bump(successes, d.key);
    return d.key;
  },
  { connection: conn(), prefix, concurrency: CONCURRENCY, stalledInterval: 5000, maxStalledCount: 5 },
);
worker.on('failed', (job, err) => {
  if (job && job.attemptsMade >= (job.opts.attempts || 1)) failedEvents.push(`${job.data.key}: ${err.message}`);
});
worker.on('error', err => console.error('worker error:', err.message));

const done = () => {
  let ok = 0;
  for (const k of expectedKeys) if (successes.get(k)) ok++;
  return ok + Math.min(ticks, TICKS);
};
// Progress is reported from the start: the worker runs while the producer is
// still adding jobs.
let lastProgress = -1;
const progressTimer = setInterval(() => {
  const d = done();
  if (PROGRESS_FILE && d !== lastProgress) {
    try { writeFileSync(PROGRESS_FILE, `${d} ${expectedTotal}\n`); } catch {}
    lastProgress = d;
  }
}, 100);

// ioredis aborts a pipeline that is in flight when the connection drops
// ("Command aborted due to connection close") instead of resending it, so a
// producer call that meets a server restart is retried here. Every job has a
// fixed jobId, so adding it again is a no-op if the first attempt got through.
const retry = async (what, fn) => {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt >= 30) throw err;
      console.log(`retrying ${what} after: ${err.message}`);
      await new Promise(r => setTimeout(r, 500));
    }
  }
};

const t0 = Date.now();
const opts = { removeOnComplete: true, removeOnFail: false };

// Producer: plain, delayed and retried jobs, in bulk batches of 500.
let rnd = 12345;
const rand = () => ((rnd = (rnd * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
for (let i = 0; i < N; i += 500) {
  const batch = [];
  for (let j = i; j < Math.min(N, i + 500); j++) {
    const r = rand();
    const data = { key: `job:${j}` };
    const o = { ...opts, jobId: `job-${j}` };
    if (r < 0.15) o.delay = Math.floor(rand() * 3000);
    else if (r < 0.3) {
      data.failTimes = 1 + (j % 2);
      o.attempts = 3;
      o.backoff = { type: 'exponential', delay: 100 };
    }
    batch.push({ name: 'work', data, opts: o });
  }
  await retry(`addBulk ${i}`, () => queue.addBulk(batch));
}
for (let f = 0; f < FLOWS; f++) {
  await retry(`flow ${f}`, () => flow.add({
    name: 'parent',
    queueName: qname,
    data: { key: `parent:${f}`, kind: 'parent', f },
    opts: { ...opts, jobId: `parent-${f}` },
    children: [0, 1, 2].map(c => ({
      name: 'child',
      queueName: qname,
      data: { key: `child:${f}:${c}` },
      opts: { ...opts, jobId: `child-${f}-${c}`, ...(c === 0 ? { delay: 200 } : {}) },
    })),
  }));
}
await retry('upsertJobScheduler', () =>
  queue.upsertJobScheduler('ticker', { every: 250, limit: TICKS }, { name: 'tick', data: { kind: 'tick' }, opts }),
);
console.log(`queued ${expectedKeys.length} jobs + ${TICKS} ticks in ${Date.now() - t0} ms`);

while (Date.now() - t0 < TIMEOUT_MS && done() < expectedTotal) {
  await new Promise(r => setTimeout(r, 200));
}
clearInterval(progressTimer);
const elapsed = Date.now() - t0;
// Give stray duplicates or extra ticks a chance to show up.
await new Promise(r => setTimeout(r, 3000));
await worker.close();

const problems = [];
const missing = expectedKeys.filter(k => !successes.get(k));
const dup = expectedKeys.filter(k => (successes.get(k) || 0) > 1);
let reexec = 0;
if (missing.length) problems.push(`${missing.length} jobs never succeeded, e.g. ${missing.slice(0, 5).join(', ')}`);
if (dup.length) {
  reexec = dup.reduce((a, k) => a + successes.get(k) - 1, 0);
  const msg = `${dup.length} jobs succeeded more than once (${reexec} extra), e.g. ${dup.slice(0, 5).join(', ')}`;
  if (ALLOW_REEXEC) console.log(`note: ${msg} (allowed: at-least-once after a crash)`);
  else problems.push(msg);
}
if (failedEvents.length) problems.push(`${failedEvents.length} jobs failed for good, e.g. ${failedEvents.slice(0, 3).join(' | ')}`);
if (ticks !== TICKS) problems.push(`scheduler fired ${ticks} times, expected ${TICKS}`);

await queue.removeJobScheduler('ticker');
const counts = await queue.getJobCounts();
const nonzero = Object.entries(counts).filter(([, v]) => v > 0);
if (nonzero.length) problems.push(`job counts not empty: ${JSON.stringify(Object.fromEntries(nonzero))}`);

// Every key of the queue: only bookkeeping keys may remain.
const raw = conn();
const keys = [];
let cursor = '0';
do {
  const [c, batch] = await raw.scan(cursor, 'MATCH', `${prefix}:${qname}:*`, 'COUNT', 1000);
  cursor = c;
  keys.push(...batch);
} while (cursor !== '0');
const allowed = new Set(['meta', 'id', 'events', 'stalled-check', 'marker', 'repeat', 'metrics:completed', 'metrics:failed']);
const leftover = keys.filter(k => !allowed.has(k.slice(`${prefix}:${qname}:`.length)));
if (leftover.length) {
  const detail = [];
  for (const k of leftover.slice(0, 8)) detail.push(`${k}(${await raw.type(k)})`);
  problems.push(`${leftover.length} queue keys left: ${detail.join(', ')}`);
}

const summary = {
  queue: qname,
  jobs: expectedKeys.length,
  ticks,
  elapsed_ms: elapsed,
  succeeded_once: expectedKeys.length - missing.length - dup.length,
  missing: missing.length,
  duplicated: dup.length,
  failed: failedEvents.length,
  leftover_keys: leftover.length,
  ok: problems.length === 0,
};
console.log(JSON.stringify(summary));
for (const p of problems) console.log(`FAIL: ${p}`);
if (process.env.CLEANUP !== '0') await queue.obliterate({ force: true }).catch(() => {});
await Promise.allSettled([queue.close(), flow.close()]);
raw.disconnect();
connection.disconnect();
process.exit(problems.length ? 1 : 0);
