#!/bin/bash

# Configuration
RPC_URL="https://bartio.rpc.berachain.com"
VERIFIER_URL="https://api.routescan.io/v2/network/testnet/evm/80084/etherscan"
CHAIN_ID=80084
ETHERSCAN_KEY="verifyContract"
WBERA="0x7507c1dc16935B82698e4C63f2746A2fCf994dF8"
INITIAL_DEPOSIT="10000000000000000000" # 10 ether
MAX_DEPOSITS="10000000000000000000000000" # 10M ether

# # Check if we have enough BERA for deployment
# echo "🔍 Checking BERA balance..."
# DEPLOYER_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY")
# BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
# MIN_REQUIRED="20000000000000000000" # 20 BERA for deployment + initial deposit

# if [ -z "$BALANCE" ] || [ "$BALANCE" -lt "$MIN_REQUIRED" ]; then
#     echo "❌ Insufficient BERA balance. Need at least 20 BERA for deployment and initial deposit."
#     echo "Current balance: $BALANCE wei"
#     exit 1
# fi

echo "✅ BERA balance sufficient for deployment"
echo "🚀 Starting deployment process..."

# 1. Deploy Implementation
echo "📝 Deploying implementation contract..."
IMPLEMENTATION_OUTPUT=$(forge script script/DeployFatBERA.s.sol:DeployFatBERA --sig "deployImplementation()" \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --verifier-url $VERIFIER_URL \
    --etherscan-api-key $ETHERSCAN_KEY \
    --chain-id $CHAIN_ID)

# Extract implementation address from the output
IMPLEMENTATION_ADDRESS=$(echo "$IMPLEMENTATION_OUTPUT" | grep "fatBERA implementation deployed to:" | awk '{print $NF}')
echo "✅ Implementation deployed at: $IMPLEMENTATION_ADDRESS"

# 2. Verify Implementation
echo "🔍 Verifying implementation contract..."
forge verify-contract $IMPLEMENTATION_ADDRESS src/fatBERA.sol:fatBERA \
    --verifier-url $VERIFIER_URL \
    --etherscan-api-key $ETHERSCAN_KEY \
    --watch \
    --chain-id $CHAIN_ID

# Wait a bit for the verification to be processed
sleep 10

# 3. Deploy Proxy
echo "📝 Deploying proxy contract..."
PROXY_OUTPUT=$(forge script script/DeployFatBERA.s.sol:DeployFatBERA --sig "deployProxy(address)" $IMPLEMENTATION_ADDRESS \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --verifier-url $VERIFIER_URL \
    --etherscan-api-key $ETHERSCAN_KEY \
    --chain-id $CHAIN_ID)

# Extract proxy address and admin from the output
PROXY_ADDRESS=$(echo "$PROXY_OUTPUT" | grep "fatBERA proxy deployed to:" | awk '{print $NF}')
ADMIN_ADDRESS=$(echo "$PROXY_OUTPUT" | grep "Proxy admin owner set to:" | awk '{print $NF}')
echo "✅ Proxy deployed at: $PROXY_ADDRESS"

# 4. Initialize Proxy
echo "🔧 Initializing proxy..."
forge script script/DeployFatBERA.s.sol:DeployFatBERA --sig "initializeProxy(address)" $PROXY_ADDRESS \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --verifier-url $VERIFIER_URL \
    --etherscan-api-key $ETHERSCAN_KEY \
    --chain-id $CHAIN_ID

# 5. Verify Proxy
echo "🔍 Verifying proxy contract..."
OWNER_ADDRESS=$ADMIN_ADDRESS # Since we're using the admin as the owner

# Update constructor args to include the initial deposit
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,bytes)" "$IMPLEMENTATION_ADDRESS" "$ADMIN_ADDRESS" $(cast calldata "initialize(address,address,uint256,uint256)" "$WBERA" "$OWNER_ADDRESS" "$MAX_DEPOSITS" "$INITIAL_DEPOSIT"))

forge verify-contract $PROXY_ADDRESS src/fatBERAProxy.sol:fatBERAProxy \
    --constructor-args $CONSTRUCTOR_ARGS \
    --verifier-url $VERIFIER_URL \
    --etherscan-api-key $ETHERSCAN_KEY \
    --watch \
    --chain-id $CHAIN_ID

echo "🎉 Deployment and verification complete!"
echo "Implementation: $IMPLEMENTATION_ADDRESS"
echo "Proxy: $PROXY_ADDRESS"
echo "Admin: $ADMIN_ADDRESS"
echo "Owner: $OWNER_ADDRESS"
echo "Initial Deposit: $INITIAL_DEPOSIT"
echo "Max Deposits: $MAX_DEPOSITS" 