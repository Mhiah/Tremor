// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

/// @notice Helpers for turning a human price (tUSD per tETH) into a pool's orientation.
library PoolMath {
    /// @notice Price in the pool's orientation (currency1 per currency0, raw units, x1e18).
    function poolPriceX18(uint256 humanPriceX18, bool ethIsCurrency0) internal pure returns (uint256) {
        return ethIsCurrency0 ? humanPriceX18 : 1e36 / humanPriceX18;
    }

    /// @notice sqrtPriceX96 for a price given as currency1 per currency0, x1e18.
    function sqrtPriceX96(uint256 priceX18) internal pure returns (uint160) {
        // sqrt(price) * 2^96 = sqrt(priceX18 * 2^192 / 1e18)
        return uint160(FixedPointMathLib.sqrt(priceX18 * (2 ** 96) / 1e18 * (2 ** 96)));
    }
}
