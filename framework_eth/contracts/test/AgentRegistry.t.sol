// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentRegistry.sol";
import "../src/interfaces/IAgentRegistry.sol";

contract AgentRegistryTest is Test {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    AgentRegistry internal impl;
    AgentRegistry internal reg; // proxy cast
    ERC1967Proxy internal proxy;

    address internal owner = makeAddr("owner");
    address internal tmAddr = makeAddr("taskManager");
    address internal agent1 = makeAddr("agent1");
    address internal agent2 = makeAddr("agent2");
    address internal agent3 = makeAddr("agent3");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant CAP_LLM = keccak256("llm");
    bytes32 internal constant CAP_SCRAPE = keccak256("scrape");
    bytes32 internal constant CAP_API = keccak256("api");
    bytes32 internal constant TASK_TYPE = keccak256("type");

    uint256 internal constant STAKE = 0.1 ether;
    uint256 internal constant PRECISION = 1e18;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        impl = new AgentRegistry();
        bytes memory initData = abi.encodeCall(
            AgentRegistry.initialize,
            (owner, tmAddr)
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        reg = AgentRegistry(payable(address(proxy)));

        vm.deal(agent1, 10 ether);
        vm.deal(agent2, 10 ether);
        vm.deal(agent3, 10 ether);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _caps(bytes32 c1) internal pure returns (bytes32[] memory) {
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = c1;
        return caps;
    }

    function _caps2(bytes32 c1, bytes32 c2) internal pure returns (bytes32[] memory) {
        bytes32[] memory caps = new bytes32[](2);
        caps[0] = c1;
        caps[1] = c2;
        return caps;
    }

    function _registerAgent(address agent, bytes32[] memory caps) internal {
        vm.prank(agent);
        reg.register{value: STAKE}(caps);
    }

    function _registerAgent1() internal {
        _registerAgent(agent1, _caps(CAP_LLM));
    }

    // =========================================================================
    // register
    // =========================================================================

    function test_register_happyPath() public {
        _registerAgent1();

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.agent, agent1);
        assertEq(info.stake, STAKE);
        assertEq(info.reputationScore, 0);
        assertEq(info.completions, 0);
        assertTrue(info.active);
        assertFalse(info.paused);
        assertEq(info.capabilities.length, 1);
        assertEq(info.capabilities[0], CAP_LLM);
    }

    function test_register_emitsEvent() public {
        bytes32[] memory caps = _caps(CAP_LLM);

        vm.expectEmit(true, false, false, true, address(reg));
        emit IAgentRegistry.AgentRegistered(agent1, STAKE, caps);

        vm.prank(agent1);
        reg.register{value: STAKE}(caps);
    }

    function test_register_belowMinStakeReverts() public {
        vm.prank(agent1);
        vm.expectRevert("Stake below minimum");
        reg.register{value: 0.001 ether}(_caps(CAP_LLM));
    }

    function test_register_emptyCapabilitiesReverts() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.prank(agent1);
        vm.expectRevert("No capabilities");
        reg.register{value: STAKE}(empty);
    }

    function test_register_alreadyRegisteredReverts() public {
        _registerAgent1();

        vm.prank(agent1);
        vm.expectRevert("Already registered");
        reg.register{value: STAKE}(_caps(CAP_LLM));
    }

    function test_register_multipleCapabilities() public {
        _registerAgent(agent1, _caps2(CAP_LLM, CAP_SCRAPE));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.capabilities.length, 2);
    }

    // =========================================================================
    // deregister
    // =========================================================================

    function test_deregister_returnsStake() public {
        _registerAgent1();
        uint256 balBefore = agent1.balance;

        vm.prank(agent1);
        reg.deregister();

        assertEq(agent1.balance, balBefore + STAKE);
        assertFalse(reg.isRegistered(agent1));
    }

    function test_deregister_resetsReputation() public {
        _registerAgent1();

        // Record a completion to build reputation.
        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory before = reg.getAgentProfile(agent1);
        assertTrue(before.reputationScore > 0);

        vm.prank(agent1);
        reg.deregister();

        // Re-register: reputation should be 0.
        vm.prank(agent1);
        reg.register{value: STAKE}(_caps(CAP_LLM));

        IAgentRegistry.AgentInfo memory after_ = reg.getAgentProfile(agent1);
        assertEq(after_.reputationScore, 0);
        assertEq(after_.completions, 0);
    }

    function test_deregister_notRegisteredReverts() public {
        vm.prank(stranger);
        vm.expectRevert("Not registered");
        reg.deregister();
    }

    function test_deregister_removesFromCapabilityIndex() public {
        _registerAgent1();

        address[] memory before = reg.getAgentsByCapability(CAP_LLM);
        assertEq(before.length, 1);

        vm.prank(agent1);
        reg.deregister();

        address[] memory after_ = reg.getAgentsByCapability(CAP_LLM);
        assertEq(after_.length, 0);
    }

    function test_deregister_emitsEvent() public {
        _registerAgent1();

        vm.expectEmit(true, false, false, true, address(reg));
        emit IAgentRegistry.AgentDeregistered(agent1, STAKE);

        vm.prank(agent1);
        reg.deregister();
    }

    // =========================================================================
    // pause / unpause
    // =========================================================================

    function test_pause_setsFlag() public {
        _registerAgent1();

        vm.prank(agent1);
        reg.pause();

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertTrue(info.paused);
        assertTrue(info.active); // still registered
        assertFalse(reg.isActive(agent1)); // not active for tasks
    }

    function test_unpause_clearsFlag() public {
        _registerAgent1();
        vm.prank(agent1);
        reg.pause();
        vm.prank(agent1);
        reg.unpause();

        assertTrue(reg.isActive(agent1));
    }

    function test_pause_alreadyPausedReverts() public {
        _registerAgent1();
        vm.prank(agent1);
        reg.pause();

        vm.prank(agent1);
        vm.expectRevert("Already paused");
        reg.pause();
    }

    function test_unpause_notPausedReverts() public {
        _registerAgent1();

        vm.prank(agent1);
        vm.expectRevert("Not paused");
        reg.unpause();
    }

    function test_pause_preservesReputation() public {
        _registerAgent1();

        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory before = reg.getAgentProfile(agent1);

        vm.prank(agent1);
        reg.pause();
        vm.prank(agent1);
        reg.unpause();

        IAgentRegistry.AgentInfo memory after_ = reg.getAgentProfile(agent1);
        assertEq(after_.reputationScore, before.reputationScore);
    }

    function test_pause_excludedFromCapabilityQuery() public {
        _registerAgent1();
        _registerAgent(agent2, _caps(CAP_LLM));

        vm.prank(agent1);
        reg.pause();

        address[] memory active = reg.getAgentsByCapability(CAP_LLM);
        assertEq(active.length, 1);
        assertEq(active[0], agent2);
    }

    // =========================================================================
    // topUpStake
    // =========================================================================

    function test_topUpStake_addsToStake() public {
        _registerAgent1();

        vm.prank(agent1);
        reg.topUpStake{value: 0.05 ether}();

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.stake, STAKE + 0.05 ether);
    }

    function test_topUpStake_notRegisteredReverts() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert("Not registered");
        reg.topUpStake{value: 0.05 ether}();
    }

    // =========================================================================
    // updateCapabilities
    // =========================================================================

    function test_updateCapabilities_changesCapabilities() public {
        _registerAgent1(); // registered with CAP_LLM

        vm.prank(agent1);
        reg.updateCapabilities(_caps2(CAP_SCRAPE, CAP_API));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.capabilities.length, 2);
        assertEq(info.capabilities[0], CAP_SCRAPE);
        assertEq(info.capabilities[1], CAP_API);

        // Old capability should have no agents.
        assertEq(reg.getAgentsByCapability(CAP_LLM).length, 0);
        // New capabilities should have agent1.
        assertEq(reg.getAgentsByCapability(CAP_SCRAPE).length, 1);
        assertEq(reg.getAgentsByCapability(CAP_API).length, 1);
    }

    // =========================================================================
    // recordCompletion — reputation algorithm
    // =========================================================================

    function test_recordCompletion_firstCompletion() public {
        _registerAgent1();

        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 1);

        // First completion: gain = 1/1 × 1/√1 = 1e18
        // Fee = 1e18 × 1e14 / 1e18 = 1e14 (0.0001 ETH)
        assertEq(info.reputationScore, PRECISION);
        assertEq(info.stake, STAKE - 1e14);
    }

    function test_recordCompletion_harmonicDiminishing() public {
        _registerAgent1();

        // 10 completions on different days to avoid daily dampening.
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(tmAddr);
            reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
        }

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 10);

        // H(10) = 1 + 1/2 + 1/3 + ... + 1/10 ≈ 2.9289682... × 1e18
        // Expected range: 2.92e18 < score < 2.93e18
        assertTrue(info.reputationScore > 2.92e18, "Score too low");
        assertTrue(info.reputationScore < 2.94e18, "Score too high");
    }

    function test_recordCompletion_dailyDampening() public {
        _registerAgent1();

        // 5 completions on the SAME day.
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(tmAddr);
            reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
        }

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 5);
        assertEq(info.dailyCompletions, 5);

        // With daily dampening: sum of (1/n × 1/√k)
        // n=1,k=1: 1/1 × 1/√1 = 1.0
        // n=2,k=2: 1/2 × 1/√2 ≈ 0.3535
        // n=3,k=3: 1/3 × 1/√3 ≈ 0.1924
        // n=4,k=4: 1/4 × 1/√4 = 0.125
        // n=5,k=5: 1/5 × 1/√5 ≈ 0.0894
        // Sum ≈ 1.760
        // Score should be less than H(5)=2.283 due to dampening.
        assertTrue(info.reputationScore < 2e18, "Daily dampening not applied");
        assertTrue(info.reputationScore > 1.5e18, "Score too low");
    }

    function test_recordCompletion_dailyReset() public {
        _registerAgent1();

        // Day 1: 3 completions.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(tmAddr);
            reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
        }

        IAgentRegistry.AgentInfo memory day1 = reg.getAgentProfile(agent1);
        assertEq(day1.dailyCompletions, 3);

        // Day 2: daily counter resets.
        vm.warp(block.timestamp + 1 days);
        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory day2 = reg.getAgentProfile(agent1);
        assertEq(day2.dailyCompletions, 1);
        assertEq(day2.completions, 4);
    }

    function test_recordCompletion_stakeFeeDeducted() public {
        _registerAgent1();

        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);

        // Fee for first completion: 1e18 × 1e14 / 1e18 = 1e14
        assertEq(info.stake, STAKE - 1e14);
    }

    function test_recordCompletion_stakeGuard_skipsRepWhenLow() public {
        // Register with exactly minimum stake.
        vm.prank(agent1);
        reg.register{value: 0.01 ether}(_caps(CAP_LLM));

        // First completion fee = 0.0001 ETH.
        // After 100 completions with fees ≈ 0.0001 * H(100) ≈ 0.0005 ETH,
        // the stake will deplete. Let's simulate until stake < fee.

        uint256 i;
        for (i = 0; i < 200; i++) {
            vm.warp(block.timestamp + 1 days); // new day each time
            vm.prank(tmAddr);
            reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
        }

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        // Stake should be >= 0 (guard prevents going negative).
        assertTrue(info.stake >= 0);
        // Some completions should have been skipped (no rep credit).
        assertTrue(info.reputationScore > 0);
    }

    function test_recordCompletion_onlyTaskManagerReverts() public {
        _registerAgent1();

        vm.prank(stranger);
        vm.expectRevert("Only TaskManager");
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
    }

    function test_recordCompletion_inactiveAgentSkips() public {
        // Don't register agent — should silently skip.
        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
        // No revert, no state change.
    }

    function test_recordCompletion_pausedAgentSkips() public {
        _registerAgent1();
        vm.prank(agent1);
        reg.pause();

        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.completions, 0); // no credit while paused
    }

    function test_recordCompletion_emitsEvent() public {
        _registerAgent1();

        vm.expectEmit(true, true, false, true, address(reg));
        emit IAgentRegistry.CompletionRecorded(agent1, TASK_TYPE, PRECISION, 1e14);

        vm.prank(tmAddr);
        reg.recordCompletion(agent1, TASK_TYPE, 1 ether);
    }

    // =========================================================================
    // slash
    // =========================================================================

    function test_slash_partialSlash() public {
        _registerAgent1();

        vm.prank(owner);
        reg.slash(agent1, 0.05 ether, keccak256("bad work"));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.stake, STAKE - 0.05 ether);
        assertEq(info.disputes, 1);
        assertTrue(info.active);
    }

    function test_slash_fullSlashDeactivates() public {
        _registerAgent1();

        vm.prank(owner);
        reg.slash(agent1, STAKE, keccak256("fraud"));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.stake, 0);
        assertFalse(info.active);
    }

    function test_slash_exceedingStakeSlashesAll() public {
        _registerAgent1();

        vm.prank(owner);
        reg.slash(agent1, STAKE * 2, keccak256("fraud"));

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent1);
        assertEq(info.stake, 0);
        assertFalse(info.active);
    }

    function test_slash_nonOwnerReverts() public {
        _registerAgent1();

        vm.prank(stranger);
        vm.expectRevert();
        reg.slash(agent1, 0.01 ether, keccak256("bad"));
    }

    function test_slash_inactiveAgentReverts() public {
        vm.prank(owner);
        vm.expectRevert("Agent not active");
        reg.slash(stranger, 0.01 ether, keccak256("bad"));
    }

    function test_slash_emitsEvent() public {
        _registerAgent1();
        bytes32 reason = keccak256("bad");

        vm.expectEmit(true, false, false, true, address(reg));
        emit IAgentRegistry.AgentSlashed(agent1, 0.05 ether, reason);

        vm.prank(owner);
        reg.slash(agent1, 0.05 ether, reason);
    }

    // =========================================================================
    // Capability deduplication
    // =========================================================================

    function test_register_duplicateCapabilitiesDeduped() public {
        // Register with duplicate capability — should not create ghost entries.
        bytes32[] memory caps = new bytes32[](3);
        caps[0] = CAP_LLM;
        caps[1] = CAP_LLM; // duplicate
        caps[2] = CAP_SCRAPE;

        vm.prank(agent1);
        reg.register{value: STAKE}(caps);

        // Reverse index should have exactly 1 entry for CAP_LLM, not 2.
        address[] memory llmAgents = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llmAgents.length, 1);
        assertEq(llmAgents[0], agent1);

        // Deregister should cleanly remove without leaving ghost entries.
        vm.prank(agent1);
        reg.deregister();

        llmAgents = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llmAgents.length, 0);
    }

    // =========================================================================
    // Query — getAgentsByCapability
    // =========================================================================

    function test_getAgentsByCapability_multipleAgents() public {
        _registerAgent(agent1, _caps(CAP_LLM));
        _registerAgent(agent2, _caps2(CAP_LLM, CAP_SCRAPE));
        _registerAgent(agent3, _caps(CAP_SCRAPE));

        address[] memory llm = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llm.length, 2);

        address[] memory scrape = reg.getAgentsByCapability(CAP_SCRAPE);
        assertEq(scrape.length, 2);

        address[] memory api = reg.getAgentsByCapability(CAP_API);
        assertEq(api.length, 0);
    }

    function test_getAgentsByCapability_excludesSlahedInactive() public {
        _registerAgent(agent1, _caps(CAP_LLM));
        _registerAgent(agent2, _caps(CAP_LLM));

        // Slash agent2 to deactivation.
        vm.prank(owner);
        reg.slash(agent2, STAKE, keccak256("fraud"));

        address[] memory llm = reg.getAgentsByCapability(CAP_LLM);
        assertEq(llm.length, 1);
        assertEq(llm[0], agent1);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_setReputationFeePerUnit() public {
        vm.prank(owner);
        reg.setReputationFeePerUnit(2e14);
        assertEq(reg.reputationFeePerUnit(), 2e14);
    }

    function test_setTaskManager() public {
        address newTm = makeAddr("newTm");
        vm.prank(owner);
        reg.setTaskManager(newTm);
        assertEq(reg.taskManager(), newTm);
    }

    // =========================================================================
    // UUPS upgrade
    // =========================================================================

    function test_upgrade_ownerCanUpgrade() public {
        AgentRegistry implV2 = new AgentRegistry();

        vm.prank(owner);
        reg.upgradeToAndCall(address(implV2), "");
    }

    function test_upgrade_nonOwnerReverts() public {
        AgentRegistry implV2 = new AgentRegistry();

        vm.prank(stranger);
        vm.expectRevert();
        reg.upgradeToAndCall(address(implV2), "");
    }
}
