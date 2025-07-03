// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {OptimizedLiquidityHelper} from "../src/OptimizedLiquidityHelper.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DeployOptimizedLiquidityHelper is Script {
    // Berachain mainnet addresses (update these when deploying)
    address constant WBERA = 0x6969696969696969696969696969696969696969;
    address constant FATBERA = 0xBAE11292A3E693aF73651BDa350D752AE4A391D4; // Update with actual address
    address constant XFATBERA = 0xcAc89B3F94eD6BAb04113884deeE2A55293c2DD7; // Update with actual address
    address constant KODIAK_ISLAND_ROUTER = 0x89c8c594f8Dea5600bf8A30877E921a5E63DCCF3; // Update with actual address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the OptimizedLiquidityHelper using UUPS proxy
        bytes memory initData = abi.encodeWithSelector(
            OptimizedLiquidityHelper.initialize.selector,
            WBERA,
            FATBERA,
            XFATBERA,
            KODIAK_ISLAND_ROUTER,
            deployer
        );
        
        address proxy = Upgrades.deployUUPSProxy(
            "OptimizedLiquidityHelper.sol:OptimizedLiquidityHelper",
            initData
        );
        
        console.log("OptimizedLiquidityHelper proxy deployed at:", proxy);
        console.log("Owner set to:", deployer);
        console.log("WBERA:", WBERA);
        console.log("fatBERA:", FATBERA);
        console.log("xfatBERA:", XFATBERA);
        console.log("Kodiak Island Router:", KODIAK_ISLAND_ROUTER);

        vm.stopBroadcast();
    }
} 