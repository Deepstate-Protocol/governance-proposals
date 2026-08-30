// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";

contract DeepstateRewarderPrecisionRegressionTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint256 internal constant INTERVAL = 5 hours;

    DeepstateRewarder internal rewarder;

    function setUp() public {
        rewarder = new DeepstateRewarder(
            address(this),
            address(0x3000),
            address(0x4000),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            500_000_000e18,
            395 days,
            37e18,
            37_000_000e18,
            1e6,
            1_000_000e6
        );
    }

    function test_OneSecondFragmentationAtMaximumGrowthHasNegligibleRoundingLossForStockScale() public view {
        _assertFragmentationLossIsNegligible(TOKEN0, 37e18);
    }

    function test_OneSecondFragmentationAtMaximumGrowthHasNegligibleRoundingLossForUSDGScale() public view {
        _assertFragmentationLossIsNegligible(TOKEN1, 1e6);
    }

    function _assertFragmentationLossIsNegligible(address token, uint160 amount) internal view {
        uint256 whole = rewarder.previewRewardAtElapsed(token, 0, INTERVAL, amount);
        uint256 fragmented;
        for (uint256 second; second < INTERVAL; ++second) {
            fragmented += rewarder.previewRewardAtElapsed(token, second, second + 1, amount);
        }

        assertLe(fragmented, whole);
        assertLe(whole - fragmented, 10_000);
        assertGt(fragmented, whole * 999_999 / 1_000_000);
    }
}
