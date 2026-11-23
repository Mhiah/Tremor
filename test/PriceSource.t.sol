// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PriceSource} from "../src/base/PriceSource.sol";

contract PriceSourceTest is Test {
    PriceSource src;

    function setUp() public {
        src = new PriceSource("ETH/USDC reporter", address(this));
    }

    function test_reportEmitsSingleTopicEvent() public {
        vm.recordLogs();
        src.report(1.02e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 1); // TremorReactive checks opCode == 1
        assertEq(logs[0].topics[0], keccak256("PriceReported(uint256,uint64,uint64)"));
        (uint256 price, uint64 at, uint64 round) = abi.decode(logs[0].data, (uint256, uint64, uint64));
        assertEq(price, 1.02e18);
        assertEq(at, block.timestamp);
        assertEq(round, 1);
    }

    function test_onlyReporters() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PriceSource.NotReporter.selector);
        src.report(1e18);

        src.setReporter(address(0xB0B), true);
        vm.prank(address(0xB0B));
        src.report(1e18);
        assertEq(src.round(), 1);
    }

    function test_rejectsZeroPrice() public {
        vm.expectRevert(PriceSource.ZeroPrice.selector);
        src.report(0);
    }
}
