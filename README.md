# The Envoy Protocol for Ethereum V2.0

> Agent Registry — from single-operator bridge to open agent discovery and reputation.

## Vision

V1.0 proved the core loop: contract creates task, agent executes, payment settles. V2.0 adds the **Agent Registry** — the trust layer that lets agents discover tasks and task creators discover verified agents.

Agentic wallets (Coinbase AgentKit, OKX) solved the payment plumbing — agents can hold funds and transact. But wallets don't verify work. V2.0 is the missing piece: **a lightweight on-chain registry where agents stake reputation, declare capabilities, and build verifiable track records.**

### Why Registry First

The full marketplace vision (competitive bidding, arbitration, governance) is V3.0. V2.0 focuses on the smallest layer that unlocks marketplace dynamics:

- Agents can self-register with stake and capability declarations
- Task creators can query the registry to find agents by capability
- Completion history is tracked on-chain, building reputation
- Bad actors can be slashed

This proves demand before investing in the full marketplace infrastructure.

## V2.0 Scope

### In Scope

- **AgentRegistry.sol** — On-chain agent registration with staking, capability tags (bytes32 taskType), and completion tracking
- **Competitive task acceptance** — Replace V1's direct agent assignment with open acceptance. First qualified registered agent locks the task.
- **Reputation tracking** — Harmonic series scoring computed on-chain: `gain = 1/n × 1/√k` where n = total completions, k = daily completions. Overall growth ≈ ln(n) (Euler). Daily spam cap = ζ(3/2) ≈ 2.612 (Riemann). No hard cap.
- **Staking / slashing** — Agents stake to register. Reputation minting fee: `fee = rep_gain × C` where C = 0.0001 ETH (tunable), deducted from stake per completion. Same harmonic curve governs both reputation and cost. Slashed on failed tasks or disputes. Reputation resets on deregister (use `pause()` for temporary breaks).
- **SDK extensions** — Extend EthBridgeSDK to query registry, auto-register agents, filter tasks by capability
- **L2 deployment** — Deploy to Arbitrum or Base for production-viable gas costs
- **TimelockController** — 48h governance delay for contract upgrades on mainnet/L2

### Deferred to V3.0

- Dispute governance mechanisms (V2 dispute is one-sided creator refund; V3 needs impartial arbitration to prevent dispute-based stake drain attacks)
- Full marketplace with competitive bidding and fee extraction
- Decentralized dispute arbitration (staked arbitrators, evidence verification)
- EIP protocol standardization
- Own chain / native task primitives
- Token economics / governance token
- Cross-chain agent identity
- AI verification (ZK proofs, TEE attestations)

## Architecture

### AgentRegistry Contract

```
AgentRegistry.sol
├── register(bytes32[] capabilities) payable  — stake via msg.value
├── deregister() → returns remaining stake
├── pause() / unpause()                      — temporary opt-out
├── topUpStake() payable                     — add stake without re-registering
├── updateCapabilities(bytes32[] capabilities)
├── recordCompletion(agent, taskType, payment) — called by TaskManager only
├── slash(agent, amount, reason)               — owner only
├── getAgentsByCapability(bytes32 taskType) → address[]  — active+unpaused only
├── getAgentProfile(address agent) → AgentInfo
├── isRegistered(address agent) → bool
└── isActive(address agent) → bool            — registered AND not paused

AgentInfo {
    address agent
    bytes32[] capabilities
    uint256 stake
    uint256 reputationScore   // 1e18 precision, harmonic growth
    uint256 completions
    uint256 dailyCompletions
    uint256 disputes
    uint256 registeredAt
    bool active
    bool paused
}
```

### Integration with TaskManagerV2

TaskManagerV2 is a **UUPS upgrade** of V1 TaskManager — same proxy address, new logic. The registry integrates directly: `settle()` calls `recordCompletion()` automatically (try/catch, never blocks payment).

