// Fills to_reactive_s in results/bench.csv for rounds that have a Lasna request block but no value: seconds from the
// Base price block to the Lasna block holding RescueRequested. Both chains stamp whole seconds, so this is a
// 1-second-resolution split of the end-to-end time, not a precise measurement.
// Usage: node script/backfill-bench.mjs   (reads BASE_SEPOLIA_RPC and REACTIVE_LASNA_RPC from .env or $ENV_FILE)
import { readFileSync, writeFileSync } from 'node:fs';

const envFile = process.env.ENV_FILE || new URL('../.env', import.meta.url);
const env = Object.fromEntries(readFileSync(envFile, 'utf8').split(/\r?\n/)
  .filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).trim()]));
const BASE = process.env.BASE_SEPOLIA_RPC || env.BASE_SEPOLIA_RPC;
const LASNA = process.env.REACTIVE_LASNA_RPC || env.REACTIVE_LASNA_RPC;
const rpc = async (url, method, params) => {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
};
const ts = async (url, n) => Number((await rpc(url, 'eth_getBlockByNumber', ['0x' + Number(n).toString(16), false])).timestamp);

const file = new URL('../results/bench.csv', import.meta.url);
const [header, ...lines] = readFileSync(file, 'utf8').trim().split(/\r?\n/);
const cols = header.split(',');
const at = (name) => cols.indexOf(name);
let filled = 0;
for (let i = 0; i < lines.length; i++) {
  const c = lines[i].split(',');
  while (c.length < cols.length) c.push('');
  if (c[at('to_reactive_s')] !== '' || !c[at('request_lasna_block')] || !c[at('price_block')]) continue;
  c[at('to_reactive_s')] = String(await ts(LASNA, c[at('request_lasna_block')]) - await ts(BASE, c[at('price_block')]));
  lines[i] = c.join(',');
  filled++;
}
writeFileSync(file, [header, ...lines].join('\n') + '\n');
console.log(`filled ${filled} rows; run node script/export-bench.mjs to update the dashboard`);
