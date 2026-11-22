# Parapet: a self-funding liquidation shield on Reactive Omni

**Track:** Every Second Counts · **Networks:** Reactive Lasna + Base Sepolia (+ Ethereum Sepolia as a lead feed) · **Live dashboard:** [parapet-shield.vercel.app](https://parapet-shield.vercel.app/) ([`dashboard/`](dashboard/))

When a borrower's collateral price drops, an Aave-style loan can be liquidated in the same block: the liquidator
takes a bonus (5% on WETH in Aave V3). Parapet watches the price feed itself through a Reactive contract and acts
while the loan is still above 1.0. It requests a rescue when the loan crosses its trigger, or one price step
earlier when the price is falling fast. The rescue lands about six Base blocks (1.2 s, median of 20 rounds on the
first version) after the price event, with no keeper bot and no server. It either adds collateral or repays debt,
by the smallest amount that restores the borrower's target. It charges **0.3% of the value it moves** (floor
0.0001 ETH, gas included). That fee is unwrapped to ETH inside the shield, where Reactive's callback proxy takes
the callback gas from it, so the destination side runs with no one topping it up.

> **Status.** The code on this branch is ahead of the contracts deployed on testnet. The addresses, transaction
> hashes and the 1.2 s benchmark below are from the first version (top-ups only, one price feed). Redeploy with
> `script/deploy.sh`, then re-run `script/bench.sh` and update the tables before submitting.

## In plain words

