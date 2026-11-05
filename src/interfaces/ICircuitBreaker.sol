// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title ICircuitBreaker
 * @notice Destination-side interface consumed by adapters and by the reactive guard.
 * @dev The guard encodes `pause.selector` into the callback payload, guaranteeing
 *      that the on-chain function selector and the reactive payload cannot drift.
 */
interface ICircuitBreaker {
    error ProtocolPaused(uint256 pausedAt);

    /// @notice Emergency pause invoked by the Reactive Network callback proxy.
    /// @param reactive_ Reactive contract address injected by the callback proxy.
    /// @param breachId_ Deterministic identifier of the origin breach.
    /// @param healthBps_ Coverage ratio observed on the origin chain.
    /// @param reserves_ Origin reserves at the time of the breach.
    /// @param liabilities_ Origin liabilities at the time of the breach.
    /// @param originChainId_ Origin chain ID, checked against the immutable configuration.
    function pause(
        address reactive_,
        bytes32 breachId_,
        uint256 healthBps_,
        uint256 reserves_,
        uint256 liabilities_,
        uint256 originChainId_
    ) external;

    /// @notice True while the breaker is tripped.
    function paused() external view returns (bool);

    /// @notice Reverts with `ProtocolPaused` while the breaker is tripped.
    function requireOperational() external view;
}
