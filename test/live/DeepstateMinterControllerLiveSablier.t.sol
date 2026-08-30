// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SablierLockup} from "@sablier/lockup/src/SablierLockup.sol";

import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";
import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

contract LiveSablierLegacyRouterMock {
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

contract LiveSablierLegacyRewarderMock {
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
        return token == token0 || token == token1 ? 2 : 0;
    }
}

/// @notice Compatibility test against the actual Sablier Lockup deployed on Robinhood Chain.
/// @dev Set ROBINHOOD_RPC_URL to run. The ordinary offline suite deliberately skips this network-dependent test.
contract DeepstateMinterControllerLiveSablierTest is Test {
    address internal mintRecipient = makeAddr("liveSablierMintRecipient");

    function test_LiveLockupCreatesAndVestsTheExactProductionStream() public {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true, "ROBINHOOD_RPC_URL is not configured");
            return;
        }

        vm.createSelectFork(rpcUrl);
        assertEq(block.chainid, DeepstateAddresses.CHAIN_ID);
        assertEq(DeepstateAddresses.SABLIER_LOCKUP.codehash, DeepstateAddresses.SABLIER_LOCKUP_CODEHASH);
        assertNotEq(SablierLockup(DeepstateAddresses.SABLIER_LOCKUP).nativeToken(), DeepstateAddresses.DEEP);

        DeepstateToken deep = new DeepstateToken(address(this), "Compatibility DEEP", "cDEEP");
        LiveSablierLegacyRouterMock legacyRouter = new LiveSablierLegacyRouterMock();
        LiveSablierLegacyRewarderMock legacyRewarder =
            new LiveSablierLegacyRewarderMock(address(deep), address(legacyRouter));
        legacyRouter.setPoolHook(legacyRewarder.poolId(), address(legacyRewarder));
        DeepstateMinterController controller = new DeepstateMinterController(
            address(this),
            address(deep),
            DeepstateAddresses.SABLIER_LOCKUP,
            address(legacyRewarder),
            DeepstateAddresses.DEEPSTATE_INC_SAFE,
            1_000_000e18,
            1_000_000e18
        );
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(controller));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        controller.lockTokenAdministration();

        SablierLockup lockup = SablierLockup(DeepstateAddresses.SABLIER_LOCKUP);
        uint256 expectedStreamId = lockup.nextStreamId();
        uint40 startTime = uint40(block.timestamp);
        uint256 streamId = controller.mint(mintRecipient, 70e18);

        assertEq(streamId, expectedStreamId);
        assertEq(lockup.ownerOf(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getRecipient(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getSender(streamId), address(controller));
        assertEq(address(lockup.getUnderlyingToken(streamId)), address(deep));
        assertEq(lockup.getDepositedAmount(streamId), 30e18);
        assertEq(lockup.getStartTime(streamId), startTime);
        assertEq(lockup.getEndTime(streamId), startTime + 365 days);
        assertEq(lockup.getCliffTime(streamId), 0);
        assertEq(lockup.getGranularity(streamId), 1);
        assertFalse(lockup.isCancelable(streamId));
        assertFalse(lockup.isTransferable(streamId));
        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(DeepstateAddresses.SABLIER_LOCKUP), 30e18 + 1);

        vm.warp(startTime + 365 days / 2);
        assertEq(lockup.streamedAmountOf(streamId), 15e18);
        vm.prank(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.withdrawMax(streamId, DeepstateAddresses.DEEPSTATE_INC_SAFE), 15e18);

        vm.expectRevert();
        vm.prank(address(controller));
        lockup.cancel(streamId);
        vm.expectRevert();
        vm.prank(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        lockup.transferFrom(DeepstateAddresses.DEEPSTATE_INC_SAFE, mintRecipient, streamId);
    }
}
