// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { OriginVault } from "../src/OriginVault.sol";

/**
 * @title SimulateBreach
 * @notice Triggers the demo invariant break on Base Sepolia. Either records a loss
 *         (owner-only demo hook) or has the operator borrow, reducing coverage.
 *
 * Usage:
 *   DEMO_LOSS_WEI=50000000000000000 \
 *   forge script script/SimulateBreach.s.sol:SimulateBreach \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY, ORIGIN_VAULT
 * Optional env: DEMO_LOSS_WEI, DEMO_BORROW_WEI
 */
contract SimulateBreach is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        OriginVault vault = OriginVault(payable(vm.envAddress("ORIGIN_VAULT")));

        uint256 lossAmount = vm.envOr("DEMO_LOSS_WEI", uint256(0));
        uint256 borrowAmount = vm.envOr("DEMO_BORROW_WEI", uint256(0));

        require(lossAmount > 0 || borrowAmount > 0, "SimulateBreach: set DEMO_LOSS_WEI or DEMO_BORROW_WEI");

        vm.startBroadcast(deployerKey);

        if (lossAmount > 0) {
            vault.recordLoss(lossAmount);
            console2.log("recordLoss wei", lossAmount);
        }

        if (borrowAmount > 0) {
            vault.borrow(borrowAmount);
            console2.log("borrow wei", borrowAmount);
        }

        vm.stopBroadcast();

        console2.log("reserves", vault.reserves());
        console2.log("totalDeposits", vault.totalDeposits());
        console2.log("healthBps", vault.healthBps());
        console2.log("breached", vault.breached());
        console2.log("Watch Lasna for BreachConfirmed and Unichain for CircuitBreakerTriggered.");
    }
}
