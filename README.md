# Aegis Reactive

**A cross-chain invariant guard that turns a solvency breach on Base Sepolia into a sub-second circuit break on Unichain Sepolia — without a keeper, bot, or off-chain oracle.**

Aegis Reactive is a 3-contract Reactive Network system:

| Chain | Contract | Role |
| --- | --- | --- |
| Base Sepolia (84532) | `OriginVault` | Holds native ETH, tracks user claims, emits `InvariantBreached` when coverage drops below a threshold. |
| Reactive Lasna (5318007) | `InvariantGuardReactive` | Subscribes to the vault's breach event, re-validates the numbers in Solidity, dedupes, rate-limits, and requests a callback. |
| Unichain Sepolia (1301) | `CircuitBreakerCallback` | Authenticates the callback, pauses destination-side credit/redemption paths, freezes the LTV parameter, and emits an incident record. |

The result is a deterministic **breach → pause** loop with on-chain authentication at every hop and no privileged off-chain actor required at runtime.

---

## Why this exists

Cross-chain lending and liquidity protocols usually discover solvency problems after the fact. A keeper-based monitor adds latency, operational cost, and a centralized trust point. Reactive Network lets a contract on the origin chain react to events from another chain and request a destination-chain transaction as part of the network's own execution flow.

Aegis Reactive demonstrates the smallest useful version of that pattern:

1. **Observe** — the vault emits a single canonical event when coverage crosses the threshold.
2. **Verify** — the reactive guard never trusts the event's self-reported health; it recomputes `reserves / liabilities` from the raw values and applies its own threshold.
3. **Act** — the guard requests an authenticated callback on the destination chain.
4. **Contain** — the breaker pauses destination-side operations and freezes parameters until a human reviews the incident.

---

## Architecture

```mermaid
flowchart LR
    subgraph Base["Base Sepolia (84532)"]
        V["OriginVault<br/>native ETH"]
        E["InvariantBreached<br/>(reserves, liabilities,<br/>healthBps, thresholdBps)"]
        V -- "emit on transition" --> E
    end

    subgraph Reactive["Reactive Lasna (5318007)"]
        G["InvariantGuardReactive"]
        S["Reactive System Contract<br/>0x8888...8888"]
        G -- "subscribe(chainId, vault, topic0)" --> S
        S -- "react(LogRecord)" --> G
    end

    subgraph Uni["Unichain Sepolia (1301)"]
        P["Callback Proxy<br/>0x775c...66C1"]
        B["CircuitBreakerCallback"]
        M["Adapters / Lending Market"]
        B -- "requireOperational()" --> M
    end

    E -. "log record" .-> S
    G -- "requestCallbackV_1_0" --> S
    S -. "authenticated callback" .-> P
    P -- "pause(...) with injected sender" .-> B
```

### Sequence

```text
User / operator                OriginVault            Reactive Lasna              Unichain
     |                             |                        |                         |
     |-- deposit / borrow -------->|                        |                         |
     |                             |-- InvariantBreached -->|                         |
     |                             |                        |-- recompute health      |
     |                             |                        |-- dedupe + cooldown     |
     |                             |                        |-- requestCallbackV_1_0  |
     |                             |                        |         |               |
     |                             |                        |         '-- proxy ----> |-- pause()
     |                             |                        |                         |-- freeze LTV
     |                             |                        |                         |-- CircuitBreakerTriggered
     |                             |                        |                         |
     |                             |                        |                         |<-- human unpause()
```

---

## Contracts

### `src/OriginVault.sol`

A deliberately small native-ETH vault used as the monitored system.

- `deposit()` / `withdraw(amount)` — user claims and reserves move together.
- `borrow(amount)` — operator-only; moves reserves out and records `outstandingDebt`.
- `repay()` — adds reserves back; overpayment is refunded.
- `recordLoss(amount)` — **owner-only demo hook** that removes reserves and sends them to `lossRecipient`, simulating an exploit or bad debt.
- `forceCheck()` — re-emits the current breach so a missed callback can be retried.
- `healthBps()` — `reserves * 10_000 / totalDeposits`, capped by construction at 10_000 when there are no liabilities.

The vault **intentionally keeps operating after a breach**. The circuit breaker protects destination-side actions; halting origin withdrawals is a separate governance decision and out of scope for v1.

### `src/InvariantGuardReactive.sol`

The reactive contract on Lasna. It inherits `AbstractReactive` from the official `reactive-lib-omni` package and uses the Omni callback API (`SYSTEM.requestCallbackV_1_0`), not the deprecated `Callback` event/`vm` pattern.

Validation pipeline for every `react()` call:

1. Caller must be the system contract (`onlySystem`).
2. `chainId`, `contractAddress`, `topic0`, and `opCode` must match the trusted origin subscription.
3. Payload must be exactly four ABI words (`128` bytes).
4. Liabilities must be non-zero.
5. **Coverage is recomputed** from raw reserves/liabilities; the event's reported `healthBps` is ignored.
6. Replayed/stale origin blocks are rejected.
7. A deterministic `breachId` (chain, vault, block, tx, log index) prevents duplicate work.
8. A configurable cooldown prevents callback spam.
9. The callback payload reserves its first argument as `address(0)`; the Reactive callback proxy injects the guard's address there for authentication.

