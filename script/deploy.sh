#!/usr/bin/env bash
# Deploys the mock Aave market (two collateral assets, Chainlink-style feeds) + LiquidationShield + DemoLoan on
# Base Sepolia, an optional lead price feed on a second chain, and ShieldReactive on Reactive Lasna.
# The shield and the reactive contract reference each other, so every address is predicted from nonces first.
# Usage: bash script/deploy.sh   (reads PRIVATE_KEY and RPC URLs from .env, or from $ENV_FILE; writes deployments.env)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . "${ENV_FILE:-./.env}"; set +a

BASE_CHAIN_ID=${BASE_CHAIN_ID:-84532}
LEAD_CHAIN_ID=${LEAD_CHAIN_ID:-11155111}      # Ethereum Sepolia; set LEAD_RPC= (empty) to skip the lead feed
LEAD_RPC=${LEAD_RPC-${ETHEREUM_SEPOLIA_RPC:-}}
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
SHIELD_SEED=${SHIELD_SEED:-0.002ether}       # covers callback gas until the first fees arrive
REACTIVE_FUNDING=${REACTIVE_FUNDING:-1ether} # lREACT for the reactive contract's own execution
FEE_BPS=${FEE_BPS:-30}
MIN_FEE_WEI=${MIN_FEE_WEI:-100000000000000}  # 0.0001 ETH
WATCH_FEE_WEI_PER_DAY=${WATCH_FEE_WEI_PER_DAY:-10000000000000} # 0.00001 ETH a day per protected loan
CRON_EVENT=${CRON_EVENT:-Cron10000}          # CRON event: Cron10000 fires every 10,000 Lasna blocks (~3 h); Cron100 costs ~100x more idle
DEMO_RESERVE=${DEMO_RESERVE:-3000000000000000} # 0.003 WETH; DemoLoan also takes 0.004 WETH of collateral
WETH_BUCKET=${WETH_BUCKET:-1000000000}       # $10 trigger-price buckets for WETH (8 decimals)
WBTC_BUCKET=${WBTC_BUCKET:-25000000000}      # $250 for WBTC

base_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC")
lasna_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$REACTIVE_LASNA_RPC")
addr() { cast compute-address "$1" --nonce "$2" | awk '{print $NF}'; }

WETH=$(addr "$DEPLOYER" $((base_nonce)))
USDC=$(addr "$DEPLOYER" $((base_nonce + 1)))
WBTC=$(addr "$DEPLOYER" $((base_nonce + 2)))
ORACLE=$(addr "$DEPLOYER" $((base_nonce + 3)))
AGG_WETH=$(addr "$DEPLOYER" $((base_nonce + 4)))
AGG_WBTC=$(addr "$DEPLOYER" $((base_nonce + 5)))
PROXY_WETH=$(addr "$DEPLOYER" $((base_nonce + 6)))
PROXY_WBTC=$(addr "$DEPLOYER" $((base_nonce + 7)))
POOL=$(addr "$DEPLOYER" $((base_nonce + 8)))
SHIELD=$(addr "$DEPLOYER" $((base_nonce + 9)))
AWETH=$(addr "$POOL" 1) # the pool creates one aToken per collateral asset: WETH in its constructor,
AWBTC=$(addr "$POOL" 2) # WBTC when it is listed
# REACTIVE_DEPLOYED reuses a ShieldReactive from an earlier, interrupted run (its constructor args must match)
REACTIVE=${REACTIVE_DEPLOYED:-$(addr "$DEPLOYER" $((lasna_nonce)))}
LEAD_AGG=0x0000000000000000000000000000000000000000
LEAD_ID=0
if [ -n "$LEAD_RPC" ]; then
  # LEAD_AGG_DEPLOYED reuses a lead feed from an earlier, interrupted run (Sepolia receipts can be slow)
  LEAD_AGG=${LEAD_AGG_DEPLOYED:-$(addr "$DEPLOYER" "$(cast nonce "$DEPLOYER" --rpc-url "$LEAD_RPC")")}
  LEAD_ID=$LEAD_CHAIN_ID
fi
CRON_TOPIC=$(cast keccak "${CRON_EVENT}(uint256)")
echo "predicted: SHIELD=$SHIELD REACTIVE=$REACTIVE POOL=$POOL ORACLE=$ORACLE AGG_WETH=$AGG_WETH LEAD_AGG=$LEAD_AGG"

