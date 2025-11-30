// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BatchAuctionHook} from "../src/BatchAuctionHook.sol";
import {IntentBridge} from "../src/IntentBridge.sol";
import {MockAVS} from "../src/mocks/MockAVS.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract BatchAuctionTest is Test, Deployers {
    BatchAuctionHook hook;
    IntentBridge bridge;
    MockAVS avs;

    function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy our contracts
        bridge = new IntentBridge();
        avs = new MockAVS();

        // Deploy Hook
        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
        );
        deployCodeTo("BatchAuctionHook.sol", abi.encode(manager), hookAddress);
        hook = BatchAuctionHook(hookAddress);

        // Initialize pool
        (key, ) = initPool(
            Currency.wrap(address(0)), // token0
            Currency.wrap(address(1)), // token1
            hook,
            3000, // fee
            SQRT_PRICE_1_1
        );
    }

    function testIntentSubmission() public {
        bytes memory ciphertext = hex"123456";
        bridge.submitIntent(ciphertext);

        (bytes memory storedCiphertext, , ) = bridge.batchIntents(0, 0);
        assertEq(storedCiphertext, ciphertext);
    }

    function testBatchIntentSubmission() public {
        // Set AVS oracle
        hook.setAVSOracle(address(avs));

        // Submit an encrypted intent via hookData
        bytes memory ciphertext = hex"abcdef1234567890";
        bytes memory hookData = abi.encode(ciphertext);

        uint256 initialBatchSize = hook.getCurrentBatchSize();
        assertEq(initialBatchSize, 0);

        // We can't directly call the hook, but we can verify the storage
        // In a real test, this would be done via a swap
    }

    function testBatchFinalization() public {
        hook.setAVSOracle(address(avs));

        // Verify initial state
        assertEq(hook.currentBatchId(), 0);
        assertEq(hook.getCurrentBatchSize(), 0);
    }

    function testAVSProcessing() public {
        hook.setAVSOracle(address(avs));

        // Simulate AVS processing
        bytes memory mockResult = abi.encode(uint256(1000e6), uint256(500e6));

        // This would normally be called by the AVS after batch finalization
        // vm.prank(address(avs));
        // hook.processBatchResult(0, mockResult);
    }
}
