#!/usr/bin/env bash
# Live demo on testnet: open a small loan, protect it, crash the price, and time the rescue end to end.
# Usage: bash script/demo.sh [crash_price_usd]   (default 1800; run deploy.sh first)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; . ./deployments.env; set +a
CRASH=${1:-1800}
B="--rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY"
send() { cast send "$@" $B > /dev/null; }
hf() { cast call "$POOL" "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC" | sed -n 6p; }

if [ "$(cast call "$POOL" "debt(address)(uint256)" "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC")" = "0" ]; then
  echo "Opening a loan: 0.004 WETH collateral at \$2000, borrow 5.5 USDC (HF 1.2)"
  send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 200000000000
  send "$WETH" "deposit()" --value 0.008ether
  send "$WETH" "approve(address,uint256)" "$POOL" "$(cast max-uint)"
  send "$WETH" "approve(address,uint256)" "$SHIELD" "$(cast max-uint)"
  send "$POOL" "supply(address,uint256,address,uint16)" "$WETH" 4000000000000000 "$DEPLOYER" 0
  send "$POOL" "borrow(address,uint256,uint256,uint16,address)" "$USDC" 5500000 2 0 "$DEPLOYER"
  echo "Protecting it: trigger HF 1.15, target HF 1.4, reserve 0.004 WETH"
  send "$SHIELD" "protect(uint64,uint64,uint256)" 1150000000000000000 1400000000000000000 4000000000000000
  echo -n "Waiting for the reactive contract to mirror the position"
  for _ in $(seq 1 30); do
    active=$(cast call "$REACTIVE" "positions(address)(uint128,uint128,uint32,uint64,bool,bool,bool)" "$DEPLOYER" --rpc-url "$REACTIVE_LASNA_RPC" | sed -n 5p)
    [ "$active" = "true" ] && break; echo -n "."; sleep 2
  done; echo " $active"
fi

echo "HF before crash: $(hf)"
echo "Crashing WETH to \$$CRASH ..."
receipt=$(cast send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" "${CRASH}00000000" $B --json)
crash_tx=$(echo "$receipt" | jq -r '(.data // .).transactionHash')
crash_block=$(( $(echo "$receipt" | jq -r '(.data // .).blockNumber') ))
crash_ts=$(cast block "$crash_block" -f timestamp --rpc-url "$BASE_SEPOLIA_RPC")
start=$(date +%s.%N)
echo "price tx $crash_tx (block $crash_block)"

topic=$(cast keccak "Rescued(address,uint256,uint256,uint256,uint256,uint256)")
for _ in $(seq 1 120); do
  # public RPC caps eth_getLogs at 200 blocks (~40s of Base Sepolia's 200ms blocks)
  log=$(cast logs --from-block "$crash_block" --to-block $((crash_block + 199)) --address "$SHIELD" "$topic"     --rpc-url "$BASE_SEPOLIA_RPC" --json 2>/dev/null | jq -c '(if type == "object" then .data else . end) | if type == "array" then (.[-1] // empty) else empty end' || true)
  [ -n "$log" ] && break; sleep 0.5
done
[ -z "$log" ] && { echo "No rescue within 60s"; exit 1; }
wall=$(awk -v a="$(date +%s.%N)" -v b="$start" 'BEGIN{printf "%.1f", a-b}')
rescue_block=$(( $(echo "$log" | jq -r .blockNumber) ))
rescue_ts=$(cast block "$rescue_block" -f timestamp --rpc-url "$BASE_SEPOLIA_RPC")
echo "rescue tx $(echo "$log" | jq -r .transactionHash) (block $rescue_block)"
echo "latency: $((rescue_block - crash_block)) Base blocks, $((rescue_ts - crash_ts))s by block timestamps, ${wall}s wall clock (incl. polling)"
echo "HF after rescue: $(hf)"
echo "ops ledger (fees, outside funding, gas paid, balance, debt):"
cast call "$SHIELD" "opsLedger()(uint256,uint256,uint256,uint256,uint256)" --rpc-url "$BASE_SEPOLIA_RPC"
echo "$crash_tx,$(echo "$log" | jq -r .transactionHash),$((rescue_block - crash_block)),$((rescue_ts - crash_ts)),$wall" >> results.csv
