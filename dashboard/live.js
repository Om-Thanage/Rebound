// Live data for the dashboard: reads the shield, the pool and the oracle on Base Sepolia over JSON-RPC,
// the shield's Rescued events from Blockscout, and the benchmark from data/bench.json.
const RPC = 'https://sepolia.base.org';
const SCOUT = 'https://base-sepolia.blockscout.com';
const A = {
  user: '0x312D0201519E71A0A7704F7a349d35B129615fcD',
  weth: '0xac1f5822da429129e15aB706D3888769De7d5cF4',
  oracle: '0x49074f7961c01416cf5A57d13df664C32fb33345',
  pool: '0x398ED21C0F95cb4F5c444CAe0F9EeB07b1689e5c',
  shield: '0x3796897b27240f329b32184f2C2cBd6666A1EeaE',
};
const SEL = { account: '0xbf92857c', price: '0xb3596f07', prot: '0x613e3fc0', ledger: '0x30b7c49f', collateral: '0xa5fdc5de', debt: '0x9b6c56ec' };
const RESCUED = '0x28b6c2526f0d05eac057487199a229c2584389d09c1a5b014dcf02610fdd8419';

const $ = (k) => document.querySelectorAll(`[data-live="${k}"]`);
const set = (k, v) => $(k).forEach((el) => { el.textContent = v; });
const arg = (addr) => addr.slice(2).toLowerCase().padStart(64, '0');
const words = (hex) => (hex.slice(2).match(/.{64}/g) || []).map((w) => BigInt('0x' + w));
const eth = (wei, d = 6) => (Number(wei) / 1e18).toFixed(d);
const hf = (v) => (v > 10n ** 30n ? '∞' : (Number(v) / 1e18).toFixed(2));

async function call(to, data) {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data }, 'latest'] }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return words(j.result);
}

async function readLoan() {
  const [acct, [price], prot, ledger, [coll], [debt]] = await Promise.all([
    call(A.pool, SEL.account + arg(A.user)),
    call(A.oracle, SEL.price + arg(A.weth)),
    call(A.shield, SEL.prot + arg(A.user)),
    call(A.shield, SEL.ledger),
    call(A.pool, SEL.collateral + arg(A.user)),
    call(A.pool, SEL.debt + arg(A.user)),
  ]);
  const h = acct[5];
  set('hf', hf(h));
  set('price', '$' + (Number(price) / 1e8).toLocaleString('en-US', { maximumFractionDigits: 0 }));
  set('coll', eth(coll, 4) + ' WETH');
  set('debt', (Number(debt) / 1e6).toFixed(2) + ' USDC');
  set('reserve', eth(prot[0], 4) + ' WETH');
  // the gauge runs from HF 0.5 to 2.0; the trigger (1.15) and target (1.40) marks sit at 43% and 60%
  const pct = Math.max(0, Math.min(100, ((Number(h) / 1e18) - 0.5) / 1.5 * 100));
  $('gauge').forEach((el) => { el.style.width = (h > 10n ** 30n ? 100 : pct) + '%'; });

  const [fees, seed, gas, , owed] = ledger;
  set('fees', eth(fees) + ' ETH');
  set('gas', eth(gas) + ' ETH');
  set('seed', eth(seed) + ' ETH');
  set('owed', eth(owed) + ' ETH');
  set('ratio', gas > 0n ? Math.round(Number(fees) / Number(gas)) + '×' : 'no gas yet');
  $('gasbar').forEach((el) => { el.style.width = (fees > 0n ? Math.max(1, Number(gas) * 100 / Number(fees)) : 0) + '%'; });
  set('updated', 'Updated ' + new Date().toLocaleTimeString('en-GB'));
}

async function readRescues() {
  const r = await fetch(`${SCOUT}/api/v2/addresses/${A.shield}/logs`);
  const j = await r.json();
  const rescues = (j.items || []).filter((l) => l.topics?.[0] === RESCUED);
  set('count', String(rescues.length));
  const list = $('rows')[0];
  if (!list || !rescues.length) return;
  list.replaceChildren(...rescues.slice(0, 12).map((l) => {
    const [supplied, , before, after, ts] = words(l.data);
    const li = document.createElement('li');
    li.className = 'ui-win__row';
    const mins = Math.max(0, Math.round((Date.now() / 1000 - Number(ts)) / 60));
    li.innerHTML = `<span class="ui-avatar" data-tone="1">R</span><span class="ui-win__who"></span><span class="ui-win__sub"></span><span class="ui-win__st is-done">Rescued</span><span class="ui-win__age"></span>`;
    li.children[1].textContent = String(l.block_number);
    li.children[2].textContent = `${hf(before)} → ${hf(after)} · ${eth(supplied, 5)} WETH`;
    li.children[4].textContent = mins < 60 ? `${mins}m` : `${Math.round(mins / 60)}h`;
    return li;
  }));
}

async function readBench() {
  const r = await fetch('data/bench.json', { cache: 'no-store' });
  if (!r.ok) return;
  const { summary, rows } = await r.json();
  if (!summary.rounds) return;
  set('median', summary.median.toFixed(1) + ' s');
  set('median-big', summary.median.toFixed(1) + ' s');
  set('summary', `Median of ${summary.rounds} rounds. Fastest ${summary.min.toFixed(1)} s, p90 ${summary.p90.toFixed(1)} s, slowest ${summary.max.toFixed(1)} s.`);
  const list = $('bench')[0];
  const top = Math.max(...rows.map((x) => x.seconds), 1);
  list.replaceChildren(...rows.slice(0, 20).map((x) => {
    const li = document.createElement('li');
    li.innerHTML = `<span></span><i></i><a class="tx" target="_blank" rel="noopener"></a>`;
    li.children[0].textContent = `Round ${x.round}`;
    li.children[1].style.setProperty('--w', (x.seconds / top * 100).toFixed(1) + '%');
    const a = li.querySelector('a');
    a.href = `${SCOUT}/tx/${x.rescueTx}`;
    a.title = `${x.blocks} Base blocks`;
    a.textContent = `${x.seconds.toFixed(1)} s`;
    return li;
  }));
}

const safe = (f) => f().catch((e) => console.warn('live data:', e.message));
safe(readBench);
safe(readRescues);
safe(readLoan);
setInterval(() => { safe(readLoan); safe(readRescues); }, 10_000);
