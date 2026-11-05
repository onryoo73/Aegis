# Architecture

This document describes the Aegis Reactive system in detail: component responsibilities, state machines, data formats, trust boundaries, failure modes, and the testing strategy.

---

## 1. System overview

Aegis Reactive is a three-chain circuit breaker for a native-ETH vault.

```text
Base Sepolia                  Reactive Lasna                 Unichain Sepolia
-----------                   --------------                 ----------------
OriginVault                   InvariantGuardReactive         CircuitBreakerCallback
   |                                |                               |
   |  InvariantBreached             |                               |
   +------------------------------->|                               |
                                    |  recompute + dedupe           |
                                    |  requestCallbackV_1_0         |
                                    +------------------------------>|
                                                                    |  pause()
                                                                    |  freezeLtv()
                                                                    |  emit incident
```

The origin chain is the source of truth for solvency. The reactive chain is a stateless-ish verifier and router. The destination chain is the enforcement point.

### Network constants

| Item | Value |
| --- | --- |
| Origin chain ID | `84532` (Base Sepolia) |
| Reactive chain ID | `5318007` (Lasna) |
| Destination chain ID | `1301` (Unichain Sepolia) |
| Reactive system contract | `0x8888888888888888888888888888888888888888` |
| Base Sepolia callback proxy | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |
| Unichain Sepolia callback proxy | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |

The guard only needs the Unichain proxy address implicitly: it sends a callback to the destination chain, and the Reactive network routes it through that chain's proxy. The breaker stores the Unichain proxy explicitly for authentication.

---

## 2. Component specifications

### 2.1 OriginVault

**Purpose:** a minimal, auditable vault whose solvency can be measured and perturbed deterministically.

**Accounting model**

| Variable | Meaning |
| --- | --- |
| `deposits[user]` | Per-user claim |
| `totalDeposits` | Sum of all claims (liabilities) |
| `reserves` | Internally accounted liquid ETH |
| `outstandingDebt` | ETH lent to the operator and expected back |
| `minCoverageBps` | Threshold in basis points |
| `breached` | Latched result of the latest assessment |

Coverage:

```text
healthBps = totalDeposits == 0
          ? 10_000
          : (reserves * 10_000) / totalDeposits
```

Invariant:

```text
reserves + outstandingDebt + realizedLosses == totalDeposits
```

This identity is enforced by the stateful invariant suite.

**State transitions that trigger assessment**

| Action | Reserves | Liabilities | Debt | Assessment |
| --- | --- | --- | --- | --- |
| `deposit` | `+amount` | `+amount` | — | yes |
| `withdraw` | `-amount` | `-amount` | — | yes |
| `borrow` | `-amount` | — | `+amount` | yes |
| `repay` | `+applied` | — | `-applied` | yes |
| `recordLoss` | `-amount` | — | — | yes |
| `setMinCoverageBps` | — | — | — | yes |
| `forceCheck` | — | — | — | always emits if breached |

`_assess(transitionOnly)` emits `InvariantBreached` on the healthy → breached transition, or on every `forceCheck()`. It emits `InvariantRestored` on breached → healthy.

**Design notes**

- Native ETH avoids token approvals, transfer hooks, and ERC-20 edge cases.
- `ReentrancyGuard` protects every function that moves ETH.
- `recordLoss` is intentionally owner-only and clearly labeled as a demo hook.
- The vault does not stop withdrawals after a breach; destination-side enforcement is the product surface.

### 2.2 InvariantGuardReactive

**Purpose:** observe the origin event, verify it, and request an authenticated destination callback.

It inherits `AbstractReactive` from `reactive-lib-omni`. `AbstractReactive` hardcodes the system contract at `0x8888...8888` and provides:

- `SYSTEM` — the `ISystemContract` instance.
- `REACTIVE_IGNORE` — wildcard topic constant.
- `onlySystem` — caller authentication for `react()`.

**Immutable configuration**

| Field | Meaning |
| --- | --- |
| `ORIGIN_CHAIN_ID` | Only logs from this chain are accepted |
| `ORIGIN_VAULT` | Only logs from this contract are accepted |
| `DESTINATION_CHAIN_ID` | Chain that receives the callback |
| `INVARIANT_BREACHED_TOPIC0` | Event selector, derived from `IOriginVault` |

