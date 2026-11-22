// Live data for the dashboard: reads the shield, the pool and the oracle on Base Sepolia over JSON-RPC,
// the shield's Rescued events from Blockscout, and the benchmark from data/bench.json.
let RPC = 'https://sepolia.base.org';
const SCOUT = 'https://base-sepolia.blockscout.com';
let LASNA = 'https://lasna-rpc.rnk.dev/';
const LASNA_SCAN = 'https://lasna.reactscan.net';
let REACTIVE = '0x49074f7961c01416cf5A57d13df664C32fb33345';
// Addresses of the live deployment; data/deployment.json (written by script/export-deployment.mjs) overrides them.
const A = {
  user: '0x3673cE1229C43ac7A64a5E85DB58c1320d5E4573', // DemoLoan: the loan visitors crash with Run a rescue
  weth: '0x8C2A82cC3A5f9d1736c3A5bE0Dd2Ef56e1c37A64',
  oracle: '0xB567239e6AE5E9b76462dAE4610335e480263b03',
  pool: '0x7ac6FcF13E42908F78A691B7CaF7Cb55BfD18774',
  shield: '0x6dAa01C49DfE0c8ccd01A2ABC32F1A3229Eb6DFc',
};
const SEL = { account: '0xbf92857c', price: '0xb3596f07', prot: '0x613e3fc0', ledger: '0x30b7c49f', collateral: '0xa5fdc5de', debt: '0x9b6c56ec', count: '0x98e78023', run: '0xc0406226', wait: '0xccca123b',
  breakdown: '0x46332ee4', mode: '0x295a5212', runWithMode: '0x6a99d796',
  ticks: '0x36ff1f66', checked: '0x82b26947', requested: '0xb8c1e462', early: '0x3a9b9e03', cron: '0x0ba10b24', users: '0x07973ccf' };
const RESCUED = '0x28b6c2526f0d05eac057487199a229c2584389d09c1a5b014dcf02610fdd8419';
const DETAIL = '0xd6a7d2fcb36c3966223a7015df24966d5b6b9a16ae2770e4708df14e86565b3f'; // RescueDetail: repaid debt, hint
const MODES = ['Collateral', 'Repay', 'Combined'];
let demoMode = 0; // the mode the visitor picked for the next run

async function loadDeployment() {
  try {
    const r = await fetch('data/deployment.json', { cache: 'no-store' });
    if (!r.ok) return;
    const d = await r.json();
    for (const k of Object.keys(A)) if (d[k]) A[k] = d[k];
    if (d.reactive) REACTIVE = d.reactive;
    if (d.rpc) RPC = d.rpc; // lets the page run against a local test chain
    if (d.lasnaRpc) LASNA = d.lasnaRpc;
  } catch { /* keep the built-in addresses */ }
}

const $ = (k) => document.querySelectorAll(`[data-live="${k}"]`);
const set = (k, v) => $(k).forEach((el) => { el.textContent = v; });
const arg = (addr) => addr.slice(2).toLowerCase().padStart(64, '0');
const words = (hex) => (hex.slice(2).match(/.{64}/g) || []).map((w) => BigInt('0x' + w));
const eth = (wei, d = 6) => (Number(wei) / 1e18).toFixed(d);
const hf = (v) => (v > 10n ** 30n ? '∞' : (Number(v) / 1e18).toFixed(2));

async function call(to, data, url = RPC) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data }, 'latest'] }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return words(j.result);
}

