# Review of `main` and the fixes, 24 November 2026

A review of everything on `main` after the v2 deployment (contracts, scripts, dashboard, data and README), the
fixes made for it, and what is still left for you to do. Three groups of fixes went in as separate commits: the
contracts, the scripts, and the dashboard. The README fixes go in with this report.

## How it was reviewed

- **Static review** of every file changed since the first version, including the contracts written before your v2
  deployment. Live chain state could not be read from the review environment (its network policy blocks the Base
  Sepolia and Lasna RPCs), so nothing here comes from the deployed contracts.
- **Data check:** each benchmark rescue in `results/bench.csv` was matched against `dashboard/data/rescues.json`.
  All 10 rounds were the benchmark loan's own rescues.
- **Local end-to-end run** on three anvil chains standing in for Base Sepolia, Lasna (with a mock system contract)
  and Ethereum Sepolia, with a small relay playing Reactive Network: `deploy.sh`, demo runs in all three modes,
  another user's loan, `demo.sh`, `status.sh`.
- **Browser test** of the dashboard's rescue list in Playwright against those chains, once with Blockscout
  answering and once with it returning HTTP 429.
- **`forge test`:** 48 tests pass (43 before), including new ones for every contract fix.

## Findings and what was done

| # | Finding | Severity | Introduced by | Status |
|---|---|---|---|---|
| 1 | Anyone could stop the live demo with one transaction | critical | contract commit (Claude) | fixed in code; **needs a redeploy** |
| 2 | Lasna runs out of lREACT during judging | high | measurement yours; extra snapshots from the contract commit | code part fixed (**needs a redeploy**); **top-up is yours** |
| 3 | Rescue list misses everything between the shipped file and the last hour | high | dashboard commit (yours) | fixed |
| 4 | Every non-demo loan labelled "Benchmark loan" | medium | dashboard commit (yours) | fixed |
| 5 | Combined-mode rescue shows only the WETH it added | low | dashboard commit (yours) | fixed |
| 6 | Scripts match the first `Rescued` event, not this loan's | medium | first version | fixed |
| 7 | `to_reactive_s` empty in all v2 rows | low | bench run and backfill (yours) | script fixed; **backfill is yours** |
| 8 | lREACT shown is only part of what Reactive can charge | medium | both | fixed |
| 9 | Repay mode drops protection silently when its USDC runs out | medium | contract commit (Claude) | fixed in code; **needs a redeploy** |
| 10 | CRON may not be firing on Lasna | unknown | contract commit (Claude) | **check with `status.sh`** |
| 11 | README: "six blocks" for 1.4 s; Lasna verification not mentioned | low | README (yours) | wording fixed; **verification is yours** |
| 12 | A price event that rescues nobody cost 78k gas (found while fixing 2) | medium | contract commit (Claude) | fixed in code; **needs a redeploy** |

### 1. Anyone could stop the live demo

**Problem.** The mocks left four admin calls open to anyone: `MockAggregatorProxy.confirmAggregator`,
`MockAaveOracle.setAssetSource`, `MockAavePool.setBorrowRate` and `MockAavePool.listCollateral`. Pointing the
WETH feed at a contract whose `latestAnswer()` reverts made every `getAssetPrice` revert, and with it
`getUserAccountData`. That stops every demo run, every rescue and every withdrawal. The reactive contract would
also have followed the swap and subscribed to the attacker's contract. You could swap it back, but so could they.

**Fix.** All four calls are deployer-only. `MockAggregator.updateAnswer` accepts only the deployer and one
updater: the oracle for the Base feeds, nobody for the lead feed. `MockAaveOracle.setAssetPrice` stays open,
because the dashboard's Run a rescue depends on it. `deploy.sh` passes the predicted oracle address to the Base
aggregators. Files: `src/mocks/MockAggregator.sol`, `src/mocks/MockAaveOracle.sol`, `src/mocks/MockAavePool.sol`,
`script/deploy.sh`.

