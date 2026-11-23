// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title TremorFeeMath
/// @notice The pure maths behind Tremor's fee. Kept separate so every number can be tested on its own.
/// @dev Units. Fees and gaps are in "pips" (millionths), the unit Uniswap v4 uses for LP fees:
///      30 bps = 3,000 pips. Confidence and the capture share (beta) are in basis points (10,000 = 100%).
library TremorFeeMath {
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;

    /// @notice Converts a pool's sqrtPriceX96 into a price scaled by 1e18 (currency1 per currency0, raw units).
    function poolPriceX18(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        return FullMath.mulDiv(priceX96, 1e18, Q96);
    }

    /// @notice The gap between the pool price and the reference, in pips of the pool price.
    /// @return gapPips |reference - pool| / pool, in millionths.
    /// @return referenceAbove True when the reference is above the pool price.
    function gap(uint256 poolX18, uint256 referenceX18) internal pure returns (uint256 gapPips, bool referenceAbove) {
        if (poolX18 == 0) return (0, false);
        referenceAbove = referenceX18 > poolX18;
        uint256 diff = referenceAbove ? referenceX18 - poolX18 : poolX18 - referenceX18;
        gapPips = FullMath.mulDiv(diff, PIPS, poolX18);
    }

    /// @notice A swap is adverse when it moves the pool price toward the reference.
    /// @dev Reference above pool: currency0 is cheap in the pool, so buying it (oneForZero) is adverse.
    ///      Reference below pool: currency0 is expensive in the pool, so selling it (zeroForOne) is adverse.
    function isAdverse(bool referenceAbove, bool zeroForOne) internal pure returns (bool) {
        return referenceAbove ? !zeroForOne : zeroForOne;
    }

    /// @notice Confidence after age is taken into account: it falls linearly to zero at `maxAge`.
    function effectiveConfidence(uint256 confidenceBps, uint256 age, uint256 maxAge) internal pure returns (uint256) {
        if (age >= maxAge || maxAge == 0) return 0;
        return confidenceBps * (maxAge - age) / maxAge;
    }

    /// @notice Tremor's fee rule.
    /// @dev fee = min(maxFee, baseFee + beta * c * max(gap - baseFee - margin, 0)).
    ///      Because beta * c is at most 100% and the base fee and margin are taken off first,
    ///      an arbitrageur always keeps a share of the gap, so the pool still gets corrected.
    function surchargedFee(
        uint256 gapPips,
        uint256 confidenceBps,
        uint256 baseFee,
        uint256 marginPips,
        uint256 betaBps,
        uint256 maxFee
    ) internal pure returns (uint24) {
        uint256 floor = baseFee + marginPips;
        uint256 fee = baseFee;
        if (gapPips > floor) {
            fee += FullMath.mulDiv(gapPips - floor, betaBps * confidenceBps, BPS * BPS);
        }
        if (fee > maxFee) fee = maxFee;
        return uint24(fee);
    }
}
