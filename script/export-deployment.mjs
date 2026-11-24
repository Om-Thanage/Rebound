// Writes dashboard/data/deployment.json from deployments.env, so the dashboard reads the latest deployment.
// Usage: node script/export-deployment.mjs   (after script/deploy.sh)
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const env = Object.fromEntries(readFileSync(new URL('../deployments.env', import.meta.url), 'utf8')
  .split('\n').filter((l) => l.includes('=')).map((l) => l.split('=').map((x) => x.trim())));
const need = ['DEMO', 'WETH', 'ORACLE', 'POOL', 'SHIELD', 'REACTIVE'];
const missing = need.filter((k) => !env[k]);
if (missing.length) throw new Error(`deployments.env is missing ${missing.join(', ')}`);

const out = { user: env.DEMO, deployer: env.DEPLOYER, weth: env.WETH, oracle: env.ORACLE, pool: env.POOL, shield: env.SHIELD, reactive: env.REACTIVE };
if (process.env.DASHBOARD_RPC) out.rpc = process.env.DASHBOARD_RPC; // local testing only
if (process.env.DASHBOARD_LASNA_RPC) out.lasnaRpc = process.env.DASHBOARD_LASNA_RPC;
mkdirSync(new URL('../dashboard/data/', import.meta.url), { recursive: true });
writeFileSync(new URL('../dashboard/data/deployment.json', import.meta.url), JSON.stringify(out, null, 2) + '\n');
console.log(out);
