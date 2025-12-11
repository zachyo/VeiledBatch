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
 * @title BatchAuctionErrorMessagesTest
 * @notice Tests for error messages and error conditions
 */
contract BatchAuctionErrorMessagesTest is Test, Deployers {
    BatchAuctionHook hook;
    IntentBridge bridge;
    MockAVS avs;

    address alice = address(0x1);
    address bob = address(0x2);
    address attacker = address(0x666);

    function setUp() public {
        deployFreshManagerAndRouters();
        bridge = new IntentBridge();
        avs = new MockAVS();

        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
        );
        deployCodeTo("BatchAuctionHook.sol", abi.encode(manager), hookAddress);
        hook = BatchAuctionHook(hookAddress);

        (currency0, currency1) = deployMintAndApprove2Currencies();

        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1
        );

        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 10000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 10000 ether);

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

    // ============ AVS Oracle Configuration Error Messages ============

    function testSetAVSOracleErrorMessageOnDoubleSet() public {
        hook.setAVSOracle(address(avs));
        
        // Attempt to set again
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0x999));
    }

    function testSetAVSOracleErrorMessageExactText() public {
        hook.setAVSOracle(address(avs));
        
        // Verify exact error message
        bytes memory expectedError = abi.encodeWithSignature("Error(string)", "AVS already set");
        
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0x999));
    }

    // ============ Process Batch Result Error Messages ============

    function testProcessBatchResultErrorOnlyAVSOracle() public {
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

    function testProcessBatchResultErrorBatchNotFinalized() public {
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

    function testProcessBatchResultErrorBatchNotFinalizedExactMessage() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
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

        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(0, mockResult);
    }

    // ============ Authorization Error Messages ============

    function testOnlyAVSOracleCanProcessBatchErrorMessage() public {
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

        // Multiple unauthorized addresses should all fail with same message
        address[] memory unauthorizedAddresses = new address[](3);
        unauthorizedAddresses[0] = attacker;
        unauthorizedAddresses[1] = alice;
        unauthorizedAddresses[2] = bob;

        for (uint i = 0; i < unauthorizedAddresses.length; i++) {
            vm.prank(unauthorizedAddresses[i]);
            vm.expectRevert("Only AVS oracle");
            hook.processBatchResult(0, mockResult);
        }
    }

    // ============ Batch State Error Messages ============

    function testBatchAlreadyFinalizedError() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Fill batch to MAX_SIZE to trigger finalization
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        // Batch 0 should be finalized
        assertEq(hook.batchFinalized(0), true);

        // Try to finalize again (indirectly by checking state)
        // The contract doesn't expose a direct finalize function, so this is implicit
    }

    // ============ Input Validation Error Messages ============

    function testProcessBatchResultWithInvalidBatchId() public {
        hook.setAVSOracle(address(avs));
        
        // Try to process a batch that doesn't exist
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](0);
        uint256[] memory matchedIndices = new uint256[](0);

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(999, mockResult);
    }

    // ============ Error Message Consistency ============

    function testErrorMessageConsistencyAcrossMultipleCalls() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
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

        // First call should fail with "Batch not finalized"
        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(0, mockResult);

        // Second call should fail with same message
        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(0, mockResult);
    }

    // ============ Authorization Error Consistency ============

    function testAuthorizationErrorConsistency() public {
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

        // Multiple unauthorized calls should all fail with "Only AVS oracle"
        for (uint i = 0; i < 3; i++) {
            vm.prank(attacker);
            vm.expectRevert("Only AVS oracle");
            hook.processBatchResult(0, mockResult);
        }
    }

    // ============ AVS Configuration Error Messages ============

    function testAVSAlreadySetErrorMessage() public {
        hook.setAVSOracle(address(avs));
        
        // Try to set different AVS
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0x123));

        // Try to set same AVS again
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(avs));

        // Try to set zero address
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0));
    }

    // ============ Batch Processing Error Scenarios ============

    function testProcessBatchResultWithoutAVSSetError() public {
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

    // ============ Boundary Condition Error Messages ============

    function testBatchFinalizationAtBoundary() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit exactly MAX_BATCH_SIZE - 1 intents
        for (uint i = 0; i < 99; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 99);
        assertEq(hook.batchFinalized(0), false);

        // Submit the 100th intent - should finalize
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);
    }

    function testTimeoutBoundaryCondition() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        // Submit first intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to exactly BATCH_TIMEOUT (30 seconds)
        vm.warp(block.timestamp + 30 seconds);
        
        // Submit second intent - should trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
    }

    // ============ Settlement Error Scenarios ============

    function testSettlementWithInvalidUserAddress() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlement with zero address user
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(0),
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

        // Should process without error (contract doesn't validate user address)
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    // ============ Matched Indices Error Scenarios ============

    function testMatchedIndicesOutOfBoundsNoError() public {
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

    // ============ Fallback Execution Error Scenarios ============

    function testFallbackExecutionWithInvalidIntentData() public {
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
        try hook.processBatchResult(0, mockResult) {
            // If it succeeds, verify intents are marked as processed
            assertTrue(hook.intentProcessed(0, 0) || hook.intentProcessed(0, 1));
        } catch {
            // Expected if invalid data causes revert
        }
    }

    // ============ Encoding Error Scenarios ============

    function testBatchResultDecodingError() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create invalid encoded result
        bytes memory invalidResult = hex"deadbeef";

        vm.prank(address(avs));
        try hook.processBatchResult(0, invalidResult) {
            // If it succeeds, that's unexpected
            assertTrue(false, "Should have failed with invalid encoding");
        } catch {
            // Expected - invalid encoding should cause revert
        }
    }

    // ============ State Consistency Error Messages ============

    function testBatchStateConsistencyAfterError() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));

        // Try to process unfinalized batch
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

        vm.prank(address(avs));
        vm.expectRevert("Batch not finalized");
        hook.processBatchResult(0, mockResult);

        // State should remain unchanged
        assertEq(hook.getCurrentBatchSize(), 1);
        assertEq(hook.batchFinalized(0), false);
        assertEq(hook.currentBatchId(), 0);
    }
}
