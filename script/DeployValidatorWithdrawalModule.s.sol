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
        address admin = deployer; // our safe address
        address initialTrigger = 0xE1Ffc8f5a4683F900a2b1793eEa5e951Ea86D821; 

        // Deploy the ValidatorWithdrawalModule
        ValidatorWithdrawalModule module = new ValidatorWithdrawalModule(admin, initialTrigger);

        vm.stopBroadcast();

        console.log("ValidatorWithdrawalModule deployed to:", address(module));
        console.log("Admin address:", admin);
        console.log("Initial trigger address:", initialTrigger);
        console.log("Deployer address:", deployer);
    }
} 