**Mutable configuration (owner, two-step)**

| Field | Default | Meaning |
| --- | --- | --- |
| `callbackRecipient` | unset | Breaker address; must be set before the first breach |
| `breachThresholdBps` | constructor arg | Local threshold, independent of the vault's threshold |
| `callbackGasLimit` | constructor arg | Gas forwarded to the callback |
| `cooldownSeconds` | `30` | Minimum spacing between callback requests |
| `active` | `true` | Soft kill switch without unsubscribing |

**Runtime bookkeeping**

| Field | Meaning |
| --- | --- |
| `handledBreaches[breachId]` | Dedupe map |
| `lastOriginBlock` | Highest origin block that produced a callback |
| `lastCallbackAt` | Reactive timestamp of the last request |
| `breachCount` | Number of callbacks requested |

**`react()` pipeline**

```text
1. active?                              no  -> return
2. chainId == ORIGIN_CHAIN_ID?          no  -> return
3. contractAddress == ORIGIN_VAULT?     no  -> return
4. topic0 == INVARIANT_BREACHED_TOPIC0? no  -> return
5. opCode == 1?                         no  -> return
6. data.length == 128?                  no  -> return
7. liabilities != 0?                    no  -> return
8. recompute health from raw values
9. recomputed health < threshold?       no  -> return
10. blockNumber > lastOriginBlock?      no  -> return
11. breachId unseen?                    no  -> return
12. cooldown elapsed?                   no  -> return
13. recipient configured?               no  -> revert
14. record breach, request callback
```

Steps 2–7 are cheap filters. Step 8 is the security-critical check: the event's `healthBps` field is discarded.

**Why recompute?**

A buggy or compromised origin could emit an event with falsified fields. A naive guard would forward the self-reported health directly into a pause. Recomputing from `reserves` and `liabilities` means the only way to cause a pause is to actually have more liabilities than reserves relative to the threshold, as observed by the event payload. The breaker also pins the origin chain ID, so a log from another chain cannot be replayed.

### 2.3 CircuitBreakerCallback

**Purpose:** enforce the pause on the destination chain.

It inherits `AbstractCallback`, which checks:

1. `msg.sender == _SERVICE_PROVIDER` (the canonical callback proxy).
2. The first callback argument equals `_CALLBACK_SENDER` (the guard).

**State**

| Field | Meaning |
| --- | --- |
| `paused` | Breaker tripped |
| `pausedAt` | Timestamp of the pause |
| `ltvBps` | Destination parameter under governance control |
| `frozenLtvBps` | Snapshot at pause time |
| `lastBreachId` | Breach that tripped the breaker |
| `handledBreaches[breachId]` | All delivered IDs, including duplicates |
| `breachCount` | Distinct IDs delivered |

**State machine**

```text
                 pause(valid breach)
   HEALTHY  ----------------------------->  PAUSED
      ^                                       |
      |                                       | pause(duplicate)
      |                                       +--> PAUSED (suppressed, no revert)
      |                                       |
      |                                       | pause(new breach)
      |                                       +--> PAUSED (recorded, ignored)
      |
      +----------- unpause() [owner] ---------+
```

**Idempotency**

Duplicates are suppressed rather than reverted. This matters because Reactive Network may retry deliveries; a revert would waste the recipient's callback gas and could cause repeated alerting. A duplicate still emits `DuplicateBreachSuppressed`, preserving an audit trail.

**Parameter freeze**

`setLtvBps` reverts with `ParametersFrozen(pausedAt)` while paused. This prevents governance from quietly loosening risk limits during an active incident. `unpause()` is the only path back to normal operation and is owner-only.

**Adapter integration**

`requireOperational()` reverts with `ProtocolPaused(pausedAt)`. Destination-side markets, redemption queues, and bridges call it before state-changing credit actions. `isOperational()` is the non-reverting variant for off-chain consumers and UI.

---

## 3. Callback payload

The guard encodes:

```solidity
abi.encodeWithSelector(
    ICircuitBreaker.pause.selector,
    address(0),        // reserved for proxy injection
    breachId,
    healthBps,
    reserves,
    liabilities,
    originChainId
)
```

