// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {TremorHook} from "../src/TremorHook.sol";
import {IReferenceSource} from "../src/interfaces/IReferenceSource.sol";
import {MockReferenceSource} from "./mocks/MockReferenceSource.sol";

/// @notice Tests the Tremor hook against the real Uniswap v4 PoolManager.
contract TremorHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    TremorHook hook;
    MockReferenceSource source;

    PoolKey staticKey; // mode A
    PoolKey tremorKey; // mode D

    uint24 constant BASE = 3_000; // 30 bps
    uint24 constant MAX = 50_000; // 500 bps
    uint24 constant MARGIN = 1_000; // 10 bps
    uint16 constant BETA = 7_000; // 70%
    uint16 constant MIN_CONF = 2_000; // 20%
    uint32 constant MAX_AGE = 60; // seconds

    uint256 constant ONE = 1e18; // pool starts at price 1.0

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        vm.warp(1_000_000);

        source = new MockReferenceSource();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(address(manager), address(this));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), flags, type(TremorHook).creationCode, args);
        hook = new TremorHook{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(hook), predicted, "hook address");

        staticKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        tremorKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(address(hook)));

        hook.setPoolConfig(staticKey, _config(TremorHook.Mode.STATIC));
        hook.setPoolConfig(tremorKey, _config(TremorHook.Mode.FULL));

        manager.initialize(staticKey, SQRT_PRICE_1_1);
        manager.initialize(tremorKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(staticKey, LIQUIDITY_PARAMS, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(tremorKey, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function _config(TremorHook.Mode mode) internal view returns (TremorHook.PoolConfig memory) {
        return TremorHook.PoolConfig({
            mode: mode,
            baseFee: BASE,
            maxFee: MAX,
            marginPips: MARGIN,
            betaBps: BETA,
            minConfidenceBps: MIN_CONF,
            maxAge: MAX_AGE,
            source: IReferenceSource(address(source))
        });
    }

    /// @dev Reference 2% above the pool, seen now, 90% confidence.
    function _setReference2PctAbove() internal {
        source.set(102 * ONE / 100, uint64(block.timestamp), 1, 9_000);
    }

    // ------------------------------------------------------------------
    // Fallbacks to the normal fee
    // ------------------------------------------------------------------

    function test_noReference_paysBaseFee() public view {
        (uint24 fee, TremorHook.Reason reason,,,,) = hook.quoteFee(tremorKey, false);
        assertEq(fee, BASE);
        assertEq(uint8(reason), uint8(TremorHook.Reason.NO_REFERENCE));
    }

    function test_staticMode_paysBaseFee() public {
        _setReference2PctAbove();
        (uint24 fee, TremorHook.Reason reason,,,,) = hook.quoteFee(staticKey, false);
        assertEq(fee, BASE);
        assertEq(uint8(reason), uint8(TremorHook.Reason.STATIC_MODE));
    }

    function test_staleReference_paysBaseFee() public {
        _setReference2PctAbove();
        vm.warp(block.timestamp + MAX_AGE);
        (uint24 fee, TremorHook.Reason reason,,,,) = hook.quoteFee(tremorKey, false);
        assertEq(fee, BASE);
        assertEq(uint8(reason), uint8(TremorHook.Reason.STALE_REFERENCE));
    }

    function test_lowConfidence_paysBaseFee() public {
        source.set(102 * ONE / 100, uint64(block.timestamp), 1, MIN_CONF - 1);
        (uint24 fee, TremorHook.Reason reason,,,,) = hook.quoteFee(tremorKey, false);
        assertEq(fee, BASE);
        assertEq(uint8(reason), uint8(TremorHook.Reason.LOW_CONFIDENCE));
    }

    function test_nonAdverseSwap_paysBaseFee() public {
        _setReference2PctAbove();
        // Reference above pool: selling currency0 (zeroForOne) pushes the pool further away. Not adverse.
        (uint24 fee, TremorHook.Reason reason,,, bool adverse,) = hook.quoteFee(tremorKey, true);
        assertEq(fee, BASE);
        assertFalse(adverse);
        assertEq(uint8(reason), uint8(TremorHook.Reason.NOT_ADVERSE));
    }

    // ------------------------------------------------------------------
    // The surcharge
    // ------------------------------------------------------------------

    /// @notice The worked example in the plan: 200 bps gap, 90% confidence -> 130.8 bps.
    function test_adverseSwap_workedExample() public {
        _setReference2PctAbove();
        (uint24 fee, TremorHook.Reason reason, uint256 gapPips, uint256 conf, bool adverse,) =
            hook.quoteFee(tremorKey, false);
        assertTrue(adverse);
        assertEq(uint8(reason), uint8(TremorHook.Reason.NONE));
        assertApproxEqAbs(gapPips, 20_000, 1);
        assertEq(conf, 9_000);
        // 3,000 + 0.7 x 0.9 x (20,000 - 3,000 - 1,000) = 13,080 pips = 130.8 bps
        assertApproxEqAbs(fee, 13_080, 1);
    }

    function test_referenceBelow_sellIsAdverse() public {
        source.set(98 * ONE / 100, uint64(block.timestamp), 1, 10_000);
        (uint24 feeSell,,, , bool adverseSell,) = hook.quoteFee(tremorKey, true);
        (uint24 feeBuy,,,,,) = hook.quoteFee(tremorKey, false);
        assertTrue(adverseSell);
        assertGt(feeSell, BASE);
        assertEq(feeBuy, BASE);
    }

    function test_confidenceFadesWithAge() public {
        _setReference2PctAbove();
        vm.warp(block.timestamp + MAX_AGE / 2);
        (uint24 fee,,, uint256 conf,,) = hook.quoteFee(tremorKey, false);
        assertEq(conf, 4_500); // 90% x half the life left
        // 3,000 + 0.7 x 0.45 x 16,000 = 8,040
        assertApproxEqAbs(fee, 8_040, 1);
    }

    function test_feeCappedAtMax() public {
        source.set(2 * ONE, uint64(block.timestamp), 1, 10_000); // 100% gap
        (uint24 fee,,,,,) = hook.quoteFee(tremorKey, false);
        assertEq(fee, MAX);
    }

    function test_smallGap_noSurcharge() public {
        // 0.3% gap is inside base fee + margin, so the normal fee applies even to adverse flow.
        source.set(1003 * ONE / 1000, uint64(block.timestamp), 1, 10_000);
        (uint24 fee,,,,,) = hook.quoteFee(tremorKey, false);
        assertEq(fee, BASE);
    }

    function test_gapMode_chargesBothDirections() public {
        hook.setPoolConfig(tremorKey, _config(TremorHook.Mode.GAP));
        _setReference2PctAbove();
        (uint24 feeBuy,,,,,) = hook.quoteFee(tremorKey, false);
        (uint24 feeSell,,,,,) = hook.quoteFee(tremorKey, true);
        assertEq(feeBuy, feeSell);
        assertApproxEqAbs(feeBuy, 14_200, 1); // 3,000 + 0.7 x 16,000, confidence ignored
    }

    function test_directionalMode_ignoresConfidence() public {
        hook.setPoolConfig(tremorKey, _config(TremorHook.Mode.DIRECTIONAL));
        source.set(102 * ONE / 100, uint64(block.timestamp), 1, 0);
        (uint24 feeBuy,,,,,) = hook.quoteFee(tremorKey, false);
        (uint24 feeSell,,,,,) = hook.quoteFee(tremorKey, true);
        assertApproxEqAbs(feeBuy, 14_200, 1);
        assertEq(feeSell, BASE);
    }

    // ------------------------------------------------------------------
    // Real swaps through the PoolManager
    // ------------------------------------------------------------------

    /// @notice The same arbitrage trade gets less out of the Tremor pool than the static pool,
    ///         because it pays the surcharge to LPs.
    function test_swap_arbitragePaysMoreInTremorPool() public {
        _setReference2PctAbove();
        int256 amountIn = -1e15;

        vm.expectEmit(true, false, false, false, address(hook));
        emit TremorHook.FeeQuoted(tremorKey.toId(), false, true, 0, 0, 0, 0, TremorHook.Reason.NONE);
        BalanceDelta dTremor = swap(tremorKey, false, amountIn, ZERO_BYTES);
        BalanceDelta dStatic = swap(staticKey, false, amountIn, ZERO_BYTES);

        uint256 outTremor = uint256(int256(dTremor.amount0()));
        uint256 outStatic = uint256(int256(dStatic.amount0()));
        assertLt(outTremor, outStatic, "arb pays more in Tremor pool");

        // Difference is about the fee difference (130.8 bps vs 30 bps -> ~1% less out).
        uint256 shortfallBps = (outStatic - outTremor) * 10_000 / outStatic;
        assertApproxEqAbs(shortfallBps, 101, 3);
    }

    function test_swap_normalTraderPaysSameInBothPools() public {
        _setReference2PctAbove();
        BalanceDelta dTremor = swap(tremorKey, true, -1e15, ZERO_BYTES);
        BalanceDelta dStatic = swap(staticKey, true, -1e15, ZERO_BYTES);
        assertEq(dTremor.amount1(), dStatic.amount1());
    }

    // ------------------------------------------------------------------
    // Access and setup rules
    // ------------------------------------------------------------------

    function test_onlyPoolManagerCanCallBeforeSwap() public {
        vm.expectRevert(TremorHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), tremorKey, SwapParams(false, -1, 0), ZERO_BYTES);
    }

    function test_onlyOwnerCanConfigure() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(TremorHook.NotOwner.selector);
        hook.setPoolConfig(tremorKey, _config(TremorHook.Mode.FULL));
    }

    function test_rejectsBadConfig() public {
        TremorHook.PoolConfig memory c = _config(TremorHook.Mode.FULL);
        c.maxFee = 200_000; // above the 10% ceiling
        vm.expectRevert(TremorHook.InvalidConfig.selector);
        hook.setPoolConfig(tremorKey, c);

        c = _config(TremorHook.Mode.FULL);
        c.source = IReferenceSource(address(0));
        vm.expectRevert(TremorHook.InvalidConfig.selector);
        hook.setPoolConfig(tremorKey, c);
    }

    function test_rejectsStaticFeePool() public {
        PoolKey memory k = PoolKey(currency0, currency1, 3000, 60, IHooks(address(hook)));
        hook.setPoolConfig(k, _config(TremorHook.Mode.FULL));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(TremorHook.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }

    function test_rejectsUnconfiguredPool() public {
        PoolKey memory k = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(TremorHook.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_PRICE_1_1);
    }
}
