// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib/interfaces/IPayable.sol";
import {IReferenceSource} from "./interfaces/IReferenceSource.sol";

/// @title ReferenceStore
/// @notice Lives on Unichain Sepolia. Receives validated reference prices from Tremor's reactive
///         contract on Reactive Lasna and keeps the latest one for the Tremor hook to read.
/// @dev Two checks guard every update:
///      1. the call must come from Reactive's official callback proxy (`_SERVICE_PROVIDER`);
///      2. the first argument, which Reactive fills with the sender's address, must be our reactive contract.
///      Updates must also carry a strictly increasing sequence, so old or replayed updates are rejected.
contract ReferenceStore is IReferenceSource, AbstractCallback {
    /// @notice How far in the future an observation's timestamp may be (clock differences between chains).
    uint64 public constant MAX_FUTURE_SKEW = 30;

    Reference internal _latest;

    /// @notice Unichain time when the latest reference landed. Used to measure the full loop.
    uint64 public lastReceivedAt;

    event ReferenceUpdated(
        uint64 indexed sequence, uint256 priceX18, uint64 observedAt, uint16 confidenceBps, uint64 receivedAt
    );

    error StaleSequence(uint64 sequence, uint64 latestSequence);
    error InvalidReference();

    /// @param callbackProxy_ Reactive's callback proxy on this chain.
    /// @param reactiveContract_ Tremor's reactive contract on Lasna, the only allowed sender.
    constructor(address callbackProxy_, address reactiveContract_)
        payable
        AbstractCallback(IPayable(payable(callbackProxy_)), reactiveContract_)
    {}

    /// @notice Called by Reactive's callback proxy. `rvmSender` is injected by Reactive.
    function updateReference(
        address rvmSender,
        uint256 priceX18,
        uint64 observedAt,
        uint64 sequence,
        uint16 confidenceBps
    ) external onlyServiceProvider onlyCallbackSender(rvmSender) {
        if (sequence <= _latest.sequence) revert StaleSequence(sequence, _latest.sequence);
        if (priceX18 == 0 || confidenceBps > 10_000 || observedAt > block.timestamp + MAX_FUTURE_SKEW) {
            revert InvalidReference();
        }

        _latest = Reference({
            priceX18: priceX18, observedAt: observedAt, sequence: sequence, confidenceBps: confidenceBps
        });
        lastReceivedAt = uint64(block.timestamp);

        emit ReferenceUpdated(sequence, priceX18, observedAt, confidenceBps, uint64(block.timestamp));
    }

    /// @inheritdoc IReferenceSource
    function latest() external view returns (Reference memory) {
        return _latest;
    }
}
