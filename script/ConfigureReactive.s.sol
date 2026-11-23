// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {TremorReactive} from "../src/reactive/TremorReactive.sol";
import {Addresses} from "./Addresses.sol";

/// @notice Points TremorReactive at the Unichain ReferenceStore and sets each source's final orientation.
/// @dev Needs LASNA_REACTIVE, UNI_REFERENCE_STORE, BASE_ETH_IS_CURRENCY0, UNI_ETH_IS_CURRENCY0.
///      forge script script/ConfigureReactive.s.sol --rpc-url lasna --broadcast
contract ConfigureReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        TremorReactive rc = TremorReactive(payable(vm.envAddress("LASNA_REACTIVE")));
        address store = vm.envAddress("UNI_REFERENCE_STORE");
        bool baseEth0 = vm.envBool("BASE_ETH_IS_CURRENCY0");
        bool uniEth0 = vm.envBool("UNI_ETH_IS_CURRENCY0");

        vm.startBroadcast(pk);
        // Source 0: Base pool price, in the Base pool's orientation -> flip if Unichain orders tokens differently.
        rc.setSourceTransform(0, baseEth0 != uniEth0, 1e18);
        // Source 1: feed reports tUSD per tETH -> flip if tETH is not currency0 on Unichain.
        rc.setSourceTransform(1, !uniEth0, 1e18);
        rc.setRecipient(Addresses.UNICHAIN_SEPOLIA, store);
        vm.stopBroadcast();

        console.log("configured recipient", store);
    }
}
