// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract PointsHookTest is Test, Deployers, ERC1155TokenReceiver {
    // Token use in ETH - TOKEN pool
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Deploy Pool Manager and Routers
        deployFreshManagerAndRouters();

        // Deploy mock ERC20 token
        token = new MockERC20("Test Token", "Test", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint some tokens
        token.mint(address(this), 1_000 ether);
        token.mint(address(1), 1_000 ether);

        // Deploy hook to an address with AFTER_SWAP_FLAG
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("PointsHook.sol", abi.encode(manager), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve routers to spend tokens
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize the pool
        (key,) = initPool(
            ethCurrency, // Currency0 (ETH)
            tokenCurrency, // Currency1 (TOKEN)
            hook, // Hook
            3000, // Fee
            SQRT_PRICE_1_1 // Initial sqrt price
        );

        // Add some liquidity
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.003 ether;

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, sqrtPriceAtTickUpper, ethToAdd);

        uint128 tokenToAdd =
            LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAtTickLower, SQRT_PRICE_1_1, liquidityDelta);

        modifyLiquidityRouter.modifyLiquidity{
            value: ethToAdd
        }(
            key,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liquidityDelta)), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolId);

        // Include hookdata with user address to receive points
        bytes memory hookdata = abi.encode(address(this));

        swapRouter.swap{
            value: 0.001 ether
        }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );

        uint256 pointsBalanceAfter = hook.balanceOf(address(this), poolId);

        assertEq(pointsBalanceAfter - pointsBalanceOriginal, 0.0002 ether, "Points not awarded correctly");
    }
}
