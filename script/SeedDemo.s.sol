// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { OriginVault } from "../src/OriginVault.sol";

/**
 * @title SeedDemo
 * @notice Optional demo setup on Base Sepolia: deposits ETH and (optionally) has the
 *         operator borrow, so the vault starts with realistic liquidity.
 *
 * Usage:
 *   forge script script/SeedDemo.s.sol:SeedDemo \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY, ORIGIN_VAULT
 * Optional env: DEMO_DEPOSIT_WEI, DEMO_BORROW_WEI
 */
contract SeedDemo is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        OriginVault vault = OriginVault(payable(vm.envAddress("ORIGIN_VAULT")));

        uint256 depositAmount = vm.envOr("DEMO_DEPOSIT_WEI", uint256(0));
        uint256 borrowAmount = vm.envOr("DEMO_BORROW_WEI", uint256(0));

        if (depositAmount > 0) {
            vm.startBroadcast(deployerKey);
            vault.deposit{ value: depositAmount }();
            vm.stopBroadcast();
            console2.log("Deposited wei", depositAmount);
        }

        if (borrowAmount > 0) {
            vm.startBroadcast(deployerKey);
            vault.borrow(borrowAmount);
            vm.stopBroadcast();
            console2.log("Borrowed wei", borrowAmount);
        }

        console2.log("reserves", vault.reserves());
        console2.log("totalDeposits", vault.totalDeposits());
        console2.log("healthBps", vault.healthBps());
        console2.log("breached", vault.breached());
    }
}
