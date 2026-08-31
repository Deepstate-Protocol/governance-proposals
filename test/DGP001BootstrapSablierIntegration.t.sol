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
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {IDeepstateLegacyRewarder} from "../src/interfaces/IDeepstateLegacyRewarder.sol";

contract DGP001BootstrapSablierComptrollerStub {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function calculateMinFeeWeiFor(uint8, address) external pure returns (uint256) {
        return 0;
    }
}

contract DGP001BootstrapSablierRouterStub {
    bytes32 internal immutable _poolId;
    address internal _hook;

    constructor(bytes32 poolId_) {
        _poolId = poolId_;
    }

    function setHook(address hook_) external {
        _hook = hook_;
    }

    function poolHook(bytes32 poolId) external view returns (address) {
        return poolId == _poolId ? _hook : address(0);
    }

    function activeBookId(address, address) external pure returns (bytes32) {
        return bytes32(0);
    }

    function topOrder(bytes32, bool) external pure returns (uint32 nonce, uint160 soldAmount) {
        return (0, 0);
    }
}

contract DGP001BootstrapSablierLegacyRewarderStub is IDeepstateLegacyRewarder {
    address public immutable override deepstate;
    address public immutable override rewardToken;
    bytes32 public immutable override poolId;
    address public immutable override token0;
    address public immutable override token1;

    uint96 internal immutable _token0Accrued;
    uint96 internal immutable _token1Accrued;

    constructor(
        address deepstate_,
        address rewardToken_,
        address token0_,
        address token1_,
        uint96 token0Accrued_,
        uint96 token1Accrued_
    ) {
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        token0 = token0_;
        token1 = token1_;
        poolId = keccak256(abi.encode(token0_, token1_));
        _token0Accrued = token0Accrued_;
        _token1Accrued = token1Accrued_;
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

    contract DGP001BootstrapSablierIntegrationTest is Test {
        uint256 internal constant INITIAL_SUPPLY = 1_000_000_000e18;
        uint96 internal constant TOKEN0_ACCRUED = 600_000_000e18;
        uint96 internal constant TOKEN1_ACCRUED = 400_000_000e18;
        uint256 internal constant ENDOWMENT = 300_000_000e18;
        uint256 internal constant MINT_CAP = 3_000_000_000e18;

        bytes32 internal constant CREATE_LOCKUP_LINEAR_STREAM_TOPIC = keccak256(
            "CreateLockupLinearStream(uint256,(address,address,address,uint128,address,bool,bool,(uint40,uint40),string),uint40,uint40,(uint128,uint128))"
        );

        address internal constant TOKEN0 = address(0x1000);
        address internal constant TOKEN1 = address(0x2000);
        address internal constant RECIPIENT = address(0xD33F);

        DeepstateToken internal deep;
        SablierLockup internal sablier;
        DGP001Bootstrap internal bootstrap;

        function setUp() public {
            deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
            sablier = new SablierLockup(address(new DGP001BootstrapSablierComptrollerStub()), address(0));

            DeepstateMinterController minterController = new DeepstateMinterController(
                address(this), address(deep), address(sablier), RECIPIENT, MINT_CAP, MINT_CAP
            );

            bytes32 poolId = keccak256(abi.encode(TOKEN0, TOKEN1));
            DGP001BootstrapSablierRouterStub router = new DGP001BootstrapSablierRouterStub(poolId);
            DGP001BootstrapSablierLegacyRewarderStub legacyRewarder = new DGP001BootstrapSablierLegacyRewarderStub(
                address(router), address(deep), TOKEN0, TOKEN1, TOKEN0_ACCRUED, TOKEN1_ACCRUED
            );
            router.setHook(address(legacyRewarder));

            bootstrap = new DGP001Bootstrap(address(this), address(minterController), address(legacyRewarder));

            deep.grantRole(deep.MINTER_ROLE(), address(this));
            deep.mint(address(this), INITIAL_SUPPLY);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
        }

        function testExecuteCreatesExactProductionStreamThroughRealSablier() public {
            uint40 startTime = 1_800_000_000;
            vm.warp(startTime);
            vm.recordLogs();

            uint256 streamId = bootstrap.execute();
            Vm.Log[] memory logs = vm.getRecordedLogs();

            assertEq(streamId, 1);
            assertEq(bootstrap.streamId(), streamId);
            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);
            assertEq(sablier.ownerOf(streamId), RECIPIENT);
            assertEq(sablier.getRecipient(streamId), RECIPIENT);
            assertEq(sablier.getSender(streamId), address(bootstrap));
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
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.allowance(address(bootstrap), address(sablier)), 0);
            assertEq(deep.totalSupply(), INITIAL_SUPPLY + ENDOWMENT);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));

            _assertSablierCreationEvent(logs, streamId, startTime);

            vm.expectRevert();
            vm.prank(address(bootstrap));
            sablier.cancel(streamId);

            vm.expectRevert();
            vm.prank(RECIPIENT);
            sablier.transferFrom(RECIPIENT, address(0xBEEF), streamId);

            vm.warp(startTime + 365 days / 2);
            assertEq(sablier.streamedAmountOf(streamId), ENDOWMENT / 2);
            vm.warp(startTime + 365 days);
            assertEq(sablier.streamedAmountOf(streamId), ENDOWMENT);
        }

        function _assertSablierCreationEvent(Vm.Log[] memory logs, uint256 streamId, uint40 startTime) internal {
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

                assertEq(commonParams.funder, address(bootstrap));
                assertEq(commonParams.sender, address(bootstrap));
                assertEq(commonParams.recipient, RECIPIENT);
                assertEq(commonParams.depositAmount, ENDOWMENT);
                assertEq(address(commonParams.token), address(deep));
                assertFalse(commonParams.cancelable);
                assertFalse(commonParams.transferable);
                assertEq(commonParams.timestamps.start, startTime);
                assertEq(commonParams.timestamps.end, startTime + 365 days);
                assertEq(commonParams.shape, "Deepstate Inc endowment");
                assertLe(bytes(commonParams.shape).length, 32);
                assertEq(cliffTime, 0);
                assertEq(granularity, 1 seconds);
                assertEq(unlockAmounts.start, 0);
                assertEq(unlockAmounts.cliff, 0);
                return;
            }

            fail("Sablier CreateLockupLinearStream event not found");
        }
    }
