// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test } from "forge-std/Test.sol";
import { OriginVault } from "../src/OriginVault.sol";

/**
 * @title OriginVaultHandler
 * @notice Stateful fuzzing handler for `OriginVault`.
 * @dev Every action is bounded so it cannot revert for input reasons. The handler
 *      mirrors the vault's accounting in ghost variables, which lets the invariant
 *      suite detect drift between user claims, reserves, debt, and losses.
 */
contract OriginVaultHandler is Test {
    OriginVault public immutable vault;
    address public immutable owner;
    address public immutable operator;
    address[] public users;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostBorrowed;
    uint256 public ghostRepaid;
    uint256 public ghostLosses;

    constructor(OriginVault vault_, address owner_, address operator_) {
        vault = vault_;
        owner = owner_;
        operator = operator_;

        users.push(makeAddr("alice"));
        users.push(makeAddr("bob"));
        users.push(makeAddr("carol"));
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    function deposit(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 value = bound(amount, 1, 10 ether);

        vm.deal(user, user.balance + value);
        vm.prank(user);
        vault.deposit{ value: value }();

        ghostDeposits += value;
    }

    function withdraw(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);

        uint256 claim = vault.deposits(user);
        if (claim == 0) return;

        uint256 value = bound(amount, 1, claim);
        uint256 liquid = vault.reserves();
        if (value > liquid) value = liquid;
        if (value == 0) return;

        vm.prank(user);
        vault.withdraw(value);

        ghostWithdrawals += value;
    }

    // ---------------------------------------------------------------------
    // Operator actions
    // ---------------------------------------------------------------------

    function borrow(uint256 amount) external {
        uint256 liquid = vault.reserves();
        if (liquid == 0) return;

        uint256 value = bound(amount, 1, liquid);

        vm.prank(operator);
        vault.borrow(value);

        ghostBorrowed += value;
    }

    function repay(uint256 amount) external {
        uint256 debt = vault.outstandingDebt();
        if (debt == 0) return;

        uint256 value = bound(amount, 1, debt);

        vm.deal(operator, operator.balance + value);
        vm.prank(operator);
        vault.repay{ value: value }();

        ghostRepaid += value;
    }

    // ---------------------------------------------------------------------
    // Governance / demo actions
    // ---------------------------------------------------------------------

    function recordLoss(uint256 amount) external {
        uint256 liquid = vault.reserves();
        if (liquid == 0) return;

        uint256 value = bound(amount, 1, liquid);

        vm.prank(owner);
        vault.recordLoss(value);

        ghostLosses += value;
    }

    function setMinCoverageBps(uint256 bps) external {
        uint256 value = bound(bps, 1, 10_000);

        vm.prank(owner);
        vault.setMinCoverageBps(value);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function userCount() external view returns (uint256) {
        return users.length;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }
}

/**
 * @title VaultInvariantTest
 * @notice Stateful invariants for the origin vault's accounting model.
 */
contract VaultInvariantTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant THRESHOLD_BPS = 8_000;

    OriginVault internal vault;
    OriginVaultHandler internal handler;

    address internal owner;
    address internal operator;

    function setUp() public {
        vm.chainId(BASE_SEPOLIA);

        owner = makeAddr("owner");
        operator = makeAddr("operator");

        vault = new OriginVault(owner, operator, THRESHOLD_BPS, makeAddr("lossRecipient"));
        handler = new OriginVaultHandler(vault, owner, operator);

        targetContract(address(handler));
        vm.deal(operator, 1_000 ether);
    }

    /// @dev The vault can only owe exactly what users deposited minus withdrawals.
    ///      reserves + outstandingDebt + realizedLosses == totalDeposits
    function invariant_SolvencyIdentity() public view {
        assertEq(
            vault.reserves() + vault.outstandingDebt() + handler.ghostLosses(),
            vault.totalDeposits(),
            "solvency identity broken"
        );
    }

    /// @dev On-chain liabilities and debt must match the handler's independent ledger.
    function invariant_LedgerMatchesGhosts() public view {
        assertEq(vault.totalDeposits(), handler.ghostDeposits() - handler.ghostWithdrawals(), "deposit ledger drift");
        assertEq(vault.outstandingDebt(), handler.ghostBorrowed() - handler.ghostRepaid(), "debt ledger drift");
    }

    /// @dev Internal reserves must always be fully backed by native ETH.
    function invariant_ReservesBackedByBalance() public view {
        assertEq(address(vault).balance, vault.reserves(), "reserves not backed");
    }

    /// @dev The breach flag is a pure function of the latest coverage assessment.
    function invariant_BreachedMatchesCoverage() public view {
        assertEq(vault.breached(), vault.healthBps() < vault.minCoverageBps(), "breach flag stale");
    }

    /// @dev Coverage can never exceed 100% without new value being donated.
    function invariant_HealthBounded() public view {
        assertLe(vault.healthBps(), 10_000, "health above 100%");
    }
}
