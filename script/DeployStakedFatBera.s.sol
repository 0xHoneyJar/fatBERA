// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/StakedFatBERA.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract Deploy is Script {
    address constant FATBERA    = 0xBAE11292A3E693aF73651BDa350D752AE4A391D4;
    address constant OPERATOR   = 0xaF582c3335D51F2DFd749F9a476eBEAb6eC5233D;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        bytes memory initData = abi.encodeWithSelector(StakedFatBERA.initialize.selector, deployer, FATBERA);
        address proxy = Upgrades.deployUUPSProxy("StakedFatBERA.sol:StakedFatBERA", initData);
        StakedFatBERA stFatBera = StakedFatBERA(proxy);

        stFatBera.grantRole(stFatBera.OPERATOR_ROLE(), OPERATOR);

        vm.stopBroadcast();
    }
}
