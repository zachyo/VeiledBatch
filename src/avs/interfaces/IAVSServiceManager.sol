// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAVSServiceManager
 * @notice Interface for the VeiledBatch AVS Service Manager
 * @dev Based on EigenLayer AVS middleware patterns
 */
interface IAVSServiceManager {
    // ============ Structs ============

    struct Operator {
        address operator;
        bytes32 pubKeyHash; // Operator's public key hash for BLS
        uint256 stake; // Amount staked
        bool isRegistered;
        uint256 registeredAt;
    }

    struct Task {
        uint256 taskId;
        uint256 batchId;
        bytes32 encryptedIntentsHash; // Hash of encrypted intents
        uint256 createdAt;
        bool isCompleted;
    }

    struct TaskResponse {
        uint256 taskId;
        bytes32 resultHash;
        bytes signature; // BLS signature from operators
        bytes result; // Encoded BatchResult
    }

    // ============ Events ============

    event OperatorRegistered(
        address indexed operator,
        bytes32 pubKeyHash,
        uint256 stake
    );
    event OperatorDeregistered(address indexed operator);
    event TaskCreated(
        uint256 indexed taskId,
        uint256 indexed batchId,
        bytes32 encryptedIntentsHash
    );
    event TaskResponded(
        uint256 indexed taskId,
        bytes32 resultHash,
        address indexed responder
    );
    event TaskCompleted(uint256 indexed taskId, bytes32 finalResultHash);

    // ============ Operator Management ============

    /**
     * @notice Register as an AVS operator
     * @param pubKeyHash BLS public key hash for signature verification
     */
    function registerOperator(bytes32 pubKeyHash) external payable;

    /**
     * @notice Deregister from the AVS
     */
    function deregisterOperator() external;

    /**
     * @notice Check if an address is a registered operator
     */
    function isOperator(address operator) external view returns (bool);

    /**
     * @notice Get operator details
     */
    function getOperator(
        address operator
    ) external view returns (Operator memory);

    // ============ Task Management ============

    /**
     * @notice Create a new batch processing task
     * @param batchId The batch ID to process
     * @param encryptedIntentsHash Hash of the encrypted intents
     * @return taskId The created task ID
     */
    function createTask(
        uint256 batchId,
        bytes32 encryptedIntentsHash
    ) external returns (uint256 taskId);

    /**
     * @notice Submit task response (from operator)
     * @param taskId The task to respond to
     * @param resultHash Hash of the result
     * @param signature BLS signature of the result
     * @param result The encoded BatchResult
     */
    function respondToTask(
        uint256 taskId,
        bytes32 resultHash,
        bytes calldata signature,
        bytes calldata result
    ) external;

    /**
     * @notice Get task details
     */
    function getTask(uint256 taskId) external view returns (Task memory);

    // ============ Configuration ============

    function minimumStake() external view returns (uint256);

    function quorumThreshold() external view returns (uint256);

    function responseTimeout() external view returns (uint256);
}
