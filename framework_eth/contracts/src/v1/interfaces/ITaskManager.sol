// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITaskManager {
    enum TaskStatus {
        Created,
        Submitted,
        Settled,
        Disputed
    }

    struct TaskInfo {
        bytes32 taskHash;
        bytes32 taskType;
        address creator;
        address agent;
        address paymentToken;
        uint256 payment;
        bytes32 resultHash;
        uint256 submittedAt;
        TaskStatus status;
    }

    event TaskCreated(
        uint256 indexed taskId,
        bytes32 indexed taskType,
        bytes32 taskHash,
        string taskURI,
        address agent,
        address paymentToken,
        uint256 payment
    );

    event ResultSubmitted(
        uint256 indexed taskId,
        bytes32 resultHash,
        string resultURI
    );

    event TaskSettled(uint256 indexed taskId);

    event TaskDisputed(uint256 indexed taskId);

    function createTask(
        bytes32 taskHash,
        string calldata taskURI,
        bytes32 taskType,
        address agent,
        address paymentToken,
        uint256 tokenAmount
    ) external payable returns (uint256 taskId);

    function submitResult(
        uint256 taskId,
        bytes32 resultHash,
        string calldata resultURI
    ) external;

    function dispute(uint256 taskId) external;

    function settle(uint256 taskId) external;

    function getTask(uint256 taskId) external view returns (TaskInfo memory);

    function getTimeLockBlocks() external view returns (uint256);
}
