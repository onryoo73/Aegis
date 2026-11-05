// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ICircuitBreaker } from "./interfaces/ICircuitBreaker.sol";

/**
 * @title CircuitBreakerCallback
 * @notice Destination-side emergency circuit breaker on Unichain Sepolia.
 * @dev Authenticated twice by Omni:
 *      1. `onlyServiceProvider` proves the call came through the callback proxy.
 *      2. `onlyCallbackSender` proves the proxy injected the expected guard address.
 *
 *      The breaker is idempotent: duplicate deliveries of the same breach ID are
 *      recorded and ignored instead of reverting, so network retries do not burn
 *      the recipient's callback gas.
 */
contract CircuitBreakerCallback is ICircuitBreaker, AbstractCallback, Ownable2Step {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Origin chain that the guard is allowed to report on.
    uint256 public immutable ORIGIN_CHAIN_ID;

    /// @notice True while the breaker is tripped.
    bool public override paused;
    /// @notice Timestamp of the pause.
    uint256 public pausedAt;
    /// @notice Destination-side parameter controlled by governance.
    uint256 public ltvBps;
    /// @notice Snapshot of the parameter at the moment of the pause.
    uint256 public frozenLtvBps;
    /// @notice Last breach that actually tripped the breaker.
    bytes32 public lastBreachId;

    /// @notice Every breach ID delivered by the guard, including duplicates.
    mapping(bytes32 => bool) public handledBreaches;
    /// @notice Number of distinct breach IDs delivered.
    uint256 public breachCount;

    event CircuitBreakerTriggered(
        bytes32 indexed breachId,
        address indexed guard,
        uint256 healthBps,
        uint256 reserves,
        uint256 liabilities,
        uint256 originChainId,
        uint256 frozenLtvBps,
        uint256 timestamp
    );
    event CircuitBreakerReset(address indexed operator, uint256 pausedFor);
    event DuplicateBreachSuppressed(bytes32 indexed breachId);
    event PauseRequestIgnored(bytes32 indexed breachId, uint256 pausedAt);
    event LtvUpdated(uint256 previousLtvBps, uint256 newLtvBps);
    event DebtCovered(uint256 amount);

    error InvalidAddress();
    error InvalidChainId();
    error InvalidBps(uint256 bps);
    error InvalidHealthBps(uint256 healthBps);
    error NotPaused();
    error ParametersFrozen(uint256 pausedAt);
    error WrongOriginChain(uint256 provided, uint256 expected);

    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        uint256 originChainId_,
        address initialOwner_,
        uint256 initialLtvBps_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) Ownable(initialOwner_) {
        if (address(callbackProxy_) == address(0)) revert InvalidAddress();
        if (callbackSender_ == address(0)) revert InvalidAddress();
        if (originChainId_ == 0) revert InvalidChainId();
        if (initialLtvBps_ > BPS_DENOMINATOR) revert InvalidBps(initialLtvBps_);

        ORIGIN_CHAIN_ID = originChainId_;
        ltvBps = initialLtvBps_;
    }

    // ---------------------------------------------------------------------
    // Reactive callback entry point
    // ---------------------------------------------------------------------

    /// @inheritdoc ICircuitBreaker
    function pause(
        address reactive_,
        bytes32 breachId_,
        uint256 healthBps_,
        uint256 reserves_,
        uint256 liabilities_,
        uint256 originChainId_
    ) external override onlyServiceProvider onlyCallbackSender(reactive_) {
        if (originChainId_ != ORIGIN_CHAIN_ID) {
            revert WrongOriginChain(originChainId_, ORIGIN_CHAIN_ID);
        }
        if (healthBps_ > BPS_DENOMINATOR) revert InvalidHealthBps(healthBps_);

        if (handledBreaches[breachId_]) {
            emit DuplicateBreachSuppressed(breachId_);
            return;
        }

        handledBreaches[breachId_] = true;
        breachCount += 1;

        if (paused) {
            emit PauseRequestIgnored(breachId_, pausedAt);
            return;
        }

        paused = true;
        pausedAt = block.timestamp;
        lastBreachId = breachId_;
        frozenLtvBps = ltvBps;

        emit CircuitBreakerTriggered(
            breachId_, reactive_, healthBps_, reserves_, liabilities_, originChainId_, frozenLtvBps, block.timestamp
        );
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    /// @notice Resets the breaker after the incident has been reviewed.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();

        paused = false;
        uint256 pausedFor = block.timestamp - pausedAt;
        emit CircuitBreakerReset(msg.sender, pausedFor);
    }

    /// @notice Updates the destination-side LTV parameter.
    /// @dev Frozen while the breaker is paused.
    function setLtvBps(uint256 newLtvBps) external onlyOwner {
        if (paused) revert ParametersFrozen(pausedAt);
        if (newLtvBps > BPS_DENOMINATOR) revert InvalidBps(newLtvBps);

        uint256 previous = ltvBps;
        ltvBps = newLtvBps;
        emit LtvUpdated(previous, newLtvBps);
    }

    /// @notice Settles any outstanding debt owed to the callback proxy.
    /// @dev Anyone may call this; it uses the breaker's own balance.
    function coverDebt() external {
        uint256 amount = _SERVICE_PROVIDER.debt(address(this));
        emit DebtCovered(amount);
        _coverDebt();
    }

    // ---------------------------------------------------------------------
    // Adapter-facing views
    // ---------------------------------------------------------------------

    /// @inheritdoc ICircuitBreaker
    function requireOperational() external view override {
        if (paused) revert ProtocolPaused(pausedAt);
    }

    /// @notice Non-reverting operational check for off-chain consumers.
    function isOperational() external view returns (bool) {
        return !paused;
    }
}
