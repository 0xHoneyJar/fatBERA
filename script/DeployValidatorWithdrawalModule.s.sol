// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ValidatorWithdrawalModule} from "../src/modules/ValidatorWithdrawalModule.sol";

contract DeployValidatorWithdrawalModule is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy parameters
        address deployerAdmin = deployer; // Deployer as admin initially
        address finalAdmin = 0xE6644e0b941A03Af8ff10BDB185d5E74D520270e; // Safe address (final admin)
        address initialTrigger = 0xE1Ffc8f5a4683F900a2b1793eEa5e951Ea86D821; 
        address fatBERAContract = 0xBAE11292A3E693aF73651BDa350D752AE4A391D4; // fatBERA contract address
        address safeAddress = 0xE6644e0b941A03Af8ff10BDB185d5E74D520270e; // Safe/withdraw credentials address

        // Deploy the ValidatorWithdrawalModule with deployer as initial admin
        ValidatorWithdrawalModule module = new ValidatorWithdrawalModule(deployerAdmin, initialTrigger);

        console.log("ValidatorWithdrawalModule deployed to:", address(module));
        console.log("Initial admin (deployer):", deployerAdmin);
        console.log("Final admin (Safe):", finalAdmin);
        console.log("Initial trigger address:", initialTrigger);
        console.log("Deployer address:", deployer);

        // Configure the Safe
        module.configureSafe(safeAddress, fatBERAContract);
        console.log("Safe configured with fatBERA contract:", fatBERAContract);

        // Add validator keys one by one to avoid stack too deep
        module.addValidatorKey(safeAddress, "0xa0c673180d97213c1c35fe3bf4e684dd3534baab235a106d1f71b9c8a37e4d37a056d47546964fd075501dff7f76aeaf");
        console.log("Added validator pubkey 1 to whitelist");
        
        module.addValidatorKey(safeAddress, "0x89cbd542c737cca4bc33f1ea5084a857a7620042fe37fd326ecf5aeb61f2ce096043cd0ed57ba44693cf606978b566ba");
        console.log("Added validator pubkey 2 to whitelist");
        
        module.addValidatorKey(safeAddress, "0xb82a791d7c3d72efa6759e0250785346266d6c70ed881424ec63ad4d060904983bc57903fa133a9bc00c2d6f9b12964d");
        console.log("Added validator pubkey 3 to whitelist");
        
        module.addValidatorKey(safeAddress, "0xad821eef22a49c9d9ef7f4eb07e57c166ae80804b6524d42d51f7cd8e7e49fb75ced2d61ec6d0e812324d9001464fa0a");
        console.log("Added validator pubkey 4 to whitelist");

        // Disable both withdrawal functions for security
        module.setStartWithdrawalBatchEnabled(false);
        module.setRequestValidatorWithdrawalEnabled(false);
        console.log("Disabled startWithdrawalBatch and requestValidatorWithdrawal functions");

        // Transfer admin role to the Safe
        module.grantRole(0x0000000000000000000000000000000000000000000000000000000000000000, finalAdmin); // DEFAULT_ADMIN_ROLE
        module.revokeRole(0x0000000000000000000000000000000000000000000000000000000000000000, deployerAdmin);
        console.log("Transferred admin role from deployer to Safe");

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("ValidatorWithdrawalModule:", address(module));
        console.log("Safe Address:", safeAddress);
        console.log("fatBERA Contract:", fatBERAContract);
        console.log("Final Admin (Safe):", finalAdmin);
        console.log("Initial Trigger:", initialTrigger);
        console.log("Validator Keys Added: 4");
        console.log("Functions Disabled: startWithdrawalBatch, requestValidatorWithdrawal");
        console.log("Functions Enabled: fulfillWithdrawalBatch only");
        console.log("Admin Role: Transferred to Safe");
    }
} 