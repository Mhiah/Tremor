// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {IReferenceSource} from "./interfaces/IReferenceSource.sol";
import {TremorFeeMath} from "./libraries/TremorFeeMath.sol";

/// @title TremorHook
/// @notice A Uniswap v4 hook that charges arbitrageurs for trading against a stale pool price.
/// @dev On every swap the hook reads the latest validated reference price (delivered from Base by
///      Reactive Omni), measures the live gap to the pool price, and sets the LP fee:
///      - trades that move the pool toward the reference (adverse flow) pay a surcharge sized to the gap
///        and to how much the reference can be trusted;
///      - every other trade pays the normal fee;
///      - when the reference is missing, stale or untrusted, everyone pays the normal fee.
///      The surcharge stays in the pool as LP fees.
contract TremorHook is IHooks {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    /// @notice How the hook prices swaps. One hook, four modes, so experiments compare like with like.
    enum Mode {
        STATIC, // A: always the base fee (control pool)
        GAP, // B: surcharge on any swap when a gap exists, no direction check, no confidence
        DIRECTIONAL, // C: surcharge only on adverse swaps, no confidence
        FULL // D: full Tremor, adverse swaps only, weighted by confidence and freshness
    }

    /// @notice Why a swap paid only the base fee (or NONE when the surcharge rule ran).
    enum Reason {
        NONE,
        STATIC_MODE,
        NO_REFERENCE,
        STALE_REFERENCE,
        LOW_CONFIDENCE,
        NOT_ADVERSE
    }

    struct PoolConfig {
        Mode mode;
        uint24 baseFee; // pips, e.g. 3,000 = 30 bps
        uint24 maxFee; // pips, fee ceiling
        uint24 marginPips; // pips left to the arbitrageur for gas and price discovery
        uint16 betaBps; // share of the gap to capture, e.g. 7,000 = 70%
        uint16 minConfidenceBps; // below this, no surcharge
        uint32 maxAge; // seconds a reference stays usable
        IReferenceSource source; // where the reference comes from
    }

    /// @notice Highest fee the hook may ever charge: 10%.
    uint24 public constant FEE_CEILING = 100_000;

    IPoolManager public immutable poolManager;
    address public owner;

    mapping(PoolId => PoolConfig) internal _configs;
    mapping(PoolId => bool) public isConfigured;

    event PoolConfigured(PoolId indexed poolId, PoolConfig config);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted on every swap so the experiment can measure what each trade paid and why.
    event FeeQuoted(
        PoolId indexed poolId,
        bool zeroForOne,
        bool adverse,
        uint256 gapPips,
        uint256 confidenceBps,
        uint24 fee,
        uint64 referenceSequence,
        Reason reason
    );

    error NotPoolManager();
    error NotOwner();
    error HookNotImplemented();
    error PoolNotConfigured();
    error NotDynamicFee();
    error InvalidConfig();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager poolManager_, address owner_) {
        poolManager = poolManager_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice The hook needs to see pool creation (to insist on dynamic fees) and every swap.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    /// @notice Sets how a pool is priced. Can be set before the pool exists, and changed between experiment runs.
    function setPoolConfig(PoolKey calldata key, PoolConfig calldata config) external onlyOwner {
        if (
            config.baseFee > config.maxFee || config.maxFee > FEE_CEILING || config.betaBps > 10_000
                || config.minConfidenceBps > 10_000
                || (config.mode != Mode.STATIC && (address(config.source) == address(0) || config.maxAge == 0))
        ) revert InvalidConfig();
        PoolId id = key.toId();
        _configs[id] = config;
        isConfigured[id] = true;
        emit PoolConfigured(id, config);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getPoolConfig(PoolId id) external view returns (PoolConfig memory) {
        return _configs[id];
    }

    // ------------------------------------------------------------------
    // Pricing
    // ------------------------------------------------------------------

    /// @notice The fee a swap would pay right now, with the reason. Same logic beforeSwap uses.
    function quoteFee(PoolKey calldata key, bool zeroForOne)
        public
        view
        returns (uint24 fee, Reason reason, uint256 gapPips, uint256 confidenceBps, bool adverse, uint64 sequence)
    {
        PoolId id = key.toId();
        PoolConfig memory c = _configs[id];
        fee = c.baseFee;

        if (c.mode == Mode.STATIC) return (fee, Reason.STATIC_MODE, 0, 0, false, 0);

        IReferenceSource.Reference memory ref = c.source.latest();
        sequence = ref.sequence;
        if (ref.sequence == 0 || ref.priceX18 == 0) return (fee, Reason.NO_REFERENCE, 0, 0, false, sequence);

        uint256 age = block.timestamp > ref.observedAt ? block.timestamp - ref.observedAt : 0;
        if (age >= c.maxAge) return (fee, Reason.STALE_REFERENCE, 0, 0, false, sequence);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        bool referenceAbove;
        (gapPips, referenceAbove) = TremorFeeMath.gap(TremorFeeMath.poolPriceX18(sqrtPriceX96), ref.priceX18);
        adverse = TremorFeeMath.isAdverse(referenceAbove, zeroForOne);

        if (c.mode == Mode.FULL) {
            confidenceBps = TremorFeeMath.effectiveConfidence(ref.confidenceBps, age, c.maxAge);
            if (confidenceBps < c.minConfidenceBps) return (fee, Reason.LOW_CONFIDENCE, gapPips, confidenceBps, adverse, sequence);
        } else {
            confidenceBps = 10_000;
        }

        if (c.mode != Mode.GAP && !adverse) return (fee, Reason.NOT_ADVERSE, gapPips, confidenceBps, adverse, sequence);

        fee = TremorFeeMath.surchargedFee(gapPips, confidenceBps, c.baseFee, c.marginPips, c.betaBps, c.maxFee);
        reason = Reason.NONE;
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        if (!isConfigured[key.toId()]) revert PoolNotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint24 fee, Reason reason, uint256 gapPips, uint256 confidenceBps, bool adverse, uint64 sequence) =
            quoteFee(key, params.zeroForOne);
        emit FeeQuoted(key.toId(), params.zeroForOne, adverse, gapPips, confidenceBps, fee, sequence, reason);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Unused hook callbacks. The PoolManager never calls them because the address bits are off.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
