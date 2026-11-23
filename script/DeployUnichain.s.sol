// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {TremorHook} from "../src/TremorHook.sol";
import {ReferenceStore} from "../src/ReferenceStore.sol";
import {IReferenceSource} from "../src/interfaces/IReferenceSource.sol";
import {Addresses} from "./Addresses.sol";
import {PoolMath} from "./PoolMath.sol";

interface ICallbackProxy {
    function depositTo(address) external payable;
}

/// @notice Deploys the Unichain Sepolia side of Tremor:
///         test tokens, the ReferenceStore (funded for callbacks), the TremorHook at a mined address,
///         and two pools that differ only in mode: STATIC (control, tick spacing 60) and FULL (tick spacing 30).
/// @dev Needs LASNA_REACTIVE. forge script script/DeployUnichain.s.sol --rpc-url unichain_sepolia --broadcast
contract DeployUnichain is Script {
    using PoolIdLibrary for PoolKey;

    uint128 constant LIQUIDITY = 1e24;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address reactive = vm.envAddress("LASNA_REACTIVE");
        uint256 callbackFunding = vm.envOr("CALLBACK_FUNDING", uint256(0.002 ether));

        vm.startBroadcast(pk);

        MockERC20 eth = new MockERC20("Tremor Test ETH", "tETH", 18);
        MockERC20 usd = new MockERC20("Tremor Test USD", "tUSD", 18);
        eth.mint(me, 1e30);
        usd.mint(me, 1e30);
        bool ethIsCurrency0 = address(eth) < address(usd);
        (address c0, address c1) = ethIsCurrency0 ? (address(eth), address(usd)) : (address(usd), address(eth));

        ReferenceStore store = new ReferenceStore(Addresses.UNI_CALLBACK_PROXY, reactive);
        ICallbackProxy(Addresses.UNI_CALLBACK_PROXY).depositTo{value: callbackFunding}(address(store));

        TremorHook hook = _deployHook(me);

        PoolKey memory staticKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        PoolKey memory tremorKey = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LPFeeLibrary.DYNAMIC_FEE_FLAG, 30, IHooks(address(hook)));
        hook.setPoolConfig(staticKey, _config(TremorHook.Mode.STATIC, store));
        hook.setPoolConfig(tremorKey, _config(TremorHook.Mode.FULL, store));

        uint160 sqrtP = PoolMath.sqrtPriceX96(PoolMath.poolPriceX18(Addresses.START_PRICE_X18, ethIsCurrency0));
        IPoolManager(Addresses.UNI_POOL_MANAGER).initialize(staticKey, sqrtP);
        IPoolManager(Addresses.UNI_POOL_MANAGER).initialize(tremorKey, sqrtP);

        eth.approve(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER, type(uint256).max);
        usd.approve(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER, type(uint256).max);
        eth.approve(Addresses.UNI_SWAP_ROUTER, type(uint256).max);
        usd.approve(Addresses.UNI_SWAP_ROUTER, type(uint256).max);
        ModifyLiquidityParams memory lp =
            ModifyLiquidityParams(Addresses.MIN_TICK, Addresses.MAX_TICK, int256(uint256(LIQUIDITY)), bytes32(0));
        PoolModifyLiquidityTest(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(staticKey, lp, "");
        PoolModifyLiquidityTest(Addresses.UNI_MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(tremorKey, lp, "");

        vm.stopBroadcast();

        console.log("UNI_TETH", address(eth));
        console.log("UNI_TUSD", address(usd));
        console.log("UNI_ETH_IS_CURRENCY0", ethIsCurrency0);
        console.log("UNI_REFERENCE_STORE", address(store));
        console.log("UNI_HOOK", address(hook));
        console.log("UNI_STATIC_POOL_ID");
        console.logBytes32(PoolId.unwrap(staticKey.toId()));
        console.log("UNI_TREMOR_POOL_ID");
        console.logBytes32(PoolId.unwrap(tremorKey.toId()));
    }

    function _deployHook(address owner) internal returns (TremorHook hook) {
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        bytes memory args = abi.encode(Addresses.UNI_POOL_MANAGER, owner);
        (address predicted, bytes32 salt) =
            HookMiner.find(Addresses.CREATE2_DEPLOYER, flags, type(TremorHook).creationCode, args);
        hook = new TremorHook{salt: salt}(IPoolManager(Addresses.UNI_POOL_MANAGER), owner);
        require(address(hook) == predicted, "hook address mismatch");
    }

    function _config(TremorHook.Mode mode, ReferenceStore store) internal pure returns (TremorHook.PoolConfig memory) {
        return TremorHook.PoolConfig({
            mode: mode,
            baseFee: 3_000, // 30 bps
            maxFee: 50_000, // 500 bps
            marginPips: 1_000, // 10 bps
            betaBps: 7_000, // 70%
            minConfidenceBps: 2_000, // 20%
            maxAge: 60, // seconds
            source: IReferenceSource(address(store))
        });
    }
}
