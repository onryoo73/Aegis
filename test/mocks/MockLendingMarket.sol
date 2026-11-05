// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { ICircuitBreaker } from "../../src/interfaces/ICircuitBreaker.sol";

/**
 * @title MockLendingMarket
 * @notice Destination-side adapter used to prove the breaker actually freezes work.
 */
contract MockLendingMarket {
    ICircuitBreaker public immutable breaker;
    uint256 public ltvBps = 7_500;

    constructor(ICircuitBreaker breaker_) {
        breaker = breaker_;
    }

    function setLtvBps(uint256 newLtvBps) external {
        breaker.requireOperational();
        ltvBps = newLtvBps;
    }

    function originateLoan() external view returns (bool) {
        breaker.requireOperational();
        return true;
    }
}
