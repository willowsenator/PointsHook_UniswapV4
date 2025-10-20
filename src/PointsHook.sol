// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "solmate/src/tokens/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract PointsHook is BaseHook, ERC1155 {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager _manager) BaseHook(_manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function uri(uint256 id) public view override returns (string memory) {
        return ""; // URI not implemented
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookdata
    ) internal override returns (bytes4, int128) {
        // ETH- TOKEN
        // Not mint points for swaps involving token0 being address(0)
        if (!key.currency0.isAddressZero()) {
            return (this.afterSwap.selector, 0);
        }

        // We only mint points if user is buying TOKEN with ETH
        if (!swapParams.zeroForOne) {
            return (this.afterSwap.selector, 0);
        }

        uint256 ethSpendAmount = uint256(int256(-delta.amount0())); // amount0 is negative when user is spending ETH
        uint256 pointsForSwap = ethSpendAmount / 5; // 20% of ETH spent (divide by 5)

        _assignPoints(key.toId(), hookdata, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    function _assignPoints(PoolId poolId, bytes calldata hookdata, uint256 points) internal {
        if (hookdata.length == 0 || points == 0) {
            return;
        }
        address user = abi.decode(hookdata, (address));

        if (user != address(0)) {
            _mint(user, uint256(PoolId.unwrap(poolId)), points, "");
        }
    }
}