- **The problem.** You borrow USDC against WETH. If WETH falls far enough, anyone may repay part of your loan
  and take your WETH at a discount (Aave's liquidation bonus, about 5%). On Base, 37% of Aave liquidations land
  in the same block as the price update ([Signals and Spoils, 2026](https://arxiv.org/pdf/2606.03434)).
- **What Parapet does.** You leave some spare WETH (and, if you like, USDC) with Parapet and say when to act
  (a health factor, for example 1.15) and how far to recover (for example 1.40). When the price pushes your loan
  under 1.15, or is falling fast enough that the next update would, Parapet either adds your spare WETH as
  collateral or repays part of your debt with your spare USDC, just enough to bring it back to 1.40.
- **Why repaying is cheaper.** Repaying debt needs target ÷ liquidation threshold times less money than adding
  collateral: 1.40 ÷ 0.825 = 1.7 times less in the demo. A USDC reserve also doesn't lose value in the crash
  it is meant to cover.
- **What it costs.** 0.3% of what a rescue moves (at least 0.0001 WETH), against the ~5% you would lose to a
  liquidation, plus a small daily watch fee (0.00001 WETH by default) for keeping your loan watched.
- **Why it is fast and needs no bot.** No server watches your loan. A Reactive contract on Reactive Network is
  subscribed to the price feed's events, so the price change itself starts the rescue.
- **What you can always do.** Take your reserves back, change your trigger and target, switch mode, or stop
  protection. Parapet can only add collateral to your loan or repay your debt; it can never withdraw collateral or
  move your funds elsewhere.

## Why it matters

| Date | Event | Liquidated or lost | Source |
|---|---|---|---|
| 12 March 2020 | Black Thursday, MakerDAO zero-bid auctions | $8.32M of collateral sold for 0 DAI | [analysis](https://medium.com/@whiterabbit_hq/black-thursday-for-makerdao-8-32-million-was-liquidated-for-0-dai-36b83cac56b6) |
| 19 May 2021 | Market crash | $377M on Aave, Compound and Maker in a day | [Cointelegraph](https://cointelegraph.com/news/cointelegraph-consulting-defi-hit-by-a-tsunami-of-liquidations-in-may) |
| 5 August 2024 | Global sell-off | $237M to $253M on Aave V3 | [The Defiant](https://thedefiant.io/news/defi/crypto-crash-wipes-out-defi-borrowers-as-all-time-aave-v3-liquidations-double) |
| 10 October 2025 | Tariff crash | over $250M on Aave in a day | [Aave](https://aave.com/blog/historical-liquidations) |
| 31 Jan – 5 Feb 2026 | Sell-off | $429M on Aave, a record | [Aave](https://aave.com/blog/historical-liquidations) |
| 10 March 2026 | wstETH oracle capped 2.85% too low | $26M to $27M from 34 accounts | [The Block](https://www.theblock.co/post/393121/aave-oracle-glitch-wsteth) |

**What one liquidation costs, and what Parapet costs instead** (debt $100,000, LT 0.83, HF 1.08 after a drop):

| Outcome | Borrower pays |
|---|---|
| Liquidated just under HF 1.0 (50% close factor, 5% bonus) | about **$2,500** |
| Parapet adds collateral to reach HF 1.40 | top-up $38,554 (still yours), fee **$116** |
| Parapet repays debt to reach HF 1.40 | repays $22,857 of your debt, fee **$69** |

Sources and method: [`docs/research.md`](https://github.com/Om-Thanage/Parapet/blob/research/overnight/docs/research.md)
(on the `research/overnight` branch).

## Try it

Open the [dashboard](https://parapet-shield.vercel.app/), pick **Adding collateral** or **Repaying debt**, and
press **Run a rescue** with a browser wallet on Base Sepolia (a little test ETH for gas). It calls `DemoLoan.run()`
(or `runWithMode(1)`), which resets the demo loan (WETH back to $2,000, the last rescue undone, HF 1.2) and drops
WETH in two steps in one transaction: $1,950 (HF 1.17, still above the 1.15 trigger) and $1,800 (HF 1.08). The
page walks through five steps as they happen. Step 4 shows ShieldReactive asking for the rescue at the $1,950
step, before the trigger was crossed, because the price was falling fast. One run a minute for everyone; anyone
can refill the demo's reserve with `DemoLoan.topUp()`.

## Protect your own loan (testnet)

Everything runs on Base Sepolia with test tokens: test WETH is wrapped from Base Sepolia ETH, and test USDC is
borrowed from the demo pool. You need [Foundry](https://getfoundry.sh) (`cast`) and a wallet with about
0.01 Base Sepolia ETH; `$KEY` is that wallet's private key, kept in your own shell or `.env`. Take the addresses
from `deployments.env` after a deploy.

```bash
RPC=https://sepolia.base.org
. ./deployments.env   # WETH, USDC, POOL, SHIELD, ...
ME=$(cast wallet address --private-key $KEY)
tx() { cast send "$@" --rpc-url $RPC --private-key $KEY; }

# 1. Get 0.008 test WETH and let the pool and the shield use it (and USDC, for repay mode)
tx $WETH "deposit()" --value 0.008ether
for spender in $POOL $SHIELD; do
  tx $WETH "approve(address,uint256)" $spender $(cast max-uint)
  tx $USDC "approve(address,uint256)" $spender $(cast max-uint)
done

# 2. Open a loan: 0.005 WETH collateral, borrow 7 USDC (HF about 1.18 at $2,000)
tx $POOL "supply(address,uint256,address,uint16)" $WETH 5000000000000000 $ME 0
tx $POOL "borrow(address,uint256,uint256,uint16,address)" $USDC 7000000 2 0 $ME

# 3. Protect it: act under HF 1.15, recover to 1.40, keep 0.003 WETH in reserve
tx $SHIELD "protect(uint64,uint64,uint256)" 1150000000000000000 1400000000000000000 3000000000000000

# 3b. Optional: rescue by repaying debt instead (keep the WETH reserve: it pays the fee)
tx $USDC "mint(address,uint256)" $ME 10000000                     # test USDC faucet
tx $SHIELD "depositRepayReserve(uint256)" 10000000
tx $SHIELD "configure(uint64,uint64,uint64,uint8)" 1150000000000000000 1400000000000000000 0 1

# 4. Check it any time
cast call $POOL "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" $ME --rpc-url $RPC  # last value = HF
cast call $SHIELD "protections(address)(uint128,uint128,uint64,uint64,uint64,uint64,uint64,uint8,bool)" $ME --rpc-url $RPC
```

The next price drop under your trigger rescues you. Anyone's **Run a rescue** on the dashboard moves the shared
test price to $1,800, which takes this example loan to about 1.06, so it is rescued in the same second as the
demo loan.

| You want to | Call |
|---|---|
| Add more WETH reserve | `protect(trigger, target, amount)` again with the extra amount |
| Add USDC for repay mode | `depositRepayReserve(amount)` |
| Change when and how it acts | `configure(trigger, target, step, mode)`: mode 0 adds collateral, 1 repays debt, 2 repays first then adds; `step` > 0 rescues in stages of trigger + step |
| Take reserve back | `withdrawReserve(amount)` or `withdrawRepayReserve(amount)`; not while your loan is under its trigger |
| Stop protection | `unprotect()` returns both reserves at any time |
| Borrow more or add collateral yourself | do it on the pool, then `sync(yourAddress)` so the Reactive contract sees the new numbers |

On mainnet the shield would point at the real Aave V3 Pool and oracle. It only calls `getUserAccountData`,
`getConfiguration`, `supply(asset, amount, onBehalfOf, 0)` and `repay(asset, amount, 2, onBehalfOf)`, which Aave V3
has with the same signatures, and reads aToken balances. The reactive contract reads Chainlink's own
`AnswerUpdated` event (price in topic 1) and follows the feed when Chainlink swaps the aggregator behind its proxy.

## How it works

```
Base Sepolia                      Reactive Lasna                         Base Sepolia
Chainlink-style aggregator        ShieldReactive                         LiquidationShield
  AnswerUpdated  ──────────────▶  re-price loans whose trigger price ──▶ rescue(rvm, user, hint)
Chainlink-style proxy             is near the new price; rescue the       re-check live HF (at the hint,
  AggregatorConfirmed ─────────▶  ones under, or one step from, their     at most 5% under the oracle),
LiquidationShield                 trigger; follow a new aggregator        repay and/or supply the smallest
  PositionSnapshot ────────────▶  mirror collateral per asset, debt,      amount that restores the goal,
Ethereum Sepolia                  trigger, cooldown                       unwrap fee → ETH pays gas
  AnswerUpdated (lead) ────────▶  rescue ahead of Base's oracle        ──▶ refresh(rvm, users): re-publish
Reactive system contract                                                  stale loans, settle watch fees
  Cron100 ─────────────────────▶  sweep for missed loans, refresh stale
```

1. A borrower calls `protect(trigger, target, reserve)` on the shield (and optionally `depositRepayReserve` and
   `configure`). The shield emits `PositionSnapshot` with collateral per asset, liquidation thresholds, debt,
   trigger and cooldown. Loans that have never been active are not published.
2. `ShieldReactive` mirrors every snapshot. Single-asset loans go into buckets by the price at which they reach
   their trigger; loans with several collateral assets are checked on every tick.
3. On each `AnswerUpdated`, it checks only the buckets near the new price, highest risk first. It requests a
   `rescue(address,address,uint256)` callback for each loan under its trigger, and for each loan that would be
   under it if the price fell again by the same step (capped at 5%), passing that projected price as a hint. A
   tick has a gas budget (650k of Reactive's 900k limit); if a crash crosses more triggers than one tick can
   serve, the next tick carries on where it stopped.
4. A price update on the lead chain (Ethereum Sepolia) does the same, with the lead price as the hint, so the
   rescue can land before Base's own oracle moves.
5. `LiquidationShield.rescue` accepts only the callback proxy (`onlyServiceProvider`) carrying our reactive
   contract's address (`onlyCallbackSender`). It re-reads the live position, prices WETH at the hint (never more
   than 5% under the oracle), skips if it is healthy or in its 10 s cooldown, then repays and/or supplies the
   smallest amount that restores the goal. A short reserve gives a partial rescue.
6. The fee is unwrapped (`WETH.withdraw`) so it lands as native ETH; the callback proxy's `pay()` takes gas from
   that balance. `opsLedger()` and `feeBreakdown()` show fees, watch fees, outside funding, gas paid, skipped
   callbacks and fee-less rescues.
7. The shield emits a fresh snapshot, which clears the pending flag on Lasna. A rescue that never comes back stops
   blocking the loan after 60 s. Every `Cron100` tick sweeps a batch of loans and asks the shield to re-publish
   any whose mirror is a day old, since interest keeps adding to their debt.

## What is different

| | DeFi Saver / Instadapp | Reactive's CRON demo, ReacDEFI | Parapet |
|---|---|---|---|
| Trigger | off-chain bots | CRON (polling interval) / trigger HF | the price event itself, plus one price step early, plus a lead feed on another chain |
| Who runs it | the operator's bots | one contract per user (demo); ReacDEFI's service | one shared shield for every borrower, no bot |
| Rescue | repay (sells collateral) | add collateral, repay, or both | add collateral, repay, both, or in stages; smallest amount to the target |
| Fee | 0.05% + gas (DeFi Saver), 0.3–0.4% + gas (Instadapp) | not stated | 0.3% gas included, plus a small watch fee; shown on-chain |
| Funding | operator | topped up by hand | fees pay callback gas, shown on-chain |

Morpho's pre-liquidations take a different route: a softer liquidation band with a smaller bonus. Parapet avoids
the liquidation altogether and leaves the collateral with the borrower.

**Research it builds on:** Qin et al., *An Empirical Study of DeFi Liquidations* (IMC 2021): $807M liquidated in
28k events; Perez et al., *Liquidations: DeFi on a Knife-edge* (FC 2021): over 70% of liquidatable positions are
liquidated immediately, so a shield must act before HF 1.0; Sevim and Ferreira Torres, *Signals and Spoils*
(2026): liquidators use one chain's Chainlink update to predict another's, which is what the lead feed turns to the
borrower's side; Qin et al., *Mitigating DeFi Liquidations with Reversible Call Options* (Miqado, FC 2023): outside
top-ups cut liquidated collateral by 89.8% in simulation.

## Measured on live testnets (first version)

`script/bench.sh` resets the loan each round (price back to $2,000, collateral back to HF 1.2), drops WETH to
$1,800 (HF 1.08, under the 1.15 trigger) and counts Base blocks between the price transaction and the
`Rescued` event. At 200 ms a block, blocks × 0.2 s is the end-to-end latency. Results:
[`results/bench.csv`](results/bench.csv), summary in [`results/summary.txt`](results/summary.txt).

| Rounds | Rescued | Median | p90 | Fastest | Slowest | Mean |
|---|---|---|---|---|---|---|
| 20 | 20 | **1.2 s** (6 blocks) | 1.6 s | 1.0 s | 2.0 s | 1.35 s |

That is six blocks after the price update. Liquidators act in the update's own block, so Parapet's protection
comes from acting while HF is between the trigger and 1.0, and from the early request when the price is falling
fast, not from beating liquidators to a loan that is already liquidatable.

Self-funding, read from `opsLedger()` on Base Sepolia after 23 rescues: **0.0023 ETH in fees against
0.0000305 ETH of callback gas paid**, about 75 times over.

The reactive side is paid in REACT. The first version used about 0.04 lREACT per rescue cycle (two price events
and two or three snapshots). At the testnet faucet rate (100 lREACT per ETH) that is 0.0004 ETH, more than the
0.0001 ETH fee floor. At the mid-November 2026 market price of REACT (about $0.0023) it is about $0.0001, which the
floor covers many times over. The real mismatch is that watching costs gas on every price event for every loan,
while rescue fees only come in on rescues. The daily watch fee covers that, and buckets keep the per-event cost
down to the loans near their trigger. Bridging fee income to REACT and calling `depositTo` is still manual.

## Deployed contracts (first version)

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

### Full-loop transactions (origin event → callback), first version

| Loop | 1. Price event (Base) | 2. Reactive tx, `RescueRequested` (Lasna) | 3. Rescue callback (Base) | Base blocks |
|---|---|---|---|---|
| First demo | [`0xf6f1…a0a1`](https://base-sepolia.blockscout.com/tx/0xf6f1125010fd6c7a747a805c6ffcfb2213528ccaae164375cc3b1d57bbf5a0a1) | [`0x6020…31e8`](https://lasna.reactscan.net/tx/0x60208ef509b0422ba7f391a0ca7afe31105f97f17d9d7012bf9803bfa00d31e8) | [`0x1bc3…184c`](https://base-sepolia.blockscout.com/tx/0x1bc3e1a0e08e9823e6b3ec988a00d0cddfc0b1b75fe74fc9e82d89750e8f184c) | 10 (2.0 s) |
| Second demo | [`0xc11e…bf5c`](https://base-sepolia.blockscout.com/tx/0xc11e446208d96d23c5269fb41a6ee02926fc79131bdf6482d4ea7a8b3f41bf5c) | [`0x623c…1d19`](https://lasna.reactscan.net/tx/0x623c91ab32597e1639392160e76dc536aa5f30156ed98d5bf4ab860619341d19) | [`0x9ce1…4595`](https://base-sepolia.blockscout.com/tx/0x9ce10614e20ef705b748d1e2f604d406e3d1bbb9868a5a7ae7c6d6a4a1b44595) | 7 (1.4 s) |
| First `DemoLoan.run()` | [`0x76b6…77ab`](https://base-sepolia.blockscout.com/tx/0x76b6fcfae1e3420008758f92a8cc1d972cc7ac0a4083821ca3c36c3dc77877ab) | [`0x21cd…a413`](https://lasna.reactscan.net/tx/0x21cd56036006de8889f7fa787347620f10e852f14a2beccf5241a622e3bfa413) | [`0xb1b4…0056`](https://base-sepolia.blockscout.com/tx/0xb1b4cf4a96a58c32ed501b2760a73c5fb00c0b84d70df3f1628b3a99c2830056) | 7 (1.4 s) |

## Run it yourself

Needs [Foundry](https://getfoundry.sh), `jq`, and a testnet wallet with Base Sepolia ETH, a little Ethereum
Sepolia ETH (for the lead feed), and Lasna lREACT (send Sepolia ETH to the faucet
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, 1 ETH → 100 lREACT).

```bash
cp .env.example .env              # then put your testnet PRIVATE_KEY in .env (or point ENV_FILE at another file)
forge test                        # 43 tests: modes, early trigger, lead feed, buckets, CRON, worst-case gas, fuzz
bash script/deploy.sh             # predicts every address, deploys lead feed, Lasna, then Base; writes deployments.env
node script/export-deployment.mjs # points the dashboard at the new deployment
bash script/demo.sh 1800          # opens and protects a loan, crashes WETH, times the rescue
bash script/lead.sh 1900          # moves the lead feed first: the rescue lands before Base's oracle moves
bash script/bench.sh 20           # 20 timed rounds -> results/bench.csv (START=n continues a run)
node script/export-bench.mjs      # feeds the dashboard's speed section
```

Open the dashboard over any static server (for example `npx serve dashboard`). It reads the contracts over
Base Sepolia's and Lasna's public RPCs and the `Rescued` events from Blockscout, and refreshes every 10 seconds.

## Submission checklist

| The brief asks for | Where it is |
|---|---|
| Public repository | this repository (MIT licence for our code; libraries keep their own) |
| Deployed contract addresses | [Deployed contracts](#deployed-contracts-first-version), all source-verified; redeploy pending for this version |
| Transaction hashes for the full loop, origin event to callback | [Full-loop transactions](#full-loop-transactions-origin-event--callback-first-version) |
| Demo video under three minutes | link to be added |
| Track: Every Second Counts on Base Sepolia | Reactive Lasna + Base Sepolia; latency in [Measured on live testnets](#measured-on-live-testnets-first-version) |
| Built during the event | every commit is from November 2026, inside the event; `forge-std` and `reactive-lib-omni` are dependencies |
| Timestamps, not block counts, for timers on Base | the shield's 10 s cooldown, the 60 s pending timeout and DemoLoan's 60 s cooldown use timestamps |

## Repository

| Path | What |
|---|---|
| `src/LiquidationShield.sol` | destination contract: reserves, modes, rescue maths, fee → gas, watch fee, ops ledger |
| `src/ShieldReactive.sol` | reactive contract: mirrors loans, buckets, early and lead-feed requests, aggregator following, CRON |
| `src/DemoLoan.sol` | a protected loan anyone can reset and crash in two steps, in either mode |
| `src/mocks/` | lending pool with Aave V3's signatures and maths (two collateral assets), Chainlink-style feeds, test tokens |
| `test/Shield.t.sol` | 43 tests with a mocked system contract and callback proxy |
| `script/` | deploy, demo, lead feed, benchmark, exports |
| `dashboard/` | the live page |

## Limits

- The pool is a mock with Aave V3's interface, because Aave's testnet oracle price can't be moved for a demo.
- Collateral top-ups and fees are in WETH. Other collateral assets are watched and priced, but a rescue tops up
  with WETH.
- The price hint (projected or lead price) is trusted up to 5% under the oracle. A manipulated lead feed can make
  a borrower top up early with their own funds, plus one fee; it cannot move funds anywhere else.
- On mainnet, the REACT that pays for Reactive execution would be bought with fees and sent across with
  `depositTo`; on testnet the reactive contract is funded by hand.
- A crash that crosses more triggers than one tick's gas budget is served over the following ticks or CRON sweeps,
  highest risk first.
