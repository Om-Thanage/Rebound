#!/usr/bin/env bash
# Latency benchmark on live testnets. Each round:
#   1. reset: price back to $2000, withdraw the collateral the last rescue added (HF back to ~1.2),
#      and return it to the shield reserve, so every round starts from the same position;
#   2. crash: price to $1800 (HF ~1.08, under the 1.15 trigger);
#   3. measure: Base block of the price event -> Lasna block of RescueRequested -> Base block of Rescued.
# Base Sepolia makes a block every 200 ms, so (rescue block - price block) x 0.2 s is the end-to-end latency.
# Usage: bash script/bench.sh [rounds]   (needs an open, protected position: run demo.sh once first)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-./.env}"; . ./deployments.env; set +a
ROUNDS=${1:-20}
START=${START:-1} # first round number, to continue an earlier run
B="--rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY"
R="--rpc-url $REACTIVE_LASNA_RPC"
OUT=results/bench.csv
mkdir -p results
[ -f "$OUT" ] || echo "round,price_tx,price_block,request_lasna_block,rescue_tx,rescue_block,blocks,end_to_end_s,to_reactive_s,hf_after" > "$OUT"

RESCUED=$(cast keccak "Rescued(address,uint256,uint256,uint256,uint256,uint256)")
REQUESTED=$(cast keccak "RescueRequested(address,uint256,uint256,uint256)")
BASE_COLL=4000000000000000 # 0.004 WETH = HF 1.2 at $2000 with 5.5 USDC debt

send() { cast send "$@" $B > /dev/null; }
field() { jq -r "$1" 2>/dev/null || true; }
coll() { cast call "$POOL" "collateral(address)(uint256)" "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}'; }
mirrored_coll() { cast call "$REACTIVE" "collateralOf(address,uint256)(uint256)" "$DEPLOYER" 0 $R | awk '{print $1}'; }
logs() { # chain-rpc from to address topic -> first matching log as compact JSON, or nothing
  cast logs --from-block "$2" --to-block "$3" --address "$4" "$5" --rpc-url "$1" --json 2>/dev/null \
    | jq -c '(if type == "object" then .data else . end) | if type == "array" then (.[0] // empty) else empty end' 2>/dev/null || true
}

for round in $(seq "$START" $((START + ROUNDS - 1))); do
  # ---- reset to the same starting position
  send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 200000000000
  extra=$(( $(coll) - BASE_COLL ))
  if [ "$extra" -gt 0 ]; then
    send "$POOL" "withdraw(address,uint256,address)" "$WETH" "$extra" "$DEPLOYER"
    send "$SHIELD" "protect(uint64,uint64,uint256)" 1150000000000000000 1400000000000000000 "$extra"
  fi
  for _ in $(seq 1 40); do [ "$(mirrored_coll)" = "$BASE_COLL" ] && break; sleep 1; done
  sleep 11 # let the shield's 10 s cooldown pass

  # ---- crash
  receipt=$(cast send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 180000000000 $B --json)
  price_tx=$(echo "$receipt" | field '(.data // .).transactionHash')
  price_block=$(( $(echo "$receipt" | field '(.data // .).blockNumber') ))
  price_ts=$(cast block "$price_block" -f timestamp --rpc-url "$BASE_SEPOLIA_RPC")
  lasna_from=$(( $(cast block-number $R) - 5 ))

  # ---- wait for the rescue on Base (log window kept under the RPC's 200-block cap)
  rescue=""
  for _ in $(seq 1 120); do
    rescue=$(logs "$BASE_SEPOLIA_RPC" "$price_block" $((price_block + 199)) "$SHIELD" "$RESCUED")
    [ -n "$rescue" ] && break; sleep 0.5
  done
  if [ -z "$rescue" ]; then echo "round $round: no rescue within 60s"; echo "$round,$price_tx,$price_block,,,,,,," >> "$OUT"; continue; fi
  rescue_tx=$(echo "$rescue" | field .transactionHash)
  rescue_block=$(( $(echo "$rescue" | field .blockNumber) ))

  request=$(logs "$REACTIVE_LASNA_RPC" "$lasna_from" $((lasna_from + 120)) "$REACTIVE" "$REQUESTED")
  req_block=""; to_reactive=""
  if [ -n "$request" ]; then
    req_block=$(( $(echo "$request" | field .blockNumber) ))
    to_reactive=$(( $(cast block "$req_block" -f timestamp $R) - price_ts ))
  fi

  blocks=$((rescue_block - price_block))
  e2e=$(awk -v b="$blocks" 'BEGIN{printf "%.1f", b*0.2}')
  hf=$(cast call "$POOL" "getUserAccountData(address)(uint256,uint256,uint256,uint256,uint256,uint256)" "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC" | sed -n 6p | awk '{print $1}')
  echo "$round,$price_tx,$price_block,$req_block,$rescue_tx,$rescue_block,$blocks,$e2e,$to_reactive,$hf" >> "$OUT"
  echo "round $round: $blocks blocks = ${e2e}s end to end (price -> Lasna ${to_reactive:-?}s), HF after $hf"
done

# ---- summary
awk -F, 'NR > 1 && $7 != "" { v[++n] = $8; s += $8 }
  END {
    if (!n) { print "no successful rounds"; exit }
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    p90 = v[int((n - 1) * 0.9) + 1]
    printf "rounds %d | median %.1fs | p90 %.1fs | min %.1fs | max %.1fs | mean %.2fs\n", n, v[int((n + 1) / 2)], p90, v[1], v[n], s / n
  }' "$OUT" | tee results/summary.txt
