// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReferenceSource} from "../../src/interfaces/IReferenceSource.sol";

/// @notice Test stand-in for the ReferenceStore: lets tests set any reference directly.
contract MockReferenceSource is IReferenceSource {
    Reference internal _ref;

    function set(uint256 priceX18, uint64 observedAt, uint64 sequence, uint16 confidenceBps) external {
        _ref = Reference(priceX18, observedAt, sequence, confidenceBps);
    }

    function latest() external view returns (Reference memory) {
        return _ref;
    }
}
