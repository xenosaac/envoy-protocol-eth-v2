# TODOS — The Envoy Protocol for Ethereum V2.0

## Core — Agent Registry

### AgentRegistry contract
- **What:** AgentRegistry.sol with register/deregister/query/slash functions, companion to V1 TaskManager
- **Why:** Core V2 feature — enables agent discovery by capability and on-chain reputation
- **Effort:** M (human: ~3 weeks / CC: ~2 days)
- **Depends on:** V1 TaskManager deployed to Sepolia
- **Added:** 2026-03-20

### Competitive task acceptance
- **What:** Extend TaskManager to support `agent=address(0)` tasks where any registered agent can call `acceptTask()` (first wins)
- **Why:** Marketplace dynamics require open task acceptance, not just direct assignment
- **Effort:** S (human: ~1 week / CC: ~1 day)
- **Depends on:** AgentRegistry contract
- **Added:** 2026-03-20

### Reputation tracking
- **What:** On-chain tracking of completions, disputes, and response times per agent in the registry
- **Why:** Task creators need signal to choose between agents — reputation is that signal
- **Effort:** S (human: ~3 days / CC: ~4 hours)
- **Depends on:** AgentRegistry contract
- **Added:** 2026-03-20

### Staking and slashing
- **What:** Agents stake ETH/tokens to register. Slashed on failed tasks or lost disputes. Stake returned on deregister.
- **Why:** Skin in the game prevents spam registrations and incentivizes good behavior
- **Effort:** S (human: ~3 days / CC: ~4 hours)
- **Depends on:** AgentRegistry contract
- **Added:** 2026-03-20

## SDK

### SDK registry extensions
- **What:** Extend EthBridgeSDK with `registerAgent()`, `queryAgents()`, `acceptTask()` methods
- **Why:** Agents need programmatic access to registry functions, not just raw contract calls
- **Effort:** M (human: ~2 weeks / CC: ~1 day)
- **Depends on:** AgentRegistry contract finalized
- **Added:** 2026-03-20

## Infrastructure

### TimelockController governance
- **What:** Add OpenZeppelin TimelockController to UUPS proxy — 48h delay on upgrades for mainnet/L2
- **Why:** Real funds require trust-minimized governance. Users must verify upgrades before they take effect.
- **Effort:** S (human: ~2 hours / CC: ~15 min)
- **Depends on:** V2 contract finalized
- **Added:** 2026-03-20

### L2 deployment (Arbitrum/Base)
- **What:** Deploy V2 contracts to Arbitrum or Base testnet, then mainnet. Multi-chain deployment scripts.
- **Why:** Mainnet gas costs (~$7-8 per lifecycle) are not viable for production. L2 brings this to cents.
- **Effort:** S (human: ~1 week / CC: ~2 hours)
- **Depends on:** V2 contracts finalized and tested
- **Added:** 2026-03-20

## Deferred to V3.0

- Full marketplace with competitive bidding and fee extraction
- Dispute governance mechanisms (V2 dispute is one-sided creator refund; V3 needs impartial arbitration to prevent dispute-based stake drain attacks)
- Decentralized dispute arbitration (staked arbitrators)
- EIP protocol standardization
- Own chain / native task primitives
- Token economics / governance token
- Cross-chain agent identity
- AI verification (ZK proofs, TEE attestations)
