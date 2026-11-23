// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title TremorReactive
/// @notice Lives on Reactive Lasna. Tremor's validation engine.
/// @dev Listens to two independent price sources on Base Sepolia, checks each observation, measures
///      how closely the sources agree, and publishes a validated reference price with a confidence
///      score to the ReferenceStore on Unichain Sepolia through a Reactive callback.
///
///      Two kinds of source are supported:
///      - ORACLE:  a PriceSource contract's `PriceReported(uint256,uint64,uint64)` event;
///      - V4_POOL: a Uniswap v4 pool's `Swap` event on the PoolManager, read from its sqrtPriceX96.
///
///      What the contract does on each event:
///      1. matches the log to a source, ignores anything else;
///      2. decodes and normalises the price, rejects out-of-bounds values and out-of-order logs;
///      3. combines the fresh sources into one reference (the midpoint) and a confidence score
///         (100% when they match, falling to 0% as they drift apart);
///      4. publishes only when the reference moved enough, confidence changed enough, or a heartbeat
///         is due, so callbacks (which cost money) aren't wasted on noise.
contract TremorReactive is AbstractReactive {
    enum SourceKind {
        ORACLE,
        V4_POOL
    }

    struct SourceConfig {
        SourceKind kind;
        uint256 chainId; // origin chain, e.g. Base Sepolia 84532
        address emitter; // PriceSource contract, or the v4 PoolManager
        bytes32 poolId; // V4_POOL only
        bool invert; // flip the price if the source quotes the pair the other way round
        uint256 scaleX18; // multiply by scaleX18 / 1e18 to match the destination pool's raw units
    }

    struct SourceState {
        uint256 priceX18;
        uint64 observedAt;
        uint64 lastBlock;
        uint64 lastLogIndex;
        bool seen;
    }

    struct Params {
        uint32 sourceMaxAge; // seconds an observation counts as fresh
        uint32 disagreePips; // divergence (millionths) at which agreement reaches 0
        uint16 singleSourceConfBps; // confidence when only one source is fresh
        uint32 minMovePips; // publish when the reference moved at least this much...
        uint16 minConfChangeBps; // ...or confidence changed at least this much...
        uint32 heartbeat; // ...or the last publish is at least this old
        uint64 callbackGasLimit;
        uint256 minPriceX18; // sanity bounds on any single observation
        uint256 maxPriceX18;
    }

    /// @notice Event signatures the contract subscribes to.
    uint256 public constant PRICE_REPORTED_TOPIC = uint256(keccak256("PriceReported(uint256,uint64,uint64)"));
    uint256 public constant V4_SWAP_TOPIC =
        uint256(keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)"));

    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 2 ** 96;

    address public owner;
    Params public params;

    SourceConfig[2] internal _sources;
    SourceState[2] internal _state;

    uint256 public destinationChainId; // Unichain Sepolia 1301
    address public recipient; // ReferenceStore on Unichain

    uint64 public sequence;
    uint256 public lastPublishedPrice;
    uint16 public lastPublishedConf;
    uint64 public lastPublishedAt;
    uint64 public skipped;

    event ObservationAccepted(uint8 indexed source, uint256 priceX18, uint64 observedAt, uint256 originTxHash);
    event ObservationRejected(uint8 indexed source, uint256 priceX18, uint256 originTxHash);
    event ReferencePublished(
        uint64 indexed sequence,
        uint256 priceX18,
        uint16 confidenceBps,
        uint64 observedAt,
        uint8 triggeredBy,
        uint256 originTxHash
    );
    event ReferenceSkipped(uint256 priceX18, uint16 confidenceBps, uint256 originTxHash);
    event RecipientSet(uint256 chainId, address recipient);
    event ParamsSet(Params params);

    error NotOwner();
    error InvalidParams();
    error InvalidSource();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Deploy order (from Reactive's docs): this contract first, then the ReferenceStore with this
    ///      contract's address, then `setRecipient`.
    constructor(SourceConfig[2] memory sources_, Params memory params_) payable {
        owner = msg.sender;
        _setParams(params_);
        for (uint8 i = 0; i < 2; i++) {
            SourceConfig memory s = sources_[i];
            if (s.emitter == address(0) || s.chainId == 0 || s.scaleX18 == 0) revert InvalidSource();
            _sources[i] = s;
            if (s.kind == SourceKind.ORACLE) {
                SYSTEM.subscribe(
                    s.chainId, s.emitter, PRICE_REPORTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            } else {
                SYSTEM.subscribe(
                    s.chainId, s.emitter, V4_SWAP_TOPIC, uint256(s.poolId), REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // Reacting
    // ------------------------------------------------------------------

    function react(LogRecord calldata log_) external onlySystem {
        (bool matched, uint8 idx) = _match(log_);
        if (!matched) return;

        SourceState storage st = _state[idx];
        if (
            st.seen
                && (
                    log_.blockNumber < st.lastBlock
                        || (log_.blockNumber == st.lastBlock && log_.logIndex <= st.lastLogIndex)
                )
        ) return; // out of order or duplicate

        (bool ok, uint256 price, uint64 observedAt) = _decode(idx, log_);
        if (!ok || price < params.minPriceX18 || price > params.maxPriceX18) {
            emit ObservationRejected(idx, price, log_.txHash);
            return;
        }

        st.priceX18 = price;
        st.observedAt = observedAt;
        st.lastBlock = uint64(log_.blockNumber);
        st.lastLogIndex = uint64(log_.logIndex);
        st.seen = true;
        emit ObservationAccepted(idx, price, observedAt, log_.txHash);

        _maybePublish(idx, log_.txHash);
    }

    function _maybePublish(uint8 idx, uint256 originTxHash) internal {
        (bool any, uint256 refPrice, uint16 conf, uint64 refObservedAt) = currentReference();
        if (!any) return;

        if (!_shouldPublish(refPrice, conf) || recipient == address(0)) {
            skipped += 1;
            emit ReferenceSkipped(refPrice, conf, originTxHash);
            return;
        }

        sequence += 1;
        lastPublishedPrice = refPrice;
        lastPublishedConf = conf;
        lastPublishedAt = uint64(block.timestamp);

        bytes memory payload = abi.encodeWithSignature(
            "updateReference(address,uint256,uint64,uint64,uint16)",
            address(0), // replaced by Reactive with this contract's address
            refPrice,
            refObservedAt,
            sequence,
            conf
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: recipient,
                gasLimit: params.callbackGasLimit,
                payload: payload
            })
        );
        emit ReferencePublished(sequence, refPrice, conf, refObservedAt, idx, originTxHash);
    }

    /// @notice The reference and confidence the contract would publish right now.
    function currentReference()
        public
        view
        returns (bool any, uint256 priceX18, uint16 confidenceBps, uint64 observedAt)
    {
        bool fresh0 = _isFresh(0);
        bool fresh1 = _isFresh(1);
        if (!fresh0 && !fresh1) return (false, 0, 0, 0);

        if (fresh0 && fresh1) {
            uint256 a = _state[0].priceX18;
            uint256 b = _state[1].priceX18;
            priceX18 = (a + b) / 2;
            uint256 diff = a > b ? a - b : b - a;
            uint256 divergence = FullMath.mulDiv(diff, PIPS, priceX18);
            uint256 limit = params.disagreePips;
            confidenceBps = divergence >= limit ? 0 : uint16(BPS * (limit - divergence) / limit);
            observedAt = _state[0].observedAt < _state[1].observedAt ? _state[0].observedAt : _state[1].observedAt;
        } else {
            uint8 i = fresh0 ? 0 : 1;
            priceX18 = _state[i].priceX18;
            confidenceBps = params.singleSourceConfBps;
            observedAt = _state[i].observedAt;
        }
        any = true;
    }

    function _shouldPublish(uint256 refPrice, uint16 conf) internal view returns (bool) {
        if (sequence == 0) return true;
        if (block.timestamp >= uint256(lastPublishedAt) + params.heartbeat) return true;
        uint256 last = lastPublishedPrice;
        uint256 diff = refPrice > last ? refPrice - last : last - refPrice;
        if (FullMath.mulDiv(diff, PIPS, last) >= params.minMovePips) return true;
        uint256 confDiff = conf > lastPublishedConf ? conf - lastPublishedConf : lastPublishedConf - conf;
        return confDiff >= params.minConfChangeBps;
    }

    function _isFresh(uint8 i) internal view returns (bool) {
        SourceState storage st = _state[i];
        if (!st.seen) return false;
        uint256 age = block.timestamp > st.observedAt ? block.timestamp - st.observedAt : 0;
        return age <= params.sourceMaxAge;
    }

    function _match(LogRecord calldata log_) internal view returns (bool, uint8) {
        for (uint8 i = 0; i < 2; i++) {
            SourceConfig storage s = _sources[i];
            if (log_.chainId != s.chainId || log_.contractAddress != s.emitter) continue;
            if (s.kind == SourceKind.ORACLE && log_.topic0 == PRICE_REPORTED_TOPIC) return (true, i);
            if (s.kind == SourceKind.V4_POOL && log_.topic0 == V4_SWAP_TOPIC && log_.topic1 == uint256(s.poolId)) {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _decode(uint8 idx, LogRecord calldata log_)
        internal
        view
        returns (bool ok, uint256 price, uint64 observedAt)
    {
        SourceConfig storage s = _sources[idx];
        uint256 raw;
        if (s.kind == SourceKind.ORACLE) {
            if (log_.opCode != 1 || log_.data.length != 96) return (false, 0, 0);
            uint64 at;
            (raw, at,) = abi.decode(log_.data, (uint256, uint64, uint64));
            // Use the source's own timestamp, but never one later than now.
            observedAt = at < block.timestamp ? at : uint64(block.timestamp);
        } else {
            if (log_.opCode != 3 || log_.data.length != 192) return (false, 0, 0);
            (,, uint160 sqrtPriceX96,,,) = abi.decode(log_.data, (int128, int128, uint160, uint128, int24, uint24));
            raw = FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96), 1e18, Q96);
            observedAt = uint64(block.timestamp); // Swap logs carry no timestamp
        }
        if (raw == 0) return (false, 0, 0);
        if (s.invert) raw = FullMath.mulDiv(1e18, 1e18, raw);
        price = FullMath.mulDiv(raw, s.scaleX18, 1e18);
        ok = price != 0;
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setRecipient(uint256 chainId_, address recipient_) external onlyOwner {
        destinationChainId = chainId_;
        recipient = recipient_;
        emit RecipientSet(chainId_, recipient_);
    }

    function setParams(Params calldata params_) external onlyOwner {
        _setParams(params_);
    }

    function _setParams(Params memory p) internal {
        if (
            p.disagreePips == 0 || p.singleSourceConfBps > BPS || p.minPriceX18 == 0 || p.maxPriceX18 <= p.minPriceX18
                || p.callbackGasLimit == 0 || p.sourceMaxAge == 0
        ) revert InvalidParams();
        params = p;
        emit ParamsSet(p);
    }

    /// @notice Settle any debt with the system contract from this contract's balance.
    function coverDebt() external onlyOwner {
        _coverDebt();
    }

    /// @notice Return unused funds.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function getSource(uint8 i) external view returns (SourceConfig memory, SourceState memory) {
        return (_sources[i], _state[i]);
    }
}
