// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IOriginVault } from "./interfaces/IOriginVault.sol";

/**
 * @title OriginVault
 * @notice Simulated liquidity vault on Base Sepolia whose solvency is monitored by
 *         the Reactive guard.
 * @dev Reserves are native ETH. `totalDeposits` is the sum of user claims
 *      (liabilities) and `reserves` is the internally accounted liquid balance.
 *      Coverage is `reserves / totalDeposits` in basis points.
 *
 *      The vault intentionally keeps operating after a breach. The circuit breaker
 *      lives on the destination chain and protects destination-side redemption /
 *      credit actions; stopping withdrawals on the origin is a separate governance
 *      decision and is outside the scope of this demo.
 */
contract OriginVault is IOriginVault, Ownable2Step, ReentrancyGuard {
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-user deposit claims.
    mapping(address => uint256) public deposits;

    /// @notice Sum of all user claims (liabilities).
    uint256 public totalDeposits;

    /// @notice Internally accounted liquid ETH reserves.
    uint256 public reserves;

    /// @notice ETH lent out to the operator and expected to be repaid.
    uint256 public outstandingDebt;

    /// @notice Minimum coverage ratio in basis points.
    uint256 public override minCoverageBps;

    /// @notice True while coverage is below the configured minimum.
    bool public override breached;

    /// @notice Address allowed to borrow from the vault.
    address public operator;

    /// @notice Recipient of simulated losses (demo only).
    address public lossRecipient;

    event Deposited(address indexed user, uint256 amount, uint256 reserves, uint256 totalDeposits);
    event Withdrawn(address indexed user, uint256 amount, uint256 reserves, uint256 totalDeposits);
    event Borrowed(address indexed borrower, uint256 amount, uint256 reserves, uint256 outstandingDebt);
    event Repaid(address indexed borrower, uint256 amount, uint256 reserves, uint256 outstandingDebt);
    event Refunded(address indexed borrower, uint256 amount);
    event LossRecorded(uint256 amount, uint256 reserves, address indexed recipient);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event LossRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event CoverageThresholdUpdated(uint256 previousThresholdBps, uint256 newThresholdBps);

    error ZeroAmount();
    error InvalidAddress();
    error InvalidBps(uint256 bps);
    error NotOperator(address caller);
    error InsufficientDeposit(uint256 requested, uint256 available);
    error InsufficientReserves(uint256 requested, uint256 available);
    error TransferFailed();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        _;
    }

    constructor(address initialOwner, address operator_, uint256 minCoverageBps_, address lossRecipient_)
        Ownable(initialOwner)
    {
        if (operator_ == address(0)) revert InvalidAddress();
        if (lossRecipient_ == address(0)) revert InvalidAddress();
        if (minCoverageBps_ == 0 || minCoverageBps_ > BPS_DENOMINATOR) {
            revert InvalidBps(minCoverageBps_);
        }

        operator = operator_;
        minCoverageBps = minCoverageBps_;
        lossRecipient = lossRecipient_;

        emit OperatorUpdated(address(0), operator_);
        emit LossRecipientUpdated(address(0), lossRecipient_);
        emit CoverageThresholdUpdated(0, minCoverageBps_);
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    /// @notice Deposits native ETH and records a matching user claim.
    function deposit() external payable nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        deposits[msg.sender] += amount;
        totalDeposits += amount;
        reserves += amount;

        _assess(true);
        emit Deposited(msg.sender, amount, reserves, totalDeposits);
    }

    /// @notice Withdraws native ETH against the caller's claim.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 userDeposit = deposits[msg.sender];
        if (amount > userDeposit) revert InsufficientDeposit(amount, userDeposit);
        if (amount > reserves) revert InsufficientReserves(amount, reserves);

        deposits[msg.sender] = userDeposit - amount;
        totalDeposits -= amount;
        reserves -= amount;

        _assess(true);
        emit Withdrawn(msg.sender, amount, reserves, totalDeposits);

        (bool success,) = payable(msg.sender).call{ value: amount }("");
        if (!success) revert TransferFailed();
    }

    // ---------------------------------------------------------------------
    // Operator actions (simulated lending / liquidity drain)
    // ---------------------------------------------------------------------

    /// @notice Borrows liquid reserves, reducing coverage without changing liabilities.
    function borrow(uint256 amount) external nonReentrant onlyOperator {
        if (amount == 0) revert ZeroAmount();
        if (amount > reserves) revert InsufficientReserves(amount, reserves);

        reserves -= amount;
        outstandingDebt += amount;

        _assess(true);
        emit Borrowed(msg.sender, amount, reserves, outstandingDebt);

        (bool success,) = payable(msg.sender).call{ value: amount }("");
        if (!success) revert TransferFailed();
    }

    /// @notice Repays outstanding debt. Overpayment is refunded.
    function repay() external payable nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        uint256 debt = outstandingDebt;
        uint256 applied = amount < debt ? amount : debt;
        uint256 refund = amount - applied;

        if (applied > 0) {
            outstandingDebt = debt - applied;
            reserves += applied;

            _assess(true);
            emit Repaid(msg.sender, applied, reserves, outstandingDebt);
        }

        if (refund > 0) {
            emit Refunded(msg.sender, refund);
            (bool success,) = payable(msg.sender).call{ value: refund }("");
            if (!success) revert TransferFailed();
        }
    }

    // ---------------------------------------------------------------------
    // Governance / demo hooks
    // ---------------------------------------------------------------------

    /// @notice Simulates an exploit or bad debt by removing reserves.
    /// @dev DEMO ONLY. In production this would be replaced by an accounting
    ///      integration with the real strategy / bridge that owns the reserves.
    function recordLoss(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > reserves) revert InsufficientReserves(amount, reserves);

        reserves -= amount;

        _assess(true);
        emit LossRecorded(amount, reserves, lossRecipient);

        (bool success,) = payable(lossRecipient).call{ value: amount }("");
        if (!success) revert TransferFailed();
    }

    /// @notice Re-emits the current breach so a failed/missed callback can be retried.
    function forceCheck() external {
        _assess(false);
    }

    /// @notice Updates the coverage threshold and immediately reassesses the vault.
    function setMinCoverageBps(uint256 newMinCoverageBps) external onlyOwner {
        if (newMinCoverageBps == 0 || newMinCoverageBps > BPS_DENOMINATOR) {
            revert InvalidBps(newMinCoverageBps);
        }

        uint256 previous = minCoverageBps;
        minCoverageBps = newMinCoverageBps;
        emit CoverageThresholdUpdated(previous, newMinCoverageBps);
        _assess(true);
    }

    /// @notice Updates the operator allowed to borrow.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        address previous = operator;
        operator = newOperator;
        emit OperatorUpdated(previous, newOperator);
    }

    /// @notice Updates the recipient of simulated losses.
    function setLossRecipient(address newLossRecipient) external onlyOwner {
        if (newLossRecipient == address(0)) revert InvalidAddress();
        address previous = lossRecipient;
        lossRecipient = newLossRecipient;
        emit LossRecipientUpdated(previous, newLossRecipient);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IOriginVault
    function healthBps() public view override returns (uint256) {
        return _healthBps(reserves, totalDeposits);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Emits only on transition when `transitionOnly` is true.
    function _assess(bool transitionOnly) internal {
        uint256 liabilities = totalDeposits;
        uint256 currentHealth = _healthBps(reserves, liabilities);

        if (currentHealth < minCoverageBps) {
            if (!breached) {
                breached = true;
                emit InvariantBreached(reserves, liabilities, currentHealth, minCoverageBps);
            } else if (!transitionOnly) {
                emit InvariantBreached(reserves, liabilities, currentHealth, minCoverageBps);
            }
        } else if (breached) {
            breached = false;
            emit InvariantRestored(reserves, liabilities, currentHealth);
        }
    }

    function _healthBps(uint256 reserveAmount, uint256 liabilityAmount) internal pure returns (uint256) {
        if (liabilityAmount == 0) return BPS_DENOMINATOR;
        return (reserveAmount * BPS_DENOMINATOR) / liabilityAmount;
    }
}
