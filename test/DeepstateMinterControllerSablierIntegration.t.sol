// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SablierLockup} from "@sablier/lockup/src/SablierLockup.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

contract SablierComptrollerStub {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function calculateMinFeeWeiFor(uint8, address) external pure returns (uint256) {
        return 0;
    }
}

contract SablierLegacyRouterMock {
    mapping(bytes32 poolId => address hook) public poolHook;

    function setPoolHook(bytes32 poolId, address hook) external {
        poolHook[poolId] = hook;
    }

    function activeBookId(address token0, address token1) external pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1, uint256(0)));
    }

    function topOrder(bytes32, bool) external pure returns (uint32 nonce, uint160 soldAmount) {
        return (0, 0);
    }
}

contract SablierLegacyRewarderMock {
    address public immutable rewardToken;
    address public immutable deepstate;
    address public constant token0 = address(0x1000);
    address public constant token1 = address(0x2000);
    bytes32 public constant poolId = keccak256(abi.encode(token0, token1));

    constructor(address rewardToken_, address deepstate_) {
        rewardToken = rewardToken_;
        deepstate = deepstate_;
    }

    function rewardees(address) external pure returns (uint32 orderNonce, uint64 startedAt) {
        return (0, 0);
    }

    function totalAccrued(address token) external pure returns (uint96) {
        if (token == token0) return 70e18;
        if (token == token1) return 30e18;
        return 0;
    }
}

contract DeepstateMinterControllerSablierIntegrationTest is Test {
    uint256 internal constant MINT_CAP = 3_000_000_000e18;
    uint256 internal constant LEGACY_ENDOWMENT = 30e18;

    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    SablierLockup internal sablier;
    SablierLegacyRouterMock internal legacyRouter;
    SablierLegacyRewarderMock internal legacyRewarder;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        SablierComptrollerStub comptroller = new SablierComptrollerStub();
        sablier = new SablierLockup(address(comptroller), address(0));
        legacyRouter = new SablierLegacyRouterMock();
        legacyRewarder = new SablierLegacyRewarderMock(address(deep), address(legacyRouter));
        legacyRouter.setPoolHook(legacyRewarder.poolId(), address(legacyRewarder));
        minterController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.lockTokenAdministration();
    }

    function test_RealSablierV4LegacyEndowmentIsExactOneYearStream() public view {
        uint256 streamId = minterController.legacyEndowmentStreamId();

        assertEq(streamId, 1);
        assertTrue(minterController.legacyEndowmentCreated());
        assertEq(minterController.legacyToken0Accrued(), 70e18);
        assertEq(minterController.legacyToken1Accrued(), 30e18);
        assertEq(minterController.legacyEndowmentAmount(), LEGACY_ENDOWMENT);
        assertEq(minterController.grossIssued(), LEGACY_ENDOWMENT);
        assertEq(sablier.ownerOf(streamId), recipient);
        assertEq(sablier.getRecipient(streamId), recipient);
        assertEq(sablier.getSender(streamId), address(minterController));
        assertEq(address(sablier.getUnderlyingToken(streamId)), address(deep));
        assertEq(sablier.getDepositedAmount(streamId), LEGACY_ENDOWMENT);
        assertEq(sablier.getEndTime(streamId), sablier.getStartTime(streamId) + 365 days);
        assertEq(sablier.getCliffTime(streamId), 0);
        assertEq(sablier.getGranularity(streamId), 1);
        assertFalse(sablier.isCancelable(streamId));
        assertFalse(sablier.isTransferable(streamId));
    }

    function test_RealSablierV4StreamVestsLinearlyForOneYear() public {
        uint40 startTime = uint40(block.timestamp);
        uint128 vestingAmount = 30e18;
        uint256 streamId = minterController.mint(mintRecipient, 70e18);

        assertEq(streamId, 2);
        assertEq(sablier.ownerOf(streamId), recipient);
        assertEq(sablier.getRecipient(streamId), recipient);
        assertEq(sablier.getSender(streamId), address(minterController));
        assertEq(address(sablier.getUnderlyingToken(streamId)), address(deep));
        assertEq(sablier.getDepositedAmount(streamId), vestingAmount);
        assertEq(sablier.getStartTime(streamId), startTime);
        assertEq(sablier.getEndTime(streamId), startTime + 365 days);
        assertEq(sablier.getCliffTime(streamId), 0);
        assertEq(sablier.getGranularity(streamId), 1);
        assertFalse(sablier.isCancelable(streamId));
        assertFalse(sablier.isTransferable(streamId));
        assertEq(sablier.streamedAmountOf(streamId), 0);
        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(address(sablier)), LEGACY_ENDOWMENT + vestingAmount);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(deep.totalSupply(), LEGACY_ENDOWMENT + 70e18 + vestingAmount);
        assertEq(minterController.grossIssued(), LEGACY_ENDOWMENT + 70e18 + vestingAmount);

        vm.warp(startTime + 365 days / 2);
        assertEq(sablier.streamedAmountOf(streamId), vestingAmount / 2);
        vm.prank(recipient);
        uint128 firstWithdrawal = sablier.withdrawMax(streamId, recipient);
        assertEq(firstWithdrawal, vestingAmount / 2);
        assertEq(deep.balanceOf(recipient), vestingAmount / 2);

        vm.warp(startTime + 365 days);
        assertEq(sablier.streamedAmountOf(streamId), vestingAmount);
        vm.prank(recipient);
        uint128 finalWithdrawal = sablier.withdrawMax(streamId, recipient);
        assertEq(finalWithdrawal, vestingAmount / 2);
        assertEq(deep.balanceOf(recipient), vestingAmount);
        assertEq(deep.balanceOf(address(sablier)), LEGACY_ENDOWMENT);
        assertTrue(sablier.isDepleted(streamId));
    }

    function test_RealSablierV4StreamCannotBeCanceledOrTransferred() public {
        uint256 streamId = minterController.mint(mintRecipient, 70e18);

        vm.expectRevert();
        vm.prank(address(minterController));
        sablier.cancel(streamId);

        vm.expectRevert();
        vm.prank(recipient);
        sablier.transferFrom(recipient, mintRecipient, streamId);

        assertEq(sablier.ownerOf(streamId), recipient);
        assertEq(deep.balanceOf(address(sablier)), LEGACY_ENDOWMENT + 30e18);
    }

    function test_RealSablierConsumesOnlyNewlyMintedVestingAmount() public {
        uint256 preexistingBalance = 11e18;
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(minterController));
        deep.grantRole(tokenMinterRole, address(this));
        deep.mint(address(minterController), preexistingBalance);

        uint256 streamId = minterController.mint(mintRecipient, 70e18);

        assertEq(sablier.getDepositedAmount(streamId), 30e18);
        assertEq(deep.balanceOf(address(sablier)), LEGACY_ENDOWMENT + 30e18);
        assertEq(deep.balanceOf(address(minterController)), preexistingBalance);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(deep.totalSupply(), LEGACY_ENDOWMENT + preexistingBalance + 100e18);
    }
}
