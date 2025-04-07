// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolId} from "v4-core/types/PoolId.sol";
import {V3StyleOracleHook} from "..//V3StyleOracleHook.sol";
import {Oracle} from "../libraries/Oracle.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @title V3TruncatedOracleAdapter
/// @notice Adapter contract that provides a Uniswap V3-compatible oracle interface for V3StyleOracleHook.
/// @dev This adapter exposes the truncated tickCumulative values from V3StyleOracleHook.
contract V3TruncatedOracleAdapter {
    using StateLibrary for IPoolManager;

    /// @notice The V3StyleOracleHook contract this adapter interacts with.
    V3StyleOracleHook public immutable v3StyleOracle;

    /// @notice The canonical Uniswap V4 pool manager.
    IPoolManager public immutable manager;

    /// @notice The pool ID of the underlying V4 pool.
    PoolId public immutable poolId;

    /// @notice Initializes the adapter with the V3StyleOracleHook contract and pool ID.
    /// @param _v3StyleOracle The V3StyleOracleHook contract
    /// @param _poolId The pool ID of the underlying V4 pool
    constructor(IPoolManager _manager, V3StyleOracleHook _v3StyleOracle, PoolId _poolId) {
        manager = _manager;
        v3StyleOracle = _v3StyleOracle;
        poolId = _poolId;
    }

    /// @notice Emulates the behavior of the exposed zeroth slot of a Uniswap V3 pool.
    /// @return sqrtPriceX96 The current price of the oracle as a sqrt(currency1/currency0) Q64.96 value
    /// @return tick The current tick of the oracle
    /// @return observationIndex The index of the last oracle observation that was written
    /// @return observationCardinality The current maximum number of observations stored in the oracle
    /// @return observationCardinalityNext The next maximum number of observations that can be stored in the oracle
    /// @return feeProtocol The protocol fee for this pool (not used in V4, always 0)
    /// @return unlocked Whether the pool is currently unlocked (always true for V4)
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        (sqrtPriceX96, tick, , ) = manager.getSlot0(poolId);

        (observationIndex, observationCardinality, observationCardinalityNext) = v3StyleOracle
            .stateById(poolId);

        feeProtocol = 0;
        unlocked = true;
    }

    /// @notice Returns data about a specific observation index.
    /// @param index The element of the observations array to fetch
    /// @return blockTimestamp The timestamp of the observation
    /// @return tickCumulativeTruncated The truncated tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp.
    /// @return secondsPerLiquidityCumulativeX128 The seconds per in range liquidity for the life of the pool (always 0 in V4)
    /// @return initialized Whether the observation has been initialized and the values are safe to use
    function observations(
        uint256 index
    )
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulativeTruncated,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        (blockTimestamp, , , tickCumulativeTruncated, initialized) = v3StyleOracle.observationsById(
            poolId,
            uint16(index)
        );

        secondsPerLiquidityCumulativeX128 = 0;
    }

    /// @notice Returns the truncated cumulative tick values as of each timestamp `secondsAgo` from the current block timestamp.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulativesTruncated Truncated cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value (always empty in V4)
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulativesTruncated,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        )
    {
        (, tickCumulativesTruncated) = v3StyleOracle.observe(secondsAgos, poolId);

        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
    }

    /// @notice Increase the maximum number of price observations that this oracle will store.
    /// @param observationCardinalityNext The desired minimum number of observations for the oracle to store
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external {
        v3StyleOracle.increaseObservationCardinalityNext(observationCardinalityNext, poolId);
    }
}
