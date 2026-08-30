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

    function testFuzz_PreviewIsBoundedAndMonotonicAcrossSupportedScales(
        uint8 decimalsSeed,
        uint32 ratioSeed,
        uint32 startUnitsSeed,
        uint32 intervalStartSeed,
        uint32 intervalLengthSeed,
        uint160 smallerAmountSeed,
        uint160 largerAmountSeed
    ) public {
        uint8 decimals = decimalsSeed % 3 == 0 ? 6 : decimalsSeed % 3 == 1 ? 8 : 18;
        uint256 unit = 10 ** decimals;
        uint256 startQuantity = bound(uint256(startUnitsSeed), 1, 10_000) * unit;
        uint256 growth = bound(uint256(ratioSeed), 1_000, 1_000_000);
        uint256 maxQuantity = startQuantity * growth;

        DeepstateRewarder fuzzRewarder = _rewarder(uint160(startQuantity), uint160(maxQuantity));
        uint256 intervalStart = bound(uint256(intervalStartSeed), 0, fuzzRewarder.emissionDuration() - 1);
        uint256 intervalEnd =
            intervalStart + bound(uint256(intervalLengthSeed), 1, fuzzRewarder.emissionDuration() - intervalStart);
        uint160 smallerAmount = uint160(bound(uint256(smallerAmountSeed), 1, maxQuantity));
        uint160 largerAmount = uint160(bound(uint256(largerAmountSeed), smallerAmount, maxQuantity));

        uint256 intervalBudget = fuzzRewarder.cumulativeEmissionsAtElapsed(intervalEnd)
            - fuzzRewarder.cumulativeEmissionsAtElapsed(intervalStart);
        uint256 smallerReward = fuzzRewarder.previewRewardAtElapsed(TOKEN0, intervalStart, intervalEnd, smallerAmount);
        uint256 largerReward = fuzzRewarder.previewRewardAtElapsed(TOKEN0, intervalStart, intervalEnd, largerAmount);

        assertLe(smallerReward, largerReward);
        assertLe(largerReward, intervalBudget);
    }

    function testFuzz_PartitioningCannotMateriallyChangeRewardsAcrossSupportedScales(
        uint8 decimalsSeed,
        uint32 ratioSeed,
        uint32 startUnitsSeed,
        uint32 intervalStartSeed,
        uint32 intervalLengthSeed,
        uint160 amountSeed
    ) public {
        uint8 decimals = decimalsSeed % 3 == 0 ? 6 : decimalsSeed % 3 == 1 ? 8 : 18;
        uint256 unit = 10 ** decimals;
        uint256 startQuantity = bound(uint256(startUnitsSeed), 1, 10_000) * unit;
        uint256 growth = bound(uint256(ratioSeed), 1_000, 1_000_000);
        uint256 maxQuantity = startQuantity * growth;

        DeepstateRewarder fuzzRewarder = _rewarder(uint160(startQuantity), uint160(maxQuantity));
        uint256 intervalStart = bound(uint256(intervalStartSeed), 0, 30 days - 1);
        uint256 intervalLength = bound(uint256(intervalLengthSeed), 8, 7 days);
        uint256 intervalEnd = intervalStart + intervalLength;
        uint160 amount = uint160(bound(uint256(amountSeed), 1, maxQuantity));
        uint256 whole = fuzzRewarder.previewRewardAtElapsed(TOKEN0, intervalStart, intervalEnd, amount);

        uint256 partitioned;
        uint256 cursor = intervalStart;
        for (uint256 i; i < 8; ++i) {
            uint256 next = i == 7 ? intervalEnd : intervalStart + intervalLength * (i + 1) / 8;
            partitioned += fuzzRewarder.previewRewardAtElapsed(TOKEN0, cursor, next, amount);
            cursor = next;
        }

        assertLe(partitioned, whole);
        // Eight independently rounded intervals may lose dust, but the loss must stay below the larger of
        // one micro-DEEP or ten parts per million of the unsplit reward.
        uint256 permittedLoss = whole / 100_000;
        if (permittedLoss < 1e12) permittedLoss = 1e12;
        assertLe(whole - partitioned, permittedLoss);
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

    function _rewarder(uint160 startQuantity, uint160 maxQuantity) internal returns (DeepstateRewarder fuzzRewarder) {
        fuzzRewarder = new DeepstateRewarder(
            address(this),
            address(0x3000),
            address(0x4000),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            500_000_000e18,
            395 days,
            startQuantity,
            maxQuantity,
            startQuantity,
            maxQuantity
        );
    }
}
