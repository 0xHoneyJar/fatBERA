// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/BountyHelperWrapper.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console} from "forge-std/console.sol";

contract DeployBountyHelperWrapper is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_ARB");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Required: BountyHelper contract address
        address bountyHelper = 0x4a19d3107F81aAa55202264f2c246aA75734eDb6;
        
        // Optional: Bot address (defaults to deployer if not set)
        address botAddress = 0x99F4C3cc5eb1839EB9fF9BA248a4d88F6241a134;
        

        vm.startBroadcast(deployerPrivateKey);

        // Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            BountyHelperWrapper.initialize.selector,
            bountyHelper,
            deployer,  // deployer is admin
            botAddress
        );

        // Deploy the UUPS proxy
        address proxy = Upgrades.deployUUPSProxy(
            "BountyHelperWrapper.sol:BountyHelperWrapper", 
            initData
        );

        vm.stopBroadcast();

        // Log deployment information
        console.log("BountyHelperWrapper proxy deployed to: %s", proxy);
        console.log("Implementation deployed at: %s", Upgrades.getImplementationAddress(proxy));
        console.log("Bounty Helper address: %s", bountyHelper);
        console.log("Admin address: %s", deployer);
        console.log("Bot address: %s", botAddress);
    }
}