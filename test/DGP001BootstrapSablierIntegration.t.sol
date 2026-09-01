// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SablierLockup} from "@sablier/lockup/src/SablierLockup.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DGP001Bootstrap} from "../src/DGP001Bootstrap.sol";
import {IDeepstateLegacyRewarder} from "../src/interfaces/IDeepstateLegacyRewarder.sol";

contract DGP001SablierComptrollerStub {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function calculateMinFeeWeiFor(uint8, address) external pure returns (uint256) {
        return 0;
    }
}

contract DGP001SablierLegacyRewarderStub is IDeepstateLegacyRewarder {
    address public immutable override token0;
    address public immutable override token1;
    uint96 private immutable _token0Accrued;
    uint96 private immutable _token1Accrued;

    constructor(address token0_, address token1_, uint96 token0Accrued_, uint96 token1Accrued_) {
        token0 = token0_;
        token1 = token1_;
        _token0Accrued = token0Accrued_;
        _token1Accrued = token1Accrued_;
    }

    function deepstate() external pure returns (address) {
        return address(0);
    }

    function rewardToken() external pure returns (address) {
        return address(0);
    }

    function poolId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function rewardees(address) external pure returns (uint32 orderNonce, uint64 startedAt) {
        return (0, 0);
    }

    function totalAccrued(address token) external view returns (uint96 accrued) {
        if (token == token0) return _token0Accrued;
        if (token == token1) return _token1Accrued;
        return 0;
    }
}

    /// @dev Models the identity and call order of the live Governor's atomic proposal execution.
    contract DGP001GovernorStyleExecutor {
        DeepstateToken public immutable deep;
        DGP001Bootstrap public immutable bootstrap;
        SablierLockup public immutable sablier;
        address public immutable recipient;

        constructor(DeepstateToken deep_, DGP001Bootstrap bootstrap_, SablierLockup sablier_, address recipient_) {
            deep = deep_;
            bootstrap = bootstrap_;
            sablier = sablier_;
            recipient = recipient_;
        }

        function executeEndowment() external returns (uint256 streamId) {
            return _executeEndowment(bootstrap.endowmentAmount());
        }

        function executeEndowmentWithDeposit(uint128 depositAmount) external returns (uint256 streamId) {
            return _executeEndowment(depositAmount);
        }

        function _executeEndowment(uint128 depositAmount) private returns (uint256 streamId) {
            bytes32 minterRole = deep.MINTER_ROLE();
            deep.grantRole(minterRole, address(bootstrap));
            bootstrap.mint();
            deep.revokeRole(minterRole, address(bootstrap));

            deep.approve(address(sablier), depositAmount);
            streamId = sablier.createWithDurationsLL(
                Lockup.CreateWithDurations({
                    sender: address(this),
                    recipient: recipient,
                    depositAmount: depositAmount,
                    token: IERC20(address(deep)),
                    cancelable: false,
                    transferable: false,
                    shape: "Deepstate Inc endowment"
                }),
                LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
                1 seconds,
                LockupLinear.Durations({cliff: 0, total: 365 days})
            );
        }
    }

    contract DGP001GovernorSablierIntegrationTest is Test {
        uint96 internal constant TOKEN0_ACCRUED = 600_000_000e18;
        uint96 internal constant TOKEN1_ACCRUED = 400_000_000e18;
        uint128 internal constant ENDOWMENT = 300_000_000e18;

        bytes32 internal constant CREATE_LOCKUP_LINEAR_STREAM_TOPIC = keccak256(
            "CreateLockupLinearStream(uint256,(address,address,address,uint128,address,bool,bool,(uint40,uint40),string),uint40,uint40,(uint128,uint128))"
        );

        address internal constant TOKEN0 = address(0x1000);
        address internal constant TOKEN1 = address(0x2000);
        address internal constant RECIPIENT = address(0xD33F);

        DeepstateToken internal deep;
        SablierLockup internal sablier;
        DGP001Bootstrap internal bootstrap;
        DGP001GovernorStyleExecutor internal governor;

        function setUp() public {
            deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
            sablier = new SablierLockup(address(new DGP001SablierComptrollerStub()), address(0));

            DGP001SablierLegacyRewarderStub legacyRewarder =
                new DGP001SablierLegacyRewarderStub(TOKEN0, TOKEN1, TOKEN0_ACCRUED, TOKEN1_ACCRUED);

            // The Bootstrap mints only to its immutable Governor, so predict the immediately following harness deployment.
            address predictedGovernor = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            bootstrap = new DGP001Bootstrap(predictedGovernor, address(deep), address(legacyRewarder));
            governor = new DGP001GovernorStyleExecutor(deep, bootstrap, sablier, RECIPIENT);
            assertEq(address(governor), predictedGovernor);

            deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(governor));
            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);
        }

        function testGovernorMulticallCreatesExactOneYearStreamThroughRealSablier() public {
            uint40 startTime = 1_800_000_000;
            vm.warp(startTime);
            vm.recordLogs();

            uint256 streamId = governor.executeEndowment();
            Vm.Log[] memory logs = vm.getRecordedLogs();

            assertEq(streamId, 1);
            assertEq(sablier.ownerOf(streamId), RECIPIENT);
            assertEq(sablier.getRecipient(streamId), RECIPIENT);
            assertEq(sablier.getSender(streamId), address(governor));
            assertEq(address(sablier.getUnderlyingToken(streamId)), address(deep));
            assertEq(uint256(sablier.getLockupModel(streamId)), uint256(Lockup.Model.LOCKUP_LINEAR));
            assertEq(sablier.getDepositedAmount(streamId), ENDOWMENT);
            assertEq(sablier.aggregateAmount(IERC20(address(deep))), ENDOWMENT);
            assertEq(sablier.getStartTime(streamId), startTime);
            assertEq(sablier.getEndTime(streamId), startTime + 365 days);
            assertEq(sablier.getCliffTime(streamId), 0);
            assertEq(sablier.getGranularity(streamId), 1 seconds);

            LockupLinear.UnlockAmounts memory unlockAmounts = sablier.getUnlockAmounts(streamId);
            assertEq(unlockAmounts.start, 0);
            assertEq(unlockAmounts.cliff, 0);
            assertFalse(sablier.isCancelable(streamId));
            assertFalse(sablier.isTransferable(streamId));
            assertEq(sablier.streamedAmountOf(streamId), 0);

            assertEq(deep.balanceOf(address(sablier)), ENDOWMENT);
            assertEq(deep.balanceOf(address(governor)), 0);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.allowance(address(governor), address(sablier)), 0);
            assertEq(deep.totalSupply(), ENDOWMENT);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));

            _assertSablierCreationEvent(logs, streamId, startTime);

            vm.expectRevert();
            vm.prank(address(governor));
            sablier.cancel(streamId);

            vm.expectRevert();
            vm.prank(RECIPIENT);
            sablier.transferFrom(RECIPIENT, address(0xBEEF), streamId);

            vm.warp(startTime + 365 days / 2);
            assertEq(sablier.streamedAmountOf(streamId), ENDOWMENT / 2);
            vm.warp(startTime + 365 days);
            assertEq(sablier.streamedAmountOf(streamId), ENDOWMENT);
        }

        function testSablierFailureRollsBackGrantMintRevokeAndApprovalAtomically() public {
            uint256 streamIdBefore = sablier.nextStreamId();

            vm.expectRevert();
            governor.executeEndowmentWithDeposit(ENDOWMENT + 1);

            assertEq(sablier.nextStreamId(), streamIdBefore);
            assertEq(deep.totalSupply(), 0);
            assertEq(deep.balanceOf(address(governor)), 0);
            assertEq(deep.balanceOf(address(sablier)), 0);
            assertEq(deep.allowance(address(governor), address(sablier)), 0);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));

            // The reverted batch did not consume the stream ID or poison the temporary-role sequence.
            assertEq(governor.executeEndowment(), streamIdBefore);
        }

        function _assertSablierCreationEvent(Vm.Log[] memory logs, uint256 streamId, uint40 startTime) private {
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(sablier) || logs[i].topics[0] != CREATE_LOCKUP_LINEAR_STREAM_TOPIC) {
                    continue;
                }

                assertEq(logs[i].topics[1], bytes32(streamId));
                (
                    Lockup.CreateEventCommon memory commonParams,
                    uint40 cliffTime,
                    uint40 granularity,
                    LockupLinear.UnlockAmounts memory unlockAmounts
                ) = abi.decode(logs[i].data, (Lockup.CreateEventCommon, uint40, uint40, LockupLinear.UnlockAmounts));

                assertEq(commonParams.funder, address(governor));
                assertEq(commonParams.sender, address(governor));
                assertEq(commonParams.recipient, RECIPIENT);
                assertEq(commonParams.depositAmount, ENDOWMENT);
                assertEq(address(commonParams.token), address(deep));
                assertFalse(commonParams.cancelable);
                assertFalse(commonParams.transferable);
                assertEq(commonParams.timestamps.start, startTime);
                assertEq(commonParams.timestamps.end, startTime + 365 days);
                assertEq(commonParams.shape, "Deepstate Inc endowment");
                assertEq(cliffTime, 0);
                assertEq(granularity, 1 seconds);
                assertEq(unlockAmounts.start, 0);
                assertEq(unlockAmounts.cliff, 0);
                return;
            }

            fail("Sablier CreateLockupLinearStream event not found");
        }
    }
