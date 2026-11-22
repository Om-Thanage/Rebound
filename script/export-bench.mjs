// Turns results/bench.csv into dashboard/data/bench.json for the dashboard's speed section.
// Usage: node script/export-bench.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const rows = readFileSync(new URL('../results/bench.csv', import.meta.url), 'utf8').trim().split(/\r?\n/).slice(1)
  .map((l) => l.split(','))
  .filter((c) => c[6] !== '' && c[6] !== undefined)
  .map(([round, priceTx, priceBlock, reqBlock, rescueTx, rescueBlock, blocks, e2e, toReactive, hf, lasnaTx]) => ({
    round: +round, priceTx, priceBlock: +priceBlock, rescueTx, rescueBlock: +rescueBlock, lasnaTx: lasnaTx || null, lasnaBlock: reqBlock ? +reqBlock : null,
    blocks: +blocks, seconds: +e2e, toReactive: toReactive === '' ? null : +toReactive, hfAfter: hf,
  }));

const s = rows.map((r) => r.seconds).sort((a, b) => a - b);
const pick = (q) => s[Math.min(s.length - 1, Math.floor((s.length - 1) * q))];
const summary = s.length
  ? { rounds: s.length, median: pick(0.5), p90: pick(0.9), min: s[0], max: s.at(-1) }
  : { rounds: 0 };
if (s.length) console.assert(summary.min <= summary.median && summary.median <= summary.max, 'summary out of order');

mkdirSync(new URL('../dashboard/data/', import.meta.url), { recursive: true });
writeFileSync(new URL('../dashboard/data/bench.json', import.meta.url), JSON.stringify({ summary, rows }, null, 2));
console.log(summary);
