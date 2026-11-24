#!/usr/bin/env bash
# Health check before a demo or judging: is the reactive side funded and doing its work, and is the demo loan ready?
# Usage: bash script/status.sh   (reads RPC URLs from .env or $ENV_FILE, addresses from deployments.env)
#   PER_RUN_LREACT (default 0.111) is the measured cost of one dashboard run on Lasna.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-./.env}"; . ./deployments.env; set +a
SYSTEM=0x8888888888888888888888888888888888888888
PER_RUN_LREACT=${PER_RUN_LREACT:-0.111}
L="--rpc-url $REACTIVE_LASNA_RPC"
B="--rpc-url $BASE_SEPOLIA_RPC"
num() { awk '{print $1}'; }
eth() { cast from-wei "$1"; }

echo "== Reactive side: ShieldReactive $REACTIVE on Lasna"
reserve=$(cast call $SYSTEM "reserves(address)(uint256)" "$REACTIVE" $L | num)
debt=$(cast call $SYSTEM "debts(address)(uint256)" "$REACTIVE" $L | num)
balance=$(cast balance "$REACTIVE" $L)
# Reactive charges the reserve first; when it is empty it calls the contract's pay(), which spends its own balance
runway=$(awk -v r="$reserve" -v b="$balance" -v d="$debt" -v p="$PER_RUN_LREACT" 'BEGIN{printf "%.0f", (r + b - d) / 1e18 / p}')
echo "reserve $(eth "$reserve") lREACT, own balance $(eth "$balance") lREACT, debt $(eth "$debt") lREACT"
echo "runway: about $runway dashboard runs at $PER_RUN_LREACT lREACT each"
[ "$debt" != "0" ] && echo "!! in debt: Reactive is not calling react(). Top up: cast send $SYSTEM 'depositTo(address)' $REACTIVE --value 5ether $L --private-key \$PRIVATE_KEY"
for f in priceTicks leadTicks cronTicks positionsChecked rescuesRequested earlyRequests refreshesRequested userCount retryCount; do
  printf "  %-20s %s\n" "$f" "$(cast call "$REACTIVE" "$f()(uint256)" $L | num)"
done
cron=$(cast call "$REACTIVE" "cronTicks()(uint256)" $L | num)
[ "$cron" = "0" ] && echo "!! cronTicks is 0: expected for a few minutes after a Cron100 deploy, or about three hours after a Cron10000 one; longer means the CRON subscription is not firing"

echo "== Base side: LiquidationShield $SHIELD"
# each read stands alone: one failing call (say, no callback proxy on a local chain) must not end the check
read_or_na() { cast call "$@" $B 2>/dev/null | num | paste -sd' ' || true; }
ledger=$(read_or_na "$SHIELD" "opsLedger()(uint256,uint256,uint256,uint256,uint256)")
[ -n "$ledger" ] && echo "$ledger" | awk '{printf "fees %s, outside funding %s, gas paid %s, balance %s, owed to proxy %s (wei)\n", $1, $2, $3, $4, $5}' \
  || echo "ops ledger unavailable (no callback proxy at this address?)"
fees=$(read_or_na "$SHIELD" "feeBreakdown()(uint256,uint256,uint256,uint256,uint256,uint256)")
[ -n "$fees" ] && echo "$fees" | awk '{printf "rescue fees %s, watch fees %s, rescues %s, skipped callbacks %s, fee-less rescues %s, refreshes %s\n", $1, $2, $3, $4, $5, $6}'

echo "== Demo loan $DEMO"
hf=$(cast call "$POOL" "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" "$DEMO" $B | sed -n 6p | num)
prot=$(cast call "$SHIELD" "protections(address)(uint128,uint128,uint64,uint64,uint64,uint64,uint64,uint8,bool)" "$DEMO" $B | num | paste -sd' ')
echo "HF $(eth "$hf"), WETH reserve $(eth "$(echo "$prot" | awk '{print $1}')"), repay reserve $(echo "$prot" | awk '{printf "%.2f", $2 / 1e6}') USDC, mode $(echo "$prot" | awk '{print $8}'), wait $(cast call "$DEMO" "waitTime()(uint256)" $B | num) s"