### `src/CircuitBreakerCallback.sol`

The destination breaker on Unichain Sepolia. It inherits `AbstractCallback`, which provides two independent checks:

- `onlyServiceProvider` — `msg.sender` must be the canonical callback proxy.
- `onlyCallbackSender(reactive_)` — the proxy-injected first argument must equal the configured guard address.

Behavior:

- Verifies the reported origin chain ID against an immutable value.
- Rejects invalid health values.
- Dedupes breach IDs; duplicates are suppressed without reverting, so network retries do not burn callback gas.
- Pauses idempotently; a different breach while already paused is recorded but ignored.
- Freezes `ltvBps` while paused.
- Exposes `requireOperational()` for adapters and `isOperational()` for off-chain consumers.
- Requires a human `unpause()` after review. Recovery on the origin chain does **not** auto-unpause the destination.

---

## Repository layout

```text
.
├── foundry.toml
├── remappings.txt
├── .env.example
├── src/
│   ├── OriginVault.sol
│   ├── InvariantGuardReactive.sol
│   ├── CircuitBreakerCallback.sol
│   └── interfaces/
│       ├── IOriginVault.sol
│       └── ICircuitBreaker.sol
├── test/
│   ├── OriginVault.t.sol
│   ├── InvariantGuardReactive.t.sol
│   ├── CircuitBreakerCallback.t.sol
│   ├── EndToEnd.t.sol
│   ├── VaultInvariant.t.sol
│   └── mocks/
│       ├── MockSystemContract.sol
│       ├── MockCallbackProxy.sol
│       ├── MockLendingMarket.sol
│       └── ReentrantBorrower.sol
├── script/
│   ├── DeployOrigin.s.sol
│   ├── DeployGuard.s.sol
│   ├── DeployBreaker.s.sol
│   ├── ConfigureGuard.s.sol
│   ├── SeedDemo.s.sol
│   └── SimulateBreach.s.sol
└── docs/
    └── ARCHITECTURE.md
```

---

## Quickstart

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Git
- RPC access to Base Sepolia, Reactive Lasna, and Unichain Sepolia
- A funded deployer key on each chain
- **lREACT** on Lasna for the guard's subscriptions/callbacks
- **ETH** on Unichain Sepolia for callback delivery

### Install and test

```bash
git submodule update --init --recursive
forge build
forge test
```

Run the full end-to-end loop with traces:

```bash
forge test --match-path test/EndToEnd.t.sol -vvv
```

Run only the stateful invariants:

```bash
forge test --match-path test/VaultInvariant.t.sol -vv
```

Coverage:

```bash
forge coverage
```

### Local cross-chain simulation

`test/EndToEnd.t.sol` co-locates all three chains in one Foundry EVM:

- `vm.chainId(...)` switches the active chain ID.
- `deployCodeTo` places `MockSystemContract` at the canonical `0x8888...8888`.
- `deployCodeTo` places `MockCallbackProxy` at the real Unichain callback proxy address.
- The mock proxy reproduces the production behavior of overwriting the first callback argument with the reactive sender address.
- Recorded vault logs are converted into `IReactive.LogRecord` values and delivered to `react()` exactly as the network would.

The suite asserts the full path: event → guard validation → callback request → proxy delivery → breaker pause → adapter freeze → human unpause, plus boundary and authentication cases.

---

## Deployment

Copy the environment template and fill in your values:

```bash
cp .env.example .env
# edit .env
set -a && source .env && set +a
```

### 1. Origin vault — Base Sepolia

```bash
forge script script/DeployOrigin.s.sol:DeployOrigin \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Save the printed address as `ORIGIN_VAULT`.

### 2. Reactive guard — Lasna

```bash
forge script script/DeployGuard.s.sol:DeployGuard \
  --rpc-url "$LASNA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Save the printed address as `GUARD_ADDRESS`. The guard is funded at construction with `GUARD_FUNDING_WEI` (lREACT); top it up later if needed.

> The guard subscribes in its constructor. If the constructor reverts, the origin vault address or chain IDs are wrong, or the account lacks lREACT.

### 3. Circuit breaker — Unichain Sepolia

```bash
forge script script/DeployBreaker.s.sol:DeployBreaker \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Save the printed address as `BREAKER_ADDRESS`. The breaker is funded with `CALLBACK_FUNDING_WEI` (ETH).

### 4. Wire the guard to the breaker — Lasna

This step resolves the circular dependency (the breaker needs the guard address, the guard needs the breaker address):

```bash
forge script script/ConfigureGuard.s.sol:ConfigureGuard \
  --rpc-url "$LASNA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

### 5. Seed the demo — Base Sepolia (optional)

```bash
forge script script/SeedDemo.s.sol:SeedDemo \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

### 6. Trigger the breach — Base Sepolia

```bash
forge script script/SimulateBreach.s.sol:SimulateBreach \
  --rpc-url "$BASE_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

