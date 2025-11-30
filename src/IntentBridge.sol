// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract IntentBridge {
    // Structure for an encrypted intent
    struct EncryptedIntent {
        bytes ciphertext; // FHE encrypted data
        address user;
        uint256 timestamp;
    }

    mapping(uint256 => EncryptedIntent[]) public batchIntents;
    uint256 public currentBatchId;

    event IntentSubmitted(uint256 indexed batchId, address indexed user);

    function submitIntent(bytes calldata ciphertext) external {
        batchIntents[currentBatchId].push(
            EncryptedIntent({ciphertext: ciphertext, user: msg.sender, timestamp: block.timestamp})
        );

        emit IntentSubmitted(currentBatchId, msg.sender);
    }
}
