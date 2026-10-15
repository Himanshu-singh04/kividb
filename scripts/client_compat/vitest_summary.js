// Summarise a vitest JSON report: counts, then one line per failed test.
//   node vitest_summary.js report.json [--names]
// With --names, prints "status<TAB>file<TAB>full name" for every test instead
// (for diffing two runs).
const fs = require('fs');
const r = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const names = process.argv.includes('--names');
const c = { passed: 0, failed: 0, skipped: 0 };
const failed = [];
for (const file of r.testResults || []) {
  const short = file.name.replace(/^.*\/tests\//, 'tests/');
  if ((file.assertionResults || []).length === 0 && file.status === 'failed') {
    c.failed++;
    failed.push(`${short}: (file failed to run) ${(file.message || '').split('\n')[0]}`);
    if (names) console.log(`failed\t${short}\t(file)`);
  }
  for (const t of file.assertionResults || []) {
    const st = t.status === 'passed' ? 'passed' : t.status === 'failed' ? 'failed' : 'skipped';
    c[st]++;
    if (names) console.log(`${st}\t${short}\t${t.fullName}`);
    if (st === 'failed') failed.push(`${short} > ${t.fullName}`);
  }
}
if (!names) {
  console.log(`${c.passed} passed, ${c.failed} failed, ${c.skipped} skipped`);
  for (const f of failed) console.log(`      FAILED ${f}`);
}
