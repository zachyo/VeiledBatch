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
 * @title BatchAuctionExtendedTest
 * @notice Comprehensive test suite covering edge cases, security, and all execution paths
 */
contract BatchAuctionExtendedTest is Test, Deployers {
    BatchAuctionHook hook;
    IntentBridge bridge;
    MockAVS avs;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    address malicious = address(0x666);

    event IntentSubmitted(uint256 indexed batchId, address indexed user);
    event BatchFinalized(uint256 indexed batchId, uint256 intentCount);
    event BatchProcessed(uint256 indexed batchId, bytes avsResult);
    event BatchSettled(uint256 indexed batchId, int256 net0, int256 net1);
    event FallbackExecuted(uint256 indexed batchId, uint256 intentIndex, address user, int256 amount0Delta, int256 amount1Delta);

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

        // Mint tokens to test users
        MockERC20(Currency.unwrap(currency0)).mint(alice, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(bob, 1000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(charlie, 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(charlie, 1000 ether);

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

    // ============ Batch Size Tests ============

    function testBatchSizeLimit() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit MAX_BATCH_SIZE - 1 intents
        for (uint i = 0; i < 99; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 99);
        assertEq(hook.batchFinalized(0), false);

        // Submit one more to reach MAX_BATCH_SIZE
        swap(key, true, -100, abi.encode(intent));

        // Batch should be finalized
        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);
    }

    function testExactlyMaxBatchSize() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit exactly MAX_BATCH_SIZE intents
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        // Batch should be finalized
        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.getCurrentBatchSize(), 0); // New batch started
    }

    function testSingleIntentBatch() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit single intent
        swap(key, true, -100, abi.encode(intent));
        
        assertEq(hook.getCurrentBatchSize(), 1);

        // Warp past timeout
        vm.warp(block.timestamp + 31 seconds);
        
        // Submit another to trigger finalization
        swap(key, true, -100, abi.encode(intent));

        // Previous batch should be finalized with 1 intent
        assertEq(hook.batchFinalized(0), true);
    }

    // ============ Timeout Tests ============

    function testBatchTimeoutExactly() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to exactly 30 seconds
        vm.warp(block.timestamp + 30 seconds);
        
        // Submit another intent - should trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
    }

    function testBatchTimeoutJustBefore() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to 29 seconds (just before timeout)
        vm.warp(block.timestamp + 29 seconds);
        
        // Submit another intent - should NOT trigger finalization yet
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.getCurrentBatchSize(), 2);
        assertEq(hook.batchFinalized(0), false);
    }

    function testBatchTimeoutWellAfter() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit intent at t=0
        swap(key, true, -100, abi.encode(intent));
        
        // Warp to 1 hour later
        vm.warp(block.timestamp + 1 hours);
        
        // Submit another intent - should trigger finalization
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
    }

    // ============ Multiple Batches Tests ============

    function testMultipleBatchSequence() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Batch 0 - fill to MAX_SIZE
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }
        
        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);

        // Batch 1 - fill to MAX_SIZE
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }
        
        assertEq(hook.batchFinalized(1), true);
        assertEq(hook.currentBatchId(), 2);

        // Batch 2 - add some intents
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        assertEq(hook.getCurrentBatchSize(), 2);
    }

    function testBatchIdIncrementsCorrectly() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        assertEq(hook.currentBatchId(), 0);

        // Fill batch 0 to MAX_SIZE to trigger finalization
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }
        
        // Batch 0 should be finalized automatically
        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.currentBatchId(), 1);

        // Fill batch 1 to MAX_SIZE
        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }
        
        assertEq(hook.batchFinalized(1), true);
        assertEq(hook.currentBatchId(), 2);
    }

    // ============ Access Control Tests ============

    function testOnlyAVSOracleCanProcessBatch() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit and finalize batch
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create mock result
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

        // Try to process from non-AVS address
        vm.prank(malicious);
        vm.expectRevert("Only AVS oracle");
        hook.processBatchResult(0, mockResult);

        // Should work from AVS
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    function testAVSOracleCanOnlyBeSetOnce() public {
        hook.setAVSOracle(address(avs));
        
        // Try to set again
        vm.expectRevert("AVS already set");
        hook.setAVSOracle(address(0x999));
        
        // Verify original AVS is still set
        assertEq(hook.avsOracle(), address(avs));
    }

    function testCannotProcessUnfinalizedBatch() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit intent but don't finalize
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), false);

        // Create mock result
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

    // ============ Empty and Edge Case Tests ============

    function testSwapWithoutHookData() public {
        hook.setAVSOracle(address(avs));
        
        // Swap without hookData should not create intent
        swap(key, true, -100, new bytes(0));
        
        assertEq(hook.getCurrentBatchSize(), 0);
    }

    function testEmptyHookData() public {
        hook.setAVSOracle(address(avs));
        
        // Empty bytes should not create intent
        swap(key, true, -100, "");
        
        assertEq(hook.getCurrentBatchSize(), 0);
    }

    // ============ Settlement Calculation Tests ============

    function testNetSettlementCalculation() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit and finalize batch
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements with specific amounts
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](3);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-105)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(-50),
            amount1: int256(52)
        });
        settlements[2] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(25),
            amount1: int256(-26)
        });

        uint256[] memory matchedIndices = new uint256[](3);
        matchedIndices[0] = 0;
        matchedIndices[1] = 1;
        matchedIndices[2] = 2;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Expected net: amount0 = 100 - 50 + 25 = 75
        //               amount1 = -105 + 52 - 26 = -79
        vm.expectEmit(true, false, false, true);
        emit BatchSettled(0, 75, -79);

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    function testZeroNetSettlement() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit and finalize batch
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create settlements that net to zero
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-100)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(-100),
            amount1: int256(100)
        });

        uint256[] memory matchedIndices = new uint256[](2);
        matchedIndices[0] = 0;
        matchedIndices[1] = 1;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Expected net: amount0 = 0, amount1 = 0
        vm.expectEmit(true, false, false, true);
        emit BatchSettled(0, 0, 0);

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    // ============ Fallback Tests - Extended ============

    function testAllIntentsUnmatched() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit 3 intents
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Create result with NO matched intents
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](0);
        uint256[] memory matchedIndices = new uint256[](0);

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // All 3 intents should use fallback
        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        // Verify all processed via fallback
        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
        assertEq(hook.intentProcessed(0, 2), true);
    }

    function testPartialFallback() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit 5 intents
        for (uint i = 0; i < 5; i++) {
            swap(key, true, -100, abi.encode(intent));
        }
        
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        // Match only intents 0, 2, 4 (odd indices use fallback)
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](3);
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
        settlements[2] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });

        uint256[] memory matchedIndices = new uint256[](3);
        matchedIndices[0] = 0;
        matchedIndices[1] = 2;
        matchedIndices[2] = 4;

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        // Verify matched intents are processed
        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 2), true);
        assertEq(hook.intentProcessed(0, 4), true);
        
        // Verify unmatched used fallback
        assertEq(hook.intentProcessed(0, 1), true);
        assertEq(hook.intentProcessed(0, 3), true);
    }

    // ============ Event Emission Tests ============

    function testIntentSubmittedEvent() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // The sender in swap will be the swapRouter, not address(this)
        // Just verify the event is emitted
        vm.recordLogs();
        swap(key, true, -100, abi.encode(intent));
        
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("IntentSubmitted(uint256,address)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "IntentSubmitted event should be emitted");
    }

    function testBatchFinalizedEvent() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        
        vm.warp(block.timestamp + 31 seconds);

        // Record logs instead of expecting specific event
        vm.recordLogs();
        swap(key, true, -100, abi.encode(intent));
        
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("BatchFinalized(uint256,uint256)")) {
                found = true;
                break;
            }
        }
        assertTrue(found, "BatchFinalized event should be emitted");
    }

    function testBatchProcessedEvent() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit and finalize
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

        vm.expectEmit(true, false, false, false);
        emit BatchProcessed(0, mockResult);

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    // ============ IntentBridge Tests ============

    function testBridgeMultipleIntents() public {
        bytes memory intent1 = hex"111111";
        bytes memory intent2 = hex"222222";
        bytes memory intent3 = hex"333333";

        bridge.submitIntent(intent1);
        bridge.submitIntent(intent2);
        bridge.submitIntent(intent3);

        (bytes memory stored1, , ) = bridge.batchIntents(0, 0);
        (bytes memory stored2, , ) = bridge.batchIntents(0, 1);
        (bytes memory stored3, , ) = bridge.batchIntents(0, 2);

        assertEq(stored1, intent1);
        assertEq(stored2, intent2);
        assertEq(stored3, intent3);
    }

    function testBridgeTimestamp() public {
        bytes memory intent = hex"123456";
        
        uint256 submitTime = block.timestamp;
        bridge.submitIntent(intent);

        (, , uint256 timestamp) = bridge.batchIntents(0, 0);
        assertEq(timestamp, submitTime);
    }

    // ============ View Function Tests ============

    function testGetBatchIntents() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent1 = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        bytes memory intent2 = abi.encode(false, int256(-200), uint160(1461446703485210103287273052203988822378723970342 - 1));

        swap(key, true, -100, abi.encode(intent1));
        swap(key, false, -200, abi.encode(intent2));

        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        
        assertEq(intents.length, 2);
        assertEq(intents[0].ciphertext, intent1);
        assertEq(intents[1].ciphertext, intent2);
        // User will be the swap router/test contract, not exactly address(this)
        assertTrue(intents[0].user != address(0), "User should be set");
        assertTrue(intents[1].user != address(0), "User should be set");
    }

    function testGetCurrentBatchSize() public {
        hook.setAVSOracle(address(avs));
        
        assertEq(hook.getCurrentBatchSize(), 0);

        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        
        swap(key, true, -100, abi.encode(intent));
        assertEq(hook.getCurrentBatchSize(), 1);

        swap(key, true, -100, abi.encode(intent));
        assertEq(hook.getCurrentBatchSize(), 2);

        swap(key, true, -100, abi.encode(intent));
        assertEq(hook.getCurrentBatchSize(), 3);
    }

    // ============ Stress Tests ============

    function testLargeBatchProcessing() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(
            true,
            int256(-10),
            uint160(4295128739 + 1)
        );

        // Submit 20 intents
        for (uint i = 0; i < 20; i++) {
            swap(key, true, -10, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 20);

        // Finalize
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -10, abi.encode(intent));

        // Test with balanced settlements - net zero to avoid swap execution
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](20);
        uint256[] memory matchedIndices = new uint256[](20);
        
        // Create balanced settlements (buyers and sellers cancel out)
        for (uint i = 0; i < 10; i++) {
            settlements[i] = BatchAuctionHook.Settlement({
                user: address(this),
                amount0: int256(10),
                amount1: int256(-10)
            });
            matchedIndices[i] = i;
        }
        for (uint i = 10; i < 20; i++) {
            settlements[i] = BatchAuctionHook.Settlement({
                user: address(this),
                amount0: int256(-10),
                amount1: int256(10)
            });
            matchedIndices[i] = i;
        }

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        // Verify all 20 intents processed
        for (uint i = 0; i < 20; i++) {
            assertEq(hook.intentProcessed(0, i), true, "Intent should be processed");
        }
    }
}
