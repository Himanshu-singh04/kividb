// Compare two vitest JSON reports (e.g. KiviDB vs Redis).
//   node vitest_compare.js <kividb.json> <redis.json>
// Prints the tests that fail in the first and pass in the second (the ones to
// look at), the reverse, and those failing in both.
const fs = require('fs');
const load = f => {
  const m = new Map();
  if (!fs.existsSync(f)) return m;
  const r = JSON.parse(fs.readFileSync(f, 'utf8'));
  for (const file of r.testResults || []) {
    const short = file.name.replace(/^.*\/tests\//, 'tests/');
    for (const t of file.assertionResults || []) {
      m.set(`${short} > ${t.fullName}`, { status: t.status, ms: Math.round(t.duration || 0) });
    }
  }
  return m;
};
const a = load(process.argv[2]);
const b = load(process.argv[3]);
const fmt = (k, x, y) => `  ${k}  (${x ? x.status + ' ' + x.ms + 'ms' : 'absent'} / ${y ? y.status + ' ' + y.ms + 'ms' : 'absent'})`;
const groups = { 'fail here, pass in baseline': [], 'pass here, fail in baseline': [], 'fail in both': [] };
for (const [k, x] of a) {
  const y = b.get(k);
  if (x.status === 'failed' && y && y.status === 'passed') groups['fail here, pass in baseline'].push(fmt(k, x, y));
  else if (x.status === 'passed' && y && y.status === 'failed') groups['pass here, fail in baseline'].push(fmt(k, x, y));
  else if (x.status === 'failed' && y && y.status === 'failed') groups['fail in both'].push(fmt(k, x, y));
}
for (const [g, l] of Object.entries(groups)) {
  console.log(`${g}: ${l.length}`);
  for (const s of l) console.log(s);
}
