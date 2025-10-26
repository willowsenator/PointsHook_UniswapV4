// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {PoolManager} from "v4-core/PoolManager.sol";

contract DeployHook is Script {
    function run() external returns (PointsHook hook) {
        address deployer = msg.sender;
        vm.startBroadcast(deployer);
        PoolManager poolManager = new PoolManager(deployer);
        hook = new PointsHook(poolManager);
        vm.stopBroadcast();
    }
}
