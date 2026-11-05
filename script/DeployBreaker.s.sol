// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { CircuitBreakerCallback } from "../src/CircuitBreakerCallback.sol";

/**
 * @title DeployBreaker
 * @notice Deploys the destination circuit breaker on Unichain Sepolia and funds it
 *         with ETH to pay for callback delivery.
 *
 * Usage:
 *   forge script script/DeployBreaker.s.sol:DeployBreaker \
 *     --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required env: PRIVATE_KEY, GUARD_ADDRESS
 * Optional env: OWNER, ORIGIN_CHAIN_ID, CALLBACK_PROXY, INITIAL_LTV_BPS,
 *               CALLBACK_FUNDING_WEI, DEST_CHAIN_ID
 */
contract DeployBreaker is Script {
    address internal constant DEFAULT_UNICHAIN_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    function run() external returns (CircuitBreakerCallback breaker) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 expectedChainId = vm.envOr("DEST_CHAIN_ID", uint256(1_301));
        require(block.chainid == expectedChainId, "DeployBreaker: wrong chain");

        address owner_ = vm.envOr("OWNER", deployer);
        address guard_ = vm.envAddress("GUARD_ADDRESS");
        uint256 originChainId_ = vm.envOr("ORIGIN_CHAIN_ID", uint256(84_532));
        address callbackProxy_ = vm.envOr("CALLBACK_PROXY", DEFAULT_UNICHAIN_CALLBACK_PROXY);
        uint256 initialLtvBps = vm.envOr("INITIAL_LTV_BPS", uint256(7_500));
        uint256 funding = vm.envOr("CALLBACK_FUNDING_WEI", uint256(0));

        vm.startBroadcast(deployerKey);
        breaker = new CircuitBreakerCallback{ value: funding }(
            IPayable(payable(callbackProxy_)), guard_, originChainId_, owner_, initialLtvBps
        );
        vm.stopBroadcast();

        console2.log("CircuitBreakerCallback", address(breaker));
        console2.log("  callbackProxy", callbackProxy_);
        console2.log("  authorizedGuard", guard_);
        console2.log("  originChainId", originChainId_);
        console2.log("  initialLtvBps", initialLtvBps);
        console2.log("  funding", funding);
        console2.log("Set BREAKER_ADDRESS to the address above, then run ConfigureGuard on Lasna.");
    }
}
