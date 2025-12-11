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
 * @title BatchAuctionSecurityEdgeCasesTest
 * @notice Tests for security scenarios, edge cases, and boundary conditions
 */
contract BatchAuctionSecurityEdgeCasesTest is Test, Deployers {
    BatchAuctionHook hook;
    IntentBridge bridge;
    MockAVS avs;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
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


    // ============ Intent User Tracking ============

    function testIntentUserAddressTracking() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertTrue(intents[0].user != address(0), "User should be tracked");
    }

    function testMultipleIntentsFromSameUser() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.EncryptedIntent[] memory intents = hook.getBatchIntents(0);
        assertEq(intents.length, 3);
        
        assertEq(intents[0].user, intents[1].user);
        assertEq(intents[1].user, intents[2].user);
    }

    // ============ Batch State Consistency ============

    function testBatchStartTimeIsSet() public {
        hook.setAVSOracle(address(avs));
        
        uint256 beforeTime = block.timestamp;
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));
        swap(key, true, -100, abi.encode(intent));
        uint256 afterTime = block.timestamp;

        assertTrue(hook.batchStartTime(0) >= beforeTime);
        assertTrue(hook.batchStartTime(0) <= afterTime);
    }

    function testBatchStartTimeUpdatesOnFinalization() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint i = 0; i < 100; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        uint256 batch0StartTime = hook.batchStartTime(0);
        uint256 batch1StartTime = hook.batchStartTime(1);

        assertTrue(batch1StartTime >= batch0StartTime);
    }

    // ============ Settlement Distribution ============

    function testSettlementDistributionToMultipleUsers() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: alice,
            amount0: int256(100),
            amount1: int256(-102)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: bob,
            amount0: int256(50),
            amount1: int256(-51)
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

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);

        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
    }

    

    function testSettlementWithOnlyNegativeAmounts() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

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

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    // ============ Timeout Edge Cases ============

    function testTimeoutWithNoNewIntents() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        
        vm.warp(block.timestamp + 31 seconds);

        assertEq(hook.batchFinalized(0), false);

        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
    }

    function testTimeoutWithMultipleIntents() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint i = 0; i < 10; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 10);

        vm.warp(block.timestamp + 31 seconds);

        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.batchFinalized(0), true);
        assertEq(hook.getCurrentBatchSize(), 0);
    }

    // ============ Intent Processing State ============

    function testIntentProcessedFlagPersistence() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        assertEq(hook.intentProcessed(0, 0), false);
        assertEq(hook.intentProcessed(0, 1), false);

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
        hook.processBatchResult(0, mockResult);

        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
        assertEq(hook.intentProcessed(0, 2), true);
    }

    // ============ Empty Batch Scenarios ============

    function testEmptyBatchProcessing() public {
        hook.setAVSOracle(address(avs));
        
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
        hook.processBatchResult(0, mockResult);
    }

    // ============ Ciphertext Variations ============

    function testCiphertextWithAllZeros() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory zeroCiphertext = new bytes(32);
        swap(key, true, -100, abi.encode(zeroCiphertext));
        
        assertEq(hook.getCurrentBatchSize(), 1);
    }

    function testCiphertextWithAllOnes() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory onesCiphertext = new bytes(32);
        for (uint i = 0; i < 32; i++) {
            onesCiphertext[i] = 0xff;
        }
        swap(key, true, -100, abi.encode(onesCiphertext));
        
        assertEq(hook.getCurrentBatchSize(), 1);
    }

    // ============ Batch Result Encoding Variations ============

    function testBatchResultWithEmptySettlements() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

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

        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
    }

    function testBatchResultWithMismatchedArrayLengths() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        swap(key, true, -100, abi.encode(intent));
        swap(key, true, -100, abi.encode(intent));
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-102)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(50),
            amount1: int256(-51)
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
        hook.processBatchResult(0, mockResult);

        assertEq(hook.intentProcessed(0, 0), true);
    }

    // ============ Rapid Batch Transitions ============

    function testRapidBatchTransitions() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint batch = 0; batch < 3; batch++) {
            for (uint i = 0; i < 100; i++) {
                swap(key, true, -100, abi.encode(intent));
            }
            assertEq(hook.batchFinalized(batch), true);
        }

        assertEq(hook.currentBatchId(), 3);
    }

    

    // ============ Fallback Swap Scenarios ============

    function testFallbackSwapWithAllIntentsUnmatched() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint i = 0; i < 5; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

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

        for (uint i = 0; i < 5; i++) {
            assertEq(hook.intentProcessed(0, i), true);
        }
    }

    function testFallbackSwapWithAlternatingMatching() public {
        hook.setAVSOracle(address(avs));
        
        bytes memory intent = abi.encode(true, int256(-100), uint160(4295128739 + 1));

        for (uint i = 0; i < 6; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -100, abi.encode(intent));

        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](3);
        for (uint i = 0; i < 3; i++) {
            settlements[i] = BatchAuctionHook.Settlement({
                user: address(this),
                amount0: int256(100),
                amount1: int256(-102)
            });
        }

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

        for (uint i = 0; i < 6; i++) {
            assertEq(hook.intentProcessed(0, i), true);
        }
    }
}
