// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IAgentRegistry.sol";

/// @title AgentRegistry — The Envoy Protocol V2.0
/// @notice On-chain agent registration with staking, capability discovery,
///         and harmonic reputation scoring.
///
/// Reputation algorithm:
///   gain = 1/n × 1/√k
///   n = total completions  → overall growth ≈ ln(n) (Euler, 1734)
///   k = daily completions  → daily cap → ζ(3/2) ≈ 2.612 (Riemann)
///
/// Reputation minting fee:
///   fee = gain × C   (C = reputationFeePerUnit, default 0.0001 ETH)
///   Deducted from agent's stake per completion.
///   Fees are permanently burned (stay locked in contract).
///
/// Storage layout (UUPS — DO NOT REORDER):
///   Slot 0: ReentrancyGuard._status
///   Slot 1: reputationFeePerUnit
///   Slot 2: taskManager
///   Slot 3: _profiles       (mapping)
///   Slot 4: _agentCapabilities (mapping)
///   Slot 5: _capabilityAgents  (mapping)
///   Slot 6: _capabilityIndex   (mapping)
///
contract AgentRegistry is
    IAgentRegistry,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using Math for uint256;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant PRECISION = 1e18;
    uint256 private constant PRECISION_SQ = 1e36;
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant DEFAULT_REP_FEE = 1e14; // 0.0001 ETH

    // -------------------------------------------------------------------------
    // Storage — internal profile struct (packed for gas)
    // -------------------------------------------------------------------------

    struct Profile {
        uint256 stake;
        uint256 reputationScore;   // 1e18 precision
        uint256 completions;
        uint256 dailyCompletions;
        uint256 lastDayStart;      // timestamp of current day window
        uint256 disputes;
        uint256 registeredAt;
        bool active;
        bool paused;
    }

    uint256 public reputationFeePerUnit; // C — wei per 1e18 reputation
    address public taskManager;

    mapping(address => Profile) private _profiles;
    mapping(address => bytes32[]) private _agentCapabilities;

    // Reverse index: capability → agents[]
    mapping(bytes32 => address[]) private _capabilityAgents;
    // 1-indexed position of agent in _capabilityAgents[cap] (0 = absent)
    mapping(bytes32 => mapping(address => uint256)) private _capabilityIndex;

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        address taskManager_
    ) external initializer {
        __Ownable_init(owner_);
        taskManager = taskManager_;
        reputationFeePerUnit = DEFAULT_REP_FEE;
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function register(bytes32[] calldata capabilities) external payable {
        require(!_profiles[msg.sender].active, "Already registered");
        require(msg.value >= MIN_STAKE, "Stake below minimum");
        require(capabilities.length > 0, "No capabilities");

        _profiles[msg.sender] = Profile({
            stake: msg.value,
            reputationScore: 0,
            completions: 0,
            dailyCompletions: 0,
            lastDayStart: 0,
            disputes: 0,
            registeredAt: block.timestamp,
            active: true,
            paused: false
        });

        // Store capabilities and build reverse index.
        _agentCapabilities[msg.sender] = capabilities;
        for (uint256 i = 0; i < capabilities.length; i++) {
            _addCapabilityAgent(capabilities[i], msg.sender);
        }

        emit AgentRegistered(msg.sender, msg.value, capabilities);
    }

    /// @inheritdoc IAgentRegistry
    function deregister() external nonReentrant {
        Profile storage p = _profiles[msg.sender];
        require(p.active, "Not registered");

        uint256 stakeReturn = p.stake;

        // Remove from capability index.
        bytes32[] storage caps = _agentCapabilities[msg.sender];
        for (uint256 i = 0; i < caps.length; i++) {
            _removeCapabilityAgent(caps[i], msg.sender);
        }
        delete _agentCapabilities[msg.sender];

        // Reset profile (reputation lost on deregister).
        delete _profiles[msg.sender];

        // Return remaining stake.
        if (stakeReturn > 0) {
            (bool success, ) = msg.sender.call{value: stakeReturn}("");
            require(success, "ETH transfer failed");
        }

        emit AgentDeregistered(msg.sender, stakeReturn);
    }

    /// @inheritdoc IAgentRegistry
    function pause() external {
        Profile storage p = _profiles[msg.sender];
        require(p.active, "Not registered");
        require(!p.paused, "Already paused");

        p.paused = true;
        emit AgentPaused(msg.sender);
    }

    /// @inheritdoc IAgentRegistry
    function unpause() external {
        Profile storage p = _profiles[msg.sender];
        require(p.active, "Not registered");
        require(p.paused, "Not paused");

        p.paused = false;
        emit AgentUnpaused(msg.sender);
    }

    /// @inheritdoc IAgentRegistry
    function topUpStake() external payable {
        Profile storage p = _profiles[msg.sender];
        require(p.active, "Not registered");
        require(msg.value > 0, "No value");

        p.stake += msg.value;
        emit StakeAdded(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // Capabilities
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function updateCapabilities(bytes32[] calldata capabilities) external {
        Profile storage p = _profiles[msg.sender];
        require(p.active, "Not registered");
        require(capabilities.length > 0, "No capabilities");

        // Remove old capability entries.
        bytes32[] storage oldCaps = _agentCapabilities[msg.sender];
        for (uint256 i = 0; i < oldCaps.length; i++) {
            _removeCapabilityAgent(oldCaps[i], msg.sender);
        }

        // Set new capabilities and rebuild index.
        _agentCapabilities[msg.sender] = capabilities;
        for (uint256 i = 0; i < capabilities.length; i++) {
            _addCapabilityAgent(capabilities[i], msg.sender);
        }

        emit CapabilitiesUpdated(msg.sender, capabilities);
    }

    // -------------------------------------------------------------------------
    // Reputation — called by TaskManager.settle()
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function recordCompletion(
        address agent,
        bytes32 taskType,
        uint256 payment
    ) external {
        require(msg.sender == taskManager, "Only TaskManager");

        Profile storage p = _profiles[agent];

        // Silently skip if agent is inactive, paused, or unknown.
        if (!p.active || p.paused) return;

        // Reset daily counter if a new day (UTC-aligned via 1-day window).
        if (block.timestamp >= p.lastDayStart + 1 days) {
            p.dailyCompletions = 0;
            p.lastDayStart = block.timestamp;
        }

        p.completions += 1;
        p.dailyCompletions += 1;

        // ── Harmonic reputation: gain = 1/n × 1/√k ──────────────────────
        //
        //   n = p.completions      (overall, harmonic → ln(n))
        //   k = p.dailyCompletions (daily, √ dampening → ζ(3/2) ≈ 2.612)

        uint256 harmonicGain = PRECISION / p.completions;                // 1/n
        uint256 dailyDampening = Math.sqrt(PRECISION_SQ / p.dailyCompletions); // 1/√k
        uint256 repGain = (harmonicGain * dailyDampening) / PRECISION;

        // ── Reputation-proportional stake fee: fee = gain × C ────────────
        uint256 fee = (repGain * reputationFeePerUnit) / PRECISION;

        if (p.stake >= fee) {
            p.stake -= fee;
            p.reputationScore += repGain;
        }
        // else: skip rep credit — agent must top up stake.

        // taskType is unused in the current algorithm but emitted for
        // off-chain analytics and future capability-weighted scoring.
        emit CompletionRecorded(agent, taskType, repGain, fee);
    }

    // -------------------------------------------------------------------------
    // Slashing (owner only)
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function slash(
        address agent,
        uint256 amount,
        bytes32 reason
    ) external onlyOwner {
        Profile storage p = _profiles[agent];
        require(p.active, "Agent not active");

        if (amount >= p.stake) {
            // Full slash — deactivate agent.
            amount = p.stake;
            p.stake = 0;
            p.active = false;
        } else {
            p.stake -= amount;
        }

        p.disputes += 1;

        emit AgentSlashed(agent, amount, reason);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setReputationFeePerUnit(uint256 fee_) external onlyOwner {
        reputationFeePerUnit = fee_;
    }

    function setTaskManager(address taskManager_) external onlyOwner {
        taskManager = taskManager_;
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function getAgentProfile(address agent) external view returns (AgentInfo memory) {
        Profile storage p = _profiles[agent];
        return AgentInfo({
            agent: agent,
            capabilities: _agentCapabilities[agent],
            stake: p.stake,
            reputationScore: p.reputationScore,
            completions: p.completions,
            dailyCompletions: p.dailyCompletions,
            disputes: p.disputes,
            registeredAt: p.registeredAt,
            active: p.active,
            paused: p.paused
        });
    }

    /// @inheritdoc IAgentRegistry
    function getAgentsByCapability(
        bytes32 taskType
    ) external view returns (address[] memory) {
        address[] storage all = _capabilityAgents[taskType];

        // Count active, unpaused agents.
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            Profile storage p = _profiles[all[i]];
            if (p.active && !p.paused) count++;
        }

        // Build filtered result.
        address[] memory result = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            Profile storage p = _profiles[all[i]];
            if (p.active && !p.paused) {
                result[j++] = all[i];
            }
        }

        return result;
    }

    /// @inheritdoc IAgentRegistry
    function isRegistered(address agent) external view returns (bool) {
        return _profiles[agent].active;
    }

    /// @inheritdoc IAgentRegistry
    function isActive(address agent) external view returns (bool) {
        Profile storage p = _profiles[agent];
        return p.active && !p.paused;
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // -------------------------------------------------------------------------
    // Internal — capability index management (swap-and-pop for O(1) removal)
    // -------------------------------------------------------------------------

    function _addCapabilityAgent(bytes32 cap, address agent) internal {
        if (_capabilityIndex[cap][agent] != 0) return; // dedup: skip if already indexed
        _capabilityAgents[cap].push(agent);
        _capabilityIndex[cap][agent] = _capabilityAgents[cap].length; // 1-indexed
    }

    function _removeCapabilityAgent(bytes32 cap, address agent) internal {
        uint256 idx = _capabilityIndex[cap][agent];
        if (idx == 0) return;

        uint256 lastIdx = _capabilityAgents[cap].length;
        if (idx != lastIdx) {
            address last = _capabilityAgents[cap][lastIdx - 1];
            _capabilityAgents[cap][idx - 1] = last;
            _capabilityIndex[cap][last] = idx;
        }
        _capabilityAgents[cap].pop();
        delete _capabilityIndex[cap][agent];
    }
}
