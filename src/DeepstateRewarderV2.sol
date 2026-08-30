// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {DeepstateRewarder} from "./DeepstateRewarder.sol";
import {IBurnableERC20} from "deepstate-protocol/interfaces/IBurnableERC20.sol";

/// @title Deepstate Rewarder V2
/// @notice Extends the pinned rewarder with irreversible retirement and burning of remaining rewards.
/// @dev Ownable is inherited through DeepstateRewarder.
contract DeepstateRewarderV2 is DeepstateRewarder {
    event RewarderRetiredAndBalanceBurned(uint256 amount);

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
    /// is renounced after the burn, so neither the factory nor governance can reactivate this instance.
    function retireAndBurnBalance() external onlyOwner {
        _retire();
        uint256 amount = SafeTransferLib.balanceOf(rewardToken, address(this));
        IBurnableERC20(rewardToken).burn(amount);
        _setOwner(address(0));
        emit RewarderRetiredAndBalanceBurned(amount);
    }
}
