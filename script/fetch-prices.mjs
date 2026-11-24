// Fetches Chainlink ETH/USD answers on Ethereum mainnet for the crash windows the README cites, and caches them in
// results/sim/prices.json, so script/replay.mjs runs offline and reproducibly. It reads the feed's own round history
// (proxy.getRoundData per phase), which needs only current state, not an archive node or wide log queries.
// Usage: node script/fetch-prices.mjs   (ETH_RPC, default https://ethereum-rpc.publicnode.com)
import { writeFileSync, mkdirSync } from 'node:fs';

const RPC = process.env.ETH_RPC || 'https://ethereum-rpc.publicnode.com';
const PROXY = '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419'; // Chainlink ETH/USD proxy
const WINDOWS = [ // UTC; each starts a day or two before the crash day
  { name: '2021-05-19 market crash', from: '2021-05-17', to: '2021-05-21' },
  { name: '2024-08-05 global sell-off', from: '2024-08-03', to: '2024-08-07' },
  { name: '2025-10-10 tariff crash', from: '2025-10-08', to: '2025-10-12' },
  { name: '2026-01-31 to 02-05 sell-off', from: '2026-01-29', to: '2026-02-06' },
];

let id = 0;
async function batch(calls) { // [[to, data]] -> hex results, null for a reverted call
  for (let attempt = 0; ; attempt++) {
    try {
      const body = calls.map(([to, data]) => ({ jsonrpc: '2.0', id: ++id, method: 'eth_call', params: [{ to, data }, 'latest'] }));
      const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
      const j = await r.json();
      if (!Array.isArray(j)) throw new Error(j.error?.message || `HTTP ${r.status}`);
      const byId = new Map(j.map((x) => [x.id, x]));
      return body.map((b) => (byId.get(b.id)?.error ? null : byId.get(b.id)?.result ?? null));
    } catch (e) {
      if (attempt >= 5) throw e;
      await new Promise((res) => setTimeout(res, 1500 * (attempt + 1)));
    }
  }
}
const call = async (to, data) => (await batch([[to, data]]))[0];
const u = (hex, i) => BigInt('0x' + hex.slice(2 + 64 * i, 66 + 64 * i));
const enc = (n) => n.toString(16).padStart(64, '0');
const GET_ROUND = '0x9a6fc8f5'; // getRoundData(uint80) -> (roundId, answer, startedAt, updatedAt, answeredInRound)

async function rounds(ids) { // proxy round ids -> [{ id, t, price }], skipping rounds that do not exist
  const out = [];
  for (let i = 0; i < ids.length; i += 50) {
    const res = await batch(ids.slice(i, i + 50).map((r) => [PROXY, GET_ROUND + enc(r)]));
    res.forEach((h, k) => {
      if (h && h.length >= 2 + 64 * 4) out.push({ id: ids[i + k], t: Number(u(h, 3)), price: Number(BigInt.asIntN(256, u(h, 1))) / 1e8 });
    });
  }
  return out;
}

const phaseId = Number(u(await call(PROXY, '0x58303b10'), 0)); // phaseId()
const phases = [];
for (let p = 1; p <= phaseId; p++) {
  const agg = '0x' + (await call(PROXY, '0xc1597304' + enc(BigInt(p)))).slice(-40); // phaseAggregators(uint16)
  const lr = await call(agg, '0x668a0f02'); // latestRound(); the oldest phases' aggregators no longer answer
  if (!lr || lr.length < 66) continue;
  const latest = Number(u(lr, 0));
  const base = BigInt(p) << 64n;
  const [first] = await rounds([base + 1n]);
  const [last] = await rounds([base + BigInt(latest)]);
  if (first && last) phases.push({ p, agg, base, latest, from: first.t, to: last.t });
}

async function firstRoundAtOrAfter(ph, ts) { // binary search on updatedAt inside one phase
  let lo = 1, hi = ph.latest;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const [r] = await rounds([ph.base + BigInt(mid)]);
    if (!r || r.t < ts) lo = mid + 1; else hi = mid;
  }
  return lo;
}

const result = { source: `Chainlink ETH/USD on Ethereum mainnet (proxy ${PROXY}), getRoundData per phase`, windows: [] };
for (const w of WINDOWS) {
  const from = Date.parse(w.from + 'T00:00:00Z') / 1000;
  const to = Date.parse(w.to + 'T00:00:00Z') / 1000;
  const updates = [];
  for (const ph of phases.filter((x) => x.to >= from && x.from < to)) {
    const a = await firstRoundAtOrAfter(ph, from);
    const b = await firstRoundAtOrAfter(ph, to);
    const ids = [];
    for (let r = a; r <= b; r++) ids.push(ph.base + BigInt(r));
    updates.push(...(await rounds(ids)).filter((x) => x.t >= from && x.t < to).map(({ t, price }) => ({ t, price, phase: ph.p })));
  }
  updates.sort((x, y) => x.t - y.t);
  result.windows.push({ ...w, updates });
  const ps = updates.map((x) => x.price);
  console.log(`${w.name}: ${updates.length} updates, high $${Math.max(...ps).toFixed(0)}, low $${Math.min(...ps).toFixed(0)}`);
}
mkdirSync(new URL('../results/sim/', import.meta.url), { recursive: true });
writeFileSync(new URL('../results/sim/prices.json', import.meta.url), JSON.stringify(result) + '\n');
