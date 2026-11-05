// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IOriginVault } from "./interfaces/IOriginVault.sol";
import { ICircuitBreaker } from "./interfaces/ICircuitBreaker.sol";

/**
 * @title InvariantGuardReactive
 * @notice Reactive contract deployed on Reactive Lasna. It observes the Base Sepolia
 *         vault's `InvariantBreached` event, re-validates the coverage ratio in
 *         Solidity, and requests an emergency callback on Unichain Sepolia.
 * @dev Omni-style reactive contract: no RVMs, no `vm` modifier, no deprecated
 *      `Callback` event. Callbacks are requested through the system contract.
 */
contract InvariantGuardReactive is AbstractReactive, Ownable2Step {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Origin chain whose logs are trusted.
    uint256 public immutable ORIGIN_CHAIN_ID;
    /// @notice Origin vault whose logs are trusted.
    address public immutable ORIGIN_VAULT;
    /// @notice Destination chain that receives the circuit-breaker callback.
    uint256 public immutable DESTINATION_CHAIN_ID;
    /// @notice Topic 0 of `IOriginVault.InvariantBreached`.
    uint256 public immutable INVARIANT_BREACHED_TOPIC0;

    /// @notice Destination breaker. Set after deployment to break the circular dependency.
    address public callbackRecipient;
    /// @notice Coverage below this value (in bps) triggers a callback.
    uint256 public breachThresholdBps;
    /// @notice Gas forwarded to the destination callback.
    uint64 public callbackGasLimit;
    /// @notice Minimum time between two callback requests.
    uint256 public cooldownSeconds;
    /// @notice Allows the owner to pause the guard without unsubscribing.
    bool public active;

    /// @notice Breaches already forwarded, keyed by deterministic breach ID.
    mapping(bytes32 => bool) public handledBreaches;

    /// @notice Reactive timestamp of the last callback request.
    uint256 public lastCallbackAt;
    /// @notice Highest origin block number that produced a callback.
    uint256 public lastOriginBlock;
    /// @notice Number of callbacks requested.
    uint256 public breachCount;

    event BreachConfirmed(
        bytes32 indexed breachId,
        uint256 healthBps,
        uint256 reserves,
        uint256 liabilities,
        uint256 originBlockNumber,
        uint256 originTxHash
    );
    event CallbackRequested(
        bytes32 indexed breachId, uint256 indexed destinationChainId, address indexed recipient, uint64 gasLimit
    );
    event CallbackRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event BreachThresholdUpdated(uint256 previousThresholdBps, uint256 newThresholdBps);
    event CallbackGasLimitUpdated(uint64 previousGasLimit, uint64 newGasLimit);
    event CooldownUpdated(uint256 previousCooldownSeconds, uint256 newCooldownSeconds);
    event GuardActiveUpdated(bool active);
    event DebtCovered(uint256 amount);

    error InvalidAddress();
    error InvalidChainId();
    error InvalidBps(uint256 bps);
    error InvalidGasLimit();
    error CallbackRecipientNotSet();

    constructor(
        uint256 originChainId_,
        address originVault_,
        uint256 destinationChainId_,
        address initialOwner_,
        uint256 breachThresholdBps_,
        uint64 callbackGasLimit_
    ) payable Ownable(initialOwner_) {
        if (originChainId_ == 0 || destinationChainId_ == 0) revert InvalidChainId();
        if (originChainId_ == destinationChainId_) revert InvalidChainId();
        if (originVault_ == address(0)) revert InvalidAddress();
        if (breachThresholdBps_ == 0 || breachThresholdBps_ > BPS_DENOMINATOR) {
            revert InvalidBps(breachThresholdBps_);
        }
        if (callbackGasLimit_ == 0) revert InvalidGasLimit();

        ORIGIN_CHAIN_ID = originChainId_;
        ORIGIN_VAULT = originVault_;
        DESTINATION_CHAIN_ID = destinationChainId_;
        INVARIANT_BREACHED_TOPIC0 = uint256(IOriginVault.InvariantBreached.selector);

        breachThresholdBps = breachThresholdBps_;
        callbackGasLimit = callbackGasLimit_;
        cooldownSeconds = 30;
        active = true;

        SYSTEM.subscribe(
            originChainId_,
            originVault_,
            uint256(IOriginVault.InvariantBreached.selector),
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external override onlySystem {
        if (!active) return;
        if (log_.chainId != ORIGIN_CHAIN_ID) return;
        if (log_.contractAddress != ORIGIN_VAULT) return;
        if (log_.topic0 != INVARIANT_BREACHED_TOPIC0) return;
        if (log_.opCode != 1) return;
        if (log_.data.length != 128) return;

        (uint256 vaultReserves, uint256 vaultLiabilities,,) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));

        if (vaultLiabilities == 0) return;

        // Never trust the event's self-reported health. Recompute it from the
        // raw reserve/liability values that the origin contract emitted.
        uint256 currentHealthBps = (vaultReserves * BPS_DENOMINATOR) / vaultLiabilities;
        if (currentHealthBps >= breachThresholdBps) return;

        // Ignore stale logs. A new breach must come from a newer origin block.
        if (log_.blockNumber <= lastOriginBlock) return;

        bytes32 breachId =
            keccak256(abi.encode(log_.chainId, log_.contractAddress, log_.blockNumber, log_.txHash, log_.logIndex));
        if (handledBreaches[breachId]) return;
        if (lastCallbackAt != 0 && block.timestamp < lastCallbackAt + cooldownSeconds) return;

        address recipient = callbackRecipient;
        if (recipient == address(0)) revert CallbackRecipientNotSet();

        // Effects before interaction. If the system call reverts, all of this
        // is rolled back by the EVM.
        handledBreaches[breachId] = true;
        lastOriginBlock = log_.blockNumber;
        lastCallbackAt = block.timestamp;
        breachCount += 1;

        bytes memory payload = abi.encodeWithSelector(
            ICircuitBreaker.pause.selector,
            address(0), // reserved: the callback proxy injects this guard's address
            breachId,
            currentHealthBps,
            vaultReserves,
            vaultLiabilities,
            ORIGIN_CHAIN_ID
        );

        emit BreachConfirmed(breachId, currentHealthBps, vaultReserves, vaultLiabilities, log_.blockNumber, log_.txHash);

        emit CallbackRequested(breachId, DESTINATION_CHAIN_ID, recipient, callbackGasLimit);

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID, recipient: recipient, gasLimit: callbackGasLimit, payload: payload
            })
        );
    }

    // ---------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------

    /// @notice Sets the destination breaker address. Required before the first breach.
    function setCallbackRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert InvalidAddress();
        address previous = callbackRecipient;
        callbackRecipient = newRecipient;
        emit CallbackRecipientUpdated(previous, newRecipient);
    }

    /// @notice Sets the local coverage threshold that triggers callbacks.
    function setBreachThresholdBps(uint256 newThresholdBps) external onlyOwner {
        if (newThresholdBps == 0 || newThresholdBps > BPS_DENOMINATOR) {
            revert InvalidBps(newThresholdBps);
        }
        uint256 previous = breachThresholdBps;
        breachThresholdBps = newThresholdBps;
        emit BreachThresholdUpdated(previous, newThresholdBps);
    }

    /// @notice Sets the gas limit forwarded to the destination callback.
    function setCallbackGasLimit(uint64 newGasLimit) external onlyOwner {
        if (newGasLimit == 0) revert InvalidGasLimit();
        uint64 previous = callbackGasLimit;
        callbackGasLimit = newGasLimit;
        emit CallbackGasLimitUpdated(previous, newGasLimit);
    }

    /// @notice Sets the minimum time between callback requests.
    function setCooldownSeconds(uint256 newCooldownSeconds) external onlyOwner {
        uint256 previous = cooldownSeconds;
        cooldownSeconds = newCooldownSeconds;
        emit CooldownUpdated(previous, newCooldownSeconds);
    }

    /// @notice Enables or disables reaction without changing the subscription.
    function setActive(bool newActive) external onlyOwner {
        active = newActive;
        emit GuardActiveUpdated(newActive);
    }

    /// @notice Settles any outstanding debt owed to the Reactive system contract.
    /// @dev Anyone may call this; it uses the guard's own balance.
    function coverDebt() external {
        uint256 amount = SYSTEM.debt(address(this));
        emit DebtCovered(amount);
        _coverDebt();
    }
}
