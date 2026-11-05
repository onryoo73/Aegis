// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { OriginVault } from "../src/OriginVault.sol";
import { InvariantGuardReactive } from "../src/InvariantGuardReactive.sol";
import { CircuitBreakerCallback } from "../src/CircuitBreakerCallback.sol";
import { IOriginVault } from "../src/interfaces/IOriginVault.sol";
import { ICircuitBreaker } from "../src/interfaces/ICircuitBreaker.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";
import { MockLendingMarket } from "./mocks/MockLendingMarket.sol";

/**
 * @title EndToEndTest
 * @notice Exercises the full Base Sepolia -> Reactive Lasna -> Unichain Sepolia loop
 *         in a single Foundry EVM: vault event, reactive callback request, proxy
 *         delivery, circuit breaker pause, adapter freeze, and manual recovery.
 *
 * @dev Foundry keeps one state database while `vm.chainId` only mutates the value
 *      returned by `block.chainid`. That lets us co-locate all three "chains" in a
 *      single test while still exercising the real chain-ID checks in the contracts.
 *      The canonical system contract and callback proxy addresses are populated with
 *      mocks via `deployCodeTo`, so the libraries' hardcoded addresses work unchanged.
 */
contract EndToEndTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant LASNA = 5_318_007;
    uint256 internal constant UNICHAIN_SEPOLIA = 1_301;
    uint256 internal constant THRESHOLD_BPS = 8_000;
    uint256 internal constant INITIAL_LTV_BPS = 7_500;
    uint64 internal constant CALLBACK_GAS_LIMIT = 500_000;

    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    MockSystemContract internal system;
    MockCallbackProxy internal proxy;
    OriginVault internal vault;
    InvariantGuardReactive internal guard;
    CircuitBreakerCallback internal breaker;
    MockLendingMarket internal market;

    address internal owner;
    address internal operator;
    address internal alice;
    address internal lossRecipient;

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        lossRecipient = makeAddr("lossRecipient");

        vm.deal(operator, 1_000 ether);
        vm.deal(alice, 1_000 ether);

        // --- Base Sepolia: origin vault -----------------------------------
        vm.chainId(BASE_SEPOLIA);
        vault = new OriginVault(owner, operator, THRESHOLD_BPS, lossRecipient);

        // --- Reactive Lasna: guard + system contract ----------------------
        vm.chainId(LASNA);
        deployCodeTo("MockSystemContract.sol:MockSystemContract", new bytes(0), SYSTEM_ADDR);
        system = MockSystemContract(payable(SYSTEM_ADDR));

        guard = new InvariantGuardReactive(
            BASE_SEPOLIA, address(vault), UNICHAIN_SEPOLIA, owner, THRESHOLD_BPS, CALLBACK_GAS_LIMIT
        );

        // --- Unichain Sepolia: breaker + proxy + adapter ------------------
        vm.chainId(UNICHAIN_SEPOLIA);
        deployCodeTo("MockCallbackProxy.sol:MockCallbackProxy", new bytes(0), CALLBACK_PROXY);
        proxy = MockCallbackProxy(payable(CALLBACK_PROXY));

        breaker = new CircuitBreakerCallback(
            IPayable(payable(CALLBACK_PROXY)), address(guard), BASE_SEPOLIA, owner, INITIAL_LTV_BPS
        );
        market = new MockLendingMarket(ICircuitBreaker(address(breaker)));

        // --- Wire the guard to the breaker --------------------------------
        vm.prank(owner);
        guard.setCallbackRecipient(address(breaker));

        vm.chainId(BASE_SEPOLIA);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        vault.deposit{ value: amount }();
    }

    /// @dev Replays a recorded EVM log as a Reactive `LogRecord` and delivers it.
    function _deliverBreachLog(Vm.Log[] memory logs_) internal returns (bytes32 breachId, bytes memory payload) {
        IReactive.LogRecord memory record;

        bool found;
        for (uint256 i = 0; i < logs_.length; i++) {
            if (
                logs_[i].emitter == address(vault)
                    && uint256(logs_[i].topics[0]) == uint256(IOriginVault.InvariantBreached.selector)
            ) {
                record = IReactive.LogRecord({
                    chainId: BASE_SEPOLIA,
                    contractAddress: address(vault),
                    topic0: uint256(logs_[i].topics[0]),
                    topic1: logs_[i].topics.length > 1 ? uint256(logs_[i].topics[1]) : 0,
                    topic2: logs_[i].topics.length > 2 ? uint256(logs_[i].topics[2]) : 0,
                    topic3: logs_[i].topics.length > 3 ? uint256(logs_[i].topics[3]) : 0,
                    data: logs_[i].data,
                    blockNumber: block.number,
                    opCode: 1,
                    blockHash: uint256(blockhash(block.number - 1)),
                    txHash: uint256(keccak256(abi.encode("e2e-tx", block.number, i))),
                    logIndex: i
                });
                found = true;
                break;
            }
        }

        require(found, "EndToEnd: no InvariantBreached log recorded");

        system.deliver(address(guard), record);

        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.getLastCallback();
        payload = cfg.payload;
        (, breachId,,,,) = _decodePausePayload(payload);
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
        require(payload_.length == 4 + 6 * 32, "EndToEnd: unexpected payload length");

        bytes memory args = new bytes(payload_.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload_[i + 4];
        }

        return abi.decode(args, (address, bytes32, uint256, uint256, uint256, uint256));
    }

    // ---------------------------------------------------------------------
    // Happy path: breach -> callback -> pause -> adapter freeze
    // ---------------------------------------------------------------------

    function test_FullBreachToPauseLoop() public {
        _deposit(alice, 100 ether);

        vm.recordLogs();
        vm.prank(owner);
        vault.recordLoss(50 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bytes32 breachId, bytes memory payload) = _deliverBreachLog(logs);

        // Guard requested exactly one callback for the destination chain.
        assertEq(system.callbackCount(), 1);
        ISystemContract.CallbackConfiguration_V_1_0 memory cfg = system.getLastCallback();
        assertEq(cfg.chainId, UNICHAIN_SEPOLIA);
        assertEq(cfg.recipient, address(breaker));
        assertEq(cfg.gasLimit, CALLBACK_GAS_LIMIT);
        assertEq(bytes4(payload), ICircuitBreaker.pause.selector);

        // Payload carries the recomputed coverage, not the event's claim.
        (
            address injected,
            bytes32 payloadBreachId,
            uint256 healthBps,
            uint256 reserves,
            uint256 liabilities,
            uint256 originChainId
        ) = _decodePausePayload(payload);
        assertEq(injected, address(0));
        assertEq(payloadBreachId, breachId);
        assertEq(healthBps, 5_000);
        assertEq(reserves, 50 ether);
        assertEq(liabilities, 100 ether);
        assertEq(originChainId, BASE_SEPOLIA);

        // The proxy delivers the callback on Unichain Sepolia.
        vm.chainId(UNICHAIN_SEPOLIA);
        proxy.deliver(address(breaker), address(guard), payload);

        assertTrue(breaker.paused());
        assertEq(breaker.lastBreachId(), breachId);
        assertEq(breaker.breachCount(), 1);
        assertEq(breaker.frozenLtvBps(), INITIAL_LTV_BPS);
        assertEq(breaker.ORIGIN_CHAIN_ID(), BASE_SEPOLIA);

        // Destination side is now frozen.
        assertFalse(breaker.isOperational());
        vm.expectRevert(abi.encodeWithSelector(ICircuitBreaker.ProtocolPaused.selector, breaker.pausedAt()));
        market.originateLoan();

        // Duplicate deliveries are idempotent.
        proxy.deliver(address(breaker), address(guard), payload);
        assertEq(breaker.breachCount(), 1);
        assertTrue(breaker.paused());

        // Governance reviews the incident and restores operations.
        uint256 pausedAt = breaker.pausedAt();
        vm.warp(pausedAt + 1 hours);
        vm.prank(owner);
        breaker.unpause();

        assertFalse(breaker.paused());
        assertTrue(market.originateLoan());
        assertEq(breaker.pausedAt(), pausedAt);
    }

    // ---------------------------------------------------------------------
    // Boundary behavior
    // ---------------------------------------------------------------------

    function test_HealthyVaultProducesNoCallback() public {
        vm.recordLogs();
        _deposit(alice, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                uint256(logs[i].topics[0]) != uint256(IOriginVault.InvariantBreached.selector),
                "unexpected breach event"
            );
        }

        assertEq(system.callbackCount(), 0);
        assertEq(guard.breachCount(), 0);
    }

    function test_ExactThresholdProducesNoCallback() public {
        _deposit(alice, 100 ether);

        // Borrowing 20% leaves exactly 80% coverage, which is still healthy.
        vm.recordLogs();
        vm.prank(operator);
        vault.borrow(20 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                uint256(logs[i].topics[0]) != uint256(IOriginVault.InvariantBreached.selector),
                "breach emitted at exact threshold"
            );
        }

        assertEq(system.callbackCount(), 0);
    }

    function test_UnhealthyEventIsRecomputedByGuard() public {
        _deposit(alice, 100 ether);

        // Borrow 30% -> 70% coverage, below the 80% threshold.
        vm.recordLogs();
        vm.prank(operator);
        vault.borrow(30 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bytes32 breachId, bytes memory payload) = _deliverBreachLog(logs);

        (, bytes32 payloadBreachId, uint256 healthBps, uint256 reserves, uint256 liabilities,) =
            _decodePausePayload(payload);

        assertEq(payloadBreachId, breachId);
        assertEq(healthBps, 7_000);
        assertEq(reserves, 70 ether);
        assertEq(liabilities, 100 ether);

        vm.chainId(UNICHAIN_SEPOLIA);
        proxy.deliver(address(breaker), address(guard), payload);
        assertTrue(breaker.paused());
    }

    function test_RecoveryAfterBreachDoesNotAutoUnpause() public {
        _deposit(alice, 100 ether);

        vm.recordLogs();
        vm.prank(owner);
        vault.recordLoss(50 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (, bytes memory payload) = _deliverBreachLog(logs);

        vm.chainId(UNICHAIN_SEPOLIA);
        proxy.deliver(address(breaker), address(guard), payload);
        assertTrue(breaker.paused());

        // Origin coverage recovers, but v1 requires a human to unpause.
        // 50 + 150 = 200 reserves against 250 liabilities = exactly 80%.
        vm.chainId(BASE_SEPOLIA);
        _deposit(alice, 150 ether);
        assertFalse(vault.breached());

        vm.chainId(UNICHAIN_SEPOLIA);
        assertTrue(breaker.paused());
    }

    // ---------------------------------------------------------------------
    // Authentication
    // ---------------------------------------------------------------------

    function test_CallbackFromUnknownReactiveContractReverts() public {
        _deposit(alice, 100 ether);

        vm.recordLogs();
        vm.prank(owner);
        vault.recordLoss(50 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bytes32 breachId, bytes memory payload) = _deliverBreachLog(logs);

        vm.chainId(UNICHAIN_SEPOLIA);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, alice, address(guard)));
        proxy.deliver(address(breaker), alice, payload);

        assertFalse(breaker.paused());
        assertFalse(breaker.handledBreaches(breachId));
    }

    function test_DirectPauseFromEoaReverts() public {
        vm.chainId(UNICHAIN_SEPOLIA);

        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), CALLBACK_PROXY));
        breaker.pause(address(guard), keccak256("breach"), 5_000, 50 ether, 100 ether, BASE_SEPOLIA);
    }
}
