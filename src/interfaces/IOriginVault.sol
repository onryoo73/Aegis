// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title IOriginVault
 * @notice Interface shared by the origin-side vault and the reactive guard.
 * @dev The guard subscribes to `InvariantBreached` and uses the event selector
 *      directly, so the event signature must only ever be changed here.
 */
interface IOriginVault {
    /// @notice Emitted when coverage crosses below the configured minimum.
    /// @param reserves Liquid reserves currently held by the vault.
    /// @param liabilities Total user claims against the vault.
    /// @param healthBps Reserves / liabilities expressed in basis points.
    /// @param thresholdBps Configured minimum coverage in basis points.
    event InvariantBreached(uint256 reserves, uint256 liabilities, uint256 healthBps, uint256 thresholdBps);

    /// @notice Emitted when coverage returns to at least the configured minimum.
    event InvariantRestored(uint256 reserves, uint256 liabilities, uint256 healthBps);

    /// @notice Current coverage ratio in basis points (10_000 = 100%).
    function healthBps() external view returns (uint256);

    /// @notice Minimum coverage ratio in basis points.
    function minCoverageBps() external view returns (uint256);

    /// @notice Whether the vault is currently below its coverage threshold.
    function breached() external view returns (bool);
}
