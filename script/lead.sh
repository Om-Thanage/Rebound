#!/usr/bin/env bash
# Lead-feed demo: move the WETH price on the lead chain first (Ethereum Sepolia by default) and watch the shield
# rescue the loan on Base before Base's own oracle has moved. Mirrors what speculative liquidators do with
# Chainlink's Optimism updates (Signals and Spoils, arXiv 2606.03434), but on the borrower's side.
# Usage: bash script/lead.sh [lead_price_usd] [base_price_usd]
#   default 1900 then 1900: the lead price goes first, Base follows LAG seconds later (default 10).
# Needs the deployer's protected loan from demo.sh at its starting point (HF 1.2 at $2,000; 1.14 at $1,900).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-./.env}"; . ./deployments.env; set +a
LEAD=${1:-1900}
BASE=${2:-$LEAD}
LAG=${LAG:-10}
LEAD_RPC=${LEAD_RPC:-$ETHEREUM_SEPOLIA_RPC}
[ "${LEAD_AGG:-0x0000000000000000000000000000000000000000}" = "0x0000000000000000000000000000000000000000" ] && {
  echo "No lead feed deployed (LEAD_AGG in deployments.env)"; exit 1; }

B="--rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY"
BASE_COLL=4000000000000000 # the demo.sh loan: 0.004 WETH, HF 1.2 at $2,000
# reset, as bench.sh does: Base back to $2,000 and the last top-up returned to the reserve
cast send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 200000000000 $B > /dev/null
coll=$(cast call "$POOL" "collateral(address)(uint256)" "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}')
if [ "$coll" -gt "$BASE_COLL" ]; then
  cast send "$POOL" "withdraw(address,uint256,address)" "$WETH" $((coll - BASE_COLL)) "$DEPLOYER" $B > /dev/null
  cast send "$SHIELD" "protect(uint64,uint64,uint256)" 1150000000000000000 1400000000000000000 $((coll - BASE_COLL)) $B > /dev/null
fi
sleep 11 # past the shield's 10 s cooldown from any earlier rescue, and time for the mirror to update
start_block=$(cast block-number --rpc-url "$BASE_SEPOLIA_RPC")
echo "Lead feed on chain $LEAD_CHAIN_ID -> \$$LEAD"
cast send "$LEAD_AGG" "updateAnswer(int256)" "${LEAD}00000000" --rpc-url "$LEAD_RPC" --private-key "$PRIVATE_KEY" > /dev/null
lead_at=$(date +%s.%N)

topic=$(cast keccak "Rescued(address,uint256,uint256,uint256,uint256,uint256)")
me=$(cast abi-encode "f(address)" "$DEPLOYER") # only this loan's rescue, not a visitor's demo run
moved=0
for _ in $(seq 1 240); do
  now=$(date +%s.%N)
  if [ $moved = 0 ] && awk -v a="$now" -v b="$lead_at" -v l="$LAG" 'BEGIN{exit !(a-b>=l)}'; then
    echo "Base oracle follows -> \$$BASE"
    cast send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" "${BASE}00000000" $B > /dev/null
    moved=1
  fi
  log=$(cast logs --from-block "$start_block" --address "$SHIELD" "$topic" "$me" --rpc-url "$BASE_SEPOLIA_RPC" --json 2>/dev/null \
    | jq -c '(if type == "object" then .data else . end) | if type == "array" then (.[-1] // empty) else empty end' || true)
  if [ -n "$log" ]; then
    secs=$(awk -v a="$(date +%s.%N)" -v b="$lead_at" 'BEGIN{printf "%.1f", a-b}')
    [ $moved = 0 ] && when="before Base's oracle moved" || when="after Base's oracle moved"
    echo "Rescued ${secs}s after the lead update, $when: tx $(echo "$log" | jq -r .transactionHash)"
    exit 0
  fi
  sleep 0.5
done
echo "No rescue within 120s"; exit 1
