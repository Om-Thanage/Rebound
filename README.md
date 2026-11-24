# Rebound: a self-funding liquidation shield on Reactive Omni

**Track:** Every Second Counts · **Networks:** Reactive Lasna + Base Sepolia (+ Ethereum Sepolia as a lead feed) · **Live dashboard:** [tryrebound.omthanage.dev](https://tryrebound.omthanage.dev/) ([`dashboard/`](dashboard/))

When a borrower's collateral price drops, an Aave-style loan can be liquidated in the same block: the liquidator
takes a bonus (5% on WETH in Aave V3). Rebound watches the price feed itself through a Reactive contract and acts
while the loan is still above 1.0. It requests a rescue when the loan crosses its trigger, or one price step
earlier when the price is falling fast. The rescue lands about seven Base blocks (1.4 s, median of 10 rounds on the
deployed version) after the price event, with no keeper bot and no server. It either adds collateral or repays debt,
by the smallest amount that restores the borrower's target. It charges **0.3% of the value it moves** (floor
0.0001 ETH, gas included). That fee is unwrapped to ETH inside the shield, where Reactive's callback proxy takes
the callback gas from it, so the destination side runs with no one topping it up. The Reactive side is not
self-funding yet: its lREACT is topped up by hand, and while it is empty no rescue is requested.

## In plain words

