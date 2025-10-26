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

import {PoolKey} from "v4-core/types/PoolKey.sol";

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

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
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

        swapRouter.swap{value: 0.001 ether}(
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

    function test_no_points_for_token_to_eth_swap() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolId);
        bytes memory hookdata = abi.encode(address(this));
        // Swap TOKEN -> ETH (zeroForOne = false)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(100 * 1e15), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        uint256 pointsBalanceAfter = hook.balanceOf(address(this), poolId);
        assertEq(pointsBalanceAfter, pointsBalanceOriginal, "Points should not be awarded for TOKEN->ETH swap");
    }

    function test_no_points_if_hookdata_empty() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolId);
        // ETH->TOKEN swap, but hookdata is empty
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        uint256 pointsBalanceAfter = hook.balanceOf(address(this), poolId);
        assertEq(pointsBalanceAfter, pointsBalanceOriginal, "Points should not be awarded if hookdata is empty");
    }

    function test_no_points_if_user_is_zero_address() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(0), poolId);
        // ETH->TOKEN swap, but user is zero address
        bytes memory hookdata = abi.encode(address(0));
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        uint256 pointsBalanceAfter = hook.balanceOf(address(0), poolId);
        assertEq(pointsBalanceAfter, pointsBalanceOriginal, "Points should not be awarded to zero address");
    }

    function test_no_points_if_token0_not_eth() public {
        // Deploy a new pool with token0 != ETH
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        // Mint and approve enough tokens for both adding liquidity and swapping
        tokenA.mint(address(this), 10_000 ether);
        tokenB.mint(address(this), 10_000 ether);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        Currency tokenACurrency = Currency.wrap(address(tokenA));
        Currency tokenBCurrency = Currency.wrap(address(tokenB));
        (PoolKey memory newKey,) = initPool(tokenACurrency, tokenBCurrency, hook, 3000, SQRT_PRICE_1_1);
        // Add liquidity (use a large amount to ensure swap succeeds)
        uint128 liquidityDelta = 5_000 ether;
        modifyLiquidityRouter.modifyLiquidity(
            newKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liquidityDelta)), salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 poolId = uint256(PoolId.unwrap(newKey.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolId);
        bytes memory hookdata = abi.encode(address(this));
        // Try to swap tokenA -> tokenB (should not mint points, use a safe amount)
        swapRouter.swap(
            newKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        uint256 pointsBalanceAfter = hook.balanceOf(address(this), poolId);
        assertEq(pointsBalanceAfter, pointsBalanceOriginal, "Points should not be awarded if token0 is not ETH");
    }

    function test_points_accumulate_on_multiple_swaps() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        bytes memory hookdata = abi.encode(address(this));
        uint256 pointsBalanceOriginal = hook.balanceOf(address(this), poolId);
        // First swap
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        // Second swap
        swapRouter.swap{value: 0.002 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -0.002 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        uint256 pointsBalanceAfter = hook.balanceOf(address(this), poolId);
        // 20% of 0.001 + 0.002 = 0.0002 + 0.0004 = 0.0006 ether
        assertEq(
            pointsBalanceAfter - pointsBalanceOriginal, 0.0006 ether, "Points should accumulate over multiple swaps"
        );
    }

    function test_no_points_for_zero_eth_swap() public {
        // Expect revert: SwapAmountCannotBeZero()
        bytes memory hookdata = abi.encode(address(this));
        vm.expectRevert("SwapAmountCannotBeZero()");
        swapRouter.swap{value: 0}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(0), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
    }
}
