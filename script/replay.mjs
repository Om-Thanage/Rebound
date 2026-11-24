// SIMULATED, not a testnet measurement. Replays historical Chainlink ETH/USD updates (results/sim/prices.json, from
// script/fetch-prices.mjs) against identical Aave-style loans under three strategies, with the same reserve each:
//   none     - the reserve sits idle in the borrower's wallet
//   upfront  - the reserve repays debt at the start of the window
//   rebound  - Rebound's repay mode: trigger 1.15, target 1.40, early request on a falling price, fee, delay
// Writes results/sim/runs.csv and results/sim/summary.md. Usage: node script/replay.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const A = {
  collateralEth: 10,
  lt: 0.83, // Aave V3 WETH liquidation threshold on Ethereum
  bonus: 0.05, // liquidation bonus, paid by the borrower
  closeFactor: (hf) => (hf < 0.95 ? 1 : 0.5), // Aave V3: 100% of the debt under HF 0.95, else 50%
  startHfs: [1.2, 1.3, 1.4, 1.5, 1.7, 2.0],
  reserveShare: 0.2, // reserve = 20% of the starting debt, in USDC, the same for every strategy
  apr: 0.05, // borrow interest, accrued on outstanding debt
  trigger: 1.15,
  target: 1.4,
  feeBps: 30,
  minFeeEth: 0.0001,
  watchFeeEthPerDay: 0.00001,
  maxHintBps: 500, // the early request projects one more equal step down, at most 5%
  cooldownS: 10,
  delaysS: [1.4, 2.6, 60, 300], // measured testnet median and slowest, then two stress cases
};
const STRATEGIES = ['none', 'upfront', 'rebound'];

function run(updates, startHf, strategy, delay) {
  const p0 = updates[0].price;
  let coll = A.collateralEth;
  let debt = (coll * p0 * A.lt) / startHf;
  let reserve = A.reserveShare * debt;
  const reserve0 = reserve;
  let mark = p0;
  let ledger = coll * p0 - debt + reserve; // equity, moved only by price, interest, fees and liquidation bonus
  let lastT = updates[0].t;
  const o = { liquidations: 0, bonusLost: 0, fees: 0, interest: 0, rescues: 0, partial: 0, late: 0, missed: 0, repaid: 0, minHf: Infinity };
  const hf = (price) => (debt <= 1e-9 ? Infinity : (coll * price * A.lt) / debt);
  const move = (price) => { ledger += coll * (price - mark); mark = price; };
  const accrue = (t) => { const i = (debt * A.apr * (t - lastT)) / 31_536_000; debt += i; o.interest += i; ledger -= i; lastT = t; };
  const pay = (fee) => { reserve -= fee; o.fees += fee; ledger -= fee; };
  if (strategy === 'upfront') { const x = Math.min(reserve, debt); debt -= x; reserve -= x; o.repaid += x; }

  let pending = null; // a requested rescue: { landAt, hint }
  let cooldownUntil = 0;
  const land = (price) => { // the shield, when the callback lands: re-check live, size at the clamped hint, repay
    const hint = pending.hint;
    pending = null;
    const pEff = hint > 0 && hint < price ? Math.max(hint, price * (1 - A.maxHintBps / 1e4)) : price;
    if (hf(pEff) >= A.trigger || reserve <= 0) return;
    const need = Math.max(0, debt - (coll * pEff * A.lt) / A.target);
    const feeOf = (x) => Math.max((x * A.feeBps) / 1e4, A.minFeeEth * price);
    let x = need;
    if (x + feeOf(x) > reserve) { // short reserve: size the repayment and its fee together
      x = Math.max(0, (reserve * 1e4) / (1e4 + A.feeBps));
      x = Math.max(0, Math.min(x, reserve - feeOf(x)));
      o.partial++;
    }
    pay(Math.min(feeOf(x), reserve - x));
    debt -= x; reserve -= x; o.repaid += x; o.rescues++;
  };

  for (let i = 0; i < updates.length; i++) {
    const { t, price } = updates[i];
    if (pending && pending.landAt < t) { // landed before this update, at the price known then
      accrue(pending.landAt);
      land(mark);
    }
    accrue(t);
    move(price);
    o.minHf = Math.min(o.minHf, hf(price));
    if (hf(price) < 1) { // liquidators act in this update's block, before a rescue requested now can land
      const r = A.closeFactor(hf(price)) * debt;
      const seized = Math.min(coll, (r * (1 + A.bonus)) / price);
      const covered = (seized * price) / (1 + A.bonus);
      debt -= covered; coll -= seized;
      o.bonusLost += covered * A.bonus; ledger -= covered * A.bonus; o.liquidations++;
      if (strategy === 'rebound') { if (pending) o.late++; else if (reserve > 0) o.missed++; }
    }
    if (strategy === 'rebound' && !pending && t >= cooldownUntil && reserve > 0) {
      const prev = i > 0 ? updates[i - 1].price : price;
      const projected = prev > price ? Math.max(price - (prev - price), price * (1 - A.maxHintBps / 1e4)) : 0;
      if (hf(price) < A.trigger) pending = { landAt: t + delay, hint: 0 };
      else if (projected > 0 && hf(projected) < A.trigger) pending = { landAt: t + delay, hint: projected };
      if (pending) cooldownUntil = t + delay + A.cooldownS;
    }
  }
  const last = updates[updates.length - 1];
  if (pending) { accrue(Math.max(last.t, pending.landAt)); land(mark); }
  if (strategy === 'rebound') pay(Math.min(reserve, A.watchFeeEthPerDay * ((last.t - updates[0].t) / 86_400) * last.price));
  const equity = coll * mark - debt + reserve;
  assert.ok(Math.abs(equity - ledger) < 1e-6 * Math.max(1, Math.abs(equity)), `ledger ${ledger} vs equity ${equity}`);
  return { ...o, cost: o.bonusLost + o.fees + o.interest, endHf: hf(mark), reserveLeft: reserve, reserve0, debtLeft: debt };
}

