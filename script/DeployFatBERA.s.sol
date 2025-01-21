// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/fatBERA.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IWBERA} from "../src/interfaces/IWBERA.sol";
import {console} from "forge-std/console.sol";

contract DeployFatBERA is Script {
    // Configuration
    uint256 public constant MAX_DEPOSITS = 10_000_000 ether;
    uint256 public constant INITIAL_DEPOSIT = 1 ether; // Initial deposit to prevent share price manipulation
    address public constant WBERA = 0x7507c1dc16935B82698e4C63f2746A2fCf994dF8;

    function run() external {
        // Get deployer info
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deployer address: %s", deployer);
        console.log("WBERA address: %s", WBERA);
        
        vm.startBroadcast(deployerPrivateKey);

        try this.deploy(deployer) returns (address proxyAddress) {
            console.log("Deployment successful!");
            console.log("Proxy deployed to: %s", proxyAddress);
            console.log("Contract owner set to: %s", deployer);
            console.log("Max deposits set to: %d", MAX_DEPOSITS);
            console.log("Initial deposit set to: %d", INITIAL_DEPOSIT);
            console.log("Contract paused: true");
        } catch Error(string memory reason) {
            console.log("Deployment failed: %s", reason);
            vm.stopBroadcast();
            revert(reason);
        }

        vm.stopBroadcast();
    }

    function deploy(address deployer) external returns (address) {
        // 1. Deploy implementation
        fatBERA implementation = new fatBERA();
        console.log("Implementation deployed to: %s", address(implementation));

        // 2. Deploy proxy with empty initialization data
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            "" // Empty initialization data
        );
        fatBERA vault = fatBERA(payable(address(proxy)));
        console.log("Proxy deployed to: %s", address(proxy));

        // 3. Initialize vault with native BERA
        // The vault will handle wrapping BERA to WBERA internally
        // Since we're in startBroadcast, this is called from the deployer's EOA
        vault.initialize{value: INITIAL_DEPOSIT}(
            WBERA,
            deployer,
            MAX_DEPOSITS,
            INITIAL_DEPOSIT
        );
        console.log("Vault initialized successfully");

        return address(proxy);
    }
} 