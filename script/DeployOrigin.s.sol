// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { OriginVault } from "../src/OriginVault.sol";

/**
 * @title DeployOrigin
 * @notice Deploys the origin vault on Base Sepolia.
 *
 * Usage:
 *   forge script script/DeployOrigin.s.sol:DeployOrigin \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY
 * Optional env: OWNER, OPERATOR, LOSS_RECIPIENT, BREACH_THRESHOLD_BPS, ORIGIN_CHAIN_ID
 */
contract DeployOrigin is Script {
    function run() external returns (OriginVault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 expectedChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(84_532));
        require(block.chainid == expectedChainId, "DeployOrigin: wrong chain");

        address owner_ = vm.envOr("OWNER", deployer);
        address operator_ = vm.envOr("OPERATOR", deployer);
        address lossRecipient_ = vm.envOr("LOSS_RECIPIENT", owner_);
        uint256 thresholdBps = vm.envOr("BREACH_THRESHOLD_BPS", uint256(8_000));

        vm.startBroadcast(deployerKey);
        vault = new OriginVault(owner_, operator_, thresholdBps, lossRecipient_);
        vm.stopBroadcast();

        console2.log("OriginVault", address(vault));
        console2.log("  owner", owner_);
        console2.log("  operator", operator_);
        console2.log("  lossRecipient", lossRecipient_);
        console2.log("  minCoverageBps", thresholdBps);
        console2.log("Set ORIGIN_VAULT to the address above before deploying the guard.");
    }
}