ABI layout (each word is 32 bytes):

| Offset | Field | Notes |
| --- | --- | --- |
| `0x00` | selector | `pause.selector` |
| `0x04` | injected sender | Guard writes `address(0)`; the proxy overwrites the low 160 bits with the guard address |
| `0x24` | `breachId` | `keccak256(abi.encode(chainId, vault, blockNumber, txHash, logIndex))` |
| `0x44` | `healthBps` | Recomputed by the guard |
| `0x64` | `reserves` | Raw origin reserves |
| `0x84` | `liabilities` | Raw origin liabilities |
| `0xa4` | `originChainId` | Checked against the breaker's immutable |

`breachId` is deterministic and stable across redeliveries of the same log. It is not a secret; it exists to make dedupe and incident correlation easy.

The mock proxy used in tests reproduces the production injection semantics: it patches the **low 160 bits of the first argument word** (the address is right-aligned in ABI encoding). A naive implementation that patches the high bits produces invalid address padding and reverts during ABI decoding — the test suite was written to catch exactly that class of bug.

---

## 4. Trust boundaries

```text
[OriginVault] --events--> [Reactive Network] --react--> [Guard] --callback--> [Proxy] --> [Breaker]
     ^                         ^                          ^                                  ^
     |                         |                          |                                  |
  owner/operator          system contract             guard owner                     breaker owner
```

| Boundary | Who is trusted | Why |
| --- | --- | --- |
| Origin → guard | Origin vault contract + Reactive Network log delivery | Guard pins chain, address, topic, and opcode |
| Guard → callback | Guard code + guard owner configuration | Breaker pins the guard address via proxy injection |
| Proxy → breaker | Canonical proxy at a known address | `onlyServiceProvider` |
| Breaker → adapters | Breaker code + breaker owner | `requireOperational()` is a local call |
| Owners | Multisig/timelock recommended in production | Can change recipient, thresholds, and unpause |

The guard does **not** trust the event's health field; the breaker does **not** trust arbitrary callers. The remaining trust assumptions are the correctness of the Reactive Network's cross-chain delivery and the honesty of the configured owner keys.

---

## 5. Failure modes

| Failure | Effect | Mitigation |
| --- | --- | --- |
| Origin event missed by the network | No callback | `forceCheck()` re-emits the breach; the next breach event also triggers |
| Guard callback request fails / is dropped | No pause | `forceCheck()` produces a new log index → new `breachId`; retry after cooldown |
| Breaker lacks ETH for callback | Delivery fails | Fund at deploy; monitor balance; `coverDebt()` / top-up |
| Guard lacks lREACT | Subscription/callback debt accrues, subscription may pause | Fund at deploy; `coverDebt()`; monitor debt |
| Duplicate delivery | Breaker would pause twice | Deterministic `breachId` + idempotent pause |
| Callback spam | Gas drain, alert fatigue | Cooldown + dedupe |
| Forged origin event | Could cause a pause | Guard recomputes health and checks chain/address/topic |
| Log replay | Could re-pause after unpause | Stale-block rejection + dedupe |
| Wrong destination chain | Callback routed elsewhere | Breaker checks `originChainId` and immutable origin chain |
| Guard owner compromised | Can redirect callbacks or disable guard | `Ownable2Step`; use a multisig + timelock in production |
| Breaker owner compromised | Can unpause during an incident | Use a multisig + timelock; monitor `CircuitBreakerReset` |
| Origin reorg | Log may disappear or change | Breach ID includes block hash-adjacent tx/log data; rely on Reactive finality policy; monitor alerts |

### Emergency procedures

1. **Suspected false positive** — review `BreachConfirmed` (Lasna) against the origin block. If the event was wrong, the breaker will not have paused. If it did pause, `unpause()` after review.
2. **Suspected false negative** — call `forceCheck()` on the vault. If the guard is inactive, the owner calls `setActive(true)`.
3. **Guard out of funds** — top up the guard with lREACT and call `coverDebt()`.
4. **Breaker out of funds** — top up the breaker with ETH and call `coverDebt()`.
5. **Compromised guard** — owner calls `setActive(false)` and/or `setCallbackRecipient(newBreaker)`; rotate the breaker's `_CALLBACK_SENDER` only by redeploying (it is immutable by design).

