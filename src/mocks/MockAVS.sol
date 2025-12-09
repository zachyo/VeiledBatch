// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBatchAuctionHook {
    function processBatchResult(uint256 batchId, bytes calldata avsResult) external;
}

contract MockAVS {
    struct Settlement {
        address user;
        int256 amount0;
        int256 amount1;
    }

    struct BatchResult {
        Settlement[] settlements;  // Matched settlements
        uint256[] matchedIndices;  // Which intent indices were matched
    }

    struct StoredBatchResult {
        uint256 clearingPrice;
        uint256 totalMatched;
        bytes32 resultHash;
    }

    mapping(uint256 => StoredBatchResult) public batchResults;

    event BatchProcessed(uint256 indexed batchId, uint256 clearingPrice, uint256 totalMatched);
    event BatchSubmitted(uint256 indexed batchId, uint256 intentCount);

    function submitBatch(address hookAddress, uint256 batchId, uint256 intentCount) external {
        emit BatchSubmitted(batchId, intentCount);

        // Simulate off-chain FHE computation
        // In reality, this would be done by EigenLayer operators
        uint256 mockClearingPrice = 1000e6; // Mock USDC price
        uint256 mockTotalMatched = intentCount * 100e6; // Mock matched volume

        batchResults[batchId] = StoredBatchResult({
            clearingPrice: mockClearingPrice,
            totalMatched: mockTotalMatched,
            resultHash: keccak256(abi.encodePacked(batchId, mockClearingPrice, mockTotalMatched))
        });

        emit BatchProcessed(batchId, mockClearingPrice, mockTotalMatched);

        // Simulate matching: For demo, match first 2 intents if we have them
        // In reality, AVS would run real auction logic
        Settlement[] memory settlements = new Settlement[](intentCount >= 2 ? 2 : intentCount);
        uint256[] memory matchedIndices = new uint256[](intentCount >= 2 ? 2 : intentCount);

        if (intentCount >= 2) {
            // Mock: Intent 0 and 1 get matched
            settlements[0] = Settlement({
                user: address(0), // Hook will fill this
                amount0: 100,
                amount1: -102
            });
            settlements[1] = Settlement({
                user: address(0),
                amount0: -100,
                amount1: 102
            });
            matchedIndices[0] = 0;
            matchedIndices[1] = 1;
        } else if (intentCount == 1) {
            // Only one intent, match it
            settlements[0] = Settlement({
                user: address(0),
                amount0: 100,
                amount1: -102
            });
            matchedIndices[0] = 0;
        }

        // Create BatchResult with settlements and matched indices
        BatchResult memory result = BatchResult({
            settlements: settlements,
            matchedIndices: matchedIndices
        });

        // Send result back to hook
        bytes memory avsResult = abi.encode(result);
        IBatchAuctionHook(hookAddress).processBatchResult(batchId, avsResult);
    }

    function getBatchResult(uint256 batchId) external view returns (StoredBatchResult memory) {
        return batchResults[batchId];
    }
}
