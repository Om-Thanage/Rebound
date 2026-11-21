// Live data for the dashboard: reads the shield, the pool and the oracle on Base Sepolia over JSON-RPC,
// the shield's Rescued events from Blockscout, and the benchmark from data/bench.json.
const RPC = 'https://sepolia.base.org';
const SCOUT = 'https://base-sepolia.blockscout.com';
const A = {
  user: '0x0d3d64fe02614136e92aB630E8BF9Db3E2E22BdF', // DemoLoan: the loan visitors crash with Run a rescue
  weth: '0xac1f5822da429129e15aB706D3888769De7d5cF4',
  oracle: '0x49074f7961c01416cf5A57d13df664C32fb33345',
  pool: '0x398ED21C0F95cb4F5c444CAe0F9EeB07b1689e5c',
  shield: '0x3796897b27240f329b32184f2C2cBd6666A1EeaE',
};
const SEL = { account: '0xbf92857c', price: '0xb3596f07', prot: '0x613e3fc0', ledger: '0x30b7c49f', collateral: '0xa5fdc5de', debt: '0x9b6c56ec', count: '0x98e78023', run: '0xc0406226', wait: '0xccca123b' };
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
safe(readBench);
safe(readRescues);
safe(readLoan);
setInterval(() => { safe(readLoan); safe(readRescues); }, 10_000);

// ---- Run a rescue: the visitor's wallet calls DemoLoan.run(), then we time the rescue on Base Sepolia
const CHAIN = { chainId: '0x14a34', chainName: 'Base Sepolia', rpcUrls: [RPC],
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, blockExplorerUrls: [SCOUT] };
const status = (html) => document.querySelectorAll('[data-run-status]').forEach((el) => { el.innerHTML = html; });
const txLink = (h, label) => `<a href="${SCOUT}/tx/${h}" target="_blank" rel="noopener">${label}</a>`;
let running = false;

async function rpc(method, params) {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function runRescue() {
  if (running) return;
  const eth = window.ethereum;
  if (!eth) { status('Run a rescue needs a browser wallet such as MetaMask, set to Base Sepolia with a little test ETH.'); return; }
  running = true;
  try {
    const [wait] = await call(A.user, SEL.wait);
    if (wait > 0n) { status(`Someone ran one just now. The next run opens in ${wait} seconds.`); return; }
    status('Connect your wallet to continue.');
    const [from] = await eth.request({ method: 'eth_requestAccounts' });
    try {
      await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.chainId }] });
    } catch (e) {
      if (e.code !== 4902) throw e;
      await eth.request({ method: 'wallet_addEthereumChain', params: [CHAIN] });
    }
    status('Confirm the transaction in your wallet. It resets the loan, then drops WETH to $1,800.');
    const hash = await eth.request({ method: 'eth_sendTransaction', params: [{ from, to: A.user, data: SEL.run }] });
    status(`Sent ${txLink(hash, hash.slice(0, 10) + '…')}. Waiting for it to land.`);

    let receipt;
    for (let i = 0; i < 120 && !receipt; i++) { receipt = await rpc('eth_getTransactionReceipt', [hash]); if (!receipt) await sleep(500); }
    if (!receipt || receipt.status !== '0x1') { status(`The transaction ${txLink(hash, 'failed')}. Nothing changed.`); return; }
    const start = Number(receipt.blockNumber);
    safe(readLoan);

    const t0 = performance.now();
    const topics = [RESCUED, '0x' + arg(A.user)];
    for (let i = 0; i < 120; i++) {
      status(`WETH dropped to $1,800 in block ${start}. Waiting for the rescue: ${((performance.now() - t0) / 1000).toFixed(1)} s`);
      const head = Number(await rpc('eth_blockNumber', []));
      const logs = await rpc('eth_getLogs', [{ address: A.shield, topics, fromBlock: '0x' + start.toString(16), toBlock: '0x' + Math.min(head, start + 199).toString(16) }]);
      if (logs.length) {
        const blocks = Number(logs[0].blockNumber) - start;
        status(`Rescued ${blocks} blocks later, ${(blocks * 0.2).toFixed(1)} s after the price drop. Health factor back to 1.40. ${txLink(hash, 'Price drop')} · ${txLink(logs[0].transactionHash, 'Rescue')}`);
        safe(readLoan); safe(readRescues);
        return;
      }
      await sleep(500);
    }
    status(`No rescue within a minute. The Reactive contract may be out of lREACT. ${txLink(hash, 'Your transaction')}`);
  } catch (e) {
    status(e.code === 4001 ? 'Cancelled in your wallet. Nothing was sent.' : 'Something went wrong: ' + (e.message || e));
  } finally {
    running = false;
  }
}

// the main button scrolls to the live loan (its href) and starts a run there
document.querySelectorAll('[data-run]').forEach((b) => b.addEventListener('click', () => { runRescue(); }));