// ---- self-check on a made-up path: a slow fall that Rebound catches and the idle loan does not survive
{
  const path = [2000, 1900, 1800, 1700, 1600, 1500, 1400, 1300].map((price, k) => ({ t: k * 3600, price }));
  const none = run(path, 1.3, 'none', 1.4);
  const reb = run(path, 1.3, 'rebound', 1.4);
  assert.ok(none.liquidations > 0, 'idle loan is liquidated on a 35% fall');
  assert.ok(reb.rescues > 0 && reb.liquidations <= none.liquidations, 'Rebound rescues on the way down');
}

const data = JSON.parse(readFileSync(new URL('../results/sim/prices.json', import.meta.url), 'utf8'));
const rows = [];
for (const w of data.windows) {
  for (const startHf of A.startHfs) {
    for (const strategy of STRATEGIES) {
      for (const delay of strategy === 'rebound' ? A.delaysS : [0]) {
        rows.push({ window: w.name, startHf, strategy, delay, ...run(w.updates, startHf, strategy, delay) });
      }
    }
  }
}

const f = (x, d = 2) => (Number.isFinite(x) ? x.toFixed(d) : 'inf');
const cols = ['window', 'startHf', 'strategy', 'delay', 'liquidations', 'bonusLost', 'fees', 'interest', 'cost', 'rescues', 'partial', 'late', 'missed', 'repaid', 'minHf', 'endHf'];
writeFileSync(new URL('../results/sim/runs.csv', import.meta.url),
  [cols.join(','), ...rows.map((r) => cols.map((c) => (typeof r[c] === 'number' ? f(r[c], c.endsWith('Hf') ? 3 : 2) : `"${r[c]}"`)).join(','))].join('\n') + '\n');

