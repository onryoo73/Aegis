// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { InvariantGuardReactive } from "../src/InvariantGuardReactive.sol";

/**
 * @title ConfigureGuard
 * @notice Completes the guard <-> breaker wiring. Must run on Reactive Lasna
 *         from the guard owner's key.
 *
 * Usage:
 *   forge script script/ConfigureGuard.s.sol:ConfigureGuard \
 *     --rpc-url $LASNA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY, GUARD_ADDRESS, BREAKER_ADDRESS
 */
contract ConfigureGuard is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        InvariantGuardReactive guard = InvariantGuardReactive(payable(vm.envAddress("GUARD_ADDRESS")));
        address breaker = vm.envAddress("BREAKER_ADDRESS");

        require(breaker != address(0), "ConfigureGuard: BREAKER_ADDRESS is zero");

        vm.startBroadcast(deployerKey);
        guard.setCallbackRecipient(breaker);
        vm.stopBroadcast();

        console2.log("Guard callback recipient set to", breaker);
        console2.log("Guard is live. Fund it with lREACT if the balance is low.");
    }
}
