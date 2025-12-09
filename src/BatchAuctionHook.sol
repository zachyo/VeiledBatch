// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract BatchAuctionHook is BaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    // Structure for an encrypted intent
    struct EncryptedIntent {
        bytes ciphertext; // FHE encrypted data
        address user;
        uint256 timestamp;
    }

    struct Settlement {
        address user;
        int256 amount0;
        int256 amount1;
    }

    struct BatchResult {
        Settlement[] settlements;  // Matched settlements from AVS
        uint256[] matchedIndices;  // Which intent indices were matched
    }

    struct DecodedIntent {
        bool zeroForOne;           // Swap direction
        int256 amountSpecified;    // Amount to swap
        uint160 sqrtPriceLimitX96; // Price limit
    }

    // Batch configuration
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant BATCH_TIMEOUT = 30 seconds;

    mapping(uint256 => EncryptedIntent[]) public batchIntents;
    mapping(uint256 => uint256) public batchStartTime;
    mapping(uint256 => bool) public batchFinalized;
    mapping(uint256 => mapping(uint256 => bool)) public intentProcessed; // batchId => intentIndex => processed

    uint256 public currentBatchId;
    address public avsOracle;
    PoolKey public activePoolKey;

    event IntentSubmitted(uint256 indexed batchId, address indexed user);
    event BatchFinalized(uint256 indexed batchId, uint256 intentCount);
    event BatchProcessed(uint256 indexed batchId, bytes avsResult);
    event BatchSettled(uint256 indexed batchId, int256 net0, int256 net1);
    event FallbackExecuted(uint256 indexed batchId, uint256 intentIndex, address user, int256 amount0Delta, int256 amount1Delta);

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        batchStartTime[0] = block.timestamp;
    }

    function setAVSOracle(address _avsOracle) external {
        require(avsOracle == address(0), "AVS already set");
        avsOracle = _avsOracle;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // If hookData is present, treat it as an encrypted intent submission
        if (hookData.length > 0) {
            activePoolKey = key;
            bytes memory ciphertext = abi.decode(hookData, (bytes));

            batchIntents[currentBatchId].push(
                EncryptedIntent({
                    ciphertext: ciphertext,
                    user: sender,
                    timestamp: block.timestamp
                })
            );

            emit IntentSubmitted(currentBatchId, sender);

            // Check if batch should be finalized
            uint256 batchSize = batchIntents[currentBatchId].length;
            uint256 batchAge = block.timestamp - batchStartTime[currentBatchId];

            if (batchSize >= MAX_BATCH_SIZE || batchAge >= BATCH_TIMEOUT) {
                _finalizeBatch();
            }
        }

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            0
        );
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        return (BaseHook.afterSwap.selector, 0);
    }

    function _finalizeBatch() internal {
        require(!batchFinalized[currentBatchId], "Batch already finalized");

        uint256 intentCount = batchIntents[currentBatchId].length;
        batchFinalized[currentBatchId] = true;

        emit BatchFinalized(currentBatchId, intentCount);

        // Move to next batch
        currentBatchId++;
        batchStartTime[currentBatchId] = block.timestamp;
    }

    function processBatchResult(
        uint256 batchId,
        bytes calldata avsResult
    ) external {
        require(msg.sender == avsOracle, "Only AVS oracle");
        require(batchFinalized[batchId], "Batch not finalized");

        emit BatchProcessed(batchId, avsResult);

        // Decode batch result (settlements + matched indices)
        BatchResult memory result = abi.decode(avsResult, (BatchResult));

        // Mark matched intents as processed
        for (uint i = 0; i < result.matchedIndices.length; i++) {
            intentProcessed[batchId][result.matchedIndices[i]] = true;
        }

        // Calculate net flow from matched settlements
        int256 net0 = 0;
        int256 net1 = 0;
        for (uint i = 0; i < result.settlements.length; i++) {
            net0 += result.settlements[i].amount0;
            net1 += result.settlements[i].amount1;
        }

        // Execute net swap if needed
        if (net0 != 0 || net1 != 0) {
            poolManager.unlock(abi.encode(net0, net1));
        }

        // Distribute funds to matched users
        for (uint i = 0; i < result.settlements.length; i++) {
            if (result.settlements[i].amount0 > 0) {
                activePoolKey.currency0.transfer(
                    result.settlements[i].user,
                    uint256(result.settlements[i].amount0)
                );
            }
            if (result.settlements[i].amount1 > 0) {
                activePoolKey.currency1.transfer(
                    result.settlements[i].user,
                    uint256(result.settlements[i].amount1)
                );
            }
        }

        emit BatchSettled(batchId, net0, net1);

        // Execute fallback swaps for unmatched intents
        uint256 totalIntents = batchIntents[batchId].length;
        for (uint i = 0; i < totalIntents; i++) {
            if (!intentProcessed[batchId][i]) {
                // Intent was not matched, execute fallback
                _executeFallbackSwap(batchId, i);
            }
        }
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");

        // Check if this is a fallback swap or normal batch settlement
        bool isFallback;
        assembly {
            // Load first 32 bytes to check if it's a bool (fallback flag)
            let firstWord := calldataload(data.offset)
            isFallback := iszero(iszero(firstWord))
        }

        // Try to decode as fallback first
        if (data.length > 64) {
            // Likely a fallback call
            (bool fallbackFlag, uint256 batchId, uint256 intentIndex, address user, DecodedIntent memory decoded) =
                abi.decode(data, (bool, uint256, uint256, address, DecodedIntent));

            if (fallbackFlag) {
                return _handleFallbackSwap(batchId, intentIndex, user, decoded);
            }
        }

        // Normal batch settlement
        (int256 net0, int256 net1) = abi.decode(data, (int256, int256));

        // Determine swap direction and amount
        // If net0 < 0, users are giving token0 (selling), so we swap exact input token0
        // If net0 > 0, users are receiving token0 (buying), so we swap exact output token0?
        // Or rather, if net0 > 0, users want token0, so they gave token1 (net1 < 0).

        bool zeroForOne = net0 < 0;
        int256 amountSpecified = zeroForOne ? net0 : net1;

        // If amountSpecified is negative (e.g. -100), we are selling 100 token0. amountSpecified = -100.

        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? 4295128739 + 1
                : 1461446703485210103287273052203988822378723970342 - 1
        });

        // We need TickMath.
        // For now, let's use hardcoded limits or import TickMath.
        // 4295128739 + 1 for min, 1461446703485210103287273052203988822378723970342 - 1 for max?
        // Let's import TickMath.

        BalanceDelta delta = poolManager.swap(
            activePoolKey,
            params,
            new bytes(0)
        );

        // Verify that the swap output covers the batch obligations
        if (zeroForOne) {
            // We sold T0 (exact input), bought T1. We need enough T1 to pay users (net1).
            // net1 should be positive (users receiving T1).
            // delta.amount1() is positive (received from pool).
            require(
                delta.amount1() >= net1,
                "Slippage: Insufficient T1 output"
            );
        } else {
            // We sold T1 (exact input), bought T0. We need enough T0 to pay users (net0).
            // net0 should be positive (users receiving T0).
            // delta.amount0() is positive (received from pool).
            require(
                delta.amount0() >= net0,
                "Slippage: Insufficient T0 output"
            );
        }

        // Settle token0
        if (delta.amount0() > 0) {
            poolManager.take(
                activePoolKey.currency0,
                address(this),
                uint256(int256(delta.amount0()))
            );
        } else if (delta.amount0() < 0) {
            poolManager.sync(activePoolKey.currency0);
            activePoolKey.currency0.transfer(
                address(poolManager),
                uint256(int256(-delta.amount0()))
            );
            poolManager.settle();
        }

        // Settle token1
        if (delta.amount1() > 0) {
            poolManager.take(
                activePoolKey.currency1,
                address(this),
                uint256(int256(delta.amount1()))
            );
        } else if (delta.amount1() < 0) {
            poolManager.sync(activePoolKey.currency1);
            activePoolKey.currency1.transfer(
                address(poolManager),
                uint256(int256(-delta.amount1()))
            );
            poolManager.settle();
        }

        return "";
    }

    /// @notice Decode mock encrypted intent (for demo purposes only)
    /// @dev In production, AVS would decrypt and return these parameters
    function _decodeIntent(bytes memory ciphertext) internal pure returns (DecodedIntent memory) {
        // For mock purposes, ciphertext is just abi.encode(bool, int256, uint160)
        (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(ciphertext, (bool, int256, uint160));

        return DecodedIntent({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
    }

    /// @notice Execute fallback swap for an unmatched intent
    /// @param batchId The batch ID
    /// @param intentIndex The index of the unmatched intent
    function _executeFallbackSwap(uint256 batchId, uint256 intentIndex) internal {
        EncryptedIntent storage intent = batchIntents[batchId][intentIndex];

        // Decode the intent parameters
        DecodedIntent memory decoded = _decodeIntent(intent.ciphertext);

        // Encode data for fallback unlock callback
        bytes memory fallbackData = abi.encode(
            true, // isFallback flag
            batchId,
            intentIndex,
            intent.user,
            decoded
        );

        // Execute fallback swap via unlock pattern
        poolManager.unlock(fallbackData);

        // Mark as processed
        intentProcessed[batchId][intentIndex] = true;
    }

    /// @notice Handle fallback swap execution within unlock callback
    function _handleFallbackSwap(
        uint256 batchId,
        uint256 intentIndex,
        address user,
        DecodedIntent memory decoded
    ) internal returns (bytes memory) {
        // Execute the swap
        SwapParams memory params = SwapParams({
            zeroForOne: decoded.zeroForOne,
            amountSpecified: decoded.amountSpecified,
            sqrtPriceLimitX96: decoded.sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(activePoolKey, params, new bytes(0));

        // Settle the swap
        _settleFallbackSwap(user, delta);

        emit FallbackExecuted(batchId, intentIndex, user, delta.amount0(), delta.amount1());

        return "";
    }

    /// @notice Settle the fallback swap and transfer tokens to user
    function _settleFallbackSwap(address user, BalanceDelta delta) internal {
        // First settle debts (negative amounts), then take credits (positive amounts)

        // Settle token0 debt
        if (delta.amount0() < 0) {
            poolManager.sync(activePoolKey.currency0);
            activePoolKey.currency0.transfer(
                address(poolManager),
                uint256(int256(-delta.amount0()))
            );
            poolManager.settle();
        }

        // Settle token1 debt
        if (delta.amount1() < 0) {
            poolManager.sync(activePoolKey.currency1);
            activePoolKey.currency1.transfer(
                address(poolManager),
                uint256(int256(-delta.amount1()))
            );
            poolManager.settle();
        }

        // Take token0 credit
        if (delta.amount0() > 0) {
            poolManager.take(
                activePoolKey.currency0,
                user,
                uint256(int256(delta.amount0()))
            );
        }

        // Take token1 credit
        if (delta.amount1() > 0) {
            poolManager.take(
                activePoolKey.currency1,
                user,
                uint256(int256(delta.amount1()))
            );
        }
    }

    function getBatchIntents(
        uint256 batchId
    ) external view returns (EncryptedIntent[] memory) {
        return batchIntents[batchId];
    }

    function getCurrentBatchSize() external view returns (uint256) {
        return batchIntents[currentBatchId].length;
    }
}
