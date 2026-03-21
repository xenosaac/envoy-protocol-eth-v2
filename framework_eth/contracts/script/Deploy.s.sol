// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AgentRegistry.sol";
import "../src/TaskManagerV2.sol";

/// @notice Deploys AgentRegistry + TaskManagerV2 behind UUPS proxies.
///
/// Usage:
///   DEPLOYER_PRIVATE_KEY=0x... forge script script/Deploy.s.sol \
///       --rpc-url <RPC> --broadcast
///
contract DeployScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy TaskManagerV2 behind proxy.
        TaskManagerV2 tmImpl = new TaskManagerV2();
        bytes memory tmInit = abi.encodeCall(TaskManagerV2.initialize, (deployer));
        ERC1967Proxy tmProxy = new ERC1967Proxy(address(tmImpl), tmInit);

        // 2. Deploy AgentRegistry behind proxy (needs TaskManager address).
        AgentRegistry regImpl = new AgentRegistry();
        bytes memory regInit = abi.encodeCall(
            AgentRegistry.initialize,
            (deployer, address(tmProxy))
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);

        // 3. Point TaskManager at Registry.
        TaskManagerV2(payable(address(tmProxy))).initializeV2(address(regProxy));

        vm.stopBroadcast();

        console.log("TaskManagerV2 Implementation:", address(tmImpl));
        console.log("TaskManagerV2 Proxy:", address(tmProxy));
        console.log("AgentRegistry Implementation:", address(regImpl));
        console.log("AgentRegistry Proxy:", address(regProxy));
        console.log("Owner:", deployer);
    }
}
