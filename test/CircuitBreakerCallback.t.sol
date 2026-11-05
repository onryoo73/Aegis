// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Test } from "forge-std/Test.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { CircuitBreakerCallback } from "../src/CircuitBreakerCallback.sol";
import { ICircuitBreaker } from "../src/interfaces/ICircuitBreaker.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";
import { MockLendingMarket } from "./mocks/MockLendingMarket.sol";

contract CircuitBreakerCallbackTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant INITIAL_LTV_BPS = 7_500;
    address internal constant PROXY_ADDR = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    bytes32 internal constant BREACH_ID = keccak256("breach-1");
    bytes32 internal constant BREACH_ID_2 = keccak256("breach-2");

    MockCallbackProxy internal proxy;
    CircuitBreakerCallback internal breaker;
    MockLendingMarket internal market;

    address internal owner;
    address internal guard;
    address internal alice;

    function setUp() public {
        vm.chainId(UNICHAIN_SEPOLIA);

        deployCodeTo("MockCallbackProxy.sol:MockCallbackProxy", new bytes(0), PROXY_ADDR);
        proxy = MockCallbackProxy(payable(PROXY_ADDR));

        owner = makeAddr("owner");
        guard = makeAddr("guard");
        alice = makeAddr("alice");

        breaker = new CircuitBreakerCallback(IPayable(payable(PROXY_ADDR)), guard, BASE_SEPOLIA, owner, INITIAL_LTV_BPS);

        market = new MockLendingMarket(ICircuitBreaker(address(breaker)));

        vm.deal(owner, 10 ether);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _payload(
        bytes32 breachId_,
        uint256 healthBps_,
        uint256 reserves_,
        uint256 liabilities_,
        uint256 originChainId_
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ICircuitBreaker.pause.selector, address(0), breachId_, healthBps_, reserves_, liabilities_, originChainId_
        );
    }

    function _deliverDefault() internal {
        proxy.deliver(address(breaker), guard, _payload(BREACH_ID, 7_000, 70 ether, 100 ether, BASE_SEPOLIA));
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_InitialState() public view {
        assertEq(breaker.owner(), owner);
        assertEq(breaker.ORIGIN_CHAIN_ID(), BASE_SEPOLIA);
        assertEq(breaker._CALLBACK_SENDER(), guard);
        assertEq(address(breaker._SERVICE_PROVIDER()), PROXY_ADDR);
        assertEq(breaker.ltvBps(), INITIAL_LTV_BPS);
        assertEq(breaker.frozenLtvBps(), 0);
        assertEq(breaker.breachCount(), 0);
        assertFalse(breaker.paused());
        assertTrue(breaker.isOperational());
    }

    function test_ConstructorRejectsInvalidParameters() public {
        vm.expectRevert(CircuitBreakerCallback.InvalidAddress.selector);
        new CircuitBreakerCallback(IPayable(payable(address(0))), guard, BASE_SEPOLIA, owner, INITIAL_LTV_BPS);

        vm.expectRevert(CircuitBreakerCallback.InvalidAddress.selector);
        new CircuitBreakerCallback(IPayable(payable(PROXY_ADDR)), address(0), BASE_SEPOLIA, owner, INITIAL_LTV_BPS);

        vm.expectRevert(CircuitBreakerCallback.InvalidChainId.selector);
        new CircuitBreakerCallback(IPayable(payable(PROXY_ADDR)), guard, 0, owner, INITIAL_LTV_BPS);

        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerCallback.InvalidBps.selector, 10_001));
        new CircuitBreakerCallback(IPayable(payable(PROXY_ADDR)), guard, BASE_SEPOLIA, owner, 10_001);
    }

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    function test_PauseOnlyProxy() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY_ADDR));
        breaker.pause(guard, BREACH_ID, 7_000, 70 ether, 100 ether, BASE_SEPOLIA);
    }

    function test_PauseOnlyAuthorizedGuard() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, alice, guard));
        proxy.deliver(address(breaker), alice, _payload(BREACH_ID, 7_000, 70 ether, 100 ether, BASE_SEPOLIA));
    }

    // ---------------------------------------------------------------------
    // Pause behavior
    // ---------------------------------------------------------------------

    function test_PauseSetsStateAndEmits() public {
        vm.expectEmit(true, true, false, true, address(breaker));
        emit CircuitBreakerCallback.CircuitBreakerTriggered(
            BREACH_ID, guard, 7_000, 70 ether, 100 ether, BASE_SEPOLIA, INITIAL_LTV_BPS, block.timestamp
        );

        _deliverDefault();

        assertTrue(breaker.paused());
        assertEq(breaker.pausedAt(), block.timestamp);
        assertEq(breaker.frozenLtvBps(), INITIAL_LTV_BPS);
        assertEq(breaker.lastBreachId(), BREACH_ID);
        assertEq(breaker.breachCount(), 1);
        assertTrue(breaker.handledBreaches(BREACH_ID));
    }

    function test_DuplicateBreachIsSuppressed() public {
        _deliverDefault();
        assertEq(breaker.breachCount(), 1);

        vm.expectEmit(true, false, false, false, address(breaker));
        emit CircuitBreakerCallback.DuplicateBreachSuppressed(BREACH_ID);

        _deliverDefault();

        assertEq(breaker.breachCount(), 1);
        assertTrue(breaker.paused());
    }

    function test_DifferentBreachWhilePausedIsRecordedButIgnored() public {
        _deliverDefault();
        uint256 firstPausedAt = breaker.pausedAt();

        vm.expectEmit(true, false, false, true, address(breaker));
        emit CircuitBreakerCallback.PauseRequestIgnored(BREACH_ID_2, firstPausedAt);

        proxy.deliver(address(breaker), guard, _payload(BREACH_ID_2, 5_000, 50 ether, 100 ether, BASE_SEPOLIA));

        assertEq(breaker.breachCount(), 2);
        assertEq(breaker.lastBreachId(), BREACH_ID);
        assertEq(breaker.frozenLtvBps(), INITIAL_LTV_BPS);
        assertTrue(breaker.paused());
    }

    function test_WrongOriginChainRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerCallback.WrongOriginChain.selector, 1, BASE_SEPOLIA));
        proxy.deliver(address(breaker), guard, _payload(BREACH_ID, 7_000, 70 ether, 100 ether, 1));
    }

    function test_InvalidHealthBpsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerCallback.InvalidHealthBps.selector, 10_001));
        proxy.deliver(address(breaker), guard, _payload(BREACH_ID, 10_001, 70 ether, 100 ether, BASE_SEPOLIA));
    }

    // ---------------------------------------------------------------------
    // Parameter freeze / recovery
    // ---------------------------------------------------------------------

    function test_PauseFreezesLtvParameter() public {
        _deliverDefault();

        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerCallback.ParametersFrozen.selector, breaker.pausedAt()));
        vm.prank(owner);
        breaker.setLtvBps(8_000);
    }

    function test_RequireOperationalRevertsWhilePaused() public {
        market.setLtvBps(8_000);
        assertEq(market.ltvBps(), 8_000);

        _deliverDefault();

        vm.expectRevert(abi.encodeWithSelector(ICircuitBreaker.ProtocolPaused.selector, breaker.pausedAt()));
        market.setLtvBps(8_500);

        vm.expectRevert(abi.encodeWithSelector(ICircuitBreaker.ProtocolPaused.selector, breaker.pausedAt()));
        market.originateLoan();
    }

    function test_UnpauseRestoresOperationalState() public {
        _deliverDefault();
        assertTrue(breaker.paused());

        vm.warp(block.timestamp + 1 hours);

        vm.prank(owner);
        breaker.unpause();

        assertFalse(breaker.paused());
        assertTrue(breaker.isOperational());

        vm.prank(owner);
        breaker.setLtvBps(8_000);
        assertEq(breaker.ltvBps(), 8_000);

        market.setLtvBps(8_250);
        assertEq(market.ltvBps(), 8_250);
    }

    function test_UnpauseOnlyOwner() public {
        _deliverDefault();

        vm.prank(alice);
        vm.expectRevert();
        breaker.unpause();
    }

    function test_UnpauseWhenNotPausedReverts() public {
        vm.prank(owner);
        vm.expectRevert(CircuitBreakerCallback.NotPaused.selector);
        breaker.unpause();
    }

    function test_SetLtvOnlyOwnerAndBounded() public {
        vm.prank(alice);
        vm.expectRevert();
        breaker.setLtvBps(8_000);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerCallback.InvalidBps.selector, 10_001));
        breaker.setLtvBps(10_001);

        vm.prank(owner);
        breaker.setLtvBps(0);
        assertEq(breaker.ltvBps(), 0);
    }

    // ---------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------

    function test_ReceiveAcceptsFunding() public {
        (bool success,) = address(breaker).call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(address(breaker).balance, 1 ether);
    }

    function test_CoverDebt() public {
        proxy.setDebt(address(breaker), 0.5 ether);
        vm.deal(address(breaker), 1 ether);

        uint256 proxyBefore = PROXY_ADDR.balance;

        vm.expectEmit(false, false, false, true, address(breaker));
        emit CircuitBreakerCallback.DebtCovered(0.5 ether);

        breaker.coverDebt();

        assertEq(PROXY_ADDR.balance, proxyBefore + 0.5 ether);
        assertEq(address(breaker).balance, 0.5 ether);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    function testFuzz_PauseUnpause(bytes32 breachId_, uint96 healthBps_, uint96 reserves_) public {
        uint256 health = bound(uint256(healthBps_), 0, 10_000);
        uint256 reserveValue = bound(uint256(reserves_), 0, 1_000 ether);

        proxy.deliver(address(breaker), guard, _payload(breachId_, health, reserveValue, 1_000 ether, BASE_SEPOLIA));

        assertTrue(breaker.paused());
        assertEq(breaker.lastBreachId(), breachId_);
        assertEq(breaker.breachCount(), 1);

        vm.prank(owner);
        breaker.unpause();

        assertFalse(breaker.paused());
    }

    function testFuzz_DuplicateBreachNeverIncrementsTwice(bytes32 breachId_) public {
        proxy.deliver(address(breaker), guard, _payload(breachId_, 7_000, 70 ether, 100 ether, BASE_SEPOLIA));
        proxy.deliver(address(breaker), guard, _payload(breachId_, 7_000, 70 ether, 100 ether, BASE_SEPOLIA));

        assertEq(breaker.breachCount(), 1);
    }
}
