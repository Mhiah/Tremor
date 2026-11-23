// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {PriceSource} from "../src/base/PriceSource.sol";
import {Addresses} from "./Addresses.sol";
import {PoolMath} from "./PoolMath.sol";

/// @notice Deploys Tremor's two price sources on Base Sepolia:
///         1. a tETH/tUSD Uniswap v4 pool (the "market"), with full-range liquidity;
///         2. a PriceSource feed (the second opinion).
/// @dev forge script script/DeployBase.s.sol --rpc-url base_sepolia --broadcast
contract DeployBase is Script {
    using PoolIdLibrary for PoolKey;

    uint128 constant LIQUIDITY = 1e24;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        MockERC20 eth = new MockERC20("Tremor Test ETH", "tETH", 18);
        MockERC20 usd = new MockERC20("Tremor Test USD", "tUSD", 18);
        eth.mint(me, 1e30);
        usd.mint(me, 1e30);

        bool ethIsCurrency0 = address(eth) < address(usd);
        (address c0, address c1) = ethIsCurrency0 ? (address(eth), address(usd)) : (address(usd), address(eth));

        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        uint160 sqrtP = PoolMath.sqrtPriceX96(PoolMath.poolPriceX18(Addresses.START_PRICE_X18, ethIsCurrency0));
        IPoolManager(Addresses.BASE_POOL_MANAGER).initialize(key, sqrtP);

        eth.approve(Addresses.BASE_MODIFY_LIQUIDITY_ROUTER, type(uint256).max);
        usd.approve(Addresses.BASE_MODIFY_LIQUIDITY_ROUTER, type(uint256).max);
        eth.approve(Addresses.BASE_SWAP_ROUTER, type(uint256).max);
        usd.approve(Addresses.BASE_SWAP_ROUTER, type(uint256).max);
        PoolModifyLiquidityTest(Addresses.BASE_MODIFY_LIQUIDITY_ROUTER).modifyLiquidity(
            key,
            ModifyLiquidityParams(Addresses.MIN_TICK, Addresses.MAX_TICK, int256(uint256(LIQUIDITY)), bytes32(0)),
            ""
        );

        PriceSource feed = new PriceSource("tETH/tUSD reporter", me);
        feed.report(Addresses.START_PRICE_X18);

        vm.stopBroadcast();

        console.log("BASE_TETH", address(eth));
        console.log("BASE_TUSD", address(usd));
        console.log("BASE_ETH_IS_CURRENCY0", ethIsCurrency0);
        console.log("BASE_POOL_ID");
        console.logBytes32(PoolId.unwrap(key.toId()));
        console.log("BASE_FEED", address(feed));
    }
}
