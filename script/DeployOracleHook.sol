// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {OracleHookWithV3Adapters} from "../src/OracleHookWithV3Adapters.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

/// @title Oracle Hook Deploy Script
/// @notice Script to deploy the v4 oracle hook contract
contract DeployOracleHook is Script {
    // For use in mining a hook address that corresponds to the right permissions - per: https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment
    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // The POOL_MANAGER_ADDRESS for unichain:
        address POOL_MANAGER_ADDRESS = 0x1F98400000000000000000000000000000000004;
        // Going with a MAX_ABS_TICK_DELTA of 250 as 99% of all wstETH<>ETH swaps move the price 250 ticks or fewer.
        // May not be appropriate for all pools.
        int24 MAX_ABS_TICK_DELTA = 250;

        // OracleHook only uses _afterInitialize and _beforeSwap
        uint160 oracleHookFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
        bytes memory oracleHookConstructorArgs = abi.encode(IPoolManager(POOL_MANAGER_ADDRESS), MAX_ABS_TICK_DELTA);
        (address minedAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            oracleHookFlags,
            type(OracleHookWithV3Adapters).creationCode,
            oracleHookConstructorArgs
        );
        console.log("Mined hook address:", minedAddress);
        console.logBytes32(salt);

        vm.startBroadcast(deployerPrivateKey);

        OracleHookWithV3Adapters oh = new OracleHookWithV3Adapters{salt: salt}(IPoolManager(POOL_MANAGER_ADDRESS), MAX_ABS_TICK_DELTA);

        vm.stopBroadcast();
        require(address(oh) == minedAddress, "Hook address mismatch");
        console.log("Deployed BaseOracleHook at:", address(oh));
    }
}