**Verified.** `test_mockAdminIsDeployerOnly` checks every locked call from a stranger, and checks that the open
price move still works. On the local chains, `deploy.sh` deployed with the new arguments and set prices through
the oracle.

**Left.** The deployed mocks are still open until you redeploy. The pool address is fixed inside the shield, so a
redeploy means new addresses for everything.

### 2. Lasna runs out of lREACT during judging

**Problem.** Your README measures 0.111 lREACT per dashboard run, and both benchmark runs ran dry partway. One
lREACT covers about 9 runs. Once it's out, Reactive stops calling `react()` and Run a rescue times out.

**Fix (code).** One `DemoLoan.run` used to send up to three snapshots (from `depositRepayReserve`, `configure`
and `protect`). The new `LiquidationShield.setup(trigger, target, step, mode, wethAmount, debtAmount)` does all of
it with one snapshot, and `DemoLoan` uses it in its constructor and in every run. On the local chains a run is now
five reactive transactions: three price events, one snapshot, and one snapshot after the rescue.

**Verified.** `test_setupPublishesOneSnapshot` and `test_demoRunPublishesOneSnapshot` (three runs, two modes).

**Left (yours).** Before judging, deposit 50–100 lREACT with `depositTo`; the command is in the README. Check the
runway with `bash script/status.sh`.

### 3. Rescue list misses rescues

**Problem.** `readRescues` used `data/rescues.json` and then only the last 20,000 blocks. On Base that's 1.1
hours. Every rescue between the file's `toBlock` and an hour ago was missing, while "All rescues" showed the
contract's true count, so the numbers on the page disagreed.

**Fix.** Three layers in `dashboard/live.js`:
1. the shipped history, read once;
2. one Blockscout call per page load (its Etherscan-style `getLogs`, any range in a single call) for the gap;
3. RPC every 10 seconds, only for blocks since the last read.

If Blockscout fails, the page reads up to a day over RPC and shows which blocks it could not load and "N of M
rescues listed", rather than dropping rescues silently.

**Verified.** In the browser test, the shipped file held 2 of 6 rescues:
- **Blockscout answering:** it was called twice (once per event type) and all 6 rescues were listed. A rescue
  made while the page was open appeared within 10 s, with no further Blockscout calls.
- **Blockscout returning 429:** all 6 were still listed, through the RPC fallback.

**Not verified.** The real Blockscout endpoint's parameters and CORS. [likely] They are the standard
Etherscan-compatible ones, and the fallback covers a failure.

### 4. Loan labels