// summary: per window and starting HF, the three strategies side by side (Rebound at the measured 1.4 s delay)
const pick = (w, h, s, d = s === 'rebound' ? 1.4 : 0) => rows.find((r) => r.window === w && r.startHf === h && r.strategy === s && r.delay === d);
const lines = [];
const cell = (r) => `${r.liquidations ? `**${r.liquidations} liq.**, ` : ''}$${f(r.cost, 0)}`;
for (const w of data.windows) {
  const ps = w.updates.map((u) => u.price);
  lines.push(`\n### ${w.name}\n\n${w.updates.length} oracle updates, $${f(ps[0], 0)} at the start, low $${f(Math.min(...ps), 0)} (${f((1 - Math.min(...ps) / ps[0]) * 100, 1)}% down).\n`);
  lines.push('| Start HF | No intervention | Upfront repayment | Rebound (1.4 s) | Rebound rescues / partial / late / missed |', '|---|---|---|---|---|');
  for (const h of A.startHfs) {
    const [n, u, r] = STRATEGIES.map((s) => pick(w.name, h, s));
    lines.push(`| ${h.toFixed(2)} | ${cell(n)} | ${cell(u)} | ${cell(r)} | ${r.rescues} / ${r.partial} / ${r.late} / ${r.missed} |`);
  }
}
const slow = rows.filter((r) => r.strategy === 'rebound');
const byDelay = A.delaysS.map((d) => {
  const rs = slow.filter((r) => r.delay === d);
  return `| ${d} s | ${rs.reduce((a, r) => a + r.liquidations, 0)} | ${rs.reduce((a, r) => a + r.late, 0)} | ${rs.reduce((a, r) => a + r.missed, 0)} | $${f(rs.reduce((a, r) => a + r.cost, 0), 0)} |`;
});
const total = (s) => rows.filter((r) => r.strategy === s && (s !== 'rebound' || r.delay === 1.4));
const sum = (rs, k) => rs.reduce((a, r) => a + r[k], 0);
writeFileSync(new URL('../results/sim/summary.md', import.meta.url), `# Historical replay (SIMULATED)

Not a testnet measurement: \`script/replay.mjs\` replays Chainlink ETH/USD updates from Ethereum mainnet
(\`results/sim/prices.json\`, fetched by \`script/fetch-prices.mjs\`) against identical loans. Every loan starts
with ${A.collateralEth} ETH of collateral at the window's first price and the debt that gives the starting HF; each
strategy gets the same reserve, ${A.reserveShare * 100}% of the starting debt in USDC.

**Assumptions.** LT ${A.lt}, liquidation bonus ${A.bonus * 100}%, close factor 50% (100% under HF 0.95), as in Aave
V3. Liquidation happens at the oracle update that puts HF under 1.0, in the same block, before any rescue requested
at that update can land. A rescue requested at update *i* lands \`delay\` seconds later at the latest price known
then; if a later update liquidates first, it counts as late. The rescue re-checks the live HF (with the hint, at
most 5% under the oracle), repays the smallest amount that reaches ${A.target} at that price, and pays 0.3% of what
it repays (floor ${A.minFeeEth} ETH) from the reserve; a short reserve gives a partial rescue. Watch fee
${A.watchFeeEthPerDay} ETH a day. Interest ${A.apr * 100}% a year on outstanding debt. One collateral asset, USDC
at $1. The Ethereum mainnet feed stands in for Base's (Base's own feed updates on the same deviation rules).
Cost = liquidation bonus lost + fees + interest, in USD. Not modelled: gas for the upfront repayment, the
borrower's use of an unspent reserve, slippage, Reactive running out of lREACT.

**Totals over ${data.windows.length} windows x ${A.startHfs.length} starting HFs:**

| Strategy | Liquidations | Cost | Reserve still unspent at the end |
|---|---|---|---|
${STRATEGIES.map((s) => `| ${s === 'rebound' ? 'Rebound (1.4 s)' : s === 'upfront' ? 'Upfront repayment' : 'No intervention'} | ${sum(total(s), 'liquidations')} | $${f(sum(total(s), 'cost'), 0)} | $${f(sum(total(s), 'reserveLeft'), 0)} of $${f(sum(total(s), 'reserve0'), 0)} |`).join('\n')}

**Rebound by delay** (all windows and starting HFs):

| Delay | Liquidations | Late | Missed | Cost |
|---|---|---|---|---|
${byDelay.join('\n')}
${lines.join('\n')}

Cells: liquidations (if any) and cost. Every run is in \`results/sim/runs.csv\`.
`);
console.log(`${rows.length} runs; totals:`, STRATEGIES.map((s) => `${s} ${sum(total(s), 'liquidations')} liq $${f(sum(total(s), 'cost'), 0)}`).join(' | '));
console.log(byDelay.join('\n'));
