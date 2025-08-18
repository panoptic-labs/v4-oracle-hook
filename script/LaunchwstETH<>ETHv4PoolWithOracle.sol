// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {OracleHookWithV3Adapters} from "../src/OracleHookWithV3Adapters.sol";

// Periphery view contracts
interface IStateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}
interface IPositionManager {
    function poolKeys(bytes25 poolId)
        external
        view
        returns (address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);
}

/// @title LaunchwstETH<>ETHv4PoolWithOracle
/// @notice Script to launch a wstETH<>ETH v4 Uniswap pool, with an OracleHook, and the adapter contract to expose the hook's values for this pool
contract LaunchwstETHEthWithOracle is Script {
    // Unichain v4 PoolManager
    address constant POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address constant POSITION_MGR = 0x4529A01c7A0410167c5740C487A8DE60232617bf;
    address constant STATE_VIEW   = 0x86e8631A016F9068C3f085fAF484Ee3F5fDee8f2;

    // DeployOracleHook.sol's output
    OracleHookWithV3Adapters ORACLE_HOOK = OracleHookWithV3Adapters(0x79330fE369c32A03e3b8516aFf35B44706E39080);

    // wstETH (Unichain) provided by you
    address constant WSTETH = 0xc02fE7317D4eb8753a02c35fe019786854A92001;

    // Pool params — should pull from existing wstETH<>ETH pool at:
    // https://app.uniswap.org/explore/pools/unichain/0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d
    bytes32 constant EXISTING_POOL_ID = 0xd10d359f50ba8d1e0b6c30974a65bf06895fba4bf2b692b2c75d987d3b6b863d;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // 1) Read fee & tickSpacing from existing pool via PositionManager (use bytes25 poolId)
        ( , , uint24 fee, int24 tickSpacing, ) =
            IPositionManager(POSITION_MGR).poolKeys(bytes25(EXISTING_POOL_ID));
        console.log("Mirroring params -> fee (pips):", fee);
        console.log(" tickSpacing:", tickSpacing);

        // 2) Read the *current* tick from existing pool via StateView
        ( , int24 currentTick, , ) = IStateView(STATE_VIEW).getSlot0(EXISTING_POOL_ID);
        console.log("Using initial tick from existing pool:", currentTick);

        // 3) Build the new PoolKey with your hook, fee, and tickSpacing
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        Currency eth    = Currency.wrap(0x0000000000000000000000000000000000000000);
        Currency wsteth = Currency.wrap(WSTETH);

        // Sanity: your hook must encode afterInitialize + beforeSwap
        uint160 required = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG;
        require((uint160(address(ORACLE_HOOK)) & required) == required, "Hook flags mismatch");

        PoolKey memory key = PoolKey({
            // eth is always c0
            currency0:   eth,
            currency1:   wsteth,
            fee:         fee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(ORACLE_HOOK)
        });

        // 4) Initialize the pool — this triggers OracleHookWithV3Adapters._afterInitialize
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        vm.startBroadcast(deployerPrivateKey);
        // If the pool already exists with different hooks, this will revert.
        manager.initialize(key, sqrtPriceX96);
        // 5) Read back the adapters from the hook’s mappings and log them
        OracleHookWithV3Adapters hook = OracleHookWithV3Adapters(address(ORACLE_HOOK));
        PoolId poolId = key.toId();

        address standard = hook.standardAdapter(poolId);
        address truncated = hook.truncatedAdapter(poolId);

        console.log("Adapters deployed for poolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("  standardAdapter: ", standard);
        console.log("  truncatedAdapter:", truncated);

        vm.stopBroadcast();
    }
}
