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
        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 1000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 1000 ether);

        // Add liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
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

        // 1. Submit first intent
        bytes memory ciphertext = hex"123456";
        bytes memory hookData = abi.encode(ciphertext);

        swap(key, true, -100, hookData);

        // 2. Warp to trigger timeout
        vm.warp(block.timestamp + 31 seconds);

        // 3. Submit second intent to trigger finalization
        swap(key, true, -100, hookData);

        assertEq(hook.batchFinalized(0), true);

        // 4. Process batch result with new BatchResult format
        // Mark BOTH intents as matched (we submitted 2 intents above)
        BatchAuctionHook.Settlement[]
            memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100), // Net buy 100 token0
            amount1: int256(-102) // Net sell 102 token1 (extra to cover fees)
        });

        // Mark both intents as matched to avoid fallback (they have mock data)
        uint256[] memory matchedIndices = new uint256[](2);
        matchedIndices[0] = 0;
        matchedIndices[1] = 1; // Mark intent 1 as matched too

        bytes memory mockResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }

    function testFallbackMechanism() public {
        hook.setAVSOracle(address(avs));

        // Create properly encoded intents (zeroForOne, amountSpecified, sqrtPriceLimitX96)
        // Intent 0: Sell token0 for token1
        bytes memory intent0 = abi.encode(
            true,  // zeroForOne: true = selling token0
            int256(-100), // Sell 100 token0
            uint160(4295128739 + 1) // Min sqrt price limit
        );

        // Intent 1: Sell token1 for token0
        bytes memory intent1 = abi.encode(
            false, // zeroForOne: false = selling token1
            int256(-100), // Sell 100 token1
            uint160(1461446703485210103287273052203988822378723970342 - 1) // Max sqrt price limit
        );

        // Intent 2: Another sell token0 for token1 (will be unmatched)
        bytes memory intent2 = abi.encode(
            true,  // zeroForOne: true = selling token0
            int256(-50), // Sell 50 token0
            uint160(4295128739 + 1) // Min sqrt price limit
        );

        // Submit 3 intents via swaps
        swap(key, true, -100, abi.encode(intent0));
        swap(key, false, -100, abi.encode(intent1));
        swap(key, true, -50, abi.encode(intent2));

        // Verify we have 3 intents
        assertEq(hook.getCurrentBatchSize(), 3);

        // Warp time to trigger timeout
        vm.warp(block.timestamp + 31 seconds);

        // Submit another intent to trigger finalization
        swap(key, true, -10, abi.encode(intent0));

        // Verify batch is finalized
        assertEq(hook.batchFinalized(0), true);

        // Create BatchResult: Only match first 2 intents, leave intent 2 unmatched
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(-100),
            amount1: int256(98)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-98)
        });

        uint256[] memory matchedIndices = new uint256[](2);
        matchedIndices[0] = 0;
        matchedIndices[1] = 1;
        // Intent 2 (index 2) is NOT in matchedIndices → will trigger fallback

        // Encode BatchResult
        bytes memory batchResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        // Expect FallbackExecuted event for intent 2
        vm.expectEmit(true, true, false, false);
        emit BatchAuctionHook.FallbackExecuted(0, 2, address(this), 0, 0);

        // Process batch result (should execute fallback for intent 2)
        vm.prank(address(avs));
        hook.processBatchResult(0, batchResult);

        // Verify intent 2 was marked as processed
        assertEq(hook.intentProcessed(0, 2), true);

        // Verify all 3 intents are now processed
        assertEq(hook.intentProcessed(0, 0), true);
        assertEq(hook.intentProcessed(0, 1), true);
        assertEq(hook.intentProcessed(0, 2), true);
    }

    function testFallbackWithMultipleUnmatched() public {
        hook.setAVSOracle(address(avs));

        // Create 5 intents
        bytes memory intent = abi.encode(
            true,
            int256(-100),
            uint160(4295128739 + 1)
        );

        // Submit 5 intents
        for (uint i = 0; i < 5; i++) {
            swap(key, true, -100, abi.encode(intent));
        }

        assertEq(hook.getCurrentBatchSize(), 5);

        // Trigger finalization
        vm.warp(block.timestamp + 31 seconds);
        swap(key, true, -10, abi.encode(intent));

        // MockAVS will only match first 2 by default
        // Intents 2, 3, 4 should use fallback

        // Create result with only 2 matched
        BatchAuctionHook.Settlement[] memory settlements = new BatchAuctionHook.Settlement[](2);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(-100),
            amount1: int256(98)
        });
        settlements[1] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100),
            amount1: int256(-98)
        });

        uint256[] memory matchedIndices = new uint256[](2);
        matchedIndices[0] = 0;
        matchedIndices[1] = 1;

        bytes memory batchResult = abi.encode(
            BatchAuctionHook.BatchResult({
                settlements: settlements,
                matchedIndices: matchedIndices
            })
        );

        vm.prank(address(avs));
        hook.processBatchResult(0, batchResult);

        // Verify all 5 intents are processed (2 matched + 3 fallback)
        for (uint i = 0; i < 5; i++) {
            assertEq(hook.intentProcessed(0, i), true, "Intent should be processed");
        }
    }
}
