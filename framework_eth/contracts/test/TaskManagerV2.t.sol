// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@envoy-v1/TaskManager.sol";
import "../src/TaskManagerV2.sol";
import "../src/AgentRegistry.sol";
import "../src/interfaces/IAgentRegistry.sol";
import "./mocks/MockERC20.sol";

/// @dev Mock registry that always reverts.
contract RevertingRegistry {
    fallback() external payable {
        revert("always reverts");
    }
}

contract TaskManagerV2Test is Test {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    TaskManagerV2 internal tmImpl;
    TaskManagerV2 internal tm;
    ERC1967Proxy internal tmProxy;

    AgentRegistry internal regImpl;
    AgentRegistry internal reg;
    ERC1967Proxy internal regProxy;

    MockERC20 internal token;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant TASK_HASH = keccak256("task");
    bytes32 internal constant TASK_TYPE = keccak256("type");
    bytes32 internal constant RESULT_HASH = keccak256("result");
    string internal constant TASK_URI = "ipfs://task";
    string internal constant RESULT_URI = "ipfs://result";
    uint256 internal constant ETH_PAYMENT = 1 ether;
    uint256 internal constant TOKEN_AMOUNT = 1_000e6;
    uint256 internal constant AGENT_STAKE = 0.1 ether;

    bytes32 internal constant CAP_LLM = keccak256("llm");

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        // Deploy TaskManagerV2 behind proxy.
        tmImpl = new TaskManagerV2();
        bytes memory tmInit = abi.encodeCall(TaskManagerV2.initialize, (owner));
        tmProxy = new ERC1967Proxy(address(tmImpl), tmInit);
        tm = TaskManagerV2(payable(address(tmProxy)));

        // Deploy AgentRegistry behind proxy.
        regImpl = new AgentRegistry();
        bytes memory regInit = abi.encodeCall(
            AgentRegistry.initialize,
            (owner, address(tmProxy))
        );
        regProxy = new ERC1967Proxy(address(regImpl), regInit);
        reg = AgentRegistry(payable(address(regProxy)));

        // Link TaskManager → Registry.
        vm.prank(owner);
        tm.initializeV2(address(regProxy));

        // Deploy token and fund accounts.
        token = new MockERC20("Mock USDC", "MUSDC");
        token.mint(creator, 100_000e6);

        vm.deal(creator, 100 ether);
        vm.deal(agent, 10 ether);
        vm.deal(agent2, 10 ether);

        // Register agent in the registry.
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent);
        reg.register{value: AGENT_STAKE}(caps);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createEthTask() internal returns (uint256) {
        vm.prank(creator);
        return tm.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(0), 0
        );
    }

    function _createOpenEthTask() internal returns (uint256) {
        vm.prank(creator);
        return tm.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, address(0), address(0), 0
        );
    }

    function _submitResult(uint256 taskId) internal {
        vm.prank(agent);
        tm.submitResult(taskId, RESULT_HASH, RESULT_URI);
    }

    // =========================================================================
    // V1 backward compatibility
    // =========================================================================

    function test_v1compat_createTaskWithAgent() public {
        uint256 taskId = _createEthTask();
        assertEq(taskId, 1);

        ITaskManager.TaskInfo memory info = tm.getTask(taskId);
        assertEq(info.agent, agent);
        assertEq(info.payment, ETH_PAYMENT);
        assertEq(uint8(info.status), uint8(ITaskManager.TaskStatus.Created));
    }

    function test_v1compat_submitAndSettle() public {
        uint256 taskId = _createEthTask();
        _submitResult(taskId);
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);

        uint256 agentBefore = agent.balance;
        tm.settle(taskId);

        assertEq(agent.balance, agentBefore + ETH_PAYMENT);
        ITaskManager.TaskInfo memory info = tm.getTask(taskId);
        assertEq(uint8(info.status), uint8(ITaskManager.TaskStatus.Settled));
    }

    function test_v1compat_dispute() public {
        uint256 taskId = _createEthTask();
        _submitResult(taskId);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        tm.dispute(taskId);

        assertEq(creator.balance, creatorBefore + ETH_PAYMENT);
    }

    function test_v1compat_tokenPayment() public {
        vm.startPrank(creator);
        token.approve(address(tm), TOKEN_AMOUNT);
        uint256 taskId = tm.createTask(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(token), TOKEN_AMOUNT
        );
        vm.stopPrank();

        _submitResult(taskId);
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);

        uint256 agentBefore = token.balanceOf(agent);
        tm.settle(taskId);
        assertEq(token.balanceOf(agent), agentBefore + TOKEN_AMOUNT);
    }

    // =========================================================================
    // Open tasks — agent = address(0)
    // =========================================================================

    function test_openTask_createSucceeds() public {
        uint256 taskId = _createOpenEthTask();

        ITaskManager.TaskInfo memory info = tm.getTask(taskId);
        assertEq(info.agent, address(0));
        assertEq(info.payment, ETH_PAYMENT);
    }

    function test_openTask_acceptSetsAgent() public {
        uint256 taskId = _createOpenEthTask();

        vm.prank(agent);
        tm.acceptTask(taskId);

        ITaskManager.TaskInfo memory info = tm.getTask(taskId);
        assertEq(info.agent, agent);
    }

    function test_openTask_acceptEmitsEvent() public {
        uint256 taskId = _createOpenEthTask();

        vm.expectEmit(true, true, false, false, address(tm));
        emit TaskManagerV2.TaskAccepted(taskId, agent);

        vm.prank(agent);
        tm.acceptTask(taskId);
    }

    function test_openTask_acceptByUnregisteredReverts() public {
        uint256 taskId = _createOpenEthTask();

        vm.prank(stranger);
        vm.expectRevert("Not a registered agent");
        tm.acceptTask(taskId);
    }

    function test_openTask_acceptAlreadyAcceptedReverts() public {
        uint256 taskId = _createOpenEthTask();

        vm.prank(agent);
        tm.acceptTask(taskId);

        // Register agent2 and try to accept.
        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent2);
        reg.register{value: AGENT_STAKE}(caps);

        vm.prank(agent2);
        vm.expectRevert("Already accepted");
        tm.acceptTask(taskId);
    }

    function test_openTask_submitBeforeAcceptReverts() public {
        uint256 taskId = _createOpenEthTask();

        // agent is the registered agent, but task.agent is still 0x0.
        vm.prank(agent);
        vm.expectRevert("Unauthorized");
        tm.submitResult(taskId, RESULT_HASH, RESULT_URI);
    }

    function test_openTask_fullLifecycle() public {
        uint256 taskId = _createOpenEthTask();

        // Accept.
        vm.prank(agent);
        tm.acceptTask(taskId);

        // Submit.
        _submitResult(taskId);

        // Settle.
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);
        uint256 agentBefore = agent.balance;
        tm.settle(taskId);

        assertEq(agent.balance, agentBefore + ETH_PAYMENT);
    }

    function test_openTask_acceptDirectAssignedReverts() public {
        // Task with specific agent — acceptTask should fail.
        uint256 taskId = _createEthTask(); // agent already assigned

        bytes32[] memory caps = new bytes32[](1);
        caps[0] = CAP_LLM;
        vm.prank(agent2);
        reg.register{value: AGENT_STAKE}(caps);

        vm.prank(agent2);
        vm.expectRevert("Already accepted");
        tm.acceptTask(taskId);
    }

    // =========================================================================
    // settle — registry integration
    // =========================================================================

    function test_settle_recordsCompletion() public {
        uint256 taskId = _createEthTask();
        _submitResult(taskId);
        vm.warp(block.timestamp + tm.getTimeLockDuration() + 1);

        tm.settle(taskId);

        IAgentRegistry.AgentInfo memory info = reg.getAgentProfile(agent);
        assertEq(info.completions, 1);
        assertTrue(info.reputationScore > 0);
    }

    function test_settle_succeedsWhenRegistryReverts() public {
        // Deploy a fresh TaskManager pointing at a reverting "registry".
        TaskManagerV2 tmImpl2 = new TaskManagerV2();
        bytes memory init = abi.encodeCall(TaskManagerV2.initialize, (owner));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(tmImpl2), init);
        TaskManagerV2 tm2 = TaskManagerV2(payable(address(proxy2)));

        // Point at a contract that always reverts.
        RevertingRegistry rr = new RevertingRegistry();
        vm.prank(owner);
        tm2.initializeV2(address(rr));

        vm.prank(creator);
        uint256 taskId = tm2.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(0), 0
        );

        vm.prank(agent);
        tm2.submitResult(taskId, RESULT_HASH, RESULT_URI);

        vm.warp(block.timestamp + tm2.getTimeLockDuration() + 1);

        uint256 agentBefore = agent.balance;

        // Should not revert — payment succeeds, reputation skipped.
        tm2.settle(taskId);

        assertEq(agent.balance, agentBefore + ETH_PAYMENT);
    }

    function test_settle_succeedsWhenNoRegistry() public {
        // Deploy a fresh TaskManager without registry.
        TaskManagerV2 tmImpl2 = new TaskManagerV2();
        bytes memory init = abi.encodeCall(TaskManagerV2.initialize, (owner));
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(tmImpl2), init);
        TaskManagerV2 tm2 = TaskManagerV2(payable(address(proxy2)));
        // Do NOT call initializeV2 — registry is address(0).

        vm.prank(creator);
        uint256 taskId = tm2.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(0), 0
        );

        vm.prank(agent);
        tm2.submitResult(taskId, RESULT_HASH, RESULT_URI);

        vm.warp(block.timestamp + tm2.getTimeLockDuration() + 1);

        uint256 agentBefore = agent.balance;
        tm2.settle(taskId);
        assertEq(agent.balance, agentBefore + ETH_PAYMENT);
    }

    // =========================================================================
    // UUPS upgrade from V1 to V2
    // =========================================================================

    function test_upgrade_v1ToV2_statePreserved() public {
        // Deploy V1 behind a proxy.
        TaskManager v1Impl = new TaskManager();
        bytes memory v1Init = abi.encodeCall(TaskManager.initialize, (owner));
        ERC1967Proxy v1Proxy = new ERC1967Proxy(address(v1Impl), v1Init);
        TaskManager v1 = TaskManager(payable(address(v1Proxy)));

        // Create a V1 task.
        vm.prank(creator);
        uint256 taskId = v1.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(0), 0
        );

        // Upgrade to V2.
        TaskManagerV2 v2Impl = new TaskManagerV2();
        vm.prank(owner);
        v1.upgradeToAndCall(address(v2Impl), "");

        // Cast proxy to V2.
        TaskManagerV2 v2 = TaskManagerV2(payable(address(v1Proxy)));

        // V1 state should be preserved.
        ITaskManager.TaskInfo memory info = v2.getTask(taskId);
        assertEq(info.creator, creator);
        assertEq(info.agent, agent);
        assertEq(info.payment, ETH_PAYMENT);
        assertEq(uint8(info.status), uint8(ITaskManager.TaskStatus.Created));

        // V2 function should be available.
        assertEq(v2.registry(), address(0)); // not yet initialized

        // Initialize V2.
        vm.prank(owner);
        v2.initializeV2(address(regProxy));
        assertEq(v2.registry(), address(regProxy));
    }

    function test_upgrade_v1ToV2_v1TaskCanStillSettle() public {
        // Deploy V1 behind a proxy.
        TaskManager v1Impl = new TaskManager();
        bytes memory v1Init = abi.encodeCall(TaskManager.initialize, (owner));
        ERC1967Proxy v1Proxy = new ERC1967Proxy(address(v1Impl), v1Init);
        TaskManager v1 = TaskManager(payable(address(v1Proxy)));

        // Create and submit a V1 task.
        vm.prank(creator);
        uint256 taskId = v1.createTask{value: ETH_PAYMENT}(
            TASK_HASH, TASK_URI, TASK_TYPE, agent, address(0), 0
        );
        vm.prank(agent);
        v1.submitResult(taskId, RESULT_HASH, RESULT_URI);

        // Upgrade to V2.
        TaskManagerV2 v2Impl = new TaskManagerV2();
        vm.prank(owner);
        v1.upgradeToAndCall(address(v2Impl), "");

        TaskManagerV2 v2 = TaskManagerV2(payable(address(v1Proxy)));

        // Settle the V1 task using V2 code.
        vm.warp(block.timestamp + v2.getTimeLockDuration() + 1);

        uint256 agentBefore = agent.balance;
        v2.settle(taskId);

        assertEq(agent.balance, agentBefore + ETH_PAYMENT);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function test_registry_returnsAddress() public view {
        assertEq(tm.registry(), address(regProxy));
    }

    function test_getTimeLockBlocks_returnsConstant() public view {
        assertEq(tm.getTimeLockBlocks(), 3600);
    }

    function test_getTimeLockDuration_returnsConstant() public view {
        assertEq(tm.getTimeLockDuration(), 3600);
    }
}
