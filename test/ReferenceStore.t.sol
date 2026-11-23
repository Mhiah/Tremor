// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ReferenceStore} from "../src/ReferenceStore.sol";
import {IReferenceSource} from "../src/interfaces/IReferenceSource.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";

contract ReferenceStoreTest is Test {
    ReferenceStore store;
    address constant PROXY = address(0xC0FFEE); // stands in for Reactive's callback proxy
    address constant REACTIVE = address(0x7E3302); // stands in for Tremor's reactive contract on Lasna

    function setUp() public {
        vm.warp(1_000_000);
        store = new ReferenceStore(PROXY, REACTIVE);
    }

    function _update(address caller, address rvm, uint64 seq) internal {
        vm.prank(caller);
        store.updateReference(rvm, 1.02e18, uint64(block.timestamp - 1), seq, 9_000);
    }

    function test_acceptsUpdateFromProxyAndReactiveContract() public {
        _update(PROXY, REACTIVE, 1);
        IReferenceSource.Reference memory r = store.latest();
        assertEq(r.priceX18, 1.02e18);
        assertEq(r.sequence, 1);
        assertEq(r.confidenceBps, 9_000);
        assertEq(store.lastReceivedAt(), block.timestamp);
    }

    function test_rejectsCallerOtherThanProxy() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        store.updateReference(REACTIVE, 1e18, uint64(block.timestamp), 1, 9_000);
    }

    function test_rejectsWrongReactiveSender() public {
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), REACTIVE)
        );
        _update(PROXY, address(0xBAD), 1);
    }

    function test_rejectsReplayedOrOldSequence() public {
        _update(PROXY, REACTIVE, 5);
        vm.expectRevert(abi.encodeWithSelector(ReferenceStore.StaleSequence.selector, 5, 5));
        _update(PROXY, REACTIVE, 5);
        vm.expectRevert(abi.encodeWithSelector(ReferenceStore.StaleSequence.selector, 4, 5));
        _update(PROXY, REACTIVE, 4);
    }

    function test_rejectsInvalidValues() public {
        vm.startPrank(PROXY);
        vm.expectRevert(ReferenceStore.InvalidReference.selector);
        store.updateReference(REACTIVE, 0, uint64(block.timestamp), 1, 9_000); // zero price
        vm.expectRevert(ReferenceStore.InvalidReference.selector);
        store.updateReference(REACTIVE, 1e18, uint64(block.timestamp), 1, 10_001); // confidence over 100%
        vm.expectRevert(ReferenceStore.InvalidReference.selector);
        store.updateReference(REACTIVE, 1e18, uint64(block.timestamp + 31), 1, 9_000); // from the future
        vm.stopPrank();
    }
}
