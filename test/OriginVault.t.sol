// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { OriginVault } from "../src/OriginVault.sol";
import { IOriginVault } from "../src/interfaces/IOriginVault.sol";
import { ReentrantBorrower } from "./mocks/ReentrantBorrower.sol";

contract OriginVaultTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant DEFAULT_THRESHOLD_BPS = 8_000;

    OriginVault internal vault;

    address internal owner;
    address internal operator;
    address internal alice;
    address internal bob;
    address internal lossRecipient;

    function setUp() public {
        vm.chainId(BASE_SEPOLIA);

        owner = makeAddr("owner");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        lossRecipient = makeAddr("lossRecipient");

        vault = new OriginVault(owner, operator, DEFAULT_THRESHOLD_BPS, lossRecipient);

        vm.deal(owner, 1_000 ether);
        vm.deal(operator, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        vault.deposit{ value: amount }();
    }

    function _borrow(uint256 amount) internal {
        vm.prank(operator);
        vault.borrow(amount);
    }

    // ---------------------------------------------------------------------
    // Construction / views
    // ---------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.operator(), operator);
        assertEq(vault.lossRecipient(), lossRecipient);
        assertEq(vault.minCoverageBps(), DEFAULT_THRESHOLD_BPS);
        assertEq(vault.totalDeposits(), 0);
        assertEq(vault.reserves(), 0);
        assertEq(vault.outstandingDebt(), 0);
        assertEq(vault.healthBps(), 10_000);
        assertFalse(vault.breached());
    }

    function test_ConstructorRejectsInvalidParameters() public {
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidAddress.selector));
        new OriginVault(owner, address(0), DEFAULT_THRESHOLD_BPS, lossRecipient);

        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidAddress.selector));
        new OriginVault(owner, operator, DEFAULT_THRESHOLD_BPS, address(0));

        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidBps.selector, 0));
        new OriginVault(owner, operator, 0, lossRecipient);

        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidBps.selector, 10_001));
        new OriginVault(owner, operator, 10_001, lossRecipient);
    }

    function test_OwnershipIsTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(alice);

        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), alice);

        vm.prank(alice);
        vault.acceptOwnership();

        assertEq(vault.owner(), alice);
        assertEq(vault.pendingOwner(), address(0));
    }

    // ---------------------------------------------------------------------
    // Deposits
    // ---------------------------------------------------------------------

    function test_DepositUpdatesAccounting() public {
        _deposit(alice, 100 ether);

        assertEq(vault.deposits(alice), 100 ether);
        assertEq(vault.totalDeposits(), 100 ether);
        assertEq(vault.reserves(), 100 ether);
        assertEq(address(vault).balance, 100 ether);
        assertEq(vault.healthBps(), 10_000);
        assertFalse(vault.breached());
    }

    function test_DepositEmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit OriginVault.Deposited(alice, 100 ether, 100 ether, 100 ether);

        _deposit(alice, 100 ether);
    }

    function test_DepositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(OriginVault.ZeroAmount.selector);
        vault.deposit{ value: 0 }();
    }

    // ---------------------------------------------------------------------
    // Withdrawals
    // ---------------------------------------------------------------------

    function test_WithdrawUpdatesAccounting() public {
        _deposit(alice, 100 ether);

        uint256 balanceBefore = alice.balance;

        vm.expectEmit(false, false, false, true, address(vault));
        emit OriginVault.Withdrawn(alice, 40 ether, 60 ether, 60 ether);

        vm.prank(alice);
        vault.withdraw(40 ether);

        assertEq(vault.deposits(alice), 60 ether);
        assertEq(vault.totalDeposits(), 60 ether);
        assertEq(vault.reserves(), 60 ether);
        assertEq(alice.balance, balanceBefore + 40 ether);
    }

    function test_WithdrawMoreThanDepositReverts() public {
        _deposit(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InsufficientDeposit.selector, 101 ether, 100 ether));
        vault.withdraw(101 ether);
    }

    function test_WithdrawMoreThanReservesReverts() public {
        _deposit(alice, 100 ether);
        _borrow(50 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InsufficientReserves.selector, 60 ether, 50 ether));
        vault.withdraw(60 ether);
    }

    function test_WithdrawZeroReverts() public {
        _deposit(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(OriginVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    // ---------------------------------------------------------------------
    // Borrow / repay
    // ---------------------------------------------------------------------

    function test_BorrowReducesCoverageAndEmitsBreach() public {
        _deposit(alice, 100 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOriginVault.InvariantBreached(70 ether, 100 ether, 7_000, DEFAULT_THRESHOLD_BPS);

        _borrow(30 ether);

        assertEq(vault.reserves(), 70 ether);
        assertEq(vault.outstandingDebt(), 30 ether);
        assertEq(vault.healthBps(), 7_000);
        assertTrue(vault.breached());
    }

    function test_BorrowOnlyOperator() public {
        _deposit(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.NotOperator.selector, alice));
        vault.borrow(1 ether);
    }

    function test_BorrowZeroReverts() public {
        _deposit(alice, 100 ether);

        vm.prank(operator);
        vm.expectRevert(OriginVault.ZeroAmount.selector);
        vault.borrow(0);
    }

    function test_BorrowMoreThanReservesReverts() public {
        _deposit(alice, 100 ether);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InsufficientReserves.selector, 101 ether, 100 ether));
        vault.borrow(101 ether);
    }

    function test_BorrowAtExactThresholdIsHealthy() public {
        _deposit(alice, 100 ether);

        _borrow(20 ether);

        assertEq(vault.healthBps(), 8_000);
        assertFalse(vault.breached());
    }

    function test_BorrowBelowThresholdBreaches() public {
        _deposit(alice, 100 ether);

        _borrow(20 ether);
        _borrow(1 wei);

        assertEq(vault.healthBps(), 7_999);
        assertTrue(vault.breached());
    }

    function test_RepayRestoresCoverageAndEmitsRestored() public {
        _deposit(alice, 100 ether);
        _borrow(30 ether);
        assertTrue(vault.breached());

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOriginVault.InvariantRestored(100 ether, 100 ether, 10_000);

        vm.prank(operator);
        vault.repay{ value: 30 ether }();

        assertEq(vault.outstandingDebt(), 0);
        assertEq(vault.reserves(), 100 ether);
        assertEq(vault.healthBps(), 10_000);
        assertFalse(vault.breached());
    }

    function test_RepayRefundsExcess() public {
        _deposit(alice, 100 ether);
        _borrow(30 ether);

        uint256 balanceBefore = operator.balance;

        vm.prank(operator);
        vault.repay{ value: 50 ether }();

        assertEq(vault.outstandingDebt(), 0);
        assertEq(vault.reserves(), 100 ether);
        assertEq(operator.balance, balanceBefore - 30 ether);
    }

    function test_RepayZeroReverts() public {
        vm.prank(operator);
        vm.expectRevert(OriginVault.ZeroAmount.selector);
        vault.repay{ value: 0 }();
    }

    function test_RepayWithNoDebtRefundsEverything() public {
        _deposit(alice, 100 ether);

        uint256 balanceBefore = operator.balance;

        vm.prank(operator);
        vault.repay{ value: 5 ether }();

        assertEq(vault.outstandingDebt(), 0);
        assertEq(vault.reserves(), 100 ether);
        assertEq(operator.balance, balanceBefore);
    }

    // ---------------------------------------------------------------------
    // Loss / recovery
    // ---------------------------------------------------------------------

    function test_RecordLossTriggersBreach() public {
        _deposit(alice, 100 ether);
        uint256 recipientBefore = lossRecipient.balance;

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOriginVault.InvariantBreached(50 ether, 100 ether, 5_000, DEFAULT_THRESHOLD_BPS);

        vm.prank(owner);
        vault.recordLoss(50 ether);

        assertEq(vault.reserves(), 50 ether);
        assertEq(vault.totalDeposits(), 100 ether);
        assertEq(vault.healthBps(), 5_000);
        assertTrue(vault.breached());
        assertEq(lossRecipient.balance, recipientBefore + 50 ether);
        assertEq(address(vault).balance, 50 ether);
    }

    function test_RecordLossOnlyOwner() public {
        _deposit(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert();
        vault.recordLoss(1 ether);
    }

    function test_RecordLossMoreThanReservesReverts() public {
        _deposit(alice, 100 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InsufficientReserves.selector, 101 ether, 100 ether));
        vault.recordLoss(101 ether);
    }

    function test_ForceCheckReEmitsBreach() public {
        _deposit(alice, 100 ether);
        _borrow(30 ether);

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOriginVault.InvariantBreached(70 ether, 100 ether, 7_000, DEFAULT_THRESHOLD_BPS);

        vault.forceCheck();
    }

    function test_ForceCheckDoesNothingWhenHealthy() public {
        _deposit(alice, 100 ether);

        vm.recordLogs();
        vault.forceCheck();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 0);
    }

    function test_DepositCanRestoreCoverage() public {
        _deposit(alice, 100 ether);
        _borrow(30 ether);
        assertTrue(vault.breached());

        vm.expectEmit(false, false, false, true, address(vault));
        emit IOriginVault.InvariantRestored(120 ether, 150 ether, 8_000);

        _deposit(alice, 50 ether);

        assertEq(vault.healthBps(), 8_000);
        assertFalse(vault.breached());
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function test_SetMinCoverageBpsTriggersBreachAndRecovery() public {
        _deposit(alice, 100 ether);
        _borrow(60 ether);

        // 40% coverage is healthy under the original 80% threshold? No: 40% < 80%.
        assertTrue(vault.breached());

        vm.prank(owner);
        vault.setMinCoverageBps(3_000);
        assertFalse(vault.breached());

        vm.prank(owner);
        vault.setMinCoverageBps(5_000);
        assertTrue(vault.breached());
    }

    function test_SetMinCoverageBpsRejectsInvalid() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidBps.selector, 0));
        vault.setMinCoverageBps(0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OriginVault.InvalidBps.selector, 10_001));
        vault.setMinCoverageBps(10_001);
    }

    function test_SetOperatorOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setOperator(bob);

        vm.prank(owner);
        vault.setOperator(bob);

        assertEq(vault.operator(), bob);
    }

    function test_SetLossRecipientOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setLossRecipient(bob);

        vm.prank(owner);
        vault.setLossRecipient(bob);

        assertEq(vault.lossRecipient(), bob);
    }

    // ---------------------------------------------------------------------
    // Reentrancy / fuzz
    // ---------------------------------------------------------------------

    function test_BorrowCannotReenter() public {
        _deposit(alice, 100 ether);

        ReentrantBorrower borrower = new ReentrantBorrower(vault);

        vm.prank(owner);
        vault.setOperator(address(borrower));

        vm.expectRevert(OriginVault.TransferFailed.selector);
        borrower.attack(10 ether);

        assertEq(vault.reserves(), 100 ether);
        assertEq(vault.outstandingDebt(), 0);
    }

    function testFuzz_DepositWithdrawConservesAccounting(uint96 depositAmount, uint96 withdrawAmount) public {
        uint256 depositValue = bound(uint256(depositAmount), 1, 1_000 ether);
        uint256 withdrawValue = bound(uint256(withdrawAmount), 1, depositValue);

        vm.deal(alice, depositValue);
        vm.prank(alice);
        vault.deposit{ value: depositValue }();

        vm.prank(alice);
        vault.withdraw(withdrawValue);

        assertEq(vault.deposits(alice), depositValue - withdrawValue);
        assertEq(vault.totalDeposits(), depositValue - withdrawValue);
        assertEq(vault.reserves(), depositValue - withdrawValue);
        assertEq(address(vault).balance, depositValue - withdrawValue);
    }

    function testFuzz_HealthNeverExceedsMax(uint96 depositAmount, uint96 borrowAmount) public {
        uint256 depositValue = bound(uint256(depositAmount), 1, 1_000 ether);
        uint256 borrowValue = bound(uint256(borrowAmount), 0, depositValue);

        vm.deal(alice, depositValue);
        vm.prank(alice);
        vault.deposit{ value: depositValue }();

        if (borrowValue > 0) {
            vm.prank(operator);
            vault.borrow(borrowValue);
        }

        assertLe(vault.healthBps(), 10_000);
        assertEq(vault.reserves() + vault.outstandingDebt(), depositValue);
    }
}
