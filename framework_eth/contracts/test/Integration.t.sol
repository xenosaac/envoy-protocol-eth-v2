// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/TaskManagerV2.sol";
import "../src/AgentRegistry.sol";
import "../src/interfaces/IAgentRegistry.sol";

/// @notice End-to-end integration tests for the V2 lifecycle:
///   register → createTask(0x0) → acceptTask → submitResult → settle → reputation
contract IntegrationTest is Test {
    TaskManagerV2 internal tm;
    AgentRegistry internal reg;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal agent1 = makeAddr("agent1");
    address internal agent2 = makeAddr("agent2");
    address internal agent3 = makeAddr("agent3");

    bytes32 internal constant CAP_LLM = keccak256("llm");
    bytes32 internal constant TASK_TYPE = keccak256("llm"); // matches capability
    uint256 internal constant PRECISION = 1e18;

    function setUp() public {
        // Deploy TaskManagerV2 behind proxy.
        TaskManagerV2 tmImpl = new TaskManagerV2();
        bytes memory tmInit = abi.encodeCall(TaskManagerV2.initialize, (owner));
        ERC1967Proxy tmProxy = new ERC1967Proxy(address(tmImpl), tmInit);
        tm = TaskManagerV2(payable(address(tmProxy)));

        // Deploy AgentRegistry behind proxy.
        AgentRegistry regImpl = new AgentRegistry();
        bytes memory regInit = abi.encodeCall(
            AgentRegistry.initialize,
            (owner, address(tmProxy))
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        reg = AgentRegistry(payable(address(regProxy)));

        // Link.
        vm.prank(owner);
        tm.initializeV2(address(regProxy));

        // Fund accounts.
        vm.deal(creator, 100 ether);
        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(agent3, 10 ether);
    }

    // =========================================================================
    // Full V2 lifecycle
    // =========================================================================

    function test_fullLifecycle() public {
        // 1. Register agent with capability.
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent1);
        reg.register{value: 0.1 ether}(caps);

        // 2. Creator creates open task.
        vm.prank(creator);
        uint256 taskId = tm.createTask{value: 1 ether}(
            keccak256("do work"),
            "ipfs://task",
            TASK_TYPE,
            address(0), // open task
            address(0),
            0
        );

        // 3. Agent discovers task, accepts it.
        vm.prank(agent1);
        tm.acceptTask(taskId);

        // 4. Agent executes off-chain, submits result.
        vm.prank(agent1);
        tm.submitResult(taskId, keccak256("result"), "ipfs://result");

        // 5. Time-lock expires, anyone settles.
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);
        uint256 agentBefore = agent1.balance;
        tm.settle(taskId);

        // 6. Verify payment.
        assertEq(agent1.balance, agentBefore + 1 ether);

        // 7. Verify reputation updated.
        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 1);
        assertEq(info.reputationScore, PRECISION); // 1/1 × 1/√1 = 1.0
    }

    // =========================================================================
    // Competitive acceptance — first wins
    // =========================================================================

    function test_competitiveAcceptance_firstWins() public {
        // Register two agents.
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent1);
        reg.register{value: 0.1 ether}(caps);
        vm.prank(agent2);
        reg.register{value: 0.1 ether}(caps);

        // Create open task.
        vm.prank(creator);
        uint256 taskId = tm.createTask{value: 1 ether}(
            keccak256("task"), "ipfs://t", TASK_TYPE, address(0), address(0), 0
        );

        // Agent1 accepts first.
        vm.prank(agent1);
        tm.acceptTask(taskId);

        // Agent2 tries — should fail.
        vm.prank(agent2);
        vm.expectRevert("Already accepted");
        tm.acceptTask(taskId);

        // Agent1 completes.
        vm.prank(agent1);
        tm.submitResult(taskId, keccak256("r"), "ipfs://r");
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);
        tm.settle(taskId);

        // Only agent1 got reputation.
        assertEq(reg.getAgentProfile(agent1).completions, 1);
        assertEq(reg.getAgentProfile(agent2).completions, 0);
    }

    // =========================================================================
    // Reputation diminishing returns
    // =========================================================================

    function test_reputationDiminishingReturns() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent1);
        reg.register{value: 1 ether}(caps); // large stake

        // Complete 100 tasks on different days.
        for (uint256 i = 0; i < 100; i++) {
            vm.warp(block.timestamp + 1 days);

            vm.prank(creator);
            uint256 taskId = tm.createTask{value: 0.01 ether}(
                keccak256(abi.encodePacked("task", i)),
                "ipfs://t",
                TASK_TYPE,
                agent1,
                address(0),
                0
            );

            vm.prank(agent1);
            tm.submitResult(taskId, keccak256(abi.encodePacked("r", i)), "ipfs://r");

            vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);
            tm.settle(taskId);
        }

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 100);

        // H(100) ≈ 5.187... (harmonic series)
        // Score should be approximately 5.19 × 1e18.
        assertTrue(info.reputationScore > 5.1e18, "Rep too low for 100 completions");
        assertTrue(info.reputationScore < 5.3e18, "Rep too high for 100 completions");
    }

    // =========================================================================
    // Stake lifecycle: register → slash → deregister
    // =========================================================================

    function test_stakeLifecycle() public {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent1);
        reg.register{value: 0.5 ether}(caps);

        // Partial slash.
        vm.prank(owner);
        reg.slash(agent1, 0.2 ether, keccak256("bad work"));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.stake, 0.3 ether);
        assertTrue(info.active);

        // Deregister — get remaining stake back.
        uint256 balBefore = agent1.balance;
        vm.prank(agent1);
        reg.deregister();

        assertEq(agent1.balance, balBefore + 0.3 ether);
    }

    // =========================================================================
    // Registry discovery flow
    // =========================================================================

    function test_discoveryFlow() public {
        // Register agents with different capabilities.
        bytes32[] memory llmCaps = new bytes32[](1);
        llmCaps[0] = CAP_LLM;
        bytes32[] memory scrapeCaps = new bytes32[](1);
        scrapeCaps[0] = keccak256("scrape");

        vm.prank(agent1);
        reg.register{value: 0.1 ether}(llmCaps);
        vm.prank(agent2);
        reg.register{value: 0.1 ether}(llmCaps);
        vm.prank(agent3);
        reg.register{value: 0.1 ether}(scrapeCaps);

        // Query by capability.
        address[] memory llmAgents = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llmAgents.length, 2);

        address[] memory scrapeAgents = reg.getAgentsByCapability(keccak256("scrape"));
        assertEq(scrapeAgents.length, 1);
        assertEq(scrapeAgents[0], agent3);

        // Pause agent1 — should be excluded from queries.
        vm.prank(agent1);
        reg.pause();

        llmAgents = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llmAgents.length, 1);
        assertEq(llmAgents[0], agent2);
    }
}