async function readLoan() {
  const [acct, [price], prot, [coll], [debt]] = await Promise.all([
    call(A.pool, SEL.account + arg(A.user)),
    call(A.oracle, SEL.price + arg(A.weth)),
    call(A.shield, SEL.prot + arg(A.user)),
    call(A.pool, SEL.collateral + arg(A.user)),
    call(A.pool, SEL.debt + arg(A.user)),
  ]);
  const h = acct[5];
  set('who', `Demo loan ${A.user.slice(0, 6)}…${A.user.slice(-4)}`);
  set('hf', hf(h));
  set('price', '$' + (Number(price) / 1e8).toLocaleString('en-US', { maximumFractionDigits: 0 }));
  set('coll', eth(coll, 4) + ' WETH');
  set('debt', (Number(debt) / 1e6).toFixed(2) + ' USDC');
  set('reserve', eth(prot[0], 4) + ' WETH');
  // the current shield returns 9 words (reserve, repay reserve, trigger, target, step, last, paid, mode, mirrored)
  const mode = prot.length >= 9 ? Number(prot[7]) : 0;
  if (prot.length >= 9) {
    set('repay-reserve', (Number(prot[1]) / 1e6).toFixed(2) + ' USDC');
    set('mode', MODES[mode] || '–');
  }
  set('cover', coverNote(acct, price, prot, mode));
  // the gauge runs from HF 0.5 to 2.0; the trigger (1.15) and target (1.40) marks sit at 43% and 60%
  const pct = Math.max(0, Math.min(100, ((Number(h) / 1e18) - 0.5) / 1.5 * 100));
  $('gauge').forEach((el) => { el.style.width = (h > 10n ** 30n ? 100 : pct) + '%'; });

  set('updated', 'Updated ' + new Date().toLocaleTimeString('en-GB'));
  await readLedger();
}

// The fee ledger is read on its own, so a failing call there can't blank the loan panel.
async function readLedger() {
  const ledger = await call(A.shield, SEL.ledger).catch((e) => { console.warn('live data: ledger', e.message); return null; });
  if (ledger) {
    const [fees, seed, gas, , owed] = ledger;
    set('fees', eth(fees) + ' ETH');
    set('gas', eth(gas) + ' ETH');
    set('seed', eth(seed) + ' ETH');
    set('owed', eth(owed) + ' ETH');
    set('ratio', gas > 0n ? Math.round(Number(fees) / Number(gas)) + '×' : 'no gas yet');
    $('gasbar').forEach((el) => { el.style.width = (fees > 0n ? Math.max(1, Number(gas) * 100 / Number(fees)) : 0) + '%'; });
  }

  const breakdown = await call(A.shield, SEL.breakdown).catch(() => null);
  if (breakdown) {
    const [, watch, rescues, skipped] = breakdown;
    set('watch', eth(watch) + ' ETH');
    set('skipped', `${skipped} of ${rescues + skipped}`);
  }
}

/// Would the reserve still reach the 1.40 target if WETH fell another 20% from here?
function coverNote(acct, price, prot, mode) {
  const [collBase, debtBase, , lt] = acct.map(Number);
  if (!debtBase || !lt || !price) return '';
  const p = Number(price) * 0.8;
  const coll = collBase * 0.8;
  if (mode === 1 && prot.length >= 9) {
    const need = Math.max(0, debtBase - coll * lt / 1.4e4) / 1e8; // USD of debt to repay
    const have = Number(prot[1]) / 1e6;
    return have >= need ? `Repay reserve covers a further 20% drop (needs ${need.toFixed(2)} USDC).`
      : `Repay reserve would fall short after a further 20% drop: needs ${need.toFixed(2)} USDC.`;
  }
  const needBase = Math.max(0, 1.4 * debtBase * 1e4 / lt - coll);
  const needWeth = needBase / p;
  const have = Number(prot[0]) / 1e18;
  return have >= needWeth ? `Reserve covers a further 20% drop (needs ${needWeth.toFixed(4)} WETH).`
    : `Reserve would fall short after a further 20% drop: needs ${needWeth.toFixed(4)} WETH.`;
}

/// What the reactive contract on Lasna has done: its own counters and its lREACT balance.
async function readReactive() {
  const lasna = (sel) => call(REACTIVE, sel, LASNA).then((w) => w[0]);
  const [ticks, checked, requested, early, cron, users] = await Promise.all(
    [SEL.ticks, SEL.checked, SEL.requested, SEL.early, SEL.cron, SEL.users].map(lasna));
  // Reactive charges execution against the system contract's reserve for this contract, not its own balance
  const [bal] = await call('0x8888888888888888888888888888888888888888', '0xd66bd524' + arg(REACTIVE), LASNA);
  set('ticks', String(ticks));
  const watched = `${users} ${users === 1n ? 'loan' : 'loans'} watched`;
  set('checked', ticks > 0n ? `${(Number(checked) / Number(ticks)).toFixed(1)} per event, ${watched}` : watched);
  set('requested', `${requested} (${early} early)`);
  set('cron', String(cron));
  set('lreact', eth(bal, 3) + ' lREACT');
}

