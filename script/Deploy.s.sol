// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BatchAuctionHook} from "../src/BatchAuctionHook.sol";
import {IntentBridge} from "../src/IntentBridge.sol";
import {MockAVS} from "../src/mocks/MockAVS.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Mock PoolManager for now if not on a testnet with v4 deployed
        // address poolManager = 0x...;

        // Deploy MockAVS
        MockAVS avs = new MockAVS();
        console.log("MockAVS deployed at:", address(avs));

        // Deploy IntentBridge
        IntentBridge bridge = new IntentBridge();
        console.log("IntentBridge deployed at:", address(bridge));

        // Deploy Hook (requires PoolManager address, using a placeholder or mock in real script)
        // BatchAuctionHook hook = new BatchAuctionHook(IPoolManager(poolManager));
        // console.log("BatchAuctionHook deployed at:", address(hook));

        vm.stopBroadcast();
    }
}