```
Task Creator                    Agent
    │                            │
    │ 1. Query registry          │ 0. register{value: stake}(capabilities)
    │    by capability           │
    │◄───────────────────────────│
    │                            │
    │ 2. createTask(agent, ...)  │
    │    on TaskManagerV2        │
    │                            │
    │ 3. TaskCreated event ──────►│
    │                            │ 4. Execute off-chain
    │                            │ 5. submitResult()
    │                            │
    │ 6. settle()                │ Payment released
    │    └─ recordCompletion() ──►│ Reputation updated (auto, try/catch)
```

### Competitive Acceptance

For tasks that don't target a specific agent (`agent=address(0)`), V2 supports open acceptance — first registered agent to call `acceptTask()` wins:

```
Task Creator                    Agent A         Agent B
    │                            │               │
    │ createTask(agent=0x0, ...) │               │
    │ (open task)                │               │
    │                            │               │
    │ TaskCreated ───────────────►│──────────────►│
    │                            │               │
    │                            │ acceptTask()  │
    │                            │ (first wins)  │ acceptTask() → reverts
    │                            │               │
    │                            │ submitResult()│
    │                            │               │
    │ settle()                   │ Payment + rep │
```

## V1.0 → V2.0 Upgrade Path

V1 uses UUPS proxy — same contract address survives the upgrade.

| Feature | V1.0 | V2.0 |
|---------|------|------|
| Agent assignment | Per-task (creator picks) | Registry-based discovery + open acceptance |
| Task discovery | Direct assignment | Agent registry + taskType filtering |
| Payment | ETH + ERC-20 | Same (stablecoin focus in practice) |
| Reputation | None | Harmonic on-chain scoring (1/n × 1/√k) |
| Dispute | Creator-only refund | Same (governance arbitration deferred to V3) |
| Time-lock | Block-based (300 blocks) | Timestamp-based (3600s) for L2 compatibility |
| Governance | Owner-controlled upgrades | TimelockController (48h delay, TODO) |

## L2 Deployment

V1 gas analysis: ~250,000 gas per task lifecycle (~$7-8 on mainnet at 15 gwei). L2 reduces this to cents:

| Chain | Cost | Notes |
|-------|------|-------|
| Ethereum Mainnet | ~$7-8 | Testnet only for V2 |
| Arbitrum | ~$0.01-0.05 | Primary target — EVM-equivalent |
| Base | ~$0.01-0.05 | Coinbase ecosystem synergy with AgentKit |

**Plan:** Deploy to Sepolia first (validation), then Arbitrum or Base for production.

## Current Status

**Contracts: COMPLETE** — 68 tests passing (43 AgentRegistry + 20 TaskManagerV2 + 5 Integration)

```
framework_eth/contracts/
├── src/
│   ├── AgentRegistry.sol        — Registration, reputation, staking, capability index
│   ├── TaskManagerV2.sol        — UUPS upgrade of V1, open acceptance, registry integration
│   └── interfaces/
│       └── IAgentRegistry.sol   — Public interface
├── test/
│   ├── AgentRegistry.t.sol      — 43 tests (registration, reputation, slashing, capabilities)
│   ├── TaskManagerV2.t.sol      — 20 tests (V1 compat, open tasks, registry, UUPS upgrade)
│   └── Integration.t.sol        — 5 tests (full lifecycle, competitive acceptance, diminishing returns)
└── script/
    └── Deploy.s.sol             — Deployment script (proxy + initialization)
```

**SDK: NOT YET STARTED** — registry extensions pending contract finalization.

## Success Criteria

- AgentRegistry deployed alongside V1 TaskManager on Sepolia
- 10+ agents registered with real capabilities
- Full lifecycle demonstrated: register → discover → accept → execute → settle → reputation update
- 3+ external projects integrating with the registry
- Gas costs validated on L2 (Arbitrum/Base testnet)

## License

MIT
