// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @notice Test stand-in for Reactive's system contract at 0x8888...8888.
///         Records subscriptions and callback requests so tests can inspect them.
contract MockSystemContract {
    struct Sub {
        uint256 chainId;
        address emitter;
        uint256 topic0;
        uint256 topic1;
    }

    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0[] internal _callbacks;

    receive() external payable {}

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 chainId, address emitter, uint256 topic0, uint256 topic1, uint256, uint256)
        external
    {
        subs.push(Sub(chainId, emitter, topic0, topic1));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config) external {
        _callbacks.push(config);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i) external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _callbacks[i];
    }
}
