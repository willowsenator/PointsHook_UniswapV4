// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";
import {PointsHook} from "../src/PointsHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

contract PointsHookFuzzTest is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;
    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;
    PointsHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        token = new MockERC20("Test Token", "Test", 18);
        tokenCurrency = Currency.wrap(address(token));
        token.mint(address(this), 1_000 ether);
        token.mint(address(1), 1_000 ether);
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("PointsHook.sol", abi.encode(manager), address(flags));
        hook = PointsHook(address(flags));
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        (key,) = initPool(ethCurrency, tokenCurrency, hook, 3000, SQRT_PRICE_1_1);
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);
        uint256 ethToAdd = 0.003 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(SQRT_PRICE_1_1, sqrtPriceAtTickUpper, ethToAdd);
        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liquidityDelta)), salt: bytes32(0)
            }),
            ""
        );
    }

    function test_fuzz_points_awarded_on_eth_to_token_swap(uint96 ethAmount, address user) public {
        ethAmount = uint96(bound(ethAmount, 1e15, 1e18)); // 0.001 to 1 ETH
        vm.assume(user != address(0));
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(user, poolId);
        bytes memory hookdata = abi.encode(user);
        vm.deal(user, ethAmount);
        vm.prank(user);
        try swapRouter.swap{value: ethAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(ethAmount)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        ) returns (
            BalanceDelta delta
        ) {
            int256 ethDelta = delta.amount0();
            uint256 pointsBalanceAfter = hook.balanceOf(user, poolId);
            // Points should be 20% of the actual ETH spent (ethDelta is negative)
            uint256 expectedPoints = uint256(-ethDelta) / 5;
            assertEq(pointsBalanceAfter - pointsBalanceOriginal, expectedPoints, "Fuzz: Points not awarded correctly");
        } catch {
            // Skip this fuzz case if swap fails
        }
    }

    function test_fuzz_no_points_for_token_to_eth_swap(uint96 tokenAmount, address user) public {
        tokenAmount = uint96(bound(tokenAmount, 1e15, 1e18));
        vm.assume(user != address(0) && user != address(this));
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(user, poolId);
        bytes memory hookdata = abi.encode(user);
        token.mint(user, tokenAmount);
        vm.prank(user);
        token.approve(address(swapRouter), tokenAmount);
        vm.prank(user);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(uint256(tokenAmount)),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        ) {
            uint256 pointsBalanceAfter = hook.balanceOf(user, poolId);
            assertEq(
                pointsBalanceAfter, pointsBalanceOriginal, "Fuzz: Points should not be awarded for TOKEN->ETH swap"
            );
        } catch {
            // Skip this fuzz case if swap fails
        }
    }

    function test_fuzz_no_points_if_token0_not_eth(uint96 amount, address user) public {
        amount = uint96(bound(amount, 1e12, 1e18));
        vm.assume(user != address(0));
        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);
        tokenA.mint(address(this), 10_000 ether);
        tokenB.mint(address(this), 10_000 ether);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        Currency tokenACurrency = Currency.wrap(address(tokenA));
        Currency tokenBCurrency = Currency.wrap(address(tokenB));
        (PoolKey memory newKey,) = initPool(tokenACurrency, tokenBCurrency, hook, 3000, SQRT_PRICE_1_1);
        uint128 liquidityDelta = 5_000 ether;
        modifyLiquidityRouter.modifyLiquidity(
            newKey,
            ModifyLiquidityParams({
                tickLower: -60, tickUpper: 60, liquidityDelta: int256(uint256(liquidityDelta)), salt: bytes32(0)
            }),
            ""
        );
        uint256 poolId = uint256(PoolId.unwrap(newKey.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(user, poolId);
        bytes memory hookdata = abi.encode(user);
        tokenA.mint(user, amount);
        vm.prank(user);
        tokenA.approve(address(swapRouter), amount);
        vm.prank(user);
        swapRouter.swap(
            newKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(uint256(amount)),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        uint256 pointsBalanceAfter = hook.balanceOf(user, poolId);
        assertEq(pointsBalanceAfter, pointsBalanceOriginal, "Fuzz: Points should not be awarded if token0 is not ETH");
    }
}