async function readRescues() {
  const r = await fetch(`${SCOUT}/api/v2/addresses/${A.shield}/logs`);
  const j = await r.json();
  // Blockscout returns one page of logs; the total comes from the contract's own counter
  const rescues = (j.items || []).filter((l) => l.topics?.[0] === RESCUED);
  const [count] = await call(A.shield, SEL.count);
  set('count', String(count));
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
loadDeployment().then(async () => {
  safe(readBench);
  safe(readRescues);
  safe(readLoan);
  safe(readReactive);
  setInterval(() => { safe(readLoan); safe(readRescues); safe(readReactive); }, 10_000);
  // the mode picker only shows when the deployed DemoLoan supports repay runs
  const hasModes = await call(A.user, SEL.mode).then(() => true).catch(() => false);
  document.querySelectorAll('[data-mode-pick]').forEach((el) => { el.hidden = !hasModes; });
});
document.querySelectorAll('[data-mode]').forEach((b) => b.addEventListener('click', () => {
  demoMode = Number(b.dataset.mode);
  document.querySelectorAll('[data-mode]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
}));

// ---- Run a rescue: the visitor's wallet calls DemoLoan.run(); the five steps on the page follow the loop
const REQUESTED = '0x831e6fe83ba01a4c7028ae204aa408895d0122a5656622d38f09941a22543423'; // RescueRequested(user, hf, price, hint) on Lasna
const usd = (v) => '$' + (Number(v) / 1e8).toLocaleString('en-US', { maximumFractionDigits: 0 });
const CHAIN = { chainId: '0x14a34', chainName: 'Base Sepolia', rpcUrls: [RPC],
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, blockExplorerUrls: [SCOUT] };
const status = (html) => document.querySelectorAll('[data-run-status]').forEach((el) => { el.innerHTML = html; });
const link = (href, label) => `<a href="${href}" target="_blank" rel="noopener">${label}</a>`;
const txLink = (h, label) => link(`${SCOUT}/tx/${h}`, label);
const short = (h) => h.slice(0, 8) + '…';
const step = (n, state, html) => document.querySelectorAll(`[data-step="${n}"]`).forEach((li) => {
  li.dataset.state = state;
  if (html) li.querySelector('[data-step-detail]').innerHTML = html;
});
const resetSteps = () => { for (let n = 1; n <= 5; n++) step(n, 'wait'); };
let running = false;

async function rpcAt(url, method, params) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const rpc = (method, params) => rpcAt(RPC, method, params);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => '0x' + n.toString(16);

async function runRescue() {
  if (running) return;
  const wallet = window.ethereum;
  resetSteps();
  if (!wallet) {
    step(1, 'fail', 'No browser wallet found. Install MetaMask and add some Base Sepolia test ETH.');
    status('Run a rescue needs a browser wallet. The steps below show what it would do.');
    return;
  }
  running = true;
  let n = 1;
  try {
    const [wait] = await call(A.user, SEL.wait);
    if (wait > 0n) { status(`Someone ran one just now. The next run opens in ${wait} seconds.`); return; }

    step(1, 'now', 'Approve the connection in your wallet');
    status('Step 1 of 5: connect your wallet.');
    const [from] = await wallet.request({ method: 'eth_requestAccounts' });
    try {
      await wallet.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.chainId }] });
    } catch (e) {
      if (e.code !== 4902) throw e;
      await wallet.request({ method: 'wallet_addEthereumChain', params: [CHAIN] });
    }
    step(1, 'done', `Connected ${short(from)} on Base Sepolia`);

    n = 2;
    step(2, 'now', 'Confirm in your wallet: DemoLoan.run(), no tokens or approvals');
    status('Step 2 of 5: confirm the transaction in your wallet.');
    const lasnaFrom = Number(await rpcAt(LASNA, 'eth_blockNumber', [])) - 2;
    const data = demoMode === 0 ? SEL.run : SEL.runWithMode + demoMode.toString(16).padStart(64, '0');
    const hash = await wallet.request({ method: 'eth_sendTransaction', params: [{ from, to: A.user, data }] });
    step(2, 'done', `Sent ${txLink(hash, short(hash))}`);

    n = 3;
    step(3, 'now', 'Waiting for the transaction to land on Base');
    status('Step 3 of 5: waiting for your transaction.');
    let receipt;
    for (let i = 0; i < 120 && !receipt; i++) { receipt = await rpc('eth_getTransactionReceipt', [hash]); if (!receipt) await sleep(500); }
    if (!receipt || receipt.status !== '0x1') throw new Error('the transaction did not go through');
    const start = Number(receipt.blockNumber);
    step(3, 'done', `WETH $1,950 then $1,800 in block ${txLink(hash, start)}. Health factor 1.20, 1.17, then 1.08`);
    safe(readLoan);

    n = 4;
    step(4, 'now', 'Waiting for ShieldReactive on Reactive Lasna');
    step(5, 'now', 'Waiting for the rescue callback on Base');
    const t0 = performance.now();
    const userTopic = '0x' + arg(A.user);
    let requested = false;
    for (let i = 0; i < 120; i++) {
      const secs = ((performance.now() - t0) / 1000).toFixed(1);
      status(`Steps 4 and 5: the loop is running on its own. ${secs} s since your price drop landed.`);
      if (!requested) {
        const head = Number(await rpcAt(LASNA, 'eth_blockNumber', []));
        const req = await rpcAt(LASNA, 'eth_getLogs', [{ address: REACTIVE, topics: [REQUESTED, userTopic], fromBlock: hex(lasnaFrom), toBlock: hex(head) }]);
        if (req.length) {
          requested = true;
          const [reqHf, reqPrice, hint] = words(req[0].data);
          const why = hint > 0n
            ? `at ${usd(reqPrice)}, before the trigger: HF ${hf(reqHf)} if the fall continues to ${usd(hint)}`
            : `at ${usd(reqPrice)}, HF ${hf(reqHf)}`;
          step(4, 'done', `ShieldReactive asked for a rescue ${why}, in Lasna block ${link(`${LASNA_SCAN}/block/${Number(req[0].blockNumber)}`, Number(req[0].blockNumber))}`);
        }
      }
      const head = Number(await rpc('eth_blockNumber', []));
      const logs = await rpc('eth_getLogs', [{ address: A.shield, topics: [RESCUED, userTopic], fromBlock: hex(start), toBlock: hex(Math.min(head, start + 199)) }]);
      if (logs.length) {
        const blocks = Number(logs[0].blockNumber) - start;
        const [supplied, fee, , after] = words(logs[0].data);
        if (!requested) step(4, 'done', 'ShieldReactive asked for a rescue on Lasna');
        const rcpt = await rpc('eth_getTransactionReceipt', [logs[0].transactionHash]);
        const detail = (rcpt?.logs || []).find((x) => x.topics?.[0] === DETAIL);
        const repaid = detail ? words(detail.data)[0] : 0n;
        const what = [supplied > 0n ? `added ${eth(supplied, 5)} WETH` : '', repaid > 0n ? `repaid ${(Number(repaid) / 1e6).toFixed(2)} USDC` : '']
          .filter(Boolean).join(' and ');
        step(5, 'done', `${what.charAt(0).toUpperCase() + what.slice(1)}, fee ${eth(fee, 4)}. Health factor ${hf(after)}, ${blocks} blocks (${(blocks * 0.2).toFixed(1)} s) after the drop. ${txLink(logs[0].transactionHash, 'Rescue tx')}`);
        status(`Rescued ${(blocks * 0.2).toFixed(1)} s after the price drop. The loan on the right is safe again.`);
        safe(readLoan); safe(readRescues);
        return;
      }
      await sleep(500);
    }
    n = requested ? 5 : 4;
    throw new Error('no rescue within a minute; the Reactive contract may be out of lREACT');
  } catch (e) {
    const msg = e.code === 4001 ? 'Cancelled in your wallet. Nothing was sent.' : 'Stopped: ' + (e.message || e);
    step(n, 'fail', msg);
    for (let k = n + 1; k <= 5; k++) step(k, 'wait');
    status(msg);
  } finally {
    running = false;
  }
}

// the main button scrolls to the live loan (its href) and starts a run there
document.querySelectorAll('[data-run]').forEach((b) => b.addEventListener('click', () => { runRescue(); }));
