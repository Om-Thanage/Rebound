# Historical replay (SIMULATED)

Not a testnet measurement: `script/replay.mjs` replays Chainlink ETH/USD updates from Ethereum mainnet
(`results/sim/prices.json`, fetched by `script/fetch-prices.mjs`) against identical loans. Every loan starts
with 10 ETH of collateral at the window's first price and the debt that gives the starting HF; each
strategy gets the same reserve, 20% of the starting debt in USDC.

**Assumptions.** LT 0.83, liquidation bonus 5%, close factor 50% (100% under HF 0.95), as in Aave
V3. Liquidation happens at the oracle update that puts HF under 1.0, in the same block, before any rescue requested
at that update can land. A rescue requested at update *i* lands `delay` seconds later at the latest price known
then; if a later update liquidates first, it counts as late. The rescue re-checks the live HF (with the hint, at
most 5% under the oracle), repays the smallest amount that reaches 1.4 at that price, and pays 0.3% of what
it repays (floor 0.0001 ETH) from the reserve; a short reserve gives a partial rescue. **Simplification:**
the replay pays fees out of the same dollar reserve it repays from; the deployed shield repays from a USDC reserve
and takes fees from a separate WETH reserve, so in practice the borrower also keeps a little WETH for fees. Watch fee
0.00001 ETH a day. Interest 5% a year on outstanding debt. One collateral asset, USDC
at $1. The Ethereum mainnet feed stands in for Base's (Base's own feed updates on the same deviation rules).
Cost = liquidation bonus lost + fees + interest, in USD. Not modelled: gas for the upfront repayment, the
borrower's use of an unspent reserve, slippage, Reactive running out of lREACT.

**Totals over 4 windows x 6 starting HFs:**

| Strategy | Liquidations | Cost | Reserve still unspent at the end |
|---|---|---|---|
| No intervention | 26 | $9379 | $94897 of $94897 |
| Upfront repayment | 7 | $2886 | $0 of $94897 |
| Rebound (1.4 s) | 7 | $3154 | $17724 of $94897 |

**Rebound by delay** (all windows and starting HFs):

| Delay | Liquidations | Late | Missed | Cost |
|---|---|---|---|---|
| 1.4 s | 7 | 0 | 0 | $3154 |
| 2.6 s | 7 | 0 | 0 | $3154 |
| 60 s | 7 | 0 | 0 | $3154 |
| 300 s | 7 | 0 | 0 | $3136 |

### 2021-05-19 market crash

1705 oracle updates, $3563 at the start, low $1977 (44.5% down).

| Start HF | No intervention | Upfront repayment | Rebound (1.4 s) | Rebound rescues / partial / late / missed |
|---|---|---|---|---|
| 1.20 | **4 liq.**, $1164 | **2 liq.**, $747 | **2 liq.**, $763 | 2 / 1 / 0 / 0 |
| 1.30 | **3 liq.**, $1004 | **2 liq.**, $690 | **2 liq.**, $705 | 2 / 1 / 0 / 0 |
| 1.40 | **3 liq.**, $932 | **1 liq.**, $430 | **1 liq.**, $444 | 2 / 1 / 0 / 0 |
| 1.50 | **2 liq.**, $747 | $9 | $22 | 2 / 1 / 0 / 0 |
| 1.70 | **1 liq.**, $443 | $8 | $19 | 2 / 1 / 0 / 0 |
| 2.00 | $8 | $6 | $16 | 1 / 0 / 0 / 0 |

### 2024-08-05 global sell-off

427 oracle updates, $2999 at the start, low $2178 (27.4% down).

| Start HF | No intervention | Upfront repayment | Rebound (1.4 s) | Rebound rescues / partial / late / missed |
|---|---|---|---|---|
| 1.20 | **2 liq.**, $785 | $9 | $22 | 2 / 1 / 0 / 0 |
| 1.30 | **1 liq.**, $487 | $8 | $21 | 2 / 1 / 0 / 0 |
| 1.40 | $10 | $8 | $19 | 1 / 0 / 0 / 0 |
| 1.50 | $9 | $7 | $18 | 1 / 0 / 0 / 0 |
| 1.70 | $8 | $6 | $8 | 0 / 0 / 0 / 0 |
| 2.00 | $7 | $5 | $7 | 0 / 0 / 0 / 0 |

### 2025-10-10 tariff crash

216 oracle updates, $4477 at the start, low $3464 (22.6% down).

| Start HF | No intervention | Upfront repayment | Rebound (1.4 s) | Rebound rescues / partial / late / missed |
|---|---|---|---|---|
| 1.20 | **1 liq.**, $789 | $13 | $33 | 2 / 1 / 0 / 0 |
| 1.30 | $15 | $12 | $31 | 1 / 0 / 0 / 0 |
| 1.40 | $14 | $11 | $29 | 1 / 0 / 0 / 0 |
| 1.50 | $13 | $11 | $26 | 1 / 0 / 0 / 0 |
| 1.70 | $12 | $9 | $12 | 0 / 0 / 0 / 0 |
| 2.00 | $10 | $8 | $10 | 0 / 0 / 0 / 0 |

### 2026-01-31 to 02-05 sell-off

650 oracle updates, $3002 at the start, low $1839 (38.7% down).

| Start HF | No intervention | Upfront repayment | Rebound (1.4 s) | Rebound rescues / partial / late / missed |
|---|---|---|---|---|
| 1.20 | **3 liq.**, $921 | **1 liq.**, $433 | **1 liq.**, $447 | 2 / 1 / 0 / 0 |
| 1.30 | **3 liq.**, $853 | **1 liq.**, $400 | **1 liq.**, $413 | 2 / 1 / 0 / 0 |
| 1.40 | **2 liq.**, $686 | $15 | $28 | 2 / 1 / 0 / 0 |
| 1.50 | **1 liq.**, $433 | $14 | $26 | 3 / 2 / 0 / 0 |
| 1.70 | $16 | $13 | $24 | 1 / 1 / 0 / 0 |
| 2.00 | $13 | $11 | $14 | 0 / 0 / 0 / 0 |

Cells: liquidations (if any) and cost. Every run is in `results/sim/runs.csv`.
