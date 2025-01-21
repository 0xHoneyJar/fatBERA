// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/fatBERA.sol";
import "../src/fatBERAProxy.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {console} from "forge-std/console.sol";

contract DeployFatBERA is Script {
    // Configuration
    uint256 constant maxDeposits = 10_000_000 ether;
    address constant WBERA = 0x7507c1dc16935B82698e4C63f2746A2fCf994dF8;
    
    function deployImplementation() external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy implementation
        fatBERA fatBERAImplementation = new fatBERA();
        
        vm.stopBroadcast();

        console.log("fatBERA implementation deployed to: %s", address(fatBERAImplementation));
        return address(fatBERAImplementation);
    }

    function deployProxy(address implementation) external returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy proxy without initialization
        fatBERAProxy proxy = new fatBERAProxy(
            implementation,
            deployer,
            "" // Empty initialization data
        );

        vm.stopBroadcast();

        console.log("fatBERA proxy deployed to: %s", address(proxy));
        console.log("Proxy admin owner set to: %s", deployer);
        
        return address(proxy);
    }

    function initializeProxy(address proxyAddress) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Initialize the proxy
        fatBERA(payable(proxyAddress)).initialize(WBERA, deployer, maxDeposits);
        
        // Set max deposits and pause
        // fatBERA(payable(proxyAddress)).setMaxDeposits(maxDeposits);
        // fatBERA(payable(proxyAddress)).pause();

        vm.stopBroadcast();

        console.log("Proxy initialized");
        console.log("Contract owner set to: %s", deployer);
        console.log("Max deposits set to: %d", maxDeposits);
        console.log("Contract paused");
    }

    function run() external {
        // Deploy implementation first
        address implementation = this.deployImplementation();
        
        // Then deploy proxy
        address proxy = this.deployProxy(implementation);

        // Finally initialize
        this.initializeProxy(proxy);
    }
} 