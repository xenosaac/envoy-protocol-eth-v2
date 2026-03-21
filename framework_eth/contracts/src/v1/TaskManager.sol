// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ITaskManager.sol";

/// @title TaskManager — On-Chain Agent SDK v1
/// @notice Enables smart contracts to create tasks for off-chain AI agents
///         with escrow payment and time-lock settlement.
///
/// Task lifecycle:
///   Created ──submitResult()──▶ Submitted ──settle()──▶ Settled
///                                  │
///                                  └──dispute()──▶ Disputed (refund)
///
contract TaskManager is
    ITaskManager,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    uint256 public constant TIME_LOCK_BLOCKS = 300; // ~1 hour at 12s/block

    uint256 private _nextTaskId;
    mapping(uint256 => TaskInfo) private _tasks;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        _nextTaskId = 1;
    }

    function createTask(
        bytes32 taskHash,
        string calldata taskURI,
        bytes32 taskType,
        address agent,
        address paymentToken,
        uint256 tokenAmount
    ) external payable returns (uint256 taskId) {
        require(agent != address(0), "Invalid agent");

        uint256 payment;
        if (paymentToken == address(0)) {
            require(msg.value > 0, "No payment");
            require(tokenAmount == 0, "tokenAmount must be 0 for ETH");
            payment = msg.value;
        } else {
            require(msg.value == 0, "ETH sent with token payment");
            require(tokenAmount > 0, "No payment");
            // Fee-on-transfer safe: measure actual received amount
            uint256 balanceBefore = IERC20(paymentToken).balanceOf(address(this));
            IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), tokenAmount);
            payment = IERC20(paymentToken).balanceOf(address(this)) - balanceBefore;
        }

        taskId = _nextTaskId++;
        _tasks[taskId] = TaskInfo({
            taskHash: taskHash,
            taskType: taskType,
            creator: msg.sender,
            agent: agent,
            paymentToken: paymentToken,
            payment: payment,
            resultHash: bytes32(0),
            submittedAt: 0,
            status: TaskStatus.Created
        });

        emit TaskCreated(taskId, taskType, taskHash, taskURI, agent, paymentToken, payment);
    }

    function submitResult(
        uint256 taskId,
        bytes32 resultHash,
        string calldata resultURI
    ) external {
        TaskInfo storage task = _tasks[taskId];
        require(task.creator != address(0), "Task not found");
        require(msg.sender == task.agent, "Unauthorized");
        require(task.status == TaskStatus.Created, "Invalid status");

        task.resultHash = resultHash;
        task.submittedAt = block.number;
        task.status = TaskStatus.Submitted;

        emit ResultSubmitted(taskId, resultHash, resultURI);
    }

    function dispute(uint256 taskId) external nonReentrant {
        TaskInfo storage task = _tasks[taskId];
        require(msg.sender == task.creator, "Unauthorized");
        require(task.status == TaskStatus.Submitted, "Invalid status");
        require(
            block.number <= task.submittedAt + TIME_LOCK_BLOCKS,
            "Dispute window closed"
        );

        task.status = TaskStatus.Disputed;

        // Refund creator
        if (task.paymentToken == address(0)) {
            (bool success, ) = task.creator.call{value: task.payment}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(task.paymentToken).safeTransfer(task.creator, task.payment);
        }

        emit TaskDisputed(taskId);
    }

    function settle(uint256 taskId) external nonReentrant {
        TaskInfo storage task = _tasks[taskId];
        require(task.status == TaskStatus.Submitted, "Invalid status");
        require(
            block.number > task.submittedAt + TIME_LOCK_BLOCKS,
            "Time lock active"
        );

        task.status = TaskStatus.Settled;

        // Pay agent
        if (task.paymentToken == address(0)) {
            (bool success, ) = task.agent.call{value: task.payment}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(task.paymentToken).safeTransfer(task.agent, task.payment);
        }

        emit TaskSettled(taskId);
    }

    function getTask(uint256 taskId) external view returns (TaskInfo memory) {
        return _tasks[taskId];
    }

    function getTimeLockBlocks() external pure returns (uint256) {
        return TIME_LOCK_BLOCKS;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
