// Self-check for the dashboard's rescue outcome: the raw health factor is compared with the exact trigger and target,
// and a value just under a line is never displayed as that line. Usage: node script/check-dashboard.mjs
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const src = readFileSync(new URL('../dashboard/live.js', import.meta.url), 'utf8');
const block = src.match(/const TRIGGER[\s\S]*?\n}\n/)[0]; // TRIGGER, TARGET, hfDown, rescueOutcome
const rescueOutcome = new Function(`${block}; return rescueOutcome;`)();
const E15 = 10n ** 15n;

const cases = [
  [1400n * E15 + 1n, 'The loan on the right is back at its 1.40 target (HF 1.40).'],
  [1400n * E15, 'The loan on the right is back at its 1.40 target (HF 1.40).'],
  [1400n * E15 - 1n, 'The loan is back above its 1.15 trigger (HF 1.39), short of the 1.40 target.'],
  [1395n * E15, 'The loan is back above its 1.15 trigger (HF 1.39), short of the 1.40 target.'],
  [1150n * E15, 'The loan is back above its 1.15 trigger (HF 1.15), short of the 1.40 target.'],
  [1150n * E15 - 1n, 'Partial rescue: HF 1.14 is still under the 1.15 trigger. Top up the reserve.'],
  [1000n * E15 - 1n, 'Partial rescue: HF 0.99 is still under 1.0, so the loan can be liquidated. Top up the reserve.'],
];
for (const [hf, want] of cases) assert.equal(rescueOutcome(hf), want, `HF ${hf}`);
console.log(`dashboard outcome: ${cases.length} cases ok`);