---

## 6. Testing strategy

| Layer | File | Focus |
| --- | --- | --- |
| Origin unit/fuzz | `test/OriginVault.t.sol` | Accounting, access control, events, reentrancy, boundary values |
| Guard unit/fuzz | `test/InvariantGuardReactive.t.sol` | Subscription, log filtering, recomputation, dedupe, cooldown, payload, funding |
| Breaker unit/fuzz | `test/CircuitBreakerCallback.t.sol` | Proxy/guard authentication, idempotency, freeze/unpause, origin chain check |
| End-to-end | `test/EndToEnd.t.sol` | Full Base → Lasna → Unichain flow with recorded logs, real proxy injection semantics, adapter freeze, duplicate suppression, manual recovery |
| Stateful invariants | `test/VaultInvariant.t.sol` | Solvency identity, ledger reconciliation, ETH backing, breach-flag consistency, health bound |

The end-to-end suite uses:

- `vm.chainId` to switch between the three chain IDs.
- `deployCodeTo` to place the mock system contract at `0x8888...8888`.
- `deployCodeTo` to place the mock callback proxy at the real Unichain proxy address.
- `vm.recordLogs` + `vm.getRecordedLogs` to turn vault events into `IReactive.LogRecord` values.
- The mock proxy's address-injection logic to reproduce the production authentication path.

This means the library's hardcoded system address, the contract's `onlySystem` check, the proxy injection, and the breaker's `onlyCallbackSender` check are all exercised without mocks that bypass authentication.

---

## 7. Deployment ordering

The guard needs the origin vault; the breaker needs the guard; the guard needs the breaker's address to send callbacks. The order is:

```text
1. Deploy OriginVault on Base Sepolia.
2. Deploy InvariantGuardReactive on Lasna with ORIGIN_VAULT set.
3. Deploy CircuitBreakerCallback on Unichain Sepolia with GUARD_ADDRESS set.
4. Call guard.setCallbackRecipient(BREAKER_ADDRESS) on Lasna.
5. Fund the guard (lREACT) and the breaker (ETH).
6. Seed demo liquidity and trigger a breach.
```

`ConfigureGuard.s.sol` performs step 4. Steps 1–3 are separate scripts because each must broadcast on a different chain.

**Post-deployment checks**

```bash
# Guard subscription and recipient
cast call "$GUARD_ADDRESS" "callbackRecipient()(address)" --rpc-url "$LASNA_RPC_URL"
cast call "$GUARD_ADDRESS" "breachThresholdBps()(uint256)" --rpc-url "$LASNA_RPC_URL"

# Breaker wiring
cast call "$BREAKER_ADDRESS" "_CALLBACK_SENDER()(address)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
cast call "$BREAKER_ADDRESS" "ORIGIN_CHAIN_ID()(uint256)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
cast call "$BREAKER_ADDRESS" "paused()(bool)" --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"
```

---

## 8. v2 extensions

- **Origin-side enforcement** — mirror the pause on Base Sepolia to stop withdrawals or throttle redemptions.
- **Acknowledgement path** — Unichain emits a confirmation that Base Sepolia consumes, closing the loop.
- **Multi-destination fan-out** — one guard, many breakers, per-chain gas limits.
- **Valuation-aware health** — replace the simple reserve ratio with signed price/liability feeds.
- **Governance hardening** — timelocked parameter changes, multisig ownership, and a two-key incident-response process.
- **Formal verification** — model the guard's filtering and the breaker's idempotency in a proof harness.

---

## 9. Glossary

| Term | Meaning |
| --- | --- |
| **Breach** | Coverage below the configured threshold |
| **healthBps** | Reserves / liabilities in basis points; `10_000` = 100% |
| **breachId** | Deterministic hash identifying an origin log |
| **Callback** | Destination-chain transaction requested by the reactive contract |
| **Reactive ignore** | Wildcard topic value used to subscribe to all topics |
| **Proxy injection** | The callback proxy overwriting the first payload argument with the reactive sender address |
| **Freeze** | Blocking parameter changes while the breaker is paused |