**Fix.** Rows are labelled demo loan, benchmark loan (the deployer, from `deployment.json`'s new `deployer` field)
or other loan, and there's a new "Other loans" filter. `export-deployment.mjs` writes the deployer address.
**Verified** in the browser test: demo 4, benchmark 1, other 1.

### 5. Combined-mode rows

**Fix.** A rescue that repaid and topped up shows both, in the form "Repaid X USDC and added Y WETH". Repay rows
read the debt from `RescueDetail` in the same transaction.

**Not exercised in the browser.** The local combined-mode run had enough USDC to repay alone, so it showed the
repay-only form; the both-parts form wasn't seen on screen.

### 6. Scripts not filtered by loan

**Problem.** `bench.sh`, `demo.sh` and `lead.sh` took the first `Rescued` (and `RescueRequested`) event after the
crash, from any loan. A visitor's demo rescue during a benchmark would have been timed as the round. Your v2 data
is clean: all 10 rows are the benchmark loan's.

**Fix.** Every log query also filters topic 1 by the deployer's address. The topic filtering was checked with
`cast logs` on a local chain.

### 7. `to_reactive_s` empty

**Problem.** `bench.sh` computed it in an unguarded `$(( ... ))`. A failed Lasna block lookup left it empty, and
the backfill filled the Lasna transaction but not this column.

**Fix.** The lookup is guarded. The new `script/backfill-bench.mjs` fills the missing values from the two chains'
block timestamps. Both chains stamp whole seconds, so this is a 1-second-resolution split, not a precise one.

**Left (yours).** Run `node script/backfill-bench.mjs`, then `node script/export-bench.mjs`.

### 8. lREACT runway

**Problem.** The dashboard showed only `reserves(address)`. When that is empty, Reactive charges the contract
through `pay()`, which spends the contract's own balance; that is where `deploy.sh`'s constructor funding sits
(confirmed in Reactive's system-contract source).

**Fix.** The dashboard and `status.sh` show reserve plus own balance minus debt, as demo runs left ("in debt:
paused until topped up" when it is). **Verified** in the browser test: a 5 lREACT reserve plus a 1 lREACT balance
showed "6.000 lREACT, about 54 demo runs".

### 9. Repay mode lapses silently

**Problem.** A repay-mode loan with no USDC left counted as inactive, so the reactive contract dropped it while
its WETH reserve was still there. Protection stopped without any signal.

**Fix.** Repay mode with an empty repay reserve tops up with WETH and emits `RepayReserveEmpty(user)`.
**Verified** by `test_repayModeFallsBackToTopUpWhenRepayReserveIsEmpty`.

### 10. CRON

**Not settled.** Your README says the contract spent nothing over three idle minutes. Either `Cron100` fires less
often than that on Lasna, or the subscription isn't working at all. `status.sh` prints `cronTicks` and warns when
it is 0. If it is still 0 an hour after the redeploy, the CRON sweep and the stale-loan refresh don't run, and the
README and dashboard should stop claiming them.

### 11. README

**Fixed:** "about seven Base blocks (1.4 s)", test counts, the `setup` call, the three-layer rescue list, the
lREACT top-up command, `status.sh` and `backfill-bench.mjs`, the mock locks under Limits, and a "Next deploy" note
saying which fixes aren't deployed yet.

**Left (yours).** The README says the Base and Ethereum Sepolia contracts are verified on Sourcify, and says
nothing about ShieldReactive on Lasna. That's the contract the Integration criterion is about. Verify it on
Lasna's explorer if you can, and say so either way.

### 12. Gas for a price event that rescues nobody (found while fixing #2)

**Problem.** With $10 trigger-price buckets, each price event read about 40 bucket slots, mostly empty, at a
cold-read cost each: 78k gas with cold storage, paid on every price event.

**Fix.** `ShieldReactive` keeps a bitmap of non-empty buckets, so one storage word covers 256 buckets. It is set
when a loan is placed and cleared when a bucket empties.

**Verified.** `test_idleTickGas` measures 39k with cold storage (−50%) and fails above 50k. The worst-case crash
tick is 671k, still under the 900k limit, and every crossed loan still gets its rescue over the following ticks.

## What you need to do, in order

1. **Redeploy:** `bash script/deploy.sh`. Fixes 1, 2, 9 and 12 are in contract code and reach the testnet only
   this way. Then run `node script/export-deployment.mjs`.
2. **Fund Lasna:** `depositTo` 50–100 lREACT (command in the README). Check with `bash script/status.sh`.
3. **Benchmark:** `bash script/bench.sh 20`, then `node script/backfill-bench.mjs`, `node script/export-bench.mjs`
   and `node script/export-rescues.mjs`.
4. **README tables:** new addresses, full-loop transactions and benchmark numbers. Remove the "Next deploy" note.
5. **CRON:** after an hour, `status.sh` should show `cronTicks` above 0. If not, tell me and we'll look at the
   subscription.
6. **Lasna verification** of ShieldReactive, and the demo video.

## Not verified in this review

- Anything about the deployed contracts' current state: counters, lREACT reserve, CRON, Blockscout and Sourcify
  pages.
- The real Blockscout API from a browser (CORS and parameters). The fallback was tested; the real endpoint was not.
- Gas on Lasna itself. Local figures come from anvil with a mock system contract, which stores callbacks the real
  one only emits, so local reactive gas for a rescue request is higher than on Lasna.
