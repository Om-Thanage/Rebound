#!/usr/bin/env bash
# Deploys the mock Aave market + LiquidationShield on Base Sepolia and ShieldReactive on Reactive Lasna.
# The two contracts reference each other, so both addresses are predicted from the deployer's nonces first.
# Usage: bash script/deploy.sh   (reads PRIVATE_KEY and RPC URLs from .env, writes deployments.env)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

BASE_CHAIN_ID=84532
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
SHIELD_SEED=${SHIELD_SEED:-0.002ether}       # covers callback gas until the first fees arrive
REACTIVE_FUNDING=${REACTIVE_FUNDING:-1ether} # lREACT for the reactive contract's own execution
FEE_BPS=${FEE_BPS:-30}
MIN_FEE_WEI=${MIN_FEE_WEI:-100000000000000}  # 0.0001 ETH

base_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$BASE_SEPOLIA_RPC")
lasna_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$REACTIVE_LASNA_RPC")
addr() { cast compute-address "$DEPLOYER" --nonce "$1" | awk '{print $NF}'; }

WETH=$(addr $((base_nonce)))
USDC=$(addr $((base_nonce + 1)))
ORACLE=$(addr $((base_nonce + 2)))
POOL=$(addr $((base_nonce + 3)))
SHIELD=$(addr $((base_nonce + 4)))
REACTIVE=$(addr $((lasna_nonce)))
echo "predicted: WETH=$WETH USDC=$USDC ORACLE=$ORACLE POOL=$POOL SHIELD=$SHIELD REACTIVE=$REACTIVE"

create() { # rpc, contract, [extra args...]; prints the deployed address
  local rpc=$1 contract=$2; shift 2
  forge create --broadcast --rpc-url "$rpc" --private-key "$PRIVATE_KEY" "$contract" "$@" \
    | awk '/Deployed to:/ {print $3}'
}
check() { [ "$1" = "$2" ] || { echo "address mismatch: got $1, expected $2" >&2; exit 1; }; }

check "$(create "$REACTIVE_LASNA_RPC" src/ShieldReactive.sol:ShieldReactive --value "$REACTIVE_FUNDING" \
  --constructor-args $BASE_CHAIN_ID "$ORACLE" "$SHIELD" "$WETH")" "$REACTIVE"
echo "ShieldReactive on Lasna: $REACTIVE"

check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockTokens.sol:MockWETH)" "$WETH"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockTokens.sol:MockERC20 --constructor-args "Test USD Coin" tUSDC 6)" "$USDC"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAaveOracle.sol:MockAaveOracle)" "$ORACLE"
check "$(create "$BASE_SEPOLIA_RPC" src/mocks/MockAavePool.sol:MockAavePool --constructor-args "$WETH" "$USDC" "$ORACLE")" "$POOL"
check "$(create "$BASE_SEPOLIA_RPC" src/LiquidationShield.sol:LiquidationShield --value "$SHIELD_SEED" \
  --constructor-args "$CALLBACK_PROXY_BASE_SEPOLIA" "$REACTIVE" "$POOL" "$ORACLE" "$WETH" $FEE_BPS $MIN_FEE_WEI)" "$SHIELD"
echo "Base Sepolia contracts deployed."

cast send "$ORACLE" "setAssetPrice(address,uint256)" "$WETH" 200000000000 \
  --rpc-url "$BASE_SEPOLIA_RPC" --private-key "$PRIVATE_KEY" > /dev/null
echo "WETH price set to \$2000."

cat > deployments.env <<EOF
DEPLOYER=$DEPLOYER
WETH=$WETH
USDC=$USDC
ORACLE=$ORACLE
POOL=$POOL
SHIELD=$SHIELD
REACTIVE=$REACTIVE
EOF
echo "Saved deployments.env"
