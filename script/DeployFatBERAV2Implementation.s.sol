// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/fatBERAV2.sol";
import {console} from "forge-std/console.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DeployFatBERAV2Implementation
 * @notice Script to deploy the fatBERAV2 implementation and generate Gnosis Safe transaction data
 * @dev This script:
 *      1. Deploys the fatBERAV2 implementation contract
 *      2. Generates the transaction data for upgradeToAndCall
 *      3. Outputs all necessary information for the Gnosis Safe transaction
 * 
 *      Usage:
 *      forge script script/DeployFatBERAV2Implementation.s.sol --broadcast --rpc-url $RPC_URL
 */
contract DeployFatBERAV2Implementation is Script {
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Configuration - Update these addresses for your deployment
        address withdrawFulfiller = 0xE6644e0b941A03Af8ff10BDB185d5E74D520270e; // Default to deployer if not set
        address existingProxy = 0xBAE11292A3E693aF73651BDa350D752AE4A391D4; // Set this to your existing proxy address
        
        console.log("=== fatBERAV2 Implementation Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Withdraw Fulfiller:", withdrawFulfiller);
        console.log("Existing Proxy:", existingProxy);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy the new implementation
        fatBERAV2 newImplementation = new fatBERAV2();
        
        vm.stopBroadcast();
        
        console.log("SUCCESS: fatBERAV2 implementation deployed!");
        console.log("Implementation address:", address(newImplementation));
        console.log("");
        
        // Generate transaction data for Gnosis Safe
        generateGnosisTransactionData(address(newImplementation), withdrawFulfiller, existingProxy);
    }
    
    /**
     * @notice Generates the transaction data needed for the Gnosis Safe upgrade
     * @param newImplementation Address of the deployed fatBERAV2 implementation
     * @param withdrawFulfiller Address that will have the WITHDRAW_FULFILLER_ROLE
     * @param existingProxy Address of the existing proxy (if provided)
     */
    function generateGnosisTransactionData(
        address newImplementation,
        address withdrawFulfiller,
        address existingProxy
    ) internal view {
        console.log("=== Gnosis Safe Transaction Data ===");
        console.log("");
        
        // Generate initializeV2 call data
        bytes memory initV2Data = abi.encodeWithSelector(
            fatBERAV2.initializeV2.selector,
            withdrawFulfiller
        );
        
        // Generate full upgradeToAndCall data
        bytes memory upgradeData = abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            newImplementation,
            initV2Data
        );
        
        console.log("For Gnosis Safe Transaction Builder:");
        console.log("-----------------------------------");
        if (existingProxy != address(0)) {
            console.log("To Address:", existingProxy);
        } else {
            console.log("To Address: [YOUR_EXISTING_PROXY_ADDRESS]");
        }
        console.log("Value: 0");
        console.log("Data (hex):");
        console.logBytes(upgradeData);
        console.log("");
        
        console.log("Transaction Components:");
        console.log("----------------------");
        console.log("Function: upgradeToAndCall(address,bytes)");
        console.log("New Implementation:", newImplementation);
        console.log("Withdraw Fulfiller:", withdrawFulfiller);
        console.log("");
        
        console.log("InitializeV2 Call Data:");
        console.logBytes(initV2Data);
        console.log("");
        
        console.log("Function Selectors:");
        console.log("-------------------");
        console.log("upgradeToAndCall selector:", vm.toString(UUPSUpgradeable.upgradeToAndCall.selector));
        console.log("initializeV2 selector:", vm.toString(fatBERAV2.initializeV2.selector));
        console.log("");
    }
    
    /**
     * @notice Helper function to verify the deployment was successful
     * @param implementation Address of the deployed implementation
     */
    function verifyDeployment(address implementation) external view {
        console.log("=== Deployment Verification ===");
        
        // Check if the contract exists
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(implementation)
        }
        
        require(codeSize > 0, "Implementation contract not deployed");
        console.log("SUCCESS: Implementation contract deployed successfully");
        console.log("Code size:", codeSize, "bytes");
        
        // Try to call a view function to verify it's the correct contract
        try fatBERAV2(implementation).MAX_REWARDS_TOKENS() returns (uint256 maxRewards) {
            console.log("SUCCESS: Contract interface verification passed");
            console.log("Max rewards tokens:", maxRewards);
        } catch {
            console.log("ERROR: Contract interface verification failed");
        }
    }
} 