// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@envoy-v1/interfaces/ITaskManager.sol";
import "./interfaces/IAgentRegistry.sol";

/// @title TaskManagerV2 — UUPS upgrade of V1 TaskManager
/// @notice Adds competitive task acceptance (agent=0x0 for open tasks) and
///         automatic reputation recording via AgentRegistry on settle().
///
/// Task lifecycle (V2):
///   Created ──acceptTask()──▶ Created (agent set)
///                │
///                └──submitResult()──▶ Submitted ──settle()──▶ Settled
///                                        │                      │
///                                        └──dispute()──▶ Disputed
///                                                     (refund)
///
/// V2 changes from V1:
///   - acceptTask() for competitive open-task acceptance
///   - settle() records reputation via AgentRegistry (try/catch)
///   - Time-lock uses block.timestamp (seconds) instead of block.number
///     for L2 compatibility (OP Stack: 2s blocks, Arbitrum: ~L1 block.number)
///
/// Storage layout is UUPS-compatible with V1 TaskManager:
///   Slot 0: ReentrancyGuard._status
///   Slot 1: _nextTaskId
///   Slot 2: _tasks (mapping) — submittedAt now stores timestamp, not block number
///   Slot 3: _registry  ← NEW in V2
///
contract TaskManagerV2 is
    ITaskManager,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Dispute window in seconds. Works identically on all EVM chains
    ///         (L1 and L2) regardless of block time.
    /// @dev    V1 used TIME_LOCK_BLOCKS = 300 (~1 hour at 12s/block on L1).
    ///         V2 switches to timestamp-based locking for L2 compatibility
    ///         (OP Stack chains produce blocks every 2s, making block-based
    ///         locks 6x shorter than intended).
    uint256 public constant TIME_LOCK_DURATION = 3600; // 1 hour in seconds

    // -------------------------------------------------------------------------
    // V1 Storage — DO NOT REORDER
    // -------------------------------------------------------------------------

    uint256 private _nextTaskId;
    mapping(uint256 => TaskInfo) private _tasks;

    // -------------------------------------------------------------------------
    // V2 Storage — APPEND ONLY
    // -------------------------------------------------------------------------

    IAgentRegistry private _registry;

    // -------------------------------------------------------------------------
    // V2 Events
    // -------------------------------------------------------------------------

    event TaskAccepted(uint256 indexed taskId, address indexed agent);

    // -------------------------------------------------------------------------
    // Constructor / Initializers
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice V1-compatible initializer. Called once on first proxy deploy.
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        _nextTaskId = 1;
    }

    /// @notice V2 re-initializer. Called once after upgrading from V1.
    function initializeV2(address registry_) external reinitializer(2) {
        _registry = IAgentRegistry(registry_);
    }

    // -------------------------------------------------------------------------
    // createTask — V2: allows agent = address(0) for open tasks
    // -------------------------------------------------------------------------

    function createTask(
        bytes32 taskHash,
        string calldata taskURI,
        bytes32 taskType,
        address agent,
        address paymentToken,
        uint256 tokenAmount
    ) external payable returns (uint256 taskId) {
        // V2: agent = address(0) is valid (open task).
        // If agent is specified, no registry check — allows non-registered
        // agents for V1 backward compatibility.

        uint256 payment;
        if (paymentToken == address(0)) {
            require(msg.value > 0, "No payment");
            require(tokenAmount == 0, "tokenAmount must be 0 for ETH");
            payment = msg.value;
        } else {
            require(msg.value == 0, "ETH sent with token payment");
            require(tokenAmount > 0, "No payment");
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

    // -------------------------------------------------------------------------
    // acceptTask — V2: competitive acceptance for open tasks
    // -------------------------------------------------------------------------

    /// @notice First registered agent to call wins the open task.
    function acceptTask(uint256 taskId) external {
        TaskInfo storage task = _tasks[taskId];
        require(task.creator != address(0), "Task not found");
        require(task.status == TaskStatus.Created, "Invalid status");
        require(task.agent == address(0), "Already accepted");

        // Agent must be active in the registry.
        require(
            address(_registry) != address(0) && _registry.isActive(msg.sender),
            "Not a registered agent"
        );

        task.agent = msg.sender;
        emit TaskAccepted(taskId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // submitResult — unchanged from V1
    // -------------------------------------------------------------------------

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
        task.submittedAt = block.timestamp;
        task.status = TaskStatus.Submitted;

        emit ResultSubmitted(taskId, resultHash, resultURI);
    }

    // -------------------------------------------------------------------------
    // dispute — DRY refactor: uses _transferPayment helper
    // -------------------------------------------------------------------------

    function dispute(uint256 taskId) external nonReentrant {
        TaskInfo storage task = _tasks[taskId];
        require(msg.sender == task.creator, "Unauthorized");
        require(task.status == TaskStatus.Submitted, "Invalid status");
        require(
            block.timestamp <= task.submittedAt + TIME_LOCK_DURATION,
            "Dispute window closed"
        );

        task.status = TaskStatus.Disputed;
        _transferPayment(task.paymentToken, task.creator, task.payment);

        emit TaskDisputed(taskId);
    }

    // -------------------------------------------------------------------------
    // settle — V2: records completion on registry (try/catch, never blocks)
    // -------------------------------------------------------------------------

    function settle(uint256 taskId) external nonReentrant {
        TaskInfo storage task = _tasks[taskId];
        require(task.status == TaskStatus.Submitted, "Invalid status");
        require(
            block.timestamp > task.submittedAt + TIME_LOCK_DURATION,
            "Time lock active"
        );

        task.status = TaskStatus.Settled;
        _transferPayment(task.paymentToken, task.agent, task.payment);

        // Record completion on registry. Payment always succeeds even if
        // reputation update fails (registry down, agent deregistered, etc.).
        // The code.length check is required because Solidity 0.8+ reverts on
        // calls to non-contract addresses, which try/catch cannot catch.
        if (
            address(_registry) != address(0) &&
            address(_registry).code.length > 0
        ) {
            try _registry.recordCompletion(
                task.agent,
                task.taskType,
                task.payment
            ) {} catch {}
        }

        emit TaskSettled(taskId);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getTask(uint256 taskId) external view returns (TaskInfo memory) {
        return _tasks[taskId];
    }

    /// @notice Returns TIME_LOCK_DURATION (seconds). Satisfies ITaskManager
    ///         interface. Note: V1 returned block count; V2 returns seconds.
    function getTimeLockBlocks() external pure returns (uint256) {
        return TIME_LOCK_DURATION;
    }

    /// @notice V2 view — returns the dispute window in seconds.
    function getTimeLockDuration() external pure returns (uint256) {
        return TIME_LOCK_DURATION;
    }

    function registry() external view returns (address) {
        return address(_registry);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // Internal — DRY payment transfer (used by dispute + settle)
    // -------------------------------------------------------------------------

    function _transferPayment(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