create() { # rpc, contract, [extra args...]; prints the deployed address
  local rpc=$1 contract=$2; shift 2
  forge create --broadcast --rpc-url "$rpc" --private-key "$PRIVATE_KEY" "$contract" "$@" \
    | awk '/Deployed to:/ {print $3}'
}
check() { [ "$1" = "$2" ] || { echo "address mismatch: got $1, expected $2" >&2; exit 1; }; }
send() { cast send "$@" --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" > /dev/null; }

if [ -n "$LEAD_RPC" ]; then
  [ -n "${LEAD_AGG_DEPLOYED:-}" ] || check "$(create "$LEAD_RPC" src/mocks/MockAggregator.sol:MockAggregator --constructor-args 0x0000000000000000000000000000000000000000)" "$LEAD_AGG"
  cast send "$LEAD_AGG" "updateAnswer(int256)" 200000000000 --rpc-url "$LEAD_RPC" --private-key "$PRIVATE_KEY" > /dev/null
  echo "Lead WETH/USD feed on chain $LEAD_CHAIN_ID: $LEAD_AGG"
fi

RC_CONFIG="($BASE_CHAIN_ID,$SHIELD,[$WETH,$WBTC],[18,8],[$AGG_WETH,$AGG_WBTC],[$PROXY_WETH,$PROXY_WBTC],[$WETH_BUCKET,$WBTC_BUCKET],$CRON_TOPIC,$LEAD_ID,$LEAD_AGG,0)"
# a 1 wei tip (forge's default) can sit in Lasna's pool indefinitely; pay a real one
[ -n "${REACTIVE_DEPLOYED:-}" ] || check "$(create "$REACTIVE_LASNA_RPC" src/ShieldReactive.sol:ShieldReactive \
  --value "$REACTIVE_FUNDING" --priority-gas-price 1gwei --constructor-args "$RC_CONFIG")" "$REACTIVE"
echo "ShieldReactive on Lasna: $REACTIVE"

check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockTokens.sol:MockWETH)" "$WETH"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockTokens.sol:MockERC20 --constructor-args "Test USD Coin" tUSDC 6)" "$USDC"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockTokens.sol:MockERC20 --constructor-args "Test Wrapped BTC" tWBTC 8)" "$WBTC"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAaveOracle.sol:MockAaveOracle)" "$ORACLE"
# the oracle (predicted above) is the one updater allowed besides the deployer; it lets only the deployer and DemoLoan move prices
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAggregator.sol:MockAggregator --constructor-args "$ORACLE")" "$AGG_WETH"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAggregator.sol:MockAggregator --constructor-args "$ORACLE")" "$AGG_WBTC"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAggregator.sol:MockAggregatorProxy --constructor-args "$AGG_WETH")" "$PROXY_WETH"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAggregator.sol:MockAggregatorProxy --constructor-args "$AGG_WBTC")" "$PROXY_WBTC"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAavePool.sol:MockAavePool --constructor-args "$WETH" "$USDC" "$ORACLE")" "$POOL"
SHIELD_CONFIG="($POOL,$ORACLE,$WETH,$USDC,[$WETH,$WBTC],[$AWETH,$AWBTC],$FEE_BPS,$MIN_FEE_WEI,$WATCH_FEE_WEI_PER_DAY)"
check "$(create "$BASE_SEPOLIA_RPC" src/LiquidationShield.sol:LiquidationShield --value "$SHIELD_SEED" \
  --constructor-args "$CALLBACK_PROXY_BASE_SEPOLIA" "$REACTIVE" "$SHIELD_CONFIG")" "$SHIELD"
echo "Base Sepolia contracts deployed."

send "$ORACLE" "setAssetSource(address,address)" "$WETH" "$PROXY_WETH"
send "$ORACLE" "setAssetSource(address,address)" "$WBTC" "$PROXY_WBTC"
send "$POOL" "listCollateral(address,uint16,uint16,uint16,uint8)" "$WBTC" 7300 7800 10500 8
check "$(cast call "$POOL" "aTokenOf(address)(address)" "$WBTC" --rpc-url "$BASE_SEPOLIA_RPC")" "$AWBTC"
send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 200000000000
send "$ORACLE" "setAssetPrice(address,uint256)" "$WBTC" 6000000000000
echo "Prices set: WETH \$2,000, WBTC \$60,000."

# only the deployer and DemoLoan may move prices (each price event costs the reactive contract lREACT)
DEMO_PREDICTED=$(addr "$DEPLOYER" $(($(cast nonce "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC") + 1)))
send "$ORACLE" "setDemo(address)" "$DEMO_PREDICTED"
DEMO=$(create "$BASE_SEPOLIA_RPC" src/DemoLoan.sol:DemoLoan --value "$((4000000000000000 + DEMO_RESERVE))" \
  --constructor-args "$WETH" "$USDC" "$ORACLE" "$POOL" "$SHIELD" "$DEMO_RESERVE")
check "$DEMO" "$DEMO_PREDICTED"
echo "DemoLoan: $DEMO"

cat > deployments.env <<EOF
DEPLOYER=$DEPLOYER
WETH=$WETH
USDC=$USDC
WBTC=$WBTC
ORACLE=$ORACLE
AGG_WETH=$AGG_WETH
AGG_WBTC=$AGG_WBTC
PROXY_WETH=$PROXY_WETH
PROXY_WBTC=$PROXY_WBTC
POOL=$POOL
SHIELD=$SHIELD
REACTIVE=$REACTIVE
DEMO=$DEMO
LEAD_CHAIN_ID=$LEAD_ID
LEAD_AGG=$LEAD_AGG
EOF
echo "Saved deployments.env"
