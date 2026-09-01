// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical legacy Rewarder interface used to validate replacement state and snapshot cumulative emissions.
interface IDeepstateLegacyRewarder {
    function deepstate() external view returns (address);
    function rewardToken() external view returns (address);
    function poolId() external view returns (bytes32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt);
    function totalAccrued(address token) external view returns (uint96 accrued);
}
