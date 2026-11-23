// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TremorFeeMath} from "../src/libraries/TremorFeeMath.sol";

contract TremorFeeMathTest is Test {
    function test_poolPriceAtOne() public pure {
        assertEq(TremorFeeMath.poolPriceX18(uint160(2 ** 96)), 1e18);
    }

    function test_gap() public pure {
        (uint256 g, bool above) = TremorFeeMath.gap(1e18, 1.02e18);
        assertEq(g, 20_000);
        assertTrue(above);
        (g, above) = TremorFeeMath.gap(1e18, 0.97e18);
        assertEq(g, 30_000);
        assertFalse(above);
    }

    function test_direction() public pure {
        assertTrue(TremorFeeMath.isAdverse(true, false)); // ref above: buying currency0 is adverse
        assertFalse(TremorFeeMath.isAdverse(true, true));
        assertTrue(TremorFeeMath.isAdverse(false, true)); // ref below: selling currency0 is adverse
        assertFalse(TremorFeeMath.isAdverse(false, false));
    }

    /// @notice Whatever the inputs, an adverse trade never pays the whole gap,
    ///         so arbitrage stays worth doing and the pool still gets corrected.
    function testFuzz_arbitrageAlwaysKeepsSomething(
        uint256 gapPips,
        uint16 conf,
        uint24 baseFee,
        uint24 margin,
        uint16 beta
    ) public pure {
        gapPips = bound(gapPips, 0, 1_000_000);
        conf = uint16(bound(conf, 0, 10_000));
        beta = uint16(bound(beta, 0, 10_000));
        baseFee = uint24(bound(baseFee, 0, 100_000));
        margin = uint24(bound(margin, 1, 10_000));
        uint24 fee = TremorFeeMath.surchargedFee(gapPips, conf, baseFee, margin, beta, 100_000);

        if (gapPips > uint256(baseFee) + margin) {
            assertLt(fee, gapPips, "arb keeps a share of the gap");
        } else {
            assertEq(fee, baseFee, "small gaps pay the normal fee");
        }
        assertGe(fee, baseFee, "never below the normal fee");
    }
}
