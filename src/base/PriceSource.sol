// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PriceSource
/// @notice Lives on Base Sepolia. A simple reported price feed: an authorised reporter posts the
///         market price and the contract emits an event that Tremor's reactive contract listens to.
/// @dev On testnet the reporter is our own script, and the README says so. Prices use the same
///      orientation as a Uniswap v4 pool: currency1 per currency0, raw units, scaled by 1e18.
contract PriceSource {
    /// @notice Emitted on every report. All fields are non-indexed, so the log has a single topic.
    event PriceReported(uint256 priceX18, uint64 observedAt, uint64 round);
    event ReporterSet(address indexed reporter, bool allowed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotReporter();
    error ZeroPrice();

    string public description;
    address public owner;
    mapping(address => bool) public isReporter;

    uint256 public latestPriceX18;
    uint64 public latestAt;
    uint64 public round;

    constructor(string memory description_, address owner_) {
        description = description_;
        owner = owner_;
        isReporter[owner_] = true;
        emit OwnershipTransferred(address(0), owner_);
        emit ReporterSet(owner_, true);
    }

    function report(uint256 priceX18) external {
        if (!isReporter[msg.sender]) revert NotReporter();
        if (priceX18 == 0) revert ZeroPrice();
        latestPriceX18 = priceX18;
        latestAt = uint64(block.timestamp);
        round += 1;
        emit PriceReported(priceX18, latestAt, round);
    }

    function setReporter(address reporter, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        isReporter[reporter] = allowed;
        emit ReporterSet(reporter, allowed);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
