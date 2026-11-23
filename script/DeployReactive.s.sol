// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {TremorReactive} from "../src/reactive/TremorReactive.sol";
import {Addresses} from "./Addresses.sol";

/// @notice Deploys TremorReactive on Reactive Lasna, subscribed to the two Base Sepolia sources.
/// @dev Needs BASE_POOL_ID, BASE_FEED and BASE_ETH_IS_CURRENCY0 from DeployBase.
///      Both sources are first normalised to the human price (tUSD per tETH). Once the Unichain
///      tokens exist, ConfigureReactive sets the final orientation and the callback recipient.
///      forge script script/DeployReactive.s.sol --rpc-url lasna --broadcast
contract DeployReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        bytes32 poolId = vm.envBytes32("BASE_POOL_ID");
        address feed = vm.envAddress("BASE_FEED");
        bool baseEthIsCurrency0 = vm.envBool("BASE_ETH_IS_CURRENCY0");
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(0.3 ether));

        TremorReactive.SourceConfig[2] memory sources;
        sources[0] = TremorReactive.SourceConfig({
            kind: TremorReactive.SourceKind.V4_POOL,
            chainId: Addresses.BASE_SEPOLIA,
            emitter: Addresses.BASE_POOL_MANAGER,
            poolId: poolId,
            invert: !baseEthIsCurrency0,
            scaleX18: 1e18
        });
        sources[1] = TremorReactive.SourceConfig({
            kind: TremorReactive.SourceKind.ORACLE,
            chainId: Addresses.BASE_SEPOLIA,
            emitter: feed,
            poolId: bytes32(0),
            invert: false,
            scaleX18: 1e18
        });

        TremorReactive.Params memory p = TremorReactive.Params({
            sourceMaxAge: 120,
            disagreePips: 10_000, // 1% apart -> 0 confidence
            singleSourceConfBps: 5_000,
            minMovePips: 500, // 5 bps
            minConfChangeBps: 1_000,
            heartbeat: 30,
            callbackGasLimit: 300_000,
            minPriceX18: 1e12, // wide sanity bounds covering both orientations
            maxPriceX18: 1e24
        });

        vm.startBroadcast(pk);
        TremorReactive rc = new TremorReactive{value: funding}(sources, p);
        vm.stopBroadcast();

        console.log("LASNA_REACTIVE", address(rc));
    }
}
