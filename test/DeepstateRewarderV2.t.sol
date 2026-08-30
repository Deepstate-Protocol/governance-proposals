// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {DeepstateRewarder} from "../src/DeepstateRewarder.sol";
import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

contract ReentrantBurnToken {
    mapping(address account => uint256 balance) public balanceOf;
    address public reentryTarget;
    bytes public reentryData;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function burn(uint256 amount) external {
        address target = reentryTarget;
        if (target != address(0)) {
            (bool success, bytes memory result) = target.call(reentryData);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
        balanceOf[msg.sender] -= amount;
    }
}

contract DeepstateRewarderV2Test is Test {
    uint96 internal constant SIDE_CAP = 500_000_000e18;
    address internal constant DEEPSTATE = address(0x1000);
    address internal constant TOKEN0 = address(0x2000);
    address internal constant TOKEN1 = address(0x3000);

    DeepstateToken internal rewardToken;
    DeepstateRewarderV2 internal rewarder;
    address internal alice = makeAddr("alice");

    function setUp() public {
        rewardToken = new DeepstateToken(address(this), "Reward", "RWD");
        rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
        rewarder = new DeepstateRewarderV2(
            address(this),
            DEEPSTATE,
            address(rewardToken),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            395 days,
            1e18,
            5_000e18,
            1e6,
            1_000_000e6
        );
        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);
    }

    function test_InheritsRewarderConfiguration() public view {
        assertEq(rewarder.owner(), address(this));
        assertEq(rewarder.deepstate(), DEEPSTATE);
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.token0(), TOKEN0);
        assertEq(rewarder.token1(), TOKEN1);
        assertEq(rewarder.sideEmissionCap(), SIDE_CAP);
    }

    function test_OwnerCanPermanentlyRetireAndBurnEntireLiveRewardBalance() public {
        uint256 funding = rewardToken.balanceOf(address(rewarder));

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewarderRetiredAndBalanceBurned(funding);
        rewarder.retireAndBurnBalance();

        assertTrue(rewarder.retired());
        assertEq(rewarder.owner(), address(0));
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }

    function test_NonOwnerCannotRetireActiveRewarderOrBurnItsBalance() public {
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        rewarder.retireAndBurnBalance();

        vm.expectRevert(DeepstateRewarderV2.RewarderNotRetired.selector);
        vm.prank(alice);
        rewarder.burnRetiredBalance();

        assertFalse(rewarder.retired());
        assertEq(rewarder.owner(), address(this));
        assertEq(rewardToken.balanceOf(address(rewarder)), fundingBefore);
        assertEq(rewardToken.totalSupply(), fundingBefore);
    }

    function test_RetirementEmitsZeroForEmptyRewarder() public {
        uint256 funding = rewardToken.balanceOf(address(rewarder));
        vm.prank(address(rewarder));
        rewardToken.burn(funding);

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewarderRetiredAndBalanceBurned(0);
        rewarder.retireAndBurnBalance();

        assertEq(funding, uint256(SIDE_CAP) * 2);
        assertTrue(rewarder.retired());
        assertEq(rewarder.owner(), address(0));
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }

    function test_RetirementPermanentlyGatesAllRewardStateTransitions() public {
        bytes32 poolId = rewarder.poolId();
        rewarder.retireAndBurnBalance();

        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        vm.prank(DEEPSTATE);
        rewarder.execute(poolId, bytes32(uint256(1)), TOKEN0, 1e18, 1);

        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        rewarder.registerClaimant(bytes32(uint256(1)), bytes32(uint256(1)));

        DeepstateRewarder.OrderReference[] memory orders = new DeepstateRewarder.OrderReference[](1);
        orders[0] = DeepstateRewarder.OrderReference({bookId: bytes32(uint256(1)), order: bytes32(uint256(1))});
        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        rewarder.registerClaimants(orders);

        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        rewarder.distributeRewards(bytes32(uint256(1)), bytes32(uint256(1)), TOKEN0);

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](1);
        claims[0] =
            DeepstateRewarder.RewardClaim({bookId: bytes32(uint256(1)), order: bytes32(uint256(1)), token: TOKEN0});
        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        rewarder.distributeRewardsBatch(claims);

        rewardToken.mint(address(rewarder), 1e18);
        vm.expectRevert(DeepstateRewarder.RewarderRetired.selector);
        rewarder.distributeRewards(bytes32(uint256(1)), bytes32(uint256(1)), TOKEN0);
        assertEq(rewardToken.balanceOf(address(rewarder)), 1e18);
    }

    function test_AnyoneCanBurnTokensDirectlySentAfterRetirement() public {
        rewarder.retireAndBurnBalance();
        rewardToken.mint(address(rewarder), 7e18);

        vm.expectEmit(true, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RetiredRewarderBalanceBurned(alice, 7e18);
        vm.prank(alice);
        rewarder.burnRetiredBalance();

        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);

        vm.expectEmit(true, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RetiredRewarderBalanceBurned(alice, 0);
        vm.prank(alice);
        rewarder.burnRetiredBalance();
    }

    function test_RetirementCannotBeRepeatedAfterOwnershipIsRenounced() public {
        rewarder.retireAndBurnBalance();

        vm.expectRevert(Ownable.Unauthorized.selector);
        rewarder.retireAndBurnBalance();
    }

    function test_MaliciousRewardTokenCannotReenterRetirementOrPartiallyCommitState() public {
        ReentrantBurnToken maliciousToken = new ReentrantBurnToken();
        DeepstateRewarderV2 maliciousRewarder = new DeepstateRewarderV2(
            address(this),
            DEEPSTATE,
            address(maliciousToken),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            395 days,
            1e18,
            5_000e18,
            1e6,
            1_000_000e6
        );
        maliciousToken.mint(address(maliciousRewarder), 1e18);
        maliciousToken.setReentry(
            address(maliciousRewarder), abi.encodeCall(DeepstateRewarderV2.burnRetiredBalance, ())
        );

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        maliciousRewarder.retireAndBurnBalance();

        assertFalse(maliciousRewarder.retired());
        assertEq(maliciousRewarder.owner(), address(this));
        assertEq(maliciousToken.balanceOf(address(maliciousRewarder)), 1e18);

        maliciousToken.setReentry(address(0), "");
        maliciousRewarder.retireAndBurnBalance();
        assertTrue(maliciousRewarder.retired());
        assertEq(maliciousRewarder.owner(), address(0));
        assertEq(maliciousToken.balanceOf(address(maliciousRewarder)), 0);
    }
}
