// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {DeepstateRewarder} from "deepstate-protocol/DeepstateRewarder.sol";
import {IBurnableERC20} from "deepstate-protocol/interfaces/IBurnableERC20.sol";

/// @title Deepstate Rewarder V2
/// @notice Extends the protocol rewarder with irreversible retirement and burning of remaining rewards.
/// @dev Ownable is inherited through DeepstateRewarder.
contract DeepstateRewarderV2 is DeepstateRewarder, ReentrancyGuard {
    /// @notice Whether this reward program has been permanently retired.
    bool public retired;

    event RewarderRetiredAndBalanceBurned(uint256 amount);
    event RetiredRewarderBalanceBurned(address indexed caller, uint256 amount);

    error RewarderRetired();
    error RewarderNotRetired();

    constructor(
        address owner_,
        address deepstate_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint96 sideEmissionCap_,
        uint32 emissionDuration_,
        uint160 token0StartQuantity_,
        uint160 token0MaxQuantity_,
        uint160 token1StartQuantity_,
        uint160 token1MaxQuantity_
    )
        DeepstateRewarder(
            owner_,
            deepstate_,
            rewardToken_,
            poolId_,
            token0_,
            token1_,
            sideEmissionCap_,
            emissionDuration_,
            token0StartQuantity_,
            token0MaxQuantity_,
            token1StartQuantity_,
            token1MaxQuantity_
        )
    {}

    /// @notice Permanently retire this rewarder and burn its entire reward-token balance.
    /// @dev Retirement disables accounting, claimant registration, and distribution forever. Ownership
    /// is renounced before the external token call, so neither reentrancy nor governance can reactivate this instance.
    function retireAndBurnBalance() external onlyOwner nonReentrant {
        _retire();
        _setOwner(address(0));
        uint256 amount = SafeTransferLib.balanceOf(rewardToken, address(this));
        IBurnableERC20(rewardToken).burn(amount);
        emit RewarderRetiredAndBalanceBurned(amount);
    }

    /// @notice Burn any reward tokens sent directly to this rewarder after its retirement.
    /// @dev Permissionless cleanup prevents mistaken or adversarial transfers from becoming permanently stranded.
    function burnRetiredBalance() external nonReentrant {
        if (!retired) revert RewarderNotRetired();
        uint256 amount = SafeTransferLib.balanceOf(rewardToken, address(this));
        IBurnableERC20(rewardToken).burn(amount);
        emit RetiredRewarderBalanceBurned(msg.sender, amount);
    }

    /// @dev Permanently stops hook accounting, claimant registration, and reward distribution.
    function _retire() internal {
        _beforeRewarderAction();
        retired = true;
    }

    /// @dev Applies the V2 lifecycle to every guarded entry point inherited from the protocol base.
    function _beforeRewarderAction() internal view override {
        if (retired) revert RewarderRetired();
    }
}
