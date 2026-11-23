// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReferenceSource
/// @notice Where the Tremor hook reads the latest validated reference price.
/// @dev On Unichain this is the ReferenceStore, which only Reactive callbacks can update.
interface IReferenceSource {
    /// @notice The latest reference.
    /// @dev `priceX18` is the price of currency0 in currency1, in raw token units, scaled by 1e18
    ///      (the same orientation as a Uniswap v4 pool price).
    struct Reference {
        uint256 priceX18; // currency1 per currency0, raw units, x 1e18
        uint64 observedAt; // timestamp of the Base observation the reference came from
        uint64 sequence; // strictly increasing update number
        uint16 confidenceBps; // 0 to 10,000: how much the Lasna engine trusts this reference
    }

    /// @notice Returns the latest reference. `sequence == 0` means none has arrived yet.
    function latest() external view returns (Reference memory);
}
