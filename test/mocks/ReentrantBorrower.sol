// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { OriginVault } from "../../src/OriginVault.sol";

/**
 * @title ReentrantBorrower
 * @notice Attempts to re-enter the vault while receiving borrowed ETH.
 */
contract ReentrantBorrower {
    OriginVault public immutable vault;
    uint256 public reentryAmount;
    bool public reentered;

    constructor(OriginVault vault_) {
        vault = vault_;
    }

    function attack(uint256 amount_) external {
        reentryAmount = amount_;
        vault.borrow(amount_);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            vault.borrow(reentryAmount);
        }
    }
}
