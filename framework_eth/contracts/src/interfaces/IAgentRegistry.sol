// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAgentRegistry {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice Public view of an agent's profile (returned by getAgentProfile).
    struct AgentInfo {
        address agent;
        bytes32[] capabilities;
        uint256 stake;
        uint256 reputationScore; // Fixed-point 1e18 precision
        uint256 completions;
        uint256 dailyCompletions;
        uint256 disputes;
        uint256 registeredAt;
        bool active;
        bool paused;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AgentRegistered(
        address indexed agent,
        uint256 stake,
        bytes32[] capabilities
    );

    event AgentDeregistered(address indexed agent, uint256 stakeReturned);

    event AgentPaused(address indexed agent);

    event AgentUnpaused(address indexed agent);

    event AgentSlashed(
        address indexed agent,
        uint256 amount,
        bytes32 reason
    );

    event CompletionRecorded(
        address indexed agent,
        bytes32 indexed taskType,
        uint256 reputationGain,
        uint256 fee
    );

    event CapabilitiesUpdated(address indexed agent, bytes32[] capabilities);

    event StakeAdded(address indexed agent, uint256 amount);

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    function register(bytes32[] calldata capabilities) external payable;

    function deregister() external;

    function pause() external;

    function unpause() external;

    function topUpStake() external payable;

    // -------------------------------------------------------------------------
    // Capabilities
    // -------------------------------------------------------------------------

    function updateCapabilities(bytes32[] calldata capabilities) external;

    // -------------------------------------------------------------------------
    // Reputation (called by TaskManager only)
    // -------------------------------------------------------------------------

    function recordCompletion(
        address agent,
        bytes32 taskType,
        uint256 payment
    ) external;

    // -------------------------------------------------------------------------
    // Slashing (owner only)
    // -------------------------------------------------------------------------

    function slash(
        address agent,
        uint256 amount,
        bytes32 reason
    ) external;

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getAgentProfile(address agent) external view returns (AgentInfo memory);

    function getAgentsByCapability(bytes32 taskType) external view returns (address[] memory);

    function isRegistered(address agent) external view returns (bool);

    function isActive(address agent) external view returns (bool);
}
