// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

contract DeployHook is Script {
    function run() external returns (PointsHook hook) {
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        address poolManager = vm.envAddress("ARBITRUM_SEPOLIA_POOL_MANAGER");
        address create2Deployer = vm.envAddress("CREATE2_DEPLOYER");

        bytes memory constructorArgs = abi.encode(poolManager);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2Deployer, flags, type(PointsHook).creationCode, constructorArgs);
        vm.startBroadcast();

        hook = new PointsHook{salt: salt}(IPoolManager(poolManager));
        require(hookAddress == address(hook), "PointsHookScript: hook address mismatch");
        vm.stopBroadcast();
    }
}
