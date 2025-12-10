// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {VeiledBatchHook} from "../src/VeiledBatchHook.sol";
import {VeiledBatchAVSOperator} from "../src/avs/VeiledBatchAVSOperator.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/**
 * @title DeployProduction
 * @notice Production deployment script for VeiledBatch
 * @dev Deploys to Fhenix Helium testnet or mainnet
 *
 * Usage:
 *   forge script script/DeployProduction.s.sol \
 *     --rpc-url https://api.helium.fhenix.zone \
 *     --broadcast \
 *     --private-key $PRIVATE_KEY
 */
contract DeployProduction is Script {
    // Fhenix Helium Testnet addresses (update for mainnet)
    address constant POOL_MANAGER = address(0); // TODO: Set actual Uniswap v4 PoolManager

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying VeiledBatch to Fhenix...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Calculate hook address with required flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        // For CREATE2 deployment, find salt that produces address with correct flags
        // In production, use HookMiner to find correct salt

        // 2. Deploy Hook (simplified - needs CREATE2 for flag compliance)
        VeiledBatchHook hook = new VeiledBatchHook(IPoolManager(POOL_MANAGER));
        console.log("VeiledBatchHook deployed at:", address(hook));

        // 3. Deploy AVS Operator contract
        VeiledBatchAVSOperator operator = new VeiledBatchAVSOperator(
            address(hook)
        );
        console.log("VeiledBatchAVSOperator deployed at:", address(operator));

        vm.stopBroadcast();

        // Output deployment info
        console.log("\n=== Deployment Complete ===");
        console.log("Network: Fhenix Helium Testnet");
        console.log("Hook:", address(hook));
        console.log("AVS Operator:", address(operator));
        console.log("\nNext steps:");
        console.log(
            "1. Register operators: hook.registerOperator{value: 0.1 ether}(pubkeyHash)"
        );
        console.log("2. Submit encrypted intents via swap hookData");
        console.log("3. Monitor BatchFinalized events");
    }
}

/**
 * @title DeployLocal
 * @notice Local/testnet deployment for development
 */
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        // For local testing without Fhenix, the FHE operations will revert
        // Use this for interface testing only

        console.log("WARNING: FHE operations require Fhenix network");
        console.log("This deployment is for interface testing only");

        vm.stopBroadcast();
    }
}
