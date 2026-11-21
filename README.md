# Parapet: a self-funding liquidation shield on Reactive Omni

**Track:** Every Second Counts · **Networks:** Reactive Lasna + Base Sepolia · **Live dashboard:** [dashboardparapet.vercel.app](https://dashboardparapet.vercel.app/) ([`dashboard/`](dashboard/))

When a borrower's collateral price drops, an Aave-style loan can be liquidated in seconds, and the liquidator
takes a bonus (about 5% on WETH in Aave V3). Parapet watches the price event itself through a Reactive
contract and tops the loan back up **about 1.2 seconds** (median of 20 rounds) after the price moves, with no keeper bot and no
server. It charges **0.3% of the collateral it adds** (floor 0.0001 ETH). That fee is unwrapped to ETH inside
the shield, where Reactive's callback proxy takes the callback gas from it, so the destination side runs
with no one topping it up.

## Try it

Open the [dashboard](https://dashboardparapet.vercel.app/) and press **Run a rescue** with a browser wallet on
Base Sepolia (a little test ETH for gas). It calls `DemoLoan.run()`, which resets the demo loan (WETH back to
$2,000, the last top-up returned to the shield reserve, HF 1.2) and drops WETH to $1,800 in one transaction.
The page then walks through five steps as they happen: wallet connected, transaction sent, loan under its trigger on Base, `RescueRequested` from ShieldReactive on Lasna, and the `Rescued` event on Base, usually 5 to 8 Base blocks after the price drop.
One run a minute for everyone.

## How it works

```
Base Sepolia                        Reactive Lasna                      Base Sepolia
MockAaveOracle                      ShieldReactive                      LiquidationShield
  AssetPriceUpdated  ───────────▶   react(): re-price every    ───▶    rescue(rvm, user)
                                    mirrored loan; callback              re-check live HF,
LiquidationShield                   for each under its trigger           supply the smallest top-up
  PositionSnapshot   ───────────▶   mirror collateral, debt,             that restores the target,
                                    LT, trigger; clear pending           unwrap fee → ETH pays gas
```

1. A borrower calls `protect(trigger, target, reserve)` on the shield and parks a WETH reserve there. The
   shield emits `PositionSnapshot`.
2. `ShieldReactive` (Lasna) mirrors every snapshot. On each oracle `AssetPriceUpdated` it recomputes every
   mirrored health factor with Aave's formula, and for each loan under its trigger it marks it pending and
   calls `SYSTEM.requestCallbackV_1_0(...)` targeting `rescue(address,address)` on Base.
3. `LiquidationShield.rescue` accepts only the callback proxy (`onlyServiceProvider`) carrying our reactive
   contract's address (`onlyCallbackSender`). It re-reads the live position, skips if it is already healthy
   or in its 10 s cooldown (timestamps, not blocks: Base Sepolia makes 200 ms blocks), then supplies
   `ceil(target × debt / LT) − collateral` worth of WETH on the borrower's behalf through the pool's
   Aave V3 `supply(asset, amount, onBehalfOf, 0)`. A short reserve gives a partial rescue.
4. The fee is unwrapped (`WETH.withdraw`) so it lands as native ETH; the callback proxy's `pay()` takes gas
   from that balance. `opsLedger()` shows fees earned, outside funding, gas paid, balance and debt.
5. The shield emits a fresh snapshot, which clears the pending flag on Lasna.

## What is different

| | Reactive's own `aave-liquidation-protection` demo | Parapet |
|---|---|---|
| Trigger | CRON, every minute | the price event itself (seconds) |
| Who runs it | each user deploys and funds a callback contract | one shared shield for every borrower |
| Funding | topped up by hand | 0.3% rescue fee pays callback gas, shown on-chain |
| Rescue size | target health factor | smallest top-up to the target, rounded up so the pool's own rounding can't leave it short |

Other buildathon entries on liquidations (Lien, AegisDeleverage, Liquidation Guardian) use fixed reserves or
fixed 25% steps and don't charge for the service; Parapet's pitch is that it keeps running without anyone
refilling it.

**Research it builds on:** Qin et al., *An Empirical Study of DeFi Liquidations* (IMC 2021): liquidators
over-sell discounted collateral, $807M liquidated in 28k events; Perez et al., *Liquidations: DeFi on a
Knife-edge* (FC 2021): over 70% of liquidatable positions are liquidated immediately, so a shield must act
before HF 1.0; Qin et al., *Mitigating DeFi Liquidations with Reversible Call Options* (Miqado, 2023): outside
top-ups cut liquidated collateral by 89.8% in simulation. Fee benchmark: DeFi Saver charges 0.05% per
automated action plus gas.

## Measured on live testnets

`script/bench.sh` resets the loan each round (price back to $2,000, collateral back to HF 1.2), drops WETH to
$1,800 (HF 1.08, under the 1.15 trigger) and counts Base blocks between the price transaction and the
`Rescued` event. At 200 ms a block, blocks × 0.2 s is the end-to-end latency. Results:
[`results/bench.csv`](results/bench.csv), summary in [`results/summary.txt`](results/summary.txt).

| Rounds | Rescued | Median | p90 | Fastest | Slowest | Mean |
|---|---|---|---|---|---|---|
| 20 | 20 | **1.2 s** (6 blocks) | 1.6 s | 1.0 s | 2.0 s | 1.35 s |

Every rescue lifted the health factor from 1.08 to 1.40. A first 20-round run stopped rescuing after round
17 because the reactive contract ran out of lREACT (the system contract stops calling `react()` while a
contract owes it); after a 0.5 lREACT `depositTo`, the loan was re-synced and rounds 18 to 20 were rerun.

Self-funding, read from `opsLedger()` on Base Sepolia after 23 rescues: **0.0023 ETH in fees against
0.0000305 ETH of callback gas paid**, about 75 times over; the 0.002 ETH seed sent at deploy is untouched and
the shield owes the proxy nothing.

The reactive side is the real cost. Watching and re-pricing used about 1 lREACT across deploy, the two demos
and the 23 rescue cycles, roughly 0.04 lREACT per cycle (each cycle is two price events and two or three
snapshots). At the faucet rate of 100 lREACT per ETH that is about 0.0004 ETH, more than the 0.0001 ETH fee
floor, so today the fee covers Base gas but not Lasna execution. Raising the floor, or charging a small
monthly fee per watched loan, would close that gap; the mainnet REACT price decides the numbers.

## Deployed contracts

| Contract | Network | Address |
|---|---|---|
| ShieldReactive | Reactive Lasna (5318007) | [`0x2C7AD06885D413E1dCd9CEa886467D1Bc8f234c4`](https://lasna.reactscan.net/address/0x2C7AD06885D413E1dCd9CEa886467D1Bc8f234c4) |
| LiquidationShield | Base Sepolia (84532) | [`0x3796897b27240f329b32184f2C2cBd6666A1EeaE`](https://base-sepolia.blockscout.com/address/0x3796897b27240f329b32184f2C2cBd6666A1EeaE) |
| MockAavePool | Base Sepolia | [`0x398ED21C0F95cb4F5c444CAe0F9EeB07b1689e5c`](https://base-sepolia.blockscout.com/address/0x398ED21C0F95cb4F5c444CAe0F9EeB07b1689e5c) |
| MockAaveOracle | Base Sepolia | [`0x49074f7961c01416cf5A57d13df664C32fb33345`](https://base-sepolia.blockscout.com/address/0x49074f7961c01416cf5A57d13df664C32fb33345) |
| Test WETH | Base Sepolia | [`0xac1f5822da429129e15aB706D3888769De7d5cF4`](https://base-sepolia.blockscout.com/address/0xac1f5822da429129e15aB706D3888769De7d5cF4) |
| DemoLoan | Base Sepolia | [`0x0d3d64fe02614136e92aB630E8BF9Db3E2E22BdF`](https://base-sepolia.blockscout.com/address/0x0d3d64fe02614136e92aB630E8BF9Db3E2E22BdF) |
| Test USDC | Base Sepolia | [`0xA91733b5641d627eD461420D0EC1D1277fC7bF37`](https://base-sepolia.blockscout.com/address/0xA91733b5641d627eD461420D0EC1D1277fC7bF37) |

Callback proxy on Base Sepolia: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`. Source is verified for every Base Sepolia contract (WETH and USDC on Blockscout, the rest on Sourcify as exact matches).

### Full-loop transactions (origin event → callback)

| Price event (Base) | Rescue callback (Base) | Blocks |
|---|---|---|
| [`0xf6f1…a0a1`](https://base-sepolia.blockscout.com/tx/0xf6f1125010fd6c7a747a805c6ffcfb2213528ccaae164375cc3b1d57bbf5a0a1) | [`0x1bc3…184c`](https://base-sepolia.blockscout.com/tx/0x1bc3e1a0e08e9823e6b3ec988a00d0cddfc0b1b75fe74fc9e82d89750e8f184c) | 10 (2.0 s) |
| [`0xc11e…bf5c`](https://base-sepolia.blockscout.com/tx/0xc11e446208d96d23c5269fb41a6ee02926fc79131bdf6482d4ea7a8b3f41bf5c) | [`0x9ce1…4595`](https://base-sepolia.blockscout.com/tx/0x9ce10614e20ef705b748d1e2f604d406e3d1bbb9868a5a7ae7c6d6a4a1b44595) | 7 (1.4 s) |

Every benchmark round adds a pair; see `results/bench.csv`.

## Run it yourself

Needs [Foundry](https://getfoundry.sh), `jq`, and a testnet wallet with Base Sepolia ETH and Lasna lREACT
(send Sepolia ETH to the faucet `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, 1 ETH → 100 lREACT).

```bash
cp .env.example .env        # then put your testnet PRIVATE_KEY in .env
forge test                  # 14 tests, incl. a 256-run fuzz test of the rescue maths
bash script/deploy.sh       # predicts both addresses, deploys Lasna then Base, writes deployments.env
bash script/demo.sh 1800    # opens and protects a loan, crashes WETH, times the rescue
bash script/bench.sh 20     # 20 timed rounds -> results/bench.csv (START=n continues a run)
node script/export-bench.mjs  # feeds the dashboard's speed section
```

Open the dashboard over any static server (for example `npx serve dashboard`). It reads the contracts over
Base Sepolia's public RPC and the `Rescued` events from Blockscout, and refreshes every 10 seconds.

## Repository

| Path | What |
|---|---|
| `src/LiquidationShield.sol` | destination contract: reserves, rescue, fee → gas, ops ledger |
| `src/DemoLoan.sol` | a protected loan anyone can reset and crash in one call, for the dashboard's Run a rescue |
| `src/ShieldReactive.sol` | reactive contract: mirrors loans, re-prices on each price event, requests callbacks |
| `src/mocks/` | lending pool with Aave V3's signatures and HF maths, settable oracle, test tokens |
| `test/Shield.t.sol` | full loop with a mocked system contract and callback proxy, auth, cooldown, partial rescue, fuzz |
| `script/` | deploy, demo, benchmark, export |
| `dashboard/` | the live page |

## Limits

- The pool is a mock with Aave V3's interface, because Aave's testnet oracle price can't be moved for a demo.
  The shield only calls `getUserAccountData` and `supply(..., onBehalfOf, 0)`, both real Aave V3 calls.
- One collateral asset (WETH) per position; the reactive contract re-prices every loan on each tick, which is
  fine for dozens of loans (bucket by liquidation price beyond that).
- On mainnet, the REACT that pays for Lasna execution would be bought with fees on Uniswap and sent across;
  on testnet the reactive contract was funded by hand (1 lREACT at deploy, 0.5 more after it ran dry).
- If a callback never lands, the loan stays pending on Lasna until its next snapshot (`sync(user)`).
