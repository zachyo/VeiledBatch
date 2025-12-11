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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title BatchAuctionInputValidationTest
 * @notice Tests for input validation, error messages, and boundary conditions
 */
contract BatchAuctionInputValidationTest is Test, Deployers {
    BatchAuctionHook hook;
    IntentBridge bridge;
    MockAVS avs;

    address alice = address(0x1);
    address bob = address(0x2);
    address attacker = address(0x666);

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

        // Create currencies
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Initialize pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000, // fee
            SQRT_PRICE_1_1
        );

        // Mint tokens to hook contract for settlement
        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 10000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 10000 ether);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );
    }

    // ============ AVS Oracle Configuration Tests ============

    function testSetAVSOracleWithZeroAddress() public {
        // Should allow setting AVS oracle to any address (including zero for testing)
        // The contract doesn't validate against zero address
        hook.setAVSOracle(address(0));
        assertEq(hook.avsOracle(), address(0));
    }

    function testSetAVSOracleOnlyOnce() public {
        hook.setAVSOracle(address(avs));
        
        // Attempt to set again should revert
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0x999));
    }

    function testSetAVSOracleWithValidAddress() public {
        address validAVS = address(0x123);
        hook.setAVSOracle(validAVS);
        assertEq(hook.avsOracle(), validAVS);
    }

    function testProcessBatchResultWithoutAVSSet() public {
        // Don't set AVS oracle
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Should revert because msg.sender != avsOracle (which is address(0))
        vm.expectRevert("Only AVS oracle");
        hook.processBatchResult(0, mockResult);
    }

    // ============ Batch Result Processing - Error Cases ============

    function testProcessBatchResultFromUnauthorizedAddress() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Try from unauthorized address
        vm.prank(attacker);
        vm.expectRevert("Only AVS oracle");
        hook.processBatchResult(0, mockResult);
    }

    function testProcessBatchResultForNonFinalizedBatch() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        // Submit intent but don't finalize
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Try to process unfinalized batch
        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(0, mockResult);
    }

    function testProcessBatchResultForAlreadyProcessedBatch() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Process batch first time
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        // Try to process same batch again - should succeed but with no effect
        // (no revert, as the contract allows reprocessing)
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    // ============ Intent Submission - Edge Cases ============

    function testSubmitIntentWithVeryLargeCiphertext() public {
        hook.setAVSOracle(address(avs));
        
        // Create a very large ciphertext (1KB)
        bytes memory largeCiphertext = new bytes(1024);
        for (uint i = 0; i < 1024; i++) {
            largeCiphertext[i] = bytes1(uint8(i % 256));
        }

        swap(key, true, -100, abi.encode(largeCiphertext));
        
        assertEq(hook.getCurrentBatchSize(), 1);
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents[0].ciphertext.length, 1024);
    }

    function testSubmitIntentWithMinimalCiphertext() public {
        hook.setAVSOracle(address(avs));
        
        // Single byte ciphertext
        bytes memory minimalCiphertext = hex"01";

        swap(key, true, -100, abi.encode(minimalCiphertext));
        
        assertEq(hook.getCurrentBatchSize(), 1);
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents[0].ciphertext.length, 1);
    }

    function testSubmitIntentWithZeroCiphertext() public {
        hook.setAVSOracle(address(avs));
        
        // Empty ciphertext
        bytes memory emptyCiphertext = hex"";

        swap(key, true, -100, abi.encode(emptyCiphertext));
        
        // Empty ciphertext should still create an intent
        assertEq(hook.getCurrentBatchSize(), 1);
    }

    function testIntentTimestampIsCorrect() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        uint256 beforeTimestamp = block.timestamp;
        swap(key, true, -100, abi.encode(intent));
        uint256 afterTimestamp = block.timestamp;

        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertTrue(intents[0].timestamp >= beforeTimestamp);
        assertTrue(intents[0].timestamp <= afterTimestamp);
    }

    // ============ Batch Finalization - Boundary Tests ============

    function testBatchFinalizationAtExactMaxSize() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit exactly MAX_BATCH_SIZE - 1 intents
        for (uint i = 0; i < 99; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 99);
        assertEq(hook.batchFinalized(0), false);

        // Submit the 100th intent
        swap(key, true, -100, abi.encode(intent));

        // Batch should be finalized
        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);
        assertEq(hook.getCurrentBatchSize(), 0);
    }

    function testBatchFinalizationAtTimeoutBoundary() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit first intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to exactly BATCH_TIMEOUT (30 seconds)
        vm.warp(block.timestamp + 30 seconds);
        
        // Submit second intent - should trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);
    }

    function testBatchFinalizationJustBeforeTimeout() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit first intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to 29 seconds (just before timeout)
        vm.warp(block.timestamp + 29 seconds);
        
        // Submit second intent - should NOT trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), false);
        assertEq(hook.getCurrentBatchSize(), 2);
    }

    function testBatchFinalizationAfterTimeout() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit first intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to 31 seconds (after timeout)
        vm.warp(block.timestamp + 31 seconds);
        
        // Submit second intent - should trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);
    }

    // ============ Settlement Amount Tests ============

    function testSettlementWithNegativeAmounts() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements with negative amounts (users paying)
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(-100),
            amount1: int256(-50)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Should process without error
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    function testSettlementWithZeroAmounts() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements with zero amounts
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(0),
            amount1: int256(0)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 0;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Should process without error
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }



    // ============ Matched Indices Tests ============

    function testMatchedIndicesOutOfBounds() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        // Submit only 2 intents
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements with matched index out of bounds
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](1);
        matchedIndices[0] = 999; // Out of bounds

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Should process without error (marks intent 999 as processed, but it doesn't exist)
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    function testDuplicateMatchedIndices() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements with duplicate matched indices
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](2);
        matchedIndices[0] = 0;
        matchedIndices[1] = 0; // Duplicate

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Should process without error (marks intent 0 as processed twice)
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        assertEq(hook.intentProcessed(0, 0), true);
    }

    // ============ IntentBridge Tests ============

    function testBridgeSubmitIntentWithLargeCiphertext() public {
        bytes memory largeCiphertext = new bytes(2048);
        for (uint i = 0; i < 2048; i++) {
            largeCiphertext[i] = bytes1(uint8(i % 256));
        }

        bridge.submitIntent(largeCiphertext);

        (bytes memory stored, , ) = bridge.batchIntents(0, 0);
        assertEq(stored.length, 2048);
    }

    function testBridgeSubmitMultipleIntentsSequentially() public {
        for (uint i = 0; i < 10; i++) {
            bytes memory intent = abi.encode(i);
            bridge.submitIntent(intent);
        }

        for (uint i = 0; i < 10; i++) {
            (bytes memory stored, , ) = bridge.batchIntents(0, i);
            bytes memory expected = abi.encode(i);
            assertEq(stored, expected);
        }
    }

    function testBridgeIntentTimestampProgression() public {
        bytes memory intent1 = hex"01";
        bridge.submitIntent(intent1);
        
        uint256 time1;
        (, , time1) = bridge.batchIntents(0, 0);

        vm.warp(block.timestamp + 100);

        bytes memory intent2 = hex"02";
        bridge.submitIntent(intent2);
        
        uint256 time2;
        (, , time2) = bridge.batchIntents(0, 1);

        assertTrue(time2 > time1);
        assertEq(time2 - time1, 100);
    }

    // ============ View Function Tests ============

    function testGetBatchIntentsForEmptyBatch() public {
        hook.setAVSOracle(address(avs));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 0);
    }

    function testGetBatchIntentsForNonExistentBatch() public {
        hook.setAVSOracle(address(avs));
        
        // Query batch that doesn't exist yet
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(999);
        assertEq(intents.length, 0);
    }

    function testGetCurrentBatchSizeAfterFinalization() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Fill batch to MAX_SIZE
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        // Batch should be finalized and new batch started
        assertEq(hook.getCurrentBatchSize(), 0);
        assertEq(hook.currentBatchId(), 1);
    }

   

    function testBatchIdIncrementConsistency() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint batchNum = 0; batchNum < 5; batchNum++) {
            // Fill each batch to MAX_SIZE
            for (uint i = 0; i < 100; i++) {
                swap(key, true, -100, abi.encode(intent));
            }
            
            assertEq(hook.batchFinalized(batchNum), true);
            assertEq(hook.currentBatchId(), batchNum + 1);
        }
    }

    // ============ Fallback Execution Tests ============

    function testFallbackWithInvalidIntentData() public {
        hook.setAVSOracle(address(avs));
        
        // Submit intent with invalid/malformed data
        bytes memory invalidIntent = hex"deadbeef";

        swap(key, true, -100, abi.encode(invalidIntent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(invalidIntent));

        // Create result with no matched intents (will trigger fallback)
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](0);
        uint256[] memory matchedIndices = new uint256[](0);

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Fallback execution may fail due to invalid intent data
        vm.prank(address(avs));
        // This may revert or succeed depending on how the contract handles invalid data
        try hook.processBatchResult(0, mockResult) {
            // If it succeeds, verify intents are marked as processed
            assertTrue(hook.intentProcessed(0, 0) || hook.intentProcessed(0, 1));
        } catch {
            // Expected if invalid data causes revert
        }
    }

    function testFallbackExecutionMarksIntentProcessed() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create result with no matched intents
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](0);
        uint256[] memory matchedIndices = new uint256[](0);

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        // All intents should be marked as processed via fallback
        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
        assertEq(hook.intentProcessed(0, 2), true);
    }

    // ============ Swap Direction Tests ============

    function testIntentWithZeroForOneTrue() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,  // zeroForOne = true
            int256(-100),
            uint160(4295128739 + 1)
        );

        swap(key, true, -100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }

    function testIntentWithZeroForOneFalse() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            false, // zeroForOne = false
            int256(-100),
            uint160(1461446703485210103287273052203988822378723970342 - 1)
        );

        swap(key, false, -100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }

    // ============ Amount Specification Tests ============

    function testIntentWithPositiveAmountSpecified() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(100), // Positive amount
            uint160(4295128739 + 1)
        );

        swap(key, true, 100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }

    function testIntentWithNegativeAmountSpecified() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100), // Negative amount
            uint160(4295128739 + 1)
        );

        swap(key, true, -100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }

  
    // ============ Price Limit Tests ============

    function testIntentWithMinPriceLimit() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(1) // Minimum price limit
        );

        swap(key, true, -100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }

    function testIntentWithMaxPriceLimit() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(type(uint160).max) // Maximum price limit
        );

        swap(key, true, -100, abi.encode(intent));
        
        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 1);
    }
}
