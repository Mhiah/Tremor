// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {TremorHook} from "../src/TremorHook.sol";
import {IReferenceSource} from "../src/interfaces/IReferenceSource.sol";
import {Addresses} from "./Addresses.sol";
import {PoolMath} from "./PoolMath.sol";

/// @notice Adds six more static/Tremor pool pairs on Unichain Sepolia, identical apart from tick spacing.
/// @dev Why: each market move costs Reactive fees, so one move is tested against seven pool pairs at once,
///      each arbitraged after a different bot reaction delay. Pools in a pair share liquidity, price and
///      settings, so the only difference inside a pair is the mode (STATIC vs FULL).
///      Needs UNI_TETH, UNI_TUSD, UNI_HOOK, UNI_REFERENCE_STORE and a price to start at (START_PRICE_X18).
contract DeployExperimentPools is Script {
    uint128 constant LIQUIDITY = 1e24;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address eth = vm.envAddress("UNI_TETH");
        address usd = vm.envAddress("UNI_TUSD");
        TremorHook hook = TremorHook(vm.envAddress("UNI_HOOK"));
        IReferenceSource store = IReferenceSource(vm.envAddress("UNI_REFERENCE_STORE"));
        uint256 startPrice = vm.envUint("START_PRICE_X18");
        require(eth < usd, "expects tETH as currency0");

        int24[6] memory staticSpacing = [int24(10), 15, 20, 31, 45, 54];
        int24[6] memory tremorSpacing = [int24(12), 18, 27, 36, 53, 62];
        uint160 sqrtP = PoolMath.sqrtPriceX96(startPrice);
        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams(Addresses.MIN_TICK, Addresses.MAX_TICK, int256(uint256(LIQUIDITY)), bytes32(0));

        vm.startBroadcast(pk);
        for (uint256 i = 0; i < 6; i++) {
            PoolKey memory s = _key(eth, usd, staticSpacing[i], hook);
            PoolKey memory t = _key(eth, usd, tremorSpacing[i], hook);
            hook.setPoolConfig(s, _config(TremorHook.Mode.STATIC, store));
            hook.setPoolConfig(t, _config(TremorHook.Mode.FULL, store));
            IPoolManager(Addresses.UNI_POOL_MANAGER).initialize(s, sqrtP);
            IPoolManager(Addresses.UNI_POOL_MANAGER).initialize(t, sqrtP);
            PoolModifyLiquidityTest(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(s, lp, "");
            PoolModifyLiquidityTest(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(t, lp, "");
        }
        vm.stopBroadcast();
        console.log("added 6 pool pairs");
    }

    function _key(address c0, address c1, int24 spacing, TremorHook hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
    }

    function _config(TremorHook.Mode mode, IReferenceSource store) internal pure returns (TremorHook.PoolConfig memory) {
        return TremorHook.PoolConfig({
            mode: mode,
            baseFee: 3_000,
            maxFee: 50_000,
            marginPips: 1_000,
            betaBps: 7_000,
            minConfidenceBps: 2_000,
            maxAge: 60,
            source: store
        });
    }
}
