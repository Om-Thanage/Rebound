// Writes dashboard/data/rescues.json: every Rescued and RescueDetail log of the shield, read from a Base Sepolia RPC
// in 20,000-block chunks, so the dashboard shows the full history without Blockscout's rate-limited API.
// The page adds rescues after `toBlock` from the RPC itself.
// Usage: node script/export-rescues.mjs   (after deploy.sh; re-run after a benchmark)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const env = Object.fromEntries(readFileSync(new URL('../deployments.env', import.meta.url), 'utf8')
  .split(/\r?\n/).filter((l) => l.includes('=')).map((l) => l.split('=').map((x) => x.trim())));
const RPC = process.env.LOGS_RPC || 'https://base-sepolia-rpc.publicnode.com'; // accepts wide eth_getLogs ranges
const FROM = Number(process.env.FROM_BLOCK || env.DEPLOY_BLOCK || 62030000); // v2 was deployed just after this block
const CHUNK = 20000;
const TOPICS = {
  rescued: '0x28b6c2526f0d05eac057487199a229c2584389d09c1a5b014dcf02610fdd8419',
  detail: '0xd6a7d2fcb36c3966223a7015df24966d5b6b9a16ae2770e4708df14e86565b3f',
};
const rpc = async (method, params) => {
  const r = await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
};
const head = Number(await rpc('eth_blockNumber', []));

async function logs(topic) {
  const all = [];
  for (let from = FROM; from <= head; from += CHUNK) {
    const to = Math.min(head, from + CHUNK - 1);
    const got = await rpc('eth_getLogs', [{ address: env.SHIELD, topics: [topic], fromBlock: '0x' + from.toString(16), toBlock: '0x' + to.toString(16) }]);
    all.push(...got.map(({ transactionHash, blockNumber, topics, data }) => ({ transactionHash, blockNumber, topics, data })));
  }
  return all;
}

const out = { shield: env.SHIELD, toBlock: head, rescued: await logs(TOPICS.rescued), detail: await logs(TOPICS.detail) };
console.assert(out.rescued.every((l) => l.topics[0] === TOPICS.rescued), 'unexpected topic');
mkdirSync(new URL('../dashboard/data/', import.meta.url), { recursive: true });
writeFileSync(new URL('../dashboard/data/rescues.json', import.meta.url), JSON.stringify(out, null, 1) + '\n');
console.log(`${out.rescued.length} rescues, ${out.detail.length} rescue details (repaid debt and price hint per rescue)`);
