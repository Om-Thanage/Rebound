# Parapet research notes

Overnight research for the Reactive Omni Buildathon entry (track "Every Second Counts"), written 21 November
2026. Part A collects evidence that the problem is real. Part B lists research that points to concrete
changes in `src/`, and ends with a ranked shortlist for the 6 December 2026 deadline.

**How these sources were read.** This environment's network policy blocked direct page fetches (aave.com,
coindesk.com and others failed to resolve), so every figure below comes from search-engine extracts of the
linked pages, not from reading the pages in full. Where two or more independent sources agreed, the figure is
given plainly. A figure resting on one source is marked *(single source)*. Anything not confirmed is marked
**Unverified**. Open the links before you put a number on a slide.

## Summary: three things to know first

1. **Parapet does not beat liquidators to a loan that is already liquidatable.** It reacts to the same oracle
   update that liquidators back-run, and on Base a large share of liquidations land in the *same block* as
   the oracle update ([Signals and Spoils, 2026](https://arxiv.org/pdf/2606.03434): 37.31% on Base). Parapet's
   1.2 s is six 200 ms blocks. So the protection comes from the gap between the trigger (1.15) and 1.0, not
   from speed alone. If one oracle step takes a loan from above 1.15 to below 1.0, liquidators win. The pitch
   should say "acts in the first seconds after the price moves, while the loan is still safe", not "faster
   than liquidators". Change 2 in the shortlist (an early trigger that reacts to how fast the price is falling)
   is the direct fix.
2. **A WETH reserve loses value in the same crash it is meant to cover.** Repaying debt from a stablecoin
   reserve needs H/LT times less capital than adding collateral (about 1.69× less at target 1.40 and
   LT 0.83; the maths is in B2), and the reserve does not fall with the collateral. ReacDEFI, a live product
   in the Reactive ecosystem, already offers collateral, repay and combined modes.
3. **The "Lasna side is not self-funding" gap is mostly an artefact of the testnet faucet rate.** At the
   faucet rate (100 lREACT per ETH), 0.04 lREACT costs 0.0004 ETH. At the mid-November 2026 market price of
   REACT (about $0.0023, *single source*), 0.04 REACT is about $0.0001, which the 0.0001 ETH floor covers
   many times over at any plausible ETH price. The real economic problem is different: the reactive contract
   pays for **every** price tick for **every** watched loan, while fees arrive only on rescues (B3).

There is also one code issue to fix before judging: anyone can grow `ShieldReactive.users` without limit
through `LiquidationShield.sync(anyAddress)`, which can make every `react()` run out of gas (B5.1).

---

# Part A: evidence that the problem is real

## A1. How much is liquidated, and what borrowers lose

| Finding | Figure | Source |
|---|---|---|
| Liquidations on Aave, Compound, MakerDAO and dYdX up to April 2021 | $807.46M across 28,138 events, 2,011 liquidator addresses | Qin, Zhou, Gamito, Jovanovic, Gervais, *An Empirical Study of DeFi Liquidations*, IMC 2021 ([arXiv 2106.06389](https://arxiv.org/abs/2106.06389), [DOI](https://www.doi.org/10.1145/3487552.3487811)) |
| How quickly liquidatable Compound positions are liquidated (to September 2020) | over 70% liquidated immediately; a 3% price move could make over $10M liquidatable | Perez, Werner, Xu, Livshits, *Liquidations: DeFi on a Knife-edge*, FC 2021 ([arXiv 2009.13235](https://arxiv.org/abs/2009.13235v6)) |
| Bonus paid to liquidators in a 7-day stress window (late January to early February 2026) | $9.34M of bonus on $202.47M collateral seized (about 4.6%) | [Chaos Labs risk report, 02/02/26, Aave governance](https://governance.aave.com/t/chaos-labs-risk-report-insights-from-recent-market-events-02-02-26/23986) *(single source)* |
| Average premium on Aave V2/V3 liquidations in one period | about 4.5% of liquidated collateral value (about $1.9M) | [Pyth, "Value leakage and fragmentation in liquidations", March 2024](https://legacy.pyth.network/blog/value-leakage-and-fragmentation-in-liquidations) *(single source)* |
| Chainlink SVR on Aave, March 2025 to early February 2026 | about $675M liquidated in about 3,900 events; about $16M recaptured (65% Aave, 35% Chainlink); average recapture 73% of non-toxic liquidation MEV | [Aave blog, "How Aave Liquidations Perform Under Volatile Conditions"](https://aave.com/blog/historical-liquidations); also [Chainlink SVR analysis](https://chain.link/blog/chainlink-svr-analysis) |
| Liquidation bonus paid during the SVR period | $32.2M of bonus on $683M of liquidations (Dune data) | secondary analysis page, **Unverified**: I could not trace the Dune query |

**What to say in the pitch.** A liquidation costs the borrower the bonus: about 5% of the collateral seized for
WETH on Aave V3 (5% was Gauntlet's launch value for WETH on Aave V3 Base,
[Gauntlet recommendations, July 2023](https://governance.aave.com/t/arfc-aave-v3-deployment-on-base/13708/9);
check the live value before quoting it). The SVR figure shows the bonus is large enough that protocols now sell
the right to capture it. Parapet charges 0.3% of the top-up.

**Worked example for the README (my arithmetic, using the shield's own formula).** Debt $100,000, LT 0.83,
health factor 1.08 after a drop, so collateral is about $130,120:

| Outcome | Borrower cost |
|---|---|
| Liquidated just under HF 1.0 (50% close factor, 5% bonus) | about 0.5 × $100,000 × 5% = **$2,500**, plus selling collateral at the bottom |
| Parapet adds collateral to reach HF 1.40 | top-up of $38,554 (still the borrower's), fee 0.3% = **$116** |
| Parapet repays debt to reach HF 1.40 (proposed in B2) | repayment of $22,857, fee 0.3% = **$69** |

## A2. Liquidation cascades, with dates and amounts

| Date | Event | Amount | Source |
|---|---|---|---|
| 12–13 March 2020 | "Black Thursday": ETH fell sharply and congested Ethereum, and MakerDAO auctions cleared at zero bids | $8.32M of collateral won for 0 DAI (about 62,843 ETH over 1,461 auctions). Unbacked DAI estimated at $4.5M ([Glassnode](https://insights.glassnode.com/what-really-happened-to-makerdao)); Maker's loss from zero-bid and half-price bids estimated at $6.65M ([Cointelegraph](https://cointelegraph.com/news/maker-debt-crisis-post-mortem-recommends-new-safeguards)) | [Medium analysis](https://medium.com/@whiterabbit_hq/black-thursday-for-makerdao-8-32-million-was-liquidated-for-0-dai-36b83cac56b6); mempool congestion as the cause: [Blocknative via Nasdaq](https://www.nasdaq.com/articles/mempool-manipulation-enabled-theft-of-$8m-in-makerdao-collateral-on-black-thursday:-report). Maker's own post-mortem was not found: **Unverified** |
| 19 May 2021 | Crypto-wide crash | $377M on Aave, Compound and Maker in a day (Aave about $170M, Compound about $147M, Maker about $60M). Gauntlet called it the largest single-day total in both Aave's and Compound's history | [Cointelegraph Consulting](https://cointelegraph.com/news/cointelegraph-consulting-defi-hit-by-a-tsunami-of-liquidations-in-may), [Gauntlet retrospective](https://gauntlet.xyz/resources/aave-protocol-liquidation-retrospective-may-2021) |
| 22 November 2022 | CRV short squeeze on Aave V2 (Eisenberg position) | about $1.6M of bad debt (Blockanalitica/Gauntlet); other estimates were $1.7M to $1.78M | [The Block](https://www.theblock.co/post/189606/llama-and-gauntlet-submit-proposal-to-cover-1-6-million-in-bad-debt-on-aave), [Blockworks](https://blockworks.co/news/aave-curve-bad-debt) |
| 5 August 2024 | Global market sell-off | Aave V3 $237M to $253M depending on source; about $350M across DeFi (Parsec) | [The Defiant](https://thedefiant.io/news/defi/crypto-crash-wipes-out-defi-borrowers-as-all-time-aave-v3-liquidations-double), [CoinDesk](https://coindesk.com/business/2024/08/05/defi-giant-aave-rakes-in-6m-in-revenue-as-crypto-market-plunges) |
| 10 October 2025 | Tariff-announcement crash (over $19B liquidated on centralised exchanges and perp DEXs) | over $250M liquidated on Aave that day, with no downtime | [Aave blog](https://aave.com/blog/historical-liquidations), [Chaos Labs report 10/11/25](https://governance.aave.com/t/chaos-labs-risk-report-insights-from-recent-market-events-10-11-25/23248) |
| 31 January to 5 February 2026 | Sell-off after a Fed Chair nomination | $429M on Aave across about 12,500 transactions, beating the May 2021 record; over $140M on 31 January alone | [Aave blog](https://aave.com/blog/historical-liquidations), [BeInCrypto](https://beincrypto.com/crypto-lending-leverage-liquidation-risk/) |
| 10 March 2026 | Misconfigured wstETH CAPO oracle on Aave (price capped about 2.85% too low) | 34 accounts, about 10,938 wstETH, $26M to $27M liquidated; reimbursement promised by Chaos Labs and proposed to the DAO | [The Block](https://www.theblock.co/post/393121/aave-oracle-glitch-wsteth), [Cointelegraph](https://cointelegraph.com/news/aave-capo-oracle-glitch-27m-liquidations), [reimbursement AIP](https://governance.aave.com/t/direct-to-aip-wsteth-capo-oracle-incident-user-reimbursement/24275) |
| 18 April 2026 | KelpDAO rsETH bridge exploit: stolen rsETH deposited on Aave as collateral | $292M drained; Aave bad debt estimated at $124M to $230M depending on the scenario. This is not a price cascade, but it shows collateral can lose its value in minutes | [The Block](https://www.theblock.co/news/defi/2026-04-20-kelp-dao-shifts-blame-layerzero-398204), [Cointelegraph](https://cointelegraph.com/news/aave-s-risk-manager-shares-2-scenarios-to-allocate-losses-from-kelp-dao-hack), [Galaxy](https://www.galaxy.com/insights/research/kelpdao-layerzero-exploit-defi) |
| mid-November 2026 | Two-day sell-off | about $18M and $21M on consecutive days (about $39M) per an Aave executive | [ChainCatcher](https://www.chaincatcher.com/en/article/2304867). **Unverified**: the exact dates could not be confirmed |

The 10 March 2026 incident is a strong point for the pitch: a correct-looking oracle mispriced collateral by
2.85% and positions were liquidated at once. A loan held at HF 1.15 by Parapet would have absorbed a 2.85%
mispricing (it needs about a 13% drop to reach 1.0).

## A3. How fast liquidations follow an oracle update

- **Same block on Base.** Sevim and Ferreira Torres measure the share of Aave liquidations that land in the same
  block as the Chainlink update: 37.31% on Base, 9.67% on Optimism. On 10 October 2025 they count 831
  "speculative" liquidations (39% of successful ones across Arbitrum, Base and Optimism), where searchers used
  the Optimism update to predict the Base and Arbitrum updates and fired first
  ([Signals and Spoils, arXiv 2606.03434](https://arxiv.org/pdf/2606.03434)).
- **Liquidations happen at the threshold.** In V3 data cited for Aave V4, the median health factor just before
  liquidation was 0.9987 ([Aave V4 liquidation engine overview](https://governance.aave.com/t/overview-of-aave-v4-s-liquidation-engine/23531)).
  There is no grace period after HF falls below 1.0.
- **Back-running is the norm.** Qin, Zhou and Gervais counted 7,919 back-running liquidations among 31,057 on
  Aave V1/V2, Compound and dYdX ([Quantifying BEV, arXiv 2101.05511](https://arxiv.org/pdf/2101.05511)).
  A 2024 fairness study found that almost every liquidation was executed in the first block it became possible,
  and that 98.68% of the rare exceptions were enabled by a Chainlink update in that block
  ([arXiv 2405.18876](https://arxiv.org/pdf/2405.18876)). The exact framing is **Unverified**: re-read §5 of
  that paper before quoting it.
- **The market prices the race.** Chainlink SVR auctions the right to back-run the price update, because the
  first transaction after the update wins the bonus ([Chainlink SVR docs](https://docs.chain.link/data-feeds/svr-feeds)).
- **Base blocks are now 200 ms.** The Denim upgrade replaced Flashblocks with 200 ms canonical blocks on Base
  Sepolia (21 October 2026) and Base mainnet (5 November 2026) ([Base docs](https://docs.base.org/upgrades/denim/200ms-blocks)).
  This supports the README's 6 blocks = 1.2 s conversion. Most of the Signals and Spoils data predates Denim.

**What this means for the pitch:** "every second counts" holds for the window between the trigger and 1.0. Once
HF is below 1.0, the race is decided within a block, and nobody running off-chain or cross-chain wins it.

## A4. Existing protection products

| Product | Trigger mechanism | What it does | Fee | Latency |
|---|---|---|---|---|
| **DeFi Saver Automation** | off-chain bots watch a ratio or HF threshold; a newer "Liquidation Protection" mode launched 10 August 2026 | repay (sell collateral, repay debt) or boost | 0.05% per trigger plus gas ([help centre](https://help.defisaver.com/features/automation/fees)); 0.25% service fee on manual swaps | not published. Self-reported: 382 automated repays and no liquidations from 25 January to 9 February 2026, defending $446M ([DeFi Saver case study](https://blog.defisaver.com/defi-saver-case-study-the-role-of-automation-during-mass-liquidation-events/), [Crypto Briefing](https://cryptobriefing.com/defi-saver-aave-v3-liquidation-protection/)); company-sourced |
| **Instadapp Protection** | trigger HF and target HF, run by Gelato | repays debt to the target | 0.3% to 0.4% per event, plus gas paid from the position ([Instadapp guide](https://guides.instadapp.io/features/protection-automation)) | not published |
| **Gelato** (infrastructure) | keepers or Web3 Functions | whatever the contract does | a premium on gas, which varied by network in older docs (20% Ethereum, 50% Arbitrum, 70% Polygon) ([docs](https://docs.gelato.network/developer-services/web3-functions/pricing-and-rate-limits)) | block-level polling |
| **Chainlink Automation** (infrastructure) | `checkUpkeep` / `performUpkeep`, log or time triggers | whatever the contract does | gas × (1 + premium) plus a fixed overhead, paid in LINK; the premium varies by chain (the docs' example is 70% on Polygon) ([docs](https://docs.chain.link/chainlink-automation/overview/automation-economics)) | block-level |
| **Chainlink CRE template** | a workflow on a schedule (hackathon projects use 30 s to 5 min) | confidential liquidation defence | CRE pricing | **Unverified** ([template](https://docs.chain.link/cre-templates/automated-liquidation-protection)) |
| **Reactive demo / "Aave Unified Protection"** | CRON events on Reactive | collateral deposit, debt repay, or both | none stated | set by the CRON interval ([Reactive blog](https://blog.reactive.network/aave-unified-protection-multi-strategy-automated-liquidation-defense-with-reactive-smart-contracts/)) |
| **ReacDEFI Liquidation Protection** | trigger HF, live on Ethereum and Base mainnets | collateral deposit, repay, or combined | **Unverified** | **Unverified**: the trigger source was not stated ([Reactive blog](https://blog.reactive.network/reacdefis-liquidation-protection-is-live-on-ethereum-and-base/)) |
| **Morpho pre-liquidations** | opt-in per borrower: a softer liquidation band between preLLTV and LLTV | anyone can partially liquidate with a smaller bonus (example: about 4% against 5%) | the pre-liquidation bonus | as fast as liquidators ([Morpho docs](https://docs.morpho.org/build/borrow/concepts/preliquidation)) |
| **Aave itself** | none for borrowers in V3. V4 liquidates only down to a target HF with a bonus that grows as HF falls | reduces over-liquidation, does not prevent it | n/a | n/a ([Aave V4 liquidations](https://aave.com/docs/aave-v4/positions/liquidations)) |

**Positioning.** Parapet's real differences are (1) triggering on the price event rather than polling or CRON,
(2) one shared shield instead of one contract per user, and (3) fees that pay for the callback on-chain. On
fee level, 0.3% matches Instadapp and is six times DeFi Saver's 0.05%. The README should say that 0.3% includes
gas, while DeFi Saver and Instadapp charge gas on top. The README's "What is different" table compares Parapet
only to Reactive's demo. ReacDEFI is a live product in the same ecosystem with a repay mode, and judges from
Reactive will know it. Name it and say what differs.

---

# Part B: research that would make Parapet better

Each item gives the source, what it says, and the change it implies. Effort assumes one developer who knows
the code. Risk means the risk of breaking the working demo.

## B1. Smarter triggers

### B1.1 Velocity-aware early trigger (predictive health factor)

- **Source.** Signals and Spoils ([arXiv 2606.03434](https://arxiv.org/pdf/2606.03434)) shows that liquidators
  act on where the price is *going*, not where it is. Belenko and Vosorov derive a closed-form liquidation
  probability under geometric Brownian motion and propose it as a forward-looking add-on to the health factor
  ([arXiv 2505.08100](https://arxiv.org/abs/2505.08100)). Morpho's pre-liquidation scales its close factor
  linearly with how deep the position is in the band ([docs](https://docs.morpho.org/overview/concepts/liquidation/)).
- **The problem it fixes.** `ShieldReactive._onPrice` compares `mirroredHF(user, price)` with `triggerHF` at
  the current price only. In a fast crash, the next oracle step can jump from above the trigger to below 1.0.
- **Change.** In `_onPrice`, also compute `projected = price - (lastPrice - price)`, which assumes the next step
  repeats this one, and request the callback if `mirroredHF(user, projected) < triggerHF` when the price is
  falling. In `LiquidationShield.rescue`, the "healthy" check must allow it: add an `early` flag to the payload
  and accept when `hf < triggerHF + EARLY_MARGIN` (for example 0.05e18). The top-up still sizes to the target
  from the live price, so the borrower only adds their own collateral a little early.
- **Effort:** about half a day, including a test with a two-step crash. **Risk:** low. Worst case, one extra
  rescue fee in a choppy market. **Demo value:** high. `DemoLoan.run()` can crash in two steps
  ($2,000 → $1,900 → $1,800) and the dashboard shows the rescue firing after step one.

### B1.2 Real oracle events (Chainlink `AnswerUpdated`)

- **Source.** On mainnet, Aave's `AaveOracle` reads Chainlink aggregators. The price event is
  `AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt)`, emitted by the
  *underlying aggregator*, which Chainlink can replace behind the proxy (proxy event `AggregatorConfirmed`)
  ([Chainlink docs](https://docs.chain.link/chainlink-local/api-reference/v023/aggregator-interface),
  [AggregatorProxy source](https://cdn.jsdelivr.net/npm/chainlink-solidity@0.1.4/contracts/v0.7/dev/AggregatorProxy.sol)).
- **Gap in the code.** `MockAaveOracle` emits `AssetPriceUpdated(asset, price, timestamp)` with the price in
  `data`. A real feed puts the price in `topic_1`. `ShieldReactive.react` decodes `log.data`, so it would not
  work against a real feed unchanged. Also, the ETH/USD heartbeat and deviation threshold on Base were not
  found (the Ethereum mainnet feed is 0.5% and 3,600 s). **Unverified** for Base.
- **Change.** Have the mock emit `AnswerUpdated` from a separate "aggregator" mock, and change `react` to read
  `int256(log.topic_1)`. Optionally also subscribe to the proxy's `AggregatorConfirmed` and re-subscribe to the
  new aggregator through a callback. **Effort:** about 2 hours for the event format, plus half a day for
  re-subscription. **Risk:** low. **Why it matters:** it answers "would this work on real Aave?" with code
  instead of a README sentence.

### B1.3 Reacting to the price before the oracle updates (cross-chain lead signal)

- **Source.** Signals and Spoils: Chainlink updates on Optimism predict the next updates on Base and Arbitrum,
  and searchers already trade on that. Sadeghi and Feinstein show that constant-product AMM prices can be pushed
  within a block, and that pool fees are what make this unprofitable
  ([arXiv 2602.12104](https://arxiv.org/html/2602.12104v1)).
- **Fit.** Subscribing to events on several chains is Reactive's core feature. `ShieldReactive` could subscribe
  to the same feed on another chain (or a Uniswap pool's `Swap`) and rescue ahead of the Base update.
- **Hard part.** `rescue` re-checks against the Base oracle, which has not moved yet, so it would skip
  ("healthy"). Accepting a price from the reactive contract means trusting a lead feed that can be pushed
  within a block. You would need a bounded "projected price" argument (for example, at most 3% below the Base
  oracle) plus the early margin from B1.1.
- **Effort:** 1.5 to 2 days, plus a second mock feed on another testnet. **Risk:** medium. **Verdict:** a
  good post-hackathon feature and a strong slide, but not for this deadline. B1.1 gets most of the benefit with
  one feed.

## B2. Rescue sizing: top-up compared with repaying debt

### The maths (derived from the shield's own formula, HF = C·LT / D)

- Adding collateral x to reach target H: x_c = H·D/LT − C (what `rescue` computes now).
- Repaying debt x to reach H: x_r = D − C·LT/H.
- Their ratio: **x_c / x_r = H / LT**, for any C and D. At H = 1.40 and LT = 0.83, a top-up needs **1.69×** the
  capital of a repayment.

A WETH reserve also falls in value with the collateral: a 20% crash cuts the reserve's dollar value by 20% just
when it is needed. A USDC reserve used to repay does not.

### Partial-liquidation rules to design against

- Aave V3: when HF is between 0.95 and 1.0, a liquidator can repay at most 50% of the debt. Below 0.95, or when
  the position is small (under about $2,000 of collateral or debt after v3.3), up to 100%
  ([Aave docs](https://docs.aave.com/developers/guides/liquidations), [BGD v3.3 post](https://governance.aave.com/t/bgd-aave-v3-3-feat-umbrella/20129)).
  Implication: a partial rescue that leaves HF just above 0.95 halves the worst case. The shield's
  partial-rescue path already "puts everything in". That is correct, and the README can cite this rule.
- Aave V4: liquidators repay only down to a target HF, with a bonus that rises linearly as HF falls (the
  Avalanche proposal uses target 1.24 and a max bonus at HF 0.90) ([Aave V4 docs](https://aave.com/docs/aave-v4/positions/liquidations),
  [Avalanche ARFC](https://governance.aave.com/t/arfc-deploy-aave-v4-on-avalanche/25165/2)). The shield's
  target-HF model matches V4's own vocabulary, which is worth saying in the README.

### Alternatives in the literature

| Design | What it does | Source | Lesson for Parapet |
|---|---|---|---|
| Miqado (reversible call options) | outside "supporters" top up an unhealthy position for a premium; 89.82% less collateral liquidated in a worst-case simulation | [Qin et al., FC 2023, arXiv 2303.15162](https://arxiv.org/abs/2303.15162v2) | Parapet is the self-supported version of this. A pooled reserve where third parties earn the fee (the Miqado model) is a credible "next step" slide |
| Curve LLAMMA soft liquidation | collateral is converted gradually across price bands; losses are typically low but can reach double digits in high volatility | [Curve docs](https://docs.curve.fi/crvUSD/llamma-explainer), [loss statistics](https://resources.curve.finance/crvusd/loan-concepts) | a staged rescue (small top-ups at several triggers) instead of one large one. B1.1 gets this cheaply |
| Euler reverse Dutch auction | the liquidation discount grows as health falls, so liquidators act as soon as it is profitable | [Euler docs](https://docs.euler.finance/concepts/risk/liquidations) | no direct change; it supports "act early, while it is cheap" |
| Morpho pre-liquidation | the borrower opts into a softer liquidation band with a smaller bonus | [Morpho blog](https://morpho.org/blog/introducing-pre-liquidations-enhanced-loan-management-on-morpho) | a competitor and a complement; mention it in "What is different" |

### Change: a repay mode

- **Code.** Add `protectRepay(trigger, target, usdcAmount)` and a `mode` field to `Protection` in
  `LiquidationShield.sol`. In `rescue`, when the mode is repay, compute `x_r` in base units, convert it to USDC
  units, and call `pool.repay(usdc, amount, 2, user)`. Aave V3's `repay` accepts any `onBehalfOf`, and the mock
  pool already has `repay(address,uint256,uint256,address)`. `ShieldReactive` needs no change, because the
  trigger logic is the same.
- **Fee for gas.** The fee would be in USDC, which the callback proxy cannot take. Simplest fix: require a
  small WETH "gas deposit" next to the USDC reserve, and charge the fee from it as today.
- **Effort:** 1 to 1.5 days with tests and a dashboard toggle. **Risk:** low to medium, because it adds a second
  code path in `rescue`.

## B3. Fees and making the Reactive side pay for itself

### What the numbers say

- Measured on Lasna: about 1 lREACT for deploy, two demos and 23 rescue cycles, about 0.04 lREACT per cycle,
  where each cycle is two price events and two or three snapshots (README).
- Reactive's current docs: callbacks are paid in the destination chain's native token, reactive transactions
  are capped at 900,000 gas, and reactive execution is paid in REACT by the contract
  ([Reactive economy docs](https://dev.reactive.network/economy), [system contract](https://dev.reactive.network/system-contract)).
  The docs disagree between versions on the exact formula.
- REACT traded at about $0.0023 on 15 November 2026 ([LBank](https://www.lbank.com/price/reactive-network),
  *single source*; other snapshots: $0.0035 on 23 October and $0.0040 on 16 September).

### Fee floor arithmetic

| Basis | 0.04 REACT costs | Base gas per rescue (0.0000305 ETH ÷ 23) | Floor needed |
|---|---|---|---|
| Testnet faucet rate (100 lREACT/ETH) | 0.0004 ETH | about 0.0000013 ETH | **about 0.00041 ETH** (4.1× the current 0.0001 floor) |
| Market price ($0.0023/REACT) | about $0.0001 | about 0.0000013 ETH | the current 0.0001 ETH floor covers it with a wide margin |

At 0.3%, a 0.00041 ETH floor applies to every top-up below 0.137 WETH, so on testnet it would charge
almost every rescue the floor.

### The real problem: cost grows with ticks × loans, revenue grows with rescues

Every oracle update runs `_onPrice` over every user, whether or not anyone is rescued. Daily Lasna cost is
roughly *updates per day × (fixed cost + per-user cost × N)*. Fees arrive only when a loan is rescued, so a calm
month with 500 watched loans costs money and earns nothing. Options:

1. **Watch fee (recommended).** In `protect()` and on each `rescue`, charge `watchFeePerDay × days since the
   last charge` from the reserve, unwrap it, and add it to the ledger. About 15 lines in `LiquidationShield`.
   Keepers price this way: Chainlink Automation and Gelato bill a premium on gas used, not on value protected.
2. **Make the cost visible on-chain.** Add `reactiveCostLedger()` to the dashboard, fed by the reactive
   contract's debt or balance, so judges see both sides of the funding. This is presentation only.
3. **Close the loop for real.** Bridge fees to Reactive and call `depositTo` on the system contract. On mainnet
   this needs a swap and a bridge. That is post-hackathon. Say so in the README rather than implying it.

Also reduce the cost per tick: B4's bucketing makes the per-user term apply only to users near their trigger.

### Smaller fee issues found in the code

- `_skip` ("healthy" or "cooldown") costs callback gas and earns no fee. Because `_skip` snapshots and clears
  `pending`, a loan in cooldown can be requested again on every tick for 10 s. Fix: have `ShieldReactive` keep
  `pending` until the snapshot shows a new `lastRescueAt`, or emit the cooldown end in the snapshot.
- When `reserve ≤ fee`, the partial path sets `fee = 0`, so that callback is paid from outside funding. This is
  minor, but the `opsLedger` should count it.

## B4. More loans and more assets

- **Bucketing by liquidation price.** For each position, the price at which its mirrored HF equals its trigger
  is `p* = trigger × debt / (collateral × LT)` (all values from the snapshot). Store users in buckets keyed by
  `p* / width`. On a tick from `lastPrice` down to `price`, scan only the buckets between them, plus a margin
  for B1.1. Move a user between buckets on each snapshot. **Effort:** about 1 day in `ShieldReactive`
  (mapping of bucket to user array with swap-and-pop, plus an index per user). **Risk:** medium, because it
  replaces the core loop. Needed beyond a few hundred loans: at about 2 to 3k gas per cold read in the loop, the
  900,000-gas reactive limit is reached in the low hundreds of users. That estimate is **Unverified**. Measure
  it with `forge test --gas-report`.
- **Multiple collateral assets.** Subscribe to one price event per asset (topic_1 = asset, as now) and mirror
  per-asset collateral amounts. Mirrored HF becomes Σ(amountᵢ × priceᵢ × LTᵢ) / debt. This is a larger change
  (both contracts plus the snapshot format). It belongs after the hackathon.
- **Debt drift.** The mirror stores debt in USD, but interest accrues between snapshots, so the mirrored HF is
  slightly optimistic. A CRON subscription on Reactive (as the Reactive demo uses) could call back `sync` for
  loans not snapshotted in a day. Low priority.

## B5. Security of callback-driven protection

### B5.1 Unbounded `users` array (fix before judging)

- **Finding (from reading the code).** `LiquidationShield.sync(address user)` is public and emits
  `PositionSnapshot` for any address. `ShieldReactive._onSnapshot` pushes every new address into `users`, even
  when it is inactive, and `_onPrice` loops over all of them on every tick. On Base, with 200 ms blocks and
  cheap gas, anyone can call `sync(randomAddress)` many times. Each call (a) costs the reactive contract one
  `react()` paid in lREACT, and (b) adds a permanent entry to the loop. Enough entries push `_onPrice` past the
  reactive gas limit, and then **no one is rescued**. `protect(t, T, 0)` from fresh addresses does the same.
- **Fix.** In `LiquidationShield._snapshot`, return early unless the user has a protection (`triggerHF != 0`),
  or allow `sync` only from the user. In `ShieldReactive._onSnapshot`, add a user to `users` only when `active`,
  and swap-and-pop on deactivation. **Effort:** about 2 hours with a test. **Risk:** low. `DemoLoan.run()` calls
  `sync(address(this))` for a protected loan, so it is unaffected.

### B5.2 Lost callbacks leave a loan pending

- **Finding.** README limit: if a callback never lands, the loan stays `pending` until its next snapshot.
  `DemoLoan` works around this by calling `sync` on each run. A real borrower would not know to do that.
- **Fix.** Store `pendingSince` (Lasna block number from `log`) in `Position`. In `_onPrice`, treat
  `pending` as expired after N blocks or about 60 s. **Effort:** about 1 hour. **Risk:** low.

### B5.3 Oracle manipulation and mispricing

- The shield trusts the same oracle Aave liquidates against, so a manipulated price that triggers a rescue
  would also trigger liquidation. A rescue can only *add* the borrower's own reserve to their own position:
  the worst case is an unnecessary top-up plus a 0.3% fee. The CAPO incident (A2) shows mispricing happens
  even without an attacker. Parapet helped in that scenario. Say so.
- If B1.3 is ever built, the lead price must be capped against the Base oracle, because AMM prices can be
  pushed within a block ([Sadeghi and Feinstein](https://arxiv.org/html/2602.12104v1)).

### B5.4 MEV around the rescue

- Base has no public mempool, and the sequencer orders transactions by priority fee
  ([Base block building](https://docs.base.org/chain/block-building)), so front-running a callback transaction
  is limited. **Unverified** for the post-Denim ordering rules. The real race is the oracle back-run (A3):
  liquidators land in the update's block, and Parapet lands about six blocks later. Parapet wins only while HF
  is still above 1.0. That is why the trigger margin, and B1.1, matter more than shaving latency.
- One griefing path: a borrower in `pending` withdraws their reserve before the callback lands. The rescue then
  skips ("no reserve") and the shield pays gas for nothing. The cost is bounded (one callback). A cooldown on
  `withdrawReserve` while pending would close it. Low priority.

### B5.5 Reserve exhaustion

- A borrower whose reserve is too small gets a partial rescue. That is correct, and under the Aave V3 rules it
  still helps if it keeps HF above 0.95 (B2). The dashboard could warn when `reserve < x_c` at a 20% further
  drop. This is UI only.

---

# Ranked shortlist for the 6 December 2026 deadline

Judging criteria: Execution, Integration (the reactive contract doing real work), Usefulness, Craft.

| Rank | Change | Files | Effort | Criteria it moves | Why it ranks here |
|---|---|---|---|---|---|
| **1** | **Bound the `users` loop and expire stale `pending` flags** (B5.1 + B5.2) | `LiquidationShield._snapshot`, `ShieldReactive._onSnapshot` / `_onPrice` | about 3 hours plus tests | Craft, Execution | Anyone can currently stop all rescues. A judge reading the code can find it. The fix is cheap and low-risk, and it removes the "pending until the next snapshot" item from the README's Limits |
| **2** | **Velocity-aware early trigger** (B1.1) | `ShieldReactive._onPrice`, `LiquidationShield.rescue` (early flag), `DemoLoan.run` (two-step crash) | about half a day | Integration, Usefulness, demo | The reactive contract makes a judgement on the price stream instead of a threshold compare. It answers the strongest objection (one oracle step jumping past the trigger), and it is visible in the demo |
| **3** | **Repay mode with a USDC reserve** (B2) | `LiquidationShield` (`protectRepay`, a `mode` field, a repay branch), tests, dashboard toggle | 1 to 1.5 days | Usefulness | 1.69× less capital for the same health factor, and the reserve does not crash with the collateral. It matches ReacDEFI's feature set, so leaving it out is a visible gap |

**Next, if time allows:** switch the mock to Chainlink's `AnswerUpdated` format (B1.2, about 2 hours, strong for
"would this work on mainnet"), and add a per-day watch fee plus a Lasna cost line on the dashboard (B3).
**Leave for after the hackathon:** cross-chain lead signals (B1.3), bucketing (B4), multi-asset (B4).

**README edits these findings support:** add the cascade table (A2) and the $2,500 against $116 example (A1);
name ReacDEFI and Morpho pre-liquidations in "What is different"; reword the latency claim as "acts within
about six Base blocks of the price event, while the loan is still above 1.0"; and replace the Lasna-funding
paragraph with the faucet-rate against market-price comparison (B3).
