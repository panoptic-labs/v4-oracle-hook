// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {V3OracleAdapter} from "./adapters/V3OracleAdapter.sol";
import {V3TruncatedOracleAdapter} from "./adapters/V3TruncatedOracleAdapter.sol";

/// @notice A hook for a pool that allows a Uniswap V4 pool to expose a V3-compatible oracle interface
contract V3StyleOracleHook is BaseHook {
    using Oracle for Oracle.Observation[65535];
    using StateLibrary for IPoolManager;

    /// @notice Only the canonical Uniswap pool manager may call this function
    error NotManager();

    /// @notice Emitted by the hook for increases to the number of observations that can be stored.
    /// @dev `observationCardinalityNext` is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    /// @notice Emitted when adapter contracts are deployed for a pool
    /// @param poolId The ID of the pool
    /// @param standardAdapter The address of the standard V3 oracle adapter
    /// @param truncatedAdapter The address of the truncated V3 oracle adapter
    event OracleInitialized(
        PoolId indexed poolId,
        address standardAdapter,
        address truncatedAdapter
    );

    /// @notice Contains information about the current number of observations stored.
    /// @param observationIndex The most-recently updated index of the observations buffer
    /// @param observationCardinality The current maximum number of observations that are being stored
    /// @param observationCardinalityNext The next maximum number of observations that can be stored
    struct ObservationState {
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
    }

    /// @notice The canonical Uniswap V4 pool manager.
    IPoolManager public immutable manager;

    /// @notice The maximum absolute tick delta that can be observed for the truncated oracle.
    int24 public immutable MAX_ABS_TICK_DELTA;

    /// @notice The list of observations for a given pool ID
    mapping(PoolId => Oracle.Observation[65535]) public observationsById;

    /// @notice The current observation array state for the given pool ID
    mapping(PoolId => ObservationState) public stateById;

    /// @notice Maps pool IDs to their standard V3 oracle adapters
    mapping(PoolId => address) public standardAdapter;

    /// @notice Maps pool IDs to their truncated V3 oracle adapters
    mapping(PoolId => address) public truncatedAdapter;

    /// @notice Reverts if the caller is not the canonical Uniswap V4 pool manager.
    modifier onlyByManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    /// @notice Initializes a Uniswap V4 pool with this hook, stores baseline observation state, and optionally performs a cardinality increase.
    /// @param _manager The canonical Uniswap V4 pool manager
    /// @param _maxAbsTickDelta The maximum absolute tick delta that can be observed for the truncated oracle
    constructor(IPoolManager _manager, int24 _maxAbsTickDelta) BaseHook(_manager) {
        manager = _manager;
        MAX_ABS_TICK_DELTA = _maxAbsTickDelta;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
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

    /// @inheritdoc BaseHook
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal virtual override onlyByManager returns (bytes4) {
        PoolId poolId = key.toId();
        (uint16 cardinality, uint16 cardinalityNext) = observationsById[poolId].initialize(
            uint32(block.timestamp),
            tick
        );

        stateById[poolId] = ObservationState({
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });

        // Deploy adapter contracts
        V3OracleAdapter _standardAdapter = new V3OracleAdapter(manager, this, poolId);
        V3TruncatedOracleAdapter _truncatedAdapter = new V3TruncatedOracleAdapter(
            manager,
            this,
            poolId
        );

        // Store adapter addresses
        standardAdapter[poolId] = address(_standardAdapter);
        truncatedAdapter[poolId] = address(_truncatedAdapter);

        // Emit event for adapter deployment
        emit OracleInitialized(poolId, address(_standardAdapter), address(_truncatedAdapter));

        return this.afterInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal virtual override onlyByManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();

        ObservationState memory _observationState = stateById[poolId];

        (, int24 tick, , ) = manager.getSlot0(poolId);

        (
            _observationState.observationIndex,
            _observationState.observationCardinality
        ) = observationsById[poolId].write(
            _observationState.observationIndex,
            uint32(block.timestamp),
            tick,
            _observationState.observationCardinality,
            _observationState.observationCardinalityNext,
            MAX_ABS_TICK_DELTA
        );

        stateById[poolId] = _observationState;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Returns the cumulative tick as of each timestamp `secondsAgo` from the current block timestamp on `underlyingPoolId`.
    /// @dev Note that the second return value, seconds per liquidity, is not implemented in this oracle hook and will always return 0 -- it has been retained for interface compatibility.
    /// @dev To get a time weighted average tick, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of currency1 / currency0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @param underlyingPoolId The pool ID of the underlying V4 pool
    /// @return Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return Truncated cumulative tick values as of each `secondsAgos` from the current block timestamp
    function observe(
        uint32[] calldata secondsAgos,
        PoolId underlyingPoolId
    ) external view returns (int56[] memory, int56[] memory) {
        ObservationState memory _observationState = stateById[underlyingPoolId];

        (, int24 tick, , ) = manager.getSlot0(underlyingPoolId);

        return
            observationsById[underlyingPoolId].observe(
                uint32(block.timestamp),
                secondsAgos,
                tick,
                _observationState.observationIndex,
                _observationState.observationCardinality,
                MAX_ABS_TICK_DELTA
            );
    }

    /// @notice Increase the maximum number of price and liquidity observations that the oracle of `underlyingPoolId`.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    /// @param underlyingPoolId The pool ID of the underlying V4 pool
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext,
        PoolId underlyingPoolId
    ) public {
        uint16 observationCardinalityNextOld = stateById[underlyingPoolId]
            .observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew = observationsById[underlyingPoolId].grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );
        stateById[underlyingPoolId].observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
    }
}
