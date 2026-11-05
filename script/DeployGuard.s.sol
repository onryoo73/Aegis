// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { InvariantGuardReactive } from "../src/InvariantGuardReactive.sol";

/**
 * @title DeployGuard
 * @notice Deploys the reactive invariant guard on Reactive Lasna and funds it with
 *         the chain's native token (lREACT) so subscriptions and callbacks can be paid.
 *
 * Usage:
 *   forge script script/DeployGuard.s.sol:DeployGuard \
 *     --rpc-url $LASNA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY, ORIGIN_VAULT
 * Optional env: OWNER, ORIGIN_CHAIN_ID, DEST_CHAIN_ID, BREACH_THRESHOLD_BPS,
 *               CALLBACK_GAS_LIMIT, GUARD_FUNDING_WEI, LASNA_CHAIN_ID
 */
contract DeployGuard is Script {
    function run() external returns (InvariantGuardReactive guard) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 expectedChainId = vm.envOr("LASNA_CHAIN_ID", uint256(5_318_007));
        require(block.chainid == expectedChainId, "DeployGuard: wrong chain");

        address owner_ = vm.envOr("OWNER", deployer);
        address originVault_ = vm.envAddress("ORIGIN_VAULT");
        uint256 originChainId_ = vm.envOr("ORIGIN_CHAIN_ID", uint256(84_532));
        uint256 destinationChainId_ = vm.envOr("DEST_CHAIN_ID", uint256(1_301));
        uint256 thresholdBps = vm.envOr("BREACH_THRESHOLD_BPS", uint256(8_000));
        uint64 gasLimit = uint64(vm.envOr("CALLBACK_GAS_LIMIT", uint256(500_000)));
        uint256 funding = vm.envOr("GUARD_FUNDING_WEI", uint256(0));

        vm.startBroadcast(deployerKey);
        guard = new InvariantGuardReactive{ value: funding }(
            originChainId_, originVault_, destinationChainId_, owner_, thresholdBps, gasLimit
        );
        vm.stopBroadcast();

        console2.log("InvariantGuardReactive", address(guard));
        console2.log("  originChainId", originChainId_);
        console2.log("  originVault", originVault_);
        console2.log("  destinationChainId", destinationChainId_);
        console2.log("  breachThresholdBps", thresholdBps);
        console2.log("  callbackGasLimit", gasLimit);
        console2.log("  funding", funding);
        console2.log("Set GUARD_ADDRESS to the address above before deploying the breaker.");
    }
}
