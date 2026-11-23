// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {AbstractPayer} from "reactive-lib/base/AbstractPayer.sol";

import {TremorReactive} from "../src/reactive/TremorReactive.sol";
import {ReferenceStore} from "../src/ReferenceStore.sol";
import {IReferenceSource} from "../src/interfaces/IReferenceSource.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";

contract TremorReactiveTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant UNICHAIN_SEPOLIA = 1301;

    address constant ORACLE = address(0xA11CE); // PriceSource on Base
    address constant POOL_MANAGER = address(0x9A11); // v4 PoolManager on Base
    bytes32 constant POOL_ID = keccak256("base-pool");
    address constant STORE = address(0x5703E); // ReferenceStore on Unichain

    MockSystemContract sys;
    TremorReactive rc;

    uint64 blockNo = 100;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(SYSTEM, address(new MockSystemContract()).code);
        sys = MockSystemContract(payable(SYSTEM));

        TremorReactive.SourceConfig[2] memory sources;
        sources[0] = TremorReactive.SourceConfig({
            kind: TremorReactive.SourceKind.V4_POOL,
            chainId: BASE_SEPOLIA,
            emitter: POOL_MANAGER,
            poolId: POOL_ID,
            invert: false,
            scaleX18: 1e18
        });
        sources[1] = TremorReactive.SourceConfig({
            kind: TremorReactive.SourceKind.ORACLE,
            chainId: BASE_SEPOLIA,
            emitter: ORACLE,
            poolId: bytes32(0),
            invert: false,
            scaleX18: 1e18
        });
        rc = new TremorReactive(sources, _params());
        rc.setRecipient(UNICHAIN_SEPOLIA, STORE);
    }

    function _params() internal pure returns (TremorReactive.Params memory) {
        return TremorReactive.Params({
            sourceMaxAge: 120,
            disagreePips: 10_000, // 1% apart -> 0 confidence
            singleSourceConfBps: 5_000,
            minMovePips: 500, // 5 bps
            minConfChangeBps: 1_000,
            heartbeat: 30,
            callbackGasLimit: 300_000,
            minPriceX18: 1e15,
            maxPriceX18: 1e21
        });
    }

    // ------------------------------------------------------------------
    // Log builders
    // ------------------------------------------------------------------

    function _oracleLog(uint256 price) internal returns (IReactive.LogRecord memory l) {
        l.chainId = BASE_SEPOLIA;
        l.contractAddress = ORACLE;
        l.topic0 = rc.PRICE_REPORTED_TOPIC();
        l.data = abi.encode(price, uint64(block.timestamp), uint64(1));
        l.opCode = 1;
        l.blockNumber = ++blockNo;
        l.txHash = uint256(keccak256(abi.encode(blockNo, "oracle")));
    }

    function _swapLog(uint256 priceX18) internal returns (IReactive.LogRecord memory l) {
        // sqrtPriceX96 = sqrt(price) * 2^96
        uint160 sqrtP = uint160(_sqrt(priceX18 * 1e18) * 2 ** 96 / 1e18);
        l.chainId = BASE_SEPOLIA;
        l.contractAddress = POOL_MANAGER;
        l.topic0 = rc.V4_SWAP_TOPIC();
        l.topic1 = uint256(POOL_ID);
        l.topic2 = uint256(uint160(address(0xB0B)));
        l.data = abi.encode(int128(-1), int128(1), sqrtP, uint128(1e18), int24(0), uint24(3000));
        l.opCode = 3;
        l.blockNumber = ++blockNo;
        l.txHash = uint256(keccak256(abi.encode(blockNo, "swap")));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _react(IReactive.LogRecord memory l) internal {
        vm.prank(SYSTEM);
        rc.react(l);
    }

    function _lastPayload()
        internal
        view
        returns (uint256 price, uint64 observedAt, uint64 seq, uint16 conf, ISystemContract.CallbackConfiguration_V_1_0 memory cb)
    {
        cb = sys.callbackAt(sys.callbackCount() - 1);
        bytes memory args = new bytes(cb.payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = cb.payload[i + 4];
        }
        (, price, observedAt, seq, conf) = abi.decode(args, (address, uint256, uint64, uint64, uint16));
    }

    // ------------------------------------------------------------------
    // Setup and access
    // ------------------------------------------------------------------

    function test_subscribesToBothSources() public view {
        assertEq(sys.subCount(), 2);
        (uint256 c0, address e0, uint256 t0, uint256 p0) = sys.subs(0);
        assertEq(c0, BASE_SEPOLIA);
        assertEq(e0, POOL_MANAGER);
        assertEq(t0, rc.V4_SWAP_TOPIC());
        assertEq(p0, uint256(POOL_ID));
        (, address e1, uint256 t1,) = sys.subs(1);
        assertEq(e1, ORACLE);
        assertEq(t1, rc.PRICE_REPORTED_TOPIC());
    }

    function test_onlySystemCanReact() public {
        IReactive.LogRecord memory l = _oracleLog(1e18);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        rc.react(l);
    }

    function test_swapTopicMatchesUniswap() public view {
        assertEq(
            rc.V4_SWAP_TOPIC(),
            uint256(0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f)
        );
    }

    // ------------------------------------------------------------------
    // Publishing
    // ------------------------------------------------------------------

    function test_firstObservationPublishes_singleSourceConfidence() public {
        _react(_oracleLog(1.02e18));
        assertEq(sys.callbackCount(), 1);
        (uint256 price,, uint64 seq, uint16 conf, ISystemContract.CallbackConfiguration_V_1_0 memory cb) =
            _lastPayload();
        assertEq(price, 1.02e18);
        assertEq(seq, 1);
        assertEq(conf, 5_000); // only one source seen so far
        assertEq(cb.chainId, UNICHAIN_SEPOLIA);
        assertEq(cb.recipient, STORE);
        assertEq(cb.gasLimit, 300_000);
    }

    function test_sourcesAgree_fullConfidence() public {
        _react(_swapLog(1.02e18));
        _react(_oracleLog(1.02e18));
        (uint256 price,,, uint16 conf,) = _lastPayload();
        assertApproxEqRel(price, 1.02e18, 1e12);
        assertEq(conf, 10_000);
        assertEq(rc.sequence(), 2); // confidence jumped 50% -> 100%, so it published again
    }

    function test_sourcesHalfAPercentApart_halfConfidence() public {
        _react(_swapLog(1.00e18));
        _react(_oracleLog(1.005e18));
        (,,, uint16 conf,) = _lastPayload();
        assertApproxEqAbs(conf, 5_000, 30);
    }

    /// @notice Manipulation test: one source spikes 5%, the other doesn't. Confidence drops to 0,
    ///         so the hook falls back to the normal fee instead of charging on a fake price.
    function test_oneSourceSpikes_confidenceZero() public {
        _react(_swapLog(1e18));
        _react(_oracleLog(1e18));
        _react(_oracleLog(1.05e18));
        (,,, uint16 conf,) = _lastPayload();
        assertEq(conf, 0);
    }

    function test_tinyMoveIsSkipped_thenHeartbeatPublishes() public {
        _react(_swapLog(1e18));
        _react(_oracleLog(1e18));
        uint256 before = sys.callbackCount();

        _react(_oracleLog(1.0001e18)); // 1 bp move: below the 5 bp threshold
        assertEq(sys.callbackCount(), before);
        assertEq(rc.skipped(), 1);

        vm.warp(block.timestamp + 30);
        _react(_oracleLog(1.0001e18));
        assertEq(sys.callbackCount(), before + 1);
    }

    function test_bigMovePublishes() public {
        _react(_swapLog(1e18));
        _react(_oracleLog(1e18));
        uint256 before = sys.callbackCount();
        _react(_swapLog(1.02e18));
        _react(_oracleLog(1.02e18));
        assertGt(sys.callbackCount(), before);
        (uint256 price,,, uint16 conf,) = _lastPayload();
        assertApproxEqRel(price, 1.02e18, 1e12);
        assertEq(conf, 10_000);
    }

    // ------------------------------------------------------------------
    // Validation
    // ------------------------------------------------------------------

    function test_outOfOrderLogIgnored() public {
        IReactive.LogRecord memory older = _oracleLog(1.5e18);
        IReactive.LogRecord memory newer = _oracleLog(1e18);
        _react(newer);
        _react(older);
        (, TremorReactive.SourceState memory st) = rc.getSource(1);
        assertEq(st.priceX18, 1e18);
    }

    function test_outOfBoundsRejected() public {
        _react(_oracleLog(1e22));
        assertEq(sys.callbackCount(), 0);
        (, TremorReactive.SourceState memory st) = rc.getSource(1);
        assertFalse(st.seen);
    }

    function test_unrelatedLogsIgnored() public {
        IReactive.LogRecord memory l = _swapLog(1e18);
        l.topic1 = uint256(keccak256("other-pool"));
        _react(l);
        l = _oracleLog(1e18);
        l.chainId = 1;
        _react(l);
        assertEq(sys.callbackCount(), 0);
    }

    function test_staleSourceDropsOut() public {
        _react(_swapLog(1e18));
        vm.warp(block.timestamp + 121); // pool observation now stale
        _react(_oracleLog(1.01e18));
        (uint256 price,,, uint16 conf,) = _lastPayload();
        assertEq(price, 1.01e18);
        assertEq(conf, 5_000);
    }

    function test_invertAndScale() public {
        TremorReactive.SourceConfig[2] memory sources;
        sources[0] = TremorReactive.SourceConfig(TremorReactive.SourceKind.ORACLE, BASE_SEPOLIA, ORACLE, 0, true, 2e18);
        sources[1] = TremorReactive.SourceConfig(TremorReactive.SourceKind.ORACLE, 1, address(1), 0, false, 1e18);
        rc = new TremorReactive(sources, _params());
        rc.setRecipient(UNICHAIN_SEPOLIA, STORE);
        _react(_oracleLog(4e18)); // inverted -> 0.25, scaled x2 -> 0.5
        (uint256 price,,,,) = _lastPayload();
        assertEq(price, 0.5e18);
    }

    function test_setSourceTransform() public {
        rc.setSourceTransform(1, true, 1e18);
        _react(_oracleLog(4e18));
        (uint256 price,,,,) = _lastPayload();
        assertEq(price, 0.25e18);

        vm.prank(address(0xBAD));
        vm.expectRevert(TremorReactive.NotOwner.selector);
        rc.setSourceTransform(1, false, 1e18);
    }

    function test_noRecipientMeansNoCallback() public {
        rc.setRecipient(0, address(0));
        _react(_oracleLog(1e18));
        assertEq(sys.callbackCount(), 0);
        assertEq(rc.skipped(), 1);
    }

    function test_onlyOwnerAdmin() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(TremorReactive.NotOwner.selector);
        rc.setRecipient(1, address(1));
        vm.expectRevert(TremorReactive.NotOwner.selector);
        rc.setParams(_params());
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // End to end: Reactive delivers the callback to the ReferenceStore
    // ------------------------------------------------------------------

    function test_callbackPayloadLandsInReferenceStore() public {
        address proxy = address(0xC0FFEE);
        ReferenceStore store = new ReferenceStore(proxy, address(rc));
        rc.setRecipient(UNICHAIN_SEPOLIA, address(store));

        _react(_swapLog(1.02e18));
        _react(_oracleLog(1.02e18));
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = sys.callbackAt(sys.callbackCount() - 1);

        // Reactive overwrites the first argument with the reactive contract's address.
        bytes memory payload = cb.payload;
        address sender = address(rc);
        assembly {
            mstore(add(payload, 36), sender)
        }
        vm.prank(proxy);
        (bool ok,) = cb.recipient.call(payload);
        assertTrue(ok, "callback accepted");

        IReferenceSource.Reference memory r = store.latest();
        assertApproxEqRel(r.priceX18, 1.02e18, 1e12);
        assertEq(r.confidenceBps, 10_000);
        assertEq(r.sequence, rc.sequence());
    }
}
