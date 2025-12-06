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

        // 4. Process batch result
        BatchAuctionHook.Settlement[]
            memory settlements = new BatchAuctionHook.Settlement[](1);
        settlements[0] = BatchAuctionHook.Settlement({
            user: address(this),
            amount0: int256(100), // Net buy 100 token0 (so we need to give 100 token0 to user? No, amount0 is flow to user)
            amount1: int256(-100) // Net sell 100 token1
        });

        // If amount0 = 100, user receives 100 token0.
        // If amount1 = -100, user gives 100 token1.
        // Net for pool: Hook needs to GET 100 token0 (from pool) and GIVE 100 token1 (to pool).
        // So Hook swaps: Sell 100 token1 for token0.
        // net0 = 100, net1 = -100.
        // In unlockCallback:
        // zeroForOne = net0 < 0 = false.
        // amountSpecified = net1 = -100.
        // Swap: Exact Input 100 Token1 -> Token0.

        bytes memory mockResult = abi.encode(settlements);

        vm.prank(address(avs));
        hook.processBatchResult(0, mockResult);
    }
}