Watch for:

- `OriginVault.InvariantBreached` on Base Sepolia.
- `InvariantGuardReactive.BreachConfirmed` / `CallbackRequested` on Lasna.
- `CircuitBreakerCallback.CircuitBreakerTriggered` on Unichain Sepolia.

Then verify the destination is frozen:

```bash
cast call "$BREAKER_ADDRESS" "paused()(bool)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
cast call "$BREAKER_ADDRESS" "frozenLtvBps()(uint256)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
```

Recovery is a deliberate human action:

```bash
cast send "$BREAKER_ADDRESS" "unpause()" \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

---

## Demo script (90 seconds)

1. Show the vault is healthy: `healthBps() == 10000`, `breached() == false`.
2. Call `recordLoss(DEMO_LOSS_WEI)` as the vault owner.
3. Show the breach event and the guard's `BreachConfirmed`.
4. Switch to Unichain and show `paused() == true`, `frozenLtvBps()` snapshot, and `CircuitBreakerTriggered`.
5. Call `requireOperational()` on an adapter (or `originateLoan()` in the mock) and show it reverts with `ProtocolPaused`.
6. Show duplicate callback delivery is a no-op (`breachCount` unchanged).
7. Review and `unpause()`; show the adapter works again.

---

## Security model

| Property | Mechanism |
| --- | --- |
| Only the origin event can trigger the guard | `onlySystem` + origin chain/contract/topic checks |
| A lying event cannot cause a pause | Guard recomputes coverage from raw integers |
| Replay protection | Deterministic `breachId`; stale block rejection |
| Callback spam resistance | Cooldown + dedupe |
| Only the guard can pause | Callback proxy check + injected sender check |
| Wrong network reports rejected | Immutable origin chain ID in the breaker |
| Retry-safe deliveries | Duplicate breach IDs are suppressed, not reverted |
| Parameter tampering during an incident | LTV frozen while paused |
| Human oversight | `unpause()` is owner-only; recovery does not auto-resume |
| Reentrancy | `ReentrancyGuard` on all ETH-moving vault paths |

### Known limitations (v1)

- `recordLoss()` is a **demo-only** owner hook. Production deployments should replace it with real strategy/bridge accounting.
- Origin withdrawals remain open after a breach. Aegis protects destination-side credit and redemption actions.
- The breaker trusts the guard's authenticated report; it does not independently verify origin state. The guard's recomputation and the proxy authentication are the trust boundary.
- Unpause is manual and deliberately not automated.
- The guard's `forceCheck()` is permissionless and can re-emit a breach, but the cooldown and dedupe prevent callback storms.
- Bidirectional acknowledgement / recovery propagation is deferred to v2.

More detail, including failure-mode analysis, is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## v2 roadmap

- Origin-side pause or withdrawal throttle on confirmed breach.
- Bidirectional acknowledgement from Unichain back to Base Sepolia.
- Multi-destination fan-out (multiple breakers / chains).
- Signed or price-aware health metrics instead of a simple reserve ratio.
- Chainlink/RedStone feeds for liability valuation in non-ETH assets.
- Automated recovery proposals with a timelock, still requiring human execution.

---

## Stack

- Solidity `0.8.29`, `cancun` EVM target
- Foundry (`forge`, `cast`, `anvil`)
- [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni) — official Omni API
- OpenZeppelin Contracts v5 (`Ownable2Step`, `ReentrancyGuard`)

## Frontend dashboard

The read-only Aegis Command Center lives in [`frontend/`](frontend/). It reads the deployed
vault, reactive guard, and destination breaker directly from their public RPC endpoints.

```bash
cd frontend
npm install
copy .env.example .env
# Set the VITE_* addresses/RPC URLs in .env
npm run dev
```

The dashboard never requests a private key or signs transactions. It is an operational view
for coverage, callback counts, breaker state, chain health, and the breach-to-pause pipeline.

### Showcase flow

Run the dashboard in one terminal:

```powershell
cd frontend
npm install
npm run dev
```

Open `http://localhost:5173`. In a second terminal, load the repository environment and use
the existing scripts to produce the live incident:

```powershell
# From the repository root
forge script script/SeedDemo.s.sol:SeedDemo `
  --rpc-url $env:BASE_SEPOLIA_RPC_URL `
  --private-key $env:PRIVATE_KEY `
  --broadcast

forge script script/SimulateBreach.s.sol:SimulateBreach `
  --rpc-url $env:BASE_SEPOLIA_RPC_URL `
  --private-key $env:PRIVATE_KEY `
  --broadcast
```

The dashboard refreshes every 15 seconds. The expected story is:

1. Origin coverage drops below the configured 80% threshold.
2. The Reactive guard confirms the breach and requests a callback.
3. The Unichain breaker changes to `PAUSED` and freezes the LTV snapshot.
4. The dashboard shows the incident count, breach ID, and chain block progression.

To reset the destination breaker after the presentation, call `unpause()` from the owner
account using `cast send`. The dashboard is intentionally read-only; it cannot broadcast
transactions or expose a private key.

## License

MIT