- **The problem.** You borrow USDC against WETH. If WETH falls far enough, anyone may repay part of your loan
  and take your WETH at a discount (Aave's liquidation bonus, about 5%). On Base, 37% of Aave liquidations land
  in the same block as the price update ([Signals and Spoils, 2026](https://arxiv.org/pdf/2606.03434)).
- **What Rebound does.** You leave some spare WETH (and, if you like, USDC) with Rebound and say when to act
  (a health factor, for example 1.15) and how far to recover (for example 1.40). When the price pushes your loan
  under 1.15, or is falling fast enough that the next update would, Rebound either adds your spare WETH as
  collateral or repays part of your debt with your spare USDC, just enough to bring it back to 1.40.
- **Why repaying is cheaper.** Repaying debt needs target ÷ liquidation threshold times less money than adding
  collateral: 1.40 ÷ 0.825 = 1.7 times less in the demo. A USDC reserve also doesn't lose value in the crash
  it is meant to cover.
- **What it costs.** 0.3% of what a rescue moves (at least 0.0001 WETH), against the ~5% you would lose to a
  liquidation, plus a small daily watch fee (0.00001 WETH by default) for keeping your loan watched.
- **Why it is fast and needs no bot.** No server watches your loan. A Reactive contract on Reactive Network is
  subscribed to the price feed's events, so the price change itself starts the rescue.
- **What you can always do.** Take your reserves back, change your trigger and target, switch mode, or stop
  protection. Rebound can only add collateral to your loan or repay your debt; it can never withdraw collateral or
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

**What one liquidation costs, and what Rebound costs instead** (debt $100,000, LT 0.83, HF 1.08 after a drop):

| Outcome | Borrower pays |
|---|---|
| Liquidated just under HF 1.0 (50% close factor, 5% bonus) | about **$2,500** |
| Rebound adds collateral to reach HF 1.40 | top-up $38,554 (still yours), fee **$116** |
| Rebound repays debt to reach HF 1.40 | repays $22,857 of your debt, fee **$69** |

Sources and method: [`docs/research.md`](https://github.com/Om-Thanage/Rebound/blob/research/overnight/docs/research.md)
(on the `research/overnight` branch).

## Try it

Open the [dashboard](https://tryrebound.omthanage.dev/), pick **Adding collateral** or **Repaying debt**, and
press **Run a rescue** with a browser wallet on Base Sepolia (a little test ETH for gas). It calls `DemoLoan.run()`
(or `runWithMode(1)`), which resets the demo loan (WETH back to $2,000, the last rescue undone, HF 1.2) and drops
WETH in two steps in one transaction: $1,950 (HF 1.17, still above the 1.15 trigger) and $1,800 (HF 1.08). The
page walks through five steps as they happen. Step 4 shows ShieldReactive asking for the rescue at the $1,950
step, before the trigger was crossed, because the price was falling fast. One run a minute for everyone; anyone
can refill the demo's reserve with `DemoLoan.topUp()`.

**The demo loan** ([`0x2Cb8…0795`](https://base-sepolia.blockscout.com/address/0x2Cb81B803689D7E2E07c04b263D4DE57cA410795)) is deliberately
small, so test funds last. Every run resets it to the same starting point before the crash:

| | Amount |
|---|---|
| Collateral | 0.004 WETH (about $8 at $2,000) |
| Debt | 5.50 USDC |
| Health factor | 1.20 at $2,000, 1.08 after the drop to $1,800; trigger 1.15, target 1.40 |
| Set aside for rescues | 0.003 WETH for adding collateral, 10 USDC for repaying debt |

A collateral rescue adds about 0.00119 WETH; a repay rescue pays back about 1.26 USDC. Each charges the 0.0001 WETH
fee floor, which comes out of the WETH reserve, so `topUp()` keeps it going.

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
| Add USDC for repay mode | `depositRepayReserve(amount)`; keep some WETH in the reserve too, since it pays the watch fee and rescue fees (a USDC reserve alone is not watched) |
| Set everything in one call | `setup(trigger, target, step, mode, wethAmount, usdcAmount)`: one snapshot, so one reactive transaction |
| Change when and how it acts | `configure(trigger, target, step, mode)`: mode 0 adds collateral, 1 repays debt, 2 repays first then adds; `step` > 0 rescues in stages of trigger + step |
| Take reserve back | `withdrawReserve(amount)` or `withdrawRepayReserve(amount)`; not while your loan is under its trigger |
| Stop protection | `unprotect()` returns both reserves at any time |
| Borrow more or add collateral yourself | do it on the pool, then `sync()` so the Reactive contract sees the new numbers |

On mainnet the shield would point at the real Aave V3 Pool and oracle. It only calls `getUserAccountData`,
`getConfiguration`, `supply(asset, amount, onBehalfOf, 0)` and `repay(asset, amount, 2, onBehalfOf)`, which Aave V3
has with the same signatures, and reads aToken balances. The reactive contract reads Chainlink's own
`AnswerUpdated` event (price in topic 1) and follows the feed when Chainlink swaps the aggregator behind its proxy.

## How it works

```mermaid
---
config:
  flowchart:
    wrappingWidth: 460
---
flowchart TB
    subgraph SRC["Event sources"]
        direction LR
        AGG["<b>Price aggregator</b><br/>Base Sepolia<br/><i>new price</i>"]
        PROXY["<b>Price proxy</b><br/>Base Sepolia<br/><i>aggregator swapped</i>"]
        LEAD["<b>Lead price feed</b><br/>Ethereum Sepolia<br/><i>price moves first</i>"]
        CRON["<b>System contract</b><br/>Reactive Lasna<br/><i>timer</i>"]
    end

    RC["<b>ShieldReactive</b> · Reactive Lasna<br/>mirrors every loan: collateral per asset, debt, trigger, cooldown<br/>re-prices only the loans whose trigger is near the new price<br/>rescues loans under, or one step from, their trigger"]

    subgraph BASE["Base Sepolia"]
        direction LR
        CP["<b>Callback proxy</b>"]
        LS["<b>LiquidationShield</b><br/>re-checks the live health factor<br/>adds the smallest amount that restores the target<br/>fee in WETH pays its own gas"]
        POOL["<b>Aave-style pool</b><br/>borrower's loan"]
    end

    AGG -- "AnswerUpdated" --> RC
    PROXY -- "AggregatorConfirmed" --> RC
    LEAD -- "AnswerUpdated (lead)" --> RC
    CRON -- "Cron10000 (about 3 h): sweep" --> RC
    RC == "rescue / refresh callback" ==> CP
    CP == "rescue(rvm, user, hint)" ==> LS
    LS -- "supply WETH or repay USDC" --> POOL
    LS -. "PositionSnapshot" .-> RC
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
   blocking the loan after 60 s. Every `Cron10000` tick sweeps a batch of loans and asks the shield to re-publish
   any whose mirror is a day old, since interest keeps adding to their debt.

**What runs when.** Every price update (each feed, and the lead feed) does the time-critical work: it re-checks the
retry list (loans under their trigger but in the shield's 10 s cooldown), the buckets near the new price (a
loan whose rescue timed out is asked again there), and loans with several collateral assets, and it requests early rescues on a fast WETH fall.
The CRON sweep is only the safety net. On Lasna `Cron10000` arrives every 10,000 blocks, about 2.95 hours (10,633 s
and 10,592 s between the boundaries at blocks 9,130,000, 9,140,000 and 9,150,000). Each tick finishes any scan a
crash interrupted and checks 50 loans, plus re-publishes up to 10 day-old ones. So:

| A loan is missed because… | It is picked up |
|---|---|
| its rescue callback was lost | after 60 s, on the next price update that scans its bucket; if prices go quiet, at the next sweep (up to ~3 h) |
| a crash crossed more triggers than one tick's gas | on the next price updates, which carry on the interrupted scan; else at the next sweep |
| its mirror drifted (interest, collateral it changed without `sync()`) | when the sweep reaches it: up to ⌈loans ÷ 50⌉ sweeps, ~3 h each (500 loans: up to ~30 h) |

`Cron100` (every ~100 s on Lasna) would cut those waits a hundredfold, at about 14 lREACT a day of idle cost
instead of 0.15; the first v4 deploy ran that way and emptied its reserve in a day.

## What is different

| | DeFi Saver / Instadapp | Reactive's CRON demo, ReacDEFI | Rebound |
|---|---|---|---|
| Trigger | off-chain bots | CRON (polling interval) / trigger HF | the price event itself, plus one price step early, plus a lead feed on another chain |
| Who runs it | the operator's bots | one contract per user (demo); ReacDEFI's service | one shared shield for every borrower, no bot |
| Rescue | repay (sells collateral) | add collateral, repay, or both | add collateral, repay, both, or in stages; smallest amount to the target |
| Fee | 0.05% + gas (DeFi Saver), 0.3–0.4% + gas (Instadapp) | not stated | 0.3% gas included, plus a small watch fee; shown on-chain |
| Funding | operator | topped up by hand | fees pay callback gas, shown on-chain |

Morpho's pre-liquidations take a different route: a softer liquidation band with a smaller bonus. Rebound avoids
the liquidation altogether and leaves the collateral with the borrower.

**Research it builds on:** Qin et al., *An Empirical Study of DeFi Liquidations* (IMC 2021): $807M liquidated in
28k events; Perez et al., *Liquidations: DeFi on a Knife-edge* (FC 2021): over 70% of liquidatable positions are
liquidated immediately, so a shield must act before HF 1.0; Sevim and Ferreira Torres, *Signals and Spoils*
(2026): liquidators use one chain's Chainlink update to predict another's, which is what the lead feed turns to the
borrower's side; Qin et al., *Mitigating DeFi Liquidations with Reversible Call Options* (Miqado, FC 2023): outside
top-ups cut liquidated collateral by 89.8% in simulation.

## Measured on live testnets

`script/bench.sh` resets the loan each round (price back to $2,000, collateral back to HF 1.2), drops WETH to
$1,800 (HF 1.08, under the 1.15 trigger) and counts Base blocks between the price transaction and the
`Rescued` event. At 200 ms a block, blocks × 0.2 s is the end-to-end latency. Results:
[`results/bench.csv`](results/bench.csv), summary in [`results/summary.txt`](results/summary.txt).

| Version | Rounds | Rescued | Median | p90 | Fastest | Slowest |
|---|---|---|---|---|---|---|
| Deployed (v4, redeployed with the review fixes and `Cron10000`) | 10 | 10 | **1.4 s** (7 blocks) | 1.6 s | 1.0 s | 1.6 s |
| v4, first deploy ([`results/v4-first/`](results/v4-first/), v3 plus the CRON fix) | 10 | 10 | 1.4 s (7 blocks) | 2.2 s | 0.8 s | 2.6 s |
| Third version ([`results/v3/`](results/v3/), the [review](docs/review.md) fixes) | 10 | 10 | 0.8 s (4 blocks) | 1.4 s | 0.6 s | 1.4 s |
| Second version ([`results/v2/`](results/v2/)) | 10 | 10 | 1.4 s (7 blocks) | 1.8 s | 1.0 s | 2.0 s |
| First version ([`results/v1/`](results/v1/)) | 20 | 20 | 1.2 s (6 blocks) | 1.6 s | 1.0 s | 2.0 s |

Every rescue lifted the health factor to 1.40. The last three runs went through without a gap. In the first two the
reactive contract ran out of lREACT partway (Reactive stops calling `react()` while a contract owes it); after a
`depositTo` the missing rounds were rerun. Runs vary by a few blocks with Lasna's load: v3 and v4 run the same
price path, and their medians are 0.8 s and 1.4 s.

That is three to thirteen blocks after the price update. Liquidators act in the update's own block, so Rebound's
protection comes from acting while HF is between the trigger and 1.0, and from the early request when the price is
falling fast, not from beating liquidators to a loan that is already liquidatable.

What this measures is latency on one price path: every round drops the loan to 1.08, still above 1.0, and the
dashboard demo posts both price steps in one transaction, so no rescue can land between them. It does not
measure how often a rescue prevents a liquidation across realistic price paths and crowded triggers (late,
partial and missed rescues included). The historical replay below is a first, simulated answer.

**Lead feed, live (second version):** `script/lead.sh 1900` moved WETH to $1,900 on Ethereum Sepolia first. The rescue landed on
Base 0.8 s after that update confirmed, **before Base's own oracle had moved** (it followed 10 s later).

**Self-funding (Base side),** from `opsLedger()` on the deployed shield after 13 rescues: 0.0013 ETH in fees against
0.0000265 ETH of callback gas, about 49 times over; the shield owes the callback proxy nothing.

**Repay mode, live:** `DemoLoan.runWithMode(1)` ([price](https://base-sepolia.blockscout.com/tx/0xcc5ebe8ede44b64540f1d8fe3e235bd586d75f7d5f56d818905ec985648e914a),
[rescue](https://base-sepolia.blockscout.com/tx/0x7686f5e3f0c7ea9408346825c5c9f925987fc9555906e4fc9c3d06dace4c6933)) was rescued
6 blocks later with no WETH added: `RescueDetail` shows 1.257 USDC repaid, the debt fell from 5.50 to 4.24 USDC and
the health factor rose from 1.08 to 1.40.

**CRON, live:** the first three versions subscribed to `CronN` from the Omni system contract (`0x8888…`), but
Reactive Network emits it from `0x0000000000000000000000000000000000fffFfF`, so the sweep never ran on Lasna. v4
subscribes there and ticks: `cronTicks` was 1 within two minutes of the first v4 deploy. The redeploy uses
`Cron10000`, which Lasna emits about every three hours. Its first tick: the system event at Lasna block 9,160,000
([`0xecd6…3e98`](https://lasna.reactscan.net/tx/0xecd6346bfd78aa502b50263b43f61d5d203cc3f96cffb8e91326076102c13e98),
19:17 UTC on 24 November 2026) moved the watcher's `cronTicks` from 0 to 1 and `positionsChecked` from 14 to 16:
the sweep checked both watched loans.

**Reactive side, measured:** read from the system contract's `reserves()` for ShieldReactive. Idle, with no price
moving, the first v4 deploy spent about **0.017 lREACT per `Cron100` tick**, roughly 0.6 lREACT an hour (0.051
lREACT over five minutes and three ticks), and ran its reserve dry in a day; v2, whose CRON never fired, spent
nothing idle. The redeploy sweeps on `Cron10000`, a hundred times less often: about 0.15 lREACT a day at the same
cost per tick. Rescues still come straight from price events; the sweep only catches what a tick missed. One dashboard run (reset, two-step crash: three price events and two
loan snapshots) cost **0.111 lREACT** on the second version; the first version's simpler loop cost about 0.04. At the testnet faucet rate
(100 lREACT per ETH) 0.111 lREACT is 0.0011 ETH, above the 0.0001 ETH fee floor; at the mid-November 2026 market
price of REACT (about $0.0023) it is about $0.0003, which the floor covers. Watching costs gas on every price event
while fees only arrive on rescues; the daily watch fee and the trigger buckets are there for that gap. Bridging fee
income to REACT and calling `depositTo` is still manual.

## Historical replay (simulated, not measured on testnet)

`script/replay.mjs` replays Chainlink ETH/USD updates from Ethereum mainnet over the four crash windows above
(2,998 updates, cached in [`results/sim/prices.json`](results/sim/prices.json) by `script/fetch-prices.mjs`)
against identical loans: 10 ETH of collateral, starting HF 1.2 to 2.0, and the same reserve (20% of the debt, in
USDC) under three strategies. Assumptions, per-window tables and every run:
[`results/sim/summary.md`](results/sim/summary.md), [`results/sim/runs.csv`](results/sim/runs.csv).

| Strategy (24 loans) | Liquidations | Cost (bonus lost + fees + interest) | Reserve unspent at the end |
|---|---|---|---|
| No intervention | 26 | $9,379 | $94,897 of $94,897 |
| Upfront repayment | 7 | $2,886 | $0 |
| Rebound, 1.4 s delay | 7 | $3,154 | $17,724 |

With the same reserve, Rebound prevented as many liquidations as repaying upfront; the 7 left in both are loans
whose reserve was too small for a 39% fall. Rebound was never late or missed a loan, even with a 300 s delay:
Chainlink moves in steps of about 0.5%, so a loan crosses 1.15 well before 1.0. It cost $268 more in total (fees,
and interest on debt it repaid later), and in exchange left 19% of the reserves unspent, where no crash reached
them. One simplification matters for the dollar figures: the replay pays Rebound's fees out of the same USDC
reserve it repays from, while the deployed shield repays from USDC and takes fees from a separate WETH reserve.
Not modelled: gas for the upfront repayment, what the borrower earns on an unspent reserve, a feed that
jumps more than one step at a time, and Reactive running out of lREACT.

## Deployed contracts

| Contract | Network | Address |
|---|---|---|
| ShieldReactive | Reactive Lasna (5318007) | [`0x1d3cc73c0B805683fd7910f63BCf360e2a50D26E`](https://lasna.reactscan.net/address/0x1d3cc73c0B805683fd7910f63BCf360e2a50D26E) |
| LiquidationShield | Base Sepolia (84532) | [`0x151c43a482687C07F603E85714F333EaA8eEd7f2`](https://base-sepolia.blockscout.com/address/0x151c43a482687C07F603E85714F333EaA8eEd7f2) |
| DemoLoan | Base Sepolia | [`0x2Cb81B803689D7E2E07c04b263D4DE57cA410795`](https://base-sepolia.blockscout.com/address/0x2Cb81B803689D7E2E07c04b263D4DE57cA410795) |
| MockAavePool | Base Sepolia | [`0x7C62dAA548158bcD1094a500F31635cAD6Ac0615`](https://base-sepolia.blockscout.com/address/0x7C62dAA548158bcD1094a500F31635cAD6Ac0615) |
| MockAaveOracle | Base Sepolia | [`0xaDBE6445f707dd59581f9219a301b6d9Aa866A16`](https://base-sepolia.blockscout.com/address/0xaDBE6445f707dd59581f9219a301b6d9Aa866A16) |
| WETH/USD feed (aggregator / proxy) | Base Sepolia | [`0x19250F87d9C3A06FBC91685D79075DE49eddaba4`](https://base-sepolia.blockscout.com/address/0x19250F87d9C3A06FBC91685D79075DE49eddaba4) |
|  |  | [`0x5B2C01c9258Fe65199BD62aAA7e96dF76aFc56A6`](https://base-sepolia.blockscout.com/address/0x5B2C01c9258Fe65199BD62aAA7e96dF76aFc56A6) |
| WBTC/USD feed (aggregator / proxy) | Base Sepolia | [`0xB7f86B2b6A36C8cb19546aB2BefC08434464Bc05`](https://base-sepolia.blockscout.com/address/0xB7f86B2b6A36C8cb19546aB2BefC08434464Bc05) |
|  |  | [`0x1b8B5056882d70DD78D091DCAb9168228f09DE8D`](https://base-sepolia.blockscout.com/address/0x1b8B5056882d70DD78D091DCAb9168228f09DE8D) |
| Test WETH | Base Sepolia | [`0xE1aC030Fa790dFE86c507c17596fc1a30F5979E1`](https://base-sepolia.blockscout.com/address/0xE1aC030Fa790dFE86c507c17596fc1a30F5979E1) |
| Test WBTC | Base Sepolia | [`0xA01495f2e5D928BFB89473b6E5F79f50Af04B967`](https://base-sepolia.blockscout.com/address/0xA01495f2e5D928BFB89473b6E5F79f50Af04B967) |
| Test USDC | Base Sepolia | [`0x599EB09E5d267765C63703211c1667607279354E`](https://base-sepolia.blockscout.com/address/0x599EB09E5d267765C63703211c1667607279354E) |
| Lead WETH/USD feed | Ethereum Sepolia (11155111) | [`0x1d3cc73c0B805683fd7910f63BCf360e2a50D26E`](https://eth-sepolia.blockscout.com/address/0x1d3cc73c0B805683fd7910f63BCf360e2a50D26E) |

Callback proxy on Base Sepolia: `0x476F44b11F5C942c58f4c8E3d0300E5710743585`. ShieldReactive on Lasna and the lead feed on
Ethereum Sepolia share an address because the deployer's nonce was the same on both chains; they are different
contracts. Every Base Sepolia and Ethereum
Sepolia contract above is source-verified on Sourcify (exact match). Earlier versions' addresses are in
[`deployments.v1.env`](deployments.v1.env), [`deployments.v2.env`](deployments.v2.env) and
[`deployments.v3.env`](deployments.v3.env); the first v4 deploy (before the review fixes) is in
[`deployments.v4-first.env`](deployments.v4-first.env).

### Full-loop transactions (origin event → callback)

| Loop | 1. Price event | 2. Reactive tx, `RescueRequested` (Lasna) | 3. Rescue callback (Base) | Latency |
|---|---|---|---|---|
| Benchmark round 1 | [`0x690a…1ce0`](https://base-sepolia.blockscout.com/tx/0x690aeaae81aba7d92bf8b6832aa86d7816710810e020b2f418757227b3021ce0) (Base) | [`0x508e…b17c`](https://lasna.reactscan.net/tx/0x508ec2783d24834d0155bf42a134e1d90a2d9808ebf8e25f6292b3df6d79b17c) | [`0x1bbe…dd03`](https://base-sepolia.blockscout.com/tx/0x1bbe50c5a46f9b41044a077648d4418366ce4aeacb2fa4007979558f0eeedd03) | 8 Base blocks (1.6 s) |
| `DemoLoan.runWithMode(1)`, repay | [`0xcc5e…914a`](https://base-sepolia.blockscout.com/tx/0xcc5ebe8ede44b64540f1d8fe3e235bd586d75f7d5f56d818905ec985648e914a) (Base) | [`0xcb9a…c72a`](https://lasna.reactscan.net/tx/0xcb9a55589ded5f6b33f7ba1da4a13171aa26afb1eb5c89963e5ab294e169c72a) | [`0x7686…6933`](https://base-sepolia.blockscout.com/tx/0x7686f5e3f0c7ea9408346825c5c9f925987fc9555906e4fc9c3d06dace4c6933) | 6 Base blocks (1.2 s) |
| Lead feed (second version) | [`0x3205…cd00`](https://eth-sepolia.blockscout.com/tx/0x3205623dc5126c391c9201481ea3140c61edffeabd4f79dcf3a886f67465cd00) (Ethereum Sepolia) | [`0xd442…e33e`](https://lasna.reactscan.net/tx/0xd442247264309eb66b637cfbf690b1ae017007e71b80610a38f85ecc1d60e33e) | [`0x8b47…9205`](https://base-sepolia.blockscout.com/tx/0x8b4712bdb4e198c7da3111e8bfd2a3a1347182c691e41a740ee0e6dadfc29205) | before Base's oracle moved |

Every benchmark round's price, Lasna and rescue transactions are in `results/bench.csv`.

## Run it yourself

Needs [Foundry](https://getfoundry.sh), `jq`, and a testnet wallet with Base Sepolia ETH, a little Ethereum
Sepolia ETH (for the lead feed), and Lasna lREACT (send Sepolia ETH to the faucet
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, 1 ETH → 100 lREACT).

```bash
cp .env.example .env              # then put your testnet PRIVATE_KEY in .env (or point ENV_FILE at another file)
forge test                        # 58 tests: modes, early trigger, lead feed, buckets, CRON, gas bounds, mock locks, fuzz
bash script/deploy.sh             # predicts every address, deploys lead feed, Lasna, then Base; writes deployments.env
bash script/status.sh             # health check: lREACT runway in demo runs, CRON firing, ledger, demo loan
node script/export-deployment.mjs # points the dashboard at the new deployment
bash script/demo.sh 1800          # opens and protects a loan, crashes WETH, times the rescue
bash script/lead.sh 1900          # moves the lead feed first: the rescue lands before Base's oracle moves
bash script/bench.sh 20           # 20 timed rounds -> results/bench.csv (START=n continues a run)
node script/backfill-bench.mjs    # fills to_reactive_s for rounds that have a Lasna block but no value
node script/export-bench.mjs      # feeds the dashboard's speed section
node script/export-rescues.mjs    # snapshots every rescue for the dashboard's list (it adds newer ones live)
node script/check-dashboard.mjs   # the dashboard's rescue outcome around 1.15 and 1.40
node script/fetch-prices.mjs      # Chainlink ETH/USD history for the crash windows (cached in results/sim/)
node script/replay.mjs            # SIMULATED replay: no intervention vs upfront repayment vs Rebound
```

Open the dashboard over any static server (for example `npx serve dashboard`). It reads the contracts over
Base Sepolia's and Lasna's public RPCs and refreshes every 10 seconds. The rescue list comes in three layers:
the history shipped in `data/rescues.json`, one Blockscout call per page load for anything after it, and the RPC
for new blocks; if Blockscout fails, it reads up to a day over RPC and says which blocks it could not load.

## Submission checklist

| The brief asks for | Where it is |
|---|---|
| Public repository | this repository (MIT licence for our code; libraries keep their own) |
| Deployed contract addresses | [Deployed contracts](#deployed-contracts), all source-verified |
| Transaction hashes for the full loop, origin event to callback | [Full-loop transactions](#full-loop-transactions-origin-event--callback) |
| Demo video under three minutes | link to be added |
| Track: Every Second Counts on Base Sepolia | Reactive Lasna + Base Sepolia; latency in [Measured on live testnets](#measured-on-live-testnets) |
| Built during the event | every commit is from November 2026, inside the event; `forge-std` and `reactive-lib-omni` are dependencies |
| Timestamps, not block counts, for timers on Base | the shield's 10 s cooldown, the 60 s pending timeout and DemoLoan's 60 s cooldown use timestamps |

## Repository

| Path | What |
|---|---|
| `src/LiquidationShield.sol` | destination contract: reserves, modes, rescue maths, fee → gas, watch fee, ops ledger |
| `src/ShieldReactive.sol` | reactive contract: mirrors loans, buckets, early and lead-feed requests, aggregator following, CRON |
| `src/DemoLoan.sol` | a protected loan anyone can reset and crash in two steps, in either mode |
| `src/mocks/` | lending pool with Aave V3's signatures and maths (two collateral assets), Chainlink-style feeds, test tokens |
| `test/Shield.t.sol` | 58 tests with a mocked system contract and callback proxy |
| `script/` | deploy, demo, lead feed, benchmark, exports |
| `dashboard/` | the live page |

## Fixes after the first v4 deploy (all live)

An outside review of `f38a97a` found five problems, and a follow-up audit found seven more. All are fixed with a test each (57 tests) and
are live: v4 was redeployed with them on 24 November 2026, with the slower `Cron10000` sweep (see below).

| Problem | Fix | Live? |
|---|---|---|
| A partial rescue charged the 0.3% fee on the full top-up the loan needed, not on what the reserve could supply (0.003 WETH on a 0.007 WETH top-up) | The top-up and its fee are sized together, so the fee is 0.3% of what moves (or the 0.0001 ETH floor) | Live |
| The snapshot counted every aToken balance as collateral; Aave leaves out assets the borrower switched off and applies eMode thresholds, so the mirror could think a loan was safer than it is | Thresholds in the snapshot are scaled so the mirror's health factor matches the pool's own `getUserAccountData` | Live |
| An early request from a falling WBTC price sent a WBTC price as the hint, which the shield reads as a WETH price, so the rescue was skipped | Early requests come only from WETH moves; WBTC loans are rescued when they cross the trigger | Live |
| A tick that ran out of gas in a crowded bucket restarted at the front of that bucket, so later loans waited for the sweep | The scan remembers its place inside the bucket, and steps back when a landed rescue moves an unchecked loan behind it | Live |
| The dashboard said "safe again" after every rescue, even a partial one | It reads the health factor after the rescue: at target, above the trigger, under the trigger, or under 1.0 | Live |
| Anyone could call the mock oracle's `setAssetPrice` in a loop, and every price event costs the reactive contract lREACT, so one person could switch the demo off | Only the deployer and `DemoLoan` (one run a minute) may move prices | Live |
| ETH forced into the shield without `receive()` made `opsLedger()` underflow and revert, breaking the dashboard's fee panel | Gas paid floors at 0 | Live |
| The dashboard kept polling public RPCs from hidden tabs, and fell back to an old deployment's addresses if `deployment.json` failed to load | Hidden tabs skip the 10-second refresh; no fallback addresses, and the page says when live data is unavailable | Live |
| `sync(address)` took an address that had to be the caller's own | `sync()` acts on the caller | Live |
| A loan protected with only a USDC repay reserve was watched for free: the watch fee comes out of the WETH reserve | Watching needs a WETH reserve in every mode | Live |
| The design kit's check reports (`dashboard/.taste-skill/`, `names.json`) were published on the site | Left out of deployments by `dashboard/.vercelignore` | Live |

## Limits

- The pool is a mock with Aave V3's interface, because Aave's testnet oracle price can't be moved for a demo.
  Only the deployer and `DemoLoan` (one run a minute) may move the test price; everything else on the mocks (swapping a feed's aggregator, oracle sources, listing collateral, the borrow rate)
  is the deployer's alone.
- Collateral top-ups and fees are in WETH. Other collateral assets are watched and priced, but a rescue tops up
  with WETH.
- The price hint (projected or lead price) is trusted up to 5% under the oracle. A manipulated lead feed can make
  a borrower top up early with their own funds, plus one fee; it cannot move funds anywhere else.
- **Open for production: real Aave collateral flags and eMode.** The snapshot scales every asset's threshold so
  the mirror matches the pool's health factor at snapshot prices. After prices move, that spread is wrong when
  assets differ: 1 WETH enabled, 0.01 WBTC switched off and $1,200 of debt, with WETH falling slowly from $2,000 to
  $1,600, the pool says 1.100 and the mirror 1.161, so no rescue is requested under the 1.15 trigger
  (`test_disabledCollateralGapAfterASlowFall`). A fast fall is still caught by the early request, and the next
  snapshot (`sync()` or the day-old refresh) re-scales and the rescue follows. The destination's sizing reads the
  pool's own collateral total, so disabled collateral is not counted there; with eMode it uses the asset's normal
  threshold and tops up more than needed. The fix is to read each asset's collateral flag
  (`getUserConfiguration`) and the borrower's eMode category in the snapshot and in rescue sizing, checked
  against a pinned Base fork of Aave V3. What the deployed demo shows: the mock pool has no per-asset collateral
  flags or eMode, so on it the mirror is exact; the gap above only appears on real Aave.
- On mainnet, the REACT that pays for Reactive execution would be bought with fees and sent across with
  `depositTo`; on testnet the reactive contract is funded by hand.
- A crash that crosses more triggers than one tick's gas budget is served over the following ticks or CRON sweeps,
  highest risk first.
