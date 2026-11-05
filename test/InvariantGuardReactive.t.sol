// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test } from "forge-std/Test.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { InvariantGuardReactive } from "../src/InvariantGuardReactive.sol";
import { IOriginVault } from "../src/interfaces/IOriginVault.sol";
import { ICircuitBreaker } from "../src/interfaces/ICircuitBreaker.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

contract InvariantGuardReactiveTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant LASNA = 5318007;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant THRESHOLD_BPS = 8_000;
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;

    MockSystemContract internal system;
    InvariantGuardReactive internal guard;

    address internal owner;
    address internal alice;
    address internal vault;
    address internal recipient;

    function setUp() public {
        vm.chainId(LASNA);

        deployCodeTo("MockSystemContract.sol:MockSystemContract", new bytes(0), SYSTEM_ADDR);
        system = MockSystemContract(payable(SYSTEM_ADDR));

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        vault = makeAddr("originVault");
        recipient = makeAddr("callbackRecipient");

        guard = new InvariantGuardReactive(
            BASE_SEPOLIA, vault, UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT
        );

        vm.prank(owner);
        guard.setCallbackRecipient(recipient);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _log(uint256 reserves_, uint256 liabilities_, uint256 blockNumber_, uint256 logIndex_)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        uint256 reportedHealth = liabilities_ == 0 ? 10_000 : (reserves_ * 10_000) / liabilities_;
        return _logWithHealth(reserves_, liabilities_, reportedHealth, blockNumber_, logIndex_);
    }

    function _logWithHealth(
        uint256 reserves_,
        uint256 liabilities_,
        uint256 reportedHealth_,
        uint256 blockNumber_,
        uint256 logIndex_
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: vault,
            topic0: uint256(IOriginVault.InvariantBreached.selector),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(reserves_, liabilities_, reportedHealth_, THRESHOLD_BPS),
            blockNumber: blockNumber_,
            opCode: 1,
            blockHash: uint256(keccak256(abi.encode("block", blockNumber_))),
            txHash: uint256(keccak256(abi.encode("tx", blockNumber_, logIndex_))),
            logIndex: logIndex_
        });
    }

    function _deliver(IReactive.LogRecord memory log_) internal {
        system.deliver(address(guard), log_);
    }

    function _decodePausePayload(bytes memory payload_)
        internal
        pure
        returns (
            address injected,
            bytes32 breachId,
            uint256 healthBps,
            uint256 reserves,
            uint256 liabilities,
            uint256 originChainId
        )
    {
        require(payload_.length == 4 + 6 * 32, "unexpected payload length");

        bytes memory args = new bytes(payload_.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload_[i + 4];
        }

        return abi.decode(args, (address, bytes32, uint256, uint256, uint256, uint256));
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_ConstructorSubscribesToVaultBreachEvent() public view {
        assertEq(system.subscriptionCount(), 1);

        MockSystemContract.Subscription memory sub = system.getSubscription(0);
        assertEq(sub.subscriber, address(guard));
        assertEq(sub.chainId, BASE_SEPOLIA);
        assertEq(sub.contractAddress, vault);
        assertEq(sub.topic0, uint256(IOriginVault.InvariantBreached.selector));
        assertEq(sub.topic1, REACTIVE_IGNORE);
        assertEq(sub.topic2, REACTIVE_IGNORE);
        assertEq(sub.topic3, REACTIVE_IGNORE);
    }

    function test_ConstructorRejectsInvalidParameters() public {
        vm.expectRevert(InvariantGuardReactive.InvalidChainId.selector);
        new InvariantGuardReactive(0, vault, UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT);

        vm.expectRevert(InvariantGuardReactive.InvalidChainId.selector);
        new InvariantGuardReactive(BASE_SEPOLIA, vault, BASE_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT);

        vm.expectRevert(InvariantGuardReactive.InvalidAddress.selector);
        new InvariantGuardReactive(BASE_SEPOLIA, address(0), UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(InvariantGuardReactive.InvalidBps.selector, 0));
        new InvariantGuardReactive(BASE_SEPOLIA, vault, UNICHAIN_SEPOLIA, owner, 0, CALLBACK_GAS_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(InvariantGuardReactive.InvalidBps.selector, 10_001));
        new InvariantGuardReactive(BASE_SEPOLIA, vault, UNICHAIN_SEPOLIA, owner, 10_001, CALLBACK_GAS_LIMIT);

        vm.expectRevert(InvariantGuardReactive.InvalidGasLimit.selector);
        new InvariantGuardReactive(BASE_SEPOLIA, vault, UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, 0);
    }

    function test_InitialConfiguration() public view {
        assertEq(guard.ORIGIN_CHAIN_ID(), BASE_SEPOLIA);
        assertEq(guard.ORIGIN_VAULT(), vault);
        assertEq(guard.DESTINATION_CHAIN_ID(), UNICHAIN_SEPOLIA);
        assertEq(guard.callbackRecipient(), recipient);
        assertEq(guard.breachThresholdBps(), THRESHOLD_BPS);
        assertEq(guard.callbackGasLimit(), CALLBACK_GAS_LIMIT);
        assertEq(guard.cooldownSeconds(), 30);
        assertTrue(guard.active());
        assertEq(guard.breachCount(), 0);
    }

    // ---------------------------------------------------------------------
    // Authorization / filtering
    // ---------------------------------------------------------------------

    function test_ReactOnlySystem() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);

        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM_ADDR));
        guard.react(log_);
    }

    function test_ReactIgnoresWrongChain() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);
        log_.chainId = 1;

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
        assertEq(guard.breachCount(), 0);
    }

    function test_ReactIgnoresWrongContract() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);
        log_.contractAddress = alice;

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactIgnoresWrongTopic() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);
        log_.topic0 = uint256(keccak256("Wrong(uint256)"));

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactIgnoresWrongOpCode() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);
        log_.opCode = 2;

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactIgnoresMalformedData() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 1, 0);
        log_.data = abi.encode(uint256(70 ether), uint256(100 ether));

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactIgnoresZeroLiabilities() public {
        IReactive.LogRecord memory log_ = _logWithHealth(0, 0, 0, 1, 0);

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactIgnoresHealthyStateEvenIfReportedBreached() public {
        // Actual coverage is 100%, but the event lies and claims 50%.
        IReactive.LogRecord memory log_ = _logWithHealth(100 ether, 100 ether, 5_000, 1, 0);

        _deliver(log_);

        assertEq(system.callbackCount(), 0);
    }

    function test_ReactFiresOnUnhealthyStateEvenIfReportedHealthy() public {
        // Actual coverage is 50%, but the event lies and claims 99.99%.
        IReactive.LogRecord memory log_ = _logWithHealth(50 ether, 100 ether, 9_999, 1, 0);

        _deliver(log_);

        assertEq(system.callbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.getLastCallback();
        (,, uint256 healthBps, uint256 reserves, uint256 liabilities,) = _decodePausePayload(cfg.payload);

        assertEq(healthBps, 5_000);
        assertEq(reserves, 50 ether);
        assertEq(liabilities, 100 ether);
    }

    function test_ReactIgnoresStaleOriginBlock() public {
        _deliver(_log(70 ether, 100 ether, 100, 0));
        assertEq(system.callbackCount(), 1);

        _deliver(_log(70 ether, 100 ether, 99, 1));
        assertEq(system.callbackCount(), 1);
    }

    // ---------------------------------------------------------------------
    // Callback construction
    // ---------------------------------------------------------------------

    function test_ReactRequestsCorrectCallback() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 100, 0);

        _deliver(log_);

        assertEq(system.callbackCount(), 1);

        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.getLastCallback();
        assertEq(cfg.chainId, UNICHAIN_SEPOLIA);
        assertEq(cfg.recipient, recipient);
        assertEq(cfg.gasLimit, CALLBACK_GAS_LIMIT);
        assertEq(bytes4(cfg.payload), ICircuitBreaker.pause.selector);

        (
            address injected,
            bytes32 breachId,
            uint256 healthBps,
            uint256 reserves,
            uint256 liabilities,
            uint256 originChainId
        ) = _decodePausePayload(cfg.payload);

        assertEq(injected, address(0), "payload must reserve the injected address");
        assertEq(healthBps, 7_000);
        assertEq(reserves, 70 ether);
        assertEq(liabilities, 100 ether);
        assertEq(originChainId, BASE_SEPOLIA);

        bytes32 expectedBreachId = keccak256(abi.encode(BASE_SEPOLIA, vault, uint256(100), log_.txHash, uint256(0)));
        assertEq(breachId, expectedBreachId);
        assertTrue(guard.handledBreaches(breachId));
        assertEq(guard.breachCount(), 1);
        assertEq(guard.lastOriginBlock(), 100);
    }

    function test_ReactEmitsBreachConfirmed() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 100, 0);
        bytes32 expectedBreachId = keccak256(abi.encode(BASE_SEPOLIA, vault, uint256(100), log_.txHash, uint256(0)));

        vm.expectEmit(true, false, false, true, address(guard));
        emit InvariantGuardReactive.BreachConfirmed(expectedBreachId, 7_000, 70 ether, 100 ether, 100, log_.txHash);

        _deliver(log_);
    }

    function test_DuplicateBreachDoesNotRequestTwice() public {
        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, 100, 0);

        _deliver(log_);
        _deliver(log_);

        assertEq(system.callbackCount(), 1);
        assertEq(guard.breachCount(), 1);
    }

    function test_CooldownPreventsSpam() public {
        vm.warp(1_000_000);

        _deliver(_log(70 ether, 100 ether, 100, 0));
        assertEq(system.callbackCount(), 1);

        vm.warp(1_000_010);
        _deliver(_log(70 ether, 100 ether, 101, 0));
        assertEq(system.callbackCount(), 1);

        vm.warp(1_000_030);
        _deliver(_log(70 ether, 100 ether, 102, 0));
        assertEq(system.callbackCount(), 2);
    }

    function test_InactiveGuardDoesNotFire() public {
        vm.prank(owner);
        guard.setActive(false);

        _deliver(_log(70 ether, 100 ether, 100, 0));
        assertEq(system.callbackCount(), 0);

        vm.prank(owner);
        guard.setActive(true);

        _deliver(_log(70 ether, 100 ether, 101, 0));
        assertEq(system.callbackCount(), 1);
    }

    function test_MissingRecipientReverts() public {
        InvariantGuardReactive fresh = new InvariantGuardReactive(
            BASE_SEPOLIA, vault, UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT
        );

        vm.expectRevert(InvariantGuardReactive.CallbackRecipientNotSet.selector);
        system.deliver(address(fresh), _log(70 ether, 100 ether, 1, 0));
    }

    // ---------------------------------------------------------------------
    // Governance
    // ---------------------------------------------------------------------

    function test_OwnerCanUpdateConfiguration() public {
        address newRecipient = makeAddr("newRecipient");

        vm.startPrank(owner);
        guard.setCallbackRecipient(newRecipient);
        guard.setBreachThresholdBps(9_000);
        guard.setCallbackGasLimit(700_000);
        guard.setCooldownSeconds(120);
        guard.setActive(false);
        vm.stopPrank();

        assertEq(guard.callbackRecipient(), newRecipient);
        assertEq(guard.breachThresholdBps(), 9_000);
        assertEq(guard.callbackGasLimit(), 700_000);
        assertEq(guard.cooldownSeconds(), 120);
        assertFalse(guard.active());
    }

    function test_OnlyOwnerCanUpdateConfiguration() public {
        vm.startPrank(alice);

        vm.expectRevert();
        guard.setCallbackRecipient(alice);

        vm.expectRevert();
        guard.setBreachThresholdBps(9_000);

        vm.expectRevert();
        guard.setCallbackGasLimit(700_000);

        vm.expectRevert();
        guard.setCooldownSeconds(120);

        vm.expectRevert();
        guard.setActive(false);

        vm.stopPrank();
    }

    function test_OwnerCanDisableGuard() public {
        vm.prank(owner);
        guard.setActive(false);

        _deliver(_log(70 ether, 100 ether, 1, 0));
        assertEq(system.callbackCount(), 0);
        assertFalse(guard.active());
    }

    // ---------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------

    function test_ReceiveAndCoverDebt() public {
        system.setDebt(address(guard), 0.5 ether);
        vm.deal(address(guard), 1 ether);

        uint256 systemBefore = SYSTEM_ADDR.balance;

        vm.expectEmit(false, false, false, true, address(guard));
        emit InvariantGuardReactive.DebtCovered(0.5 ether);

        guard.coverDebt();

        assertEq(SYSTEM_ADDR.balance, systemBefore + 0.5 ether);
        assertEq(address(guard).balance, 0.5 ether);
    }

    function test_ReceiveAcceptsFunding() public {
        vm.deal(address(this), 1 ether);

        (bool success,) = address(guard).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(guard).balance, 1 ether);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_CallbackOnlyBelowThreshold(uint96 reserves_, uint96 liabilities_) public {
        uint256 reserveValue = bound(uint256(reserves_), 1, 1_000 ether);
        uint256 liabilityValue = bound(uint256(liabilities_), 1, 1_000 ether);
        uint256 healthBps = (reserveValue * 10_000) / liabilityValue;

        _deliver(_log(reserveValue, liabilityValue, 1, 0));

        if (healthBps < THRESHOLD_BPS) {
            assertEq(system.callbackCount(), 1);
        } else {
            assertEq(system.callbackCount(), 0);
        }
    }

    function testFuzz_BreachIdIsDeterministic(uint256 blockNumber_, uint256 logIndex_) public {
        vm.assume(blockNumber_ > 0);

        IReactive.LogRecord memory log_ = _log(70 ether, 100 ether, blockNumber_, logIndex_);
        _deliver(log_);

        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.getLastCallback();
        (, bytes32 breachId,,,,) = _decodePausePayload(cfg.payload);

        bytes32 expected = keccak256(abi.encode(BASE_SEPOLIA, vault, blockNumber_, log_.txHash, logIndex_));
        assertEq(breachId, expected);
    }
}
