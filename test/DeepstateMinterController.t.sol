// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {DeepstateController} from "../src/DeepstateController.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract MinterLegacyRouterMock {
    mapping(bytes32 poolId => address hook) public poolHook;
    mapping(bytes32 bookId => mapping(bool isBid => uint32 nonce)) internal _topNonce;
    mapping(bytes32 bookId => mapping(bool isBid => uint160 soldAmount)) internal _topAmount;

    function activeBookId(address token0, address token1) public pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1, uint256(0)));
    }

    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount) {
        return (_topNonce[bookId][isBid], _topAmount[bookId][isBid]);
    }

    function setPoolHook(bytes32 poolId, address hook) external {
        poolHook[poolId] = hook;
    }

    function setTopOrder(bytes32 bookId, bool isBid, uint32 nonce, uint160 soldAmount) external {
        _topNonce[bookId][isBid] = nonce;
        _topAmount[bookId][isBid] = soldAmount;
    }
}

contract MinterLegacyRewarderMock {
    address public rewardToken;
    address public deepstate;
    address public token0 = address(0x1000);
    address public token1 = address(0x2000);
    bytes32 public poolId = keccak256(abi.encode(token0, token1));
    mapping(address token => uint96 accrued) public totalAccrued;
    mapping(address token => uint32 nonce) internal _rewardeeNonce;
    mapping(address token => uint64 startedAt) internal _rewardeeStartedAt;

    constructor(address rewardToken_, address deepstate_) {
        rewardToken = rewardToken_;
        deepstate = deepstate_;
        totalAccrued[token0] = 2;
        totalAccrued[token1] = 2;
    }

    function setRewardToken(address rewardToken_) external {
        rewardToken = rewardToken_;
    }

    function setTokens(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }

    function setDeepstate(address deepstate_) external {
        deepstate = deepstate_;
    }

    function setPoolId(bytes32 poolId_) external {
        poolId = poolId_;
    }

    function setRewardee(address token, uint32 nonce, uint64 startedAt) external {
        _rewardeeNonce[token] = nonce;
        _rewardeeStartedAt[token] = startedAt;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        return (_rewardeeNonce[token], _rewardeeStartedAt[token]);
    }

    function setTotalAccrued(uint96 token0Accrued, uint96 token1Accrued) external {
        totalAccrued[token0] = token0Accrued;
        totalAccrued[token1] = token1Accrued;
    }
}

contract InvalidMinterLegacyRewarderMock {}

contract DeepstateMinterControllerTest is Test {
    uint256 internal constant MINT_CAP = 3_000_000_000e18;
    uint256 internal constant DEFAULT_LEGACY_ENDOWMENT = 1;

    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    MockSablierLockupLinearV4 internal sablier;
    MinterLegacyRouterMock internal legacyRouter;
    MinterLegacyRewarderMock internal legacyRewarder;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");
    address internal unauthorized = makeAddr("unauthorized");
    address internal newGovernance = makeAddr("newGovernance");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        legacyRouter = new MinterLegacyRouterMock();
        legacyRewarder = new MinterLegacyRewarderMock(address(deep), address(legacyRouter));
        legacyRouter.setPoolHook(legacyRewarder.poolId(), address(legacyRewarder));
        minterController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(address(minterController.deepstateToken()), address(deep));
        assertEq(address(minterController.sablierLockup()), address(sablier));
        assertEq(address(minterController.legacyRewarder()), address(legacyRewarder));
        assertEq(minterController.recipient(), recipient);
        assertEq(minterController.mintCap(), MINT_CAP);
        assertEq(minterController.grossIssuanceCap(), MINT_CAP);
        assertEq(minterController.grossIssued(), 0);
        assertFalse(minterController.legacyEndowmentCreated());
        assertEq(minterController.legacyEndowmentSnapshotBlock(), 0);
        assertEq(minterController.legacyEndowmentSnapshotAt(), 0);
        assertEq(minterController.legacyToken0Accrued(), 0);
        assertEq(minterController.legacyToken1Accrued(), 0);
        assertEq(minterController.legacyEndowmentAmount(), 0);
        assertEq(minterController.legacyEndowmentStreamId(), 0);
        assertEq(minterController.RECIPIENT_ALLOCATION_BPS(), 30_00);
        assertEq(minterController.PRIMARY_ALLOCATION_BPS(), 70_00);
        assertEq(minterController.MINIMUM_COMBINED_ISSUANCE(), 4);
        assertEq(minterController.VESTING_DURATION(), 365 days);
        assertEq(minterController.TOKEN_ADMINISTRATION_DURATION(), 2 * 365 days);
        assertEq(minterController.owner(), address(this));
        assertEq(minterController.tokenAdministrationEndsAt(), 0);
        assertEq(minterController.MINTER_ROLE(), 1);
        assertEq(minterController.rolesOf(address(this)), 0);
        assertFalse(minterController.hasAnyRole(address(this), minterController.MINTER_ROLE()));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateController.InvalidOwner.selector);
        new DeepstateMinterController(
            address(0), address(deep), address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidDeepstateToken.selector);
        new DeepstateMinterController(
            address(this), address(0), address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidDeepstateToken.selector);
        new DeepstateMinterController(
            address(this), unauthorized, address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(
            address(this), address(deep), address(0), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(
            address(this), address(deep), unauthorized, address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidLegacyRewarder.selector);
        new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(0), recipient, MINT_CAP, MINT_CAP
        );

        InvalidMinterLegacyRewarderMock invalidLegacyRewarder = new InvalidMinterLegacyRewarderMock();
        vm.expectRevert(DeepstateMinterController.InvalidLegacyRewarder.selector);
        new DeepstateMinterController(
            address(this),
            address(deep),
            address(sablier),
            address(invalidLegacyRewarder),
            recipient,
            MINT_CAP,
            MINT_CAP
        );

        MinterLegacyRewarderMock wrongRewarder = new MinterLegacyRewarderMock(unauthorized, address(legacyRouter));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewardTokenMismatch.selector, address(deep), unauthorized
            )
        );
        new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(wrongRewarder), recipient, MINT_CAP, MINT_CAP
        );

        vm.expectRevert(DeepstateMinterController.InvalidRecipient.selector);
        new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), address(0), MINT_CAP, MINT_CAP
        );

        for (uint256 invalidCap; invalidCap < 4; ++invalidCap) {
            vm.expectRevert(DeepstateMinterController.InvalidMintCap.selector);
            new DeepstateMinterController(
                address(this), address(deep), address(sablier), address(legacyRewarder), recipient, invalidCap, MINT_CAP
            );

            vm.expectRevert(DeepstateMinterController.InvalidGrossIssuanceCap.selector);
            new DeepstateMinterController(
                address(this), address(deep), address(sablier), address(legacyRewarder), recipient, MINT_CAP, invalidCap
            );
        }
    }

    function test_ExactMinimumCapsPermitTheSmallestMint() public {
        DeepstateMinterController boundary = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, 5, 5
        );
        deep.grantRole(deep.MINTER_ROLE(), address(boundary));

        _activateTokenAdministration(boundary);
        boundary.mint(mintRecipient, 3);

        assertEq(deep.balanceOf(mintRecipient), 3);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 1);
        assertEq(deep.totalSupply(), 5);
        assertEq(boundary.grossIssued(), 5);
    }

    function test_ConstructorRequiresMinimumLiveSupplyHeadroom() public {
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(this), 1);

        vm.expectRevert(DeepstateMinterController.InvalidMintCap.selector);
        new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, 4, 4
        );

        DeepstateMinterController minimumHeadroom = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, 5, 4
        );
        assertEq(minimumHeadroom.mintCap() - deep.totalSupply(), 4);
    }

    function test_LockSnapshotsExactAccrualStreamsThirtyPercentAndActivates() public {
        uint96 token0Accrued = 76_668_471_827185259478605328;
        uint96 token1Accrued = 71_607_902_174090642172829949;
        uint256 totalAccrued = uint256(token0Accrued) + uint256(token1Accrued);
        uint256 expectedEndowment = Math.mulDiv(totalAccrued, 30_00, 10_000);
        legacyRewarder.setTotalAccrued(token0Accrued, token1Accrued);
        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
        _prepareSoleTokenAdministration(minterController);
        uint256 snapshotBlock = block.number;
        uint40 snapshotAt = uint40(block.timestamp);
        uint40 expectedEndsAt = uint40(block.timestamp + 2 * 365 days);

        vm.expectEmit(true, true, true, true, address(minterController));
        emit DeepstateMinterController.LegacyRewarderEndowmentCreated(
            address(legacyRewarder),
            legacyRewarder.token0(),
            legacyRewarder.token1(),
            token0Accrued,
            token1Accrued,
            totalAccrued,
            expectedEndowment,
            1,
            snapshotBlock,
            snapshotAt
        );
        vm.expectEmit(false, false, false, true, address(minterController));
        emit DeepstateMinterController.GrossIssuanceRecorded(expectedEndowment, expectedEndowment);
        vm.expectEmit(true, false, false, true, address(minterController));
        emit DeepstateMinterController.TokenAdministrationActivated(expectedEndsAt);
        minterController.lockTokenAdministration();

        uint256 streamId = minterController.legacyEndowmentStreamId();
        assertEq(streamId, 1);
        assertEq(minterController.tokenAdministrationEndsAt(), expectedEndsAt);
        assertTrue(minterController.legacyEndowmentCreated());
        assertEq(minterController.legacyEndowmentSnapshotBlock(), snapshotBlock);
        assertEq(minterController.legacyEndowmentSnapshotAt(), snapshotAt);
        assertEq(minterController.legacyToken0Accrued(), token0Accrued);
        assertEq(minterController.legacyToken1Accrued(), token1Accrued);
        assertEq(minterController.legacyEndowmentAmount(), expectedEndowment);
        assertEq(minterController.legacyEndowmentStreamId(), streamId);
        assertEq(minterController.grossIssued(), expectedEndowment);
        assertEq(deep.totalSupply(), expectedEndowment);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.balanceOf(address(sablier)), expectedEndowment);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);

        MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);
        assertEq(created.funder, address(minterController));
        assertEq(created.sender, address(minterController));
        assertEq(created.recipient, recipient);
        assertEq(created.token, address(deep));
        assertEq(created.depositAmount, expectedEndowment);
        assertFalse(created.cancelable);
        assertFalse(created.transferable);
        assertEq(created.shape, "Deepstate Inc endowment");
        assertEq(created.startUnlockAmount, 0);
        assertEq(created.cliffUnlockAmount, 0);
        assertEq(created.cliffDuration, 0);
        assertEq(created.totalDuration, 365 days);
    }

    function test_LockRoundsLegacyEndowmentThirtyPercentDown() public {
        legacyRewarder.setTotalAccrued(3, 2);
        _prepareSoleTokenAdministration(minterController);

        minterController.lockTokenAdministration();

        assertEq(minterController.legacyEndowmentAmount(), 1);
        assertEq(minterController.grossIssued(), 1);
    }

    function test_StandaloneLegacyEndowmentSelectorIsAbsent() public {
        bytes4 removedSelector = bytes4(keccak256("createLegacyRewarderEndowment()"));
        (bool success,) = address(minterController).call(abi.encodeWithSelector(removedSelector));

        assertFalse(success);
        assertFalse(minterController.legacyEndowmentCreated());
        assertEq(minterController.grossIssued(), 0);
        assertEq(deep.totalSupply(), 0);
    }

    function test_RevertLockForZeroAccrualOrInvalidTokensWithoutPartialState() public {
        _prepareSoleTokenAdministration(minterController);
        legacyRewarder.setTotalAccrued(0, 0);
        vm.expectRevert(DeepstateMinterController.LegacyEndowmentAmountZero.selector);
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setTotalAccrued(2, 2);
        legacyRewarder.setTokens(address(0), address(0x2000));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.InvalidLegacyRewarderTokens.selector, address(0), address(0x2000)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setTokens(address(0x2000), address(0x1000));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.InvalidLegacyRewarderTokens.selector, address(0x2000), address(0x1000)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);
    }

    function test_RevertLockForLegacyDependencyIdentityMismatchWithoutPartialState() public {
        _prepareSoleTokenAdministration(minterController);
        legacyRewarder.setRewardToken(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewardTokenMismatch.selector, address(deep), unauthorized
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setRewardToken(address(deep));
        legacyRewarder.setDeepstate(address(0));
        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.InvalidLegacyDeepstate.selector, address(0)));
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setDeepstate(address(legacyRouter));
        bytes32 expectedPoolId = keccak256(abi.encode(legacyRewarder.token0(), legacyRewarder.token1()));
        legacyRewarder.setPoolId(bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderPoolIdentityMismatch.selector,
                expectedPoolId,
                bytes32(uint256(1))
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setPoolId(expectedPoolId);
        legacyRouter.setPoolHook(expectedPoolId, unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderPoolHookMismatch.selector,
                expectedPoolId,
                address(legacyRewarder),
                unauthorized
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);
    }

    function test_RevertLockForNonIdleBookOrRewardCursorWithoutPartialState() public {
        _prepareSoleTokenAdministration(minterController);
        bytes32 bookId = legacyRouter.activeBookId(legacyRewarder.token0(), legacyRewarder.token1());
        legacyRouter.setTopOrder(bookId, true, 7, 11);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderBookNotIdle.selector, bookId, true, uint32(7), uint160(11)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRouter.setTopOrder(bookId, true, 0, 0);
        legacyRouter.setTopOrder(bookId, false, 8, 12);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderBookNotIdle.selector, bookId, false, uint32(8), uint160(12)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRouter.setTopOrder(bookId, false, 0, 0);
        legacyRewarder.setRewardee(legacyRewarder.token0(), 9, 13);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderCursorNotIdle.selector,
                legacyRewarder.token0(),
                uint32(9),
                uint64(13)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);

        legacyRewarder.setRewardee(legacyRewarder.token0(), 0, 0);
        legacyRewarder.setRewardee(legacyRewarder.token1(), 10, 14);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.LegacyRewarderCursorNotIdle.selector,
                legacyRewarder.token1(),
                uint32(10),
                uint64(14)
            )
        );
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);
    }

    function test_LockCapAndSablierFailuresAreAtomic() public {
        legacyRewarder.setTotalAccrued(20, 20);
        DeepstateMinterController grossCapped = _newUnactivatedController(MINT_CAP, 11);
        _prepareSoleTokenAdministration(grossCapped);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.GrossIssuanceCapExceeded.selector, uint256(11), uint256(12)
            )
        );
        grossCapped.lockTokenAdministration();
        _assertFailedLockState(grossCapped);
        grossCapped.returnPreActivationTokenAdministration();

        DeepstateMinterController liveCapped = _newUnactivatedController(11, MINT_CAP);
        _prepareSoleTokenAdministration(liveCapped);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.MintCapExceeded.selector, uint256(11), uint256(12))
        );
        liveCapped.lockTokenAdministration();
        _assertFailedLockState(liveCapped);
        liveCapped.returnPreActivationTokenAdministration();

        _prepareSoleTokenAdministration(minterController);
        sablier.setRevertCreate(true);
        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        minterController.lockTokenAdministration();
        _assertFailedLockState(minterController);
    }

    function test_RevertMintBeforeTokenAdministrationActivation() public {
        vm.expectRevert(DeepstateMinterController.TokenAdministrationNotActive.selector);
        minterController.mint(mintRecipient, 70e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_MintCreatesExactNonCancelableOneYearStream() public {
        _activateTokenAdministration(minterController);
        uint256 amount = 70_000_000e18;
        uint256 vestingAmount = 30_000_000e18;

        vm.expectEmit(true, true, true, true, address(minterController));
        emit DeepstateMinterController.MintedWithVesting(
            address(this), mintRecipient, amount, recipient, vestingAmount, 2
        );
        vm.expectEmit(false, false, false, true, address(minterController));
        emit DeepstateMinterController.GrossIssuanceRecorded(
            amount + vestingAmount, DEFAULT_LEGACY_ENDOWMENT + amount + vestingAmount
        );
        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(streamId, 2);
        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + vestingAmount);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + amount + vestingAmount);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT + amount + vestingAmount);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);

        MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);
        assertEq(created.funder, address(minterController));
        assertEq(created.sender, address(minterController));
        assertEq(created.recipient, recipient);
        assertEq(created.token, address(deep));
        assertEq(created.depositAmount, vestingAmount);
        assertFalse(created.cancelable);
        assertFalse(created.transferable);
        assertEq(created.shape, "Deepstate allocation");
        assertEq(created.startUnlockAmount, 0);
        assertEq(created.cliffUnlockAmount, 0);
        assertEq(created.granularity, 0);
        assertEq(created.cliffDuration, 0);
        assertEq(created.totalDuration, 365 days);
    }

    function test_LockTokenAdministrationStartsTwoYearTermAndEnsuresMinterRole() public {
        _prepareSoleTokenAdministration(minterController);

        uint40 expectedEndsAt = uint40(block.timestamp + 2 * 365 days);
        minterController.lockTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), expectedEndsAt);
        assertTrue(minterController.legacyEndowmentCreated());
        assertEq(minterController.legacyEndowmentAmount(), DEFAULT_LEGACY_ENDOWMENT);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_RevertLockWithoutTokenAdminOrByNonOwnerOrTwice() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.lockTokenAdministration();

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.lockTokenAdministration();

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.ControllerNotSoleTokenAdmin.selector, uint256(2))
        );
        minterController.lockTokenAdministration();
        assertEq(minterController.tokenAdministrationEndsAt(), 0);

        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.lockTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyActivated.selector);
        minterController.lockTokenAdministration();
    }

    function test_PreActivationRecoveryReturnsAdminRevokesMinterAndCannotRunAfterActivation() public {
        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.returnPreActivationTokenAdministration();

        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
        _prepareSoleTokenAdministration(minterController);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.returnPreActivationTokenAdministration();

        vm.expectEmit(true, true, false, true, address(minterController));
        emit DeepstateMinterController.PreActivationTokenAdministrationReturned(address(this), address(this));
        minterController.returnPreActivationTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), 0);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);

        _activateTokenAdministration(minterController);
        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyActivated.selector);
        minterController.returnPreActivationTokenAdministration();
    }

    function test_OwnerCanRevokeExternalTokenMinterDuringAndAfterAdministrationTerm() public {
        _lockSoleTokenAdministration();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(minterController));
        deep.grantRole(tokenMinterRole, unauthorized);

        vm.expectEmit(true, true, false, true, address(minterController));
        emit DeepstateMinterController.ExternalTokenMinterRevoked(unauthorized, address(this));
        minterController.revokeExternalTokenMinter(unauthorized);

        assertFalse(deep.hasRole(tokenMinterRole, unauthorized));
        assertTrue(deep.hasRole(tokenMinterRole, address(minterController)));

        vm.prank(address(minterController));
        deep.grantRole(tokenMinterRole, unauthorized);
        vm.warp(minterController.tokenAdministrationEndsAt());
        minterController.revokeExternalTokenMinter(unauthorized);

        assertFalse(deep.hasRole(tokenMinterRole, unauthorized));
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
    }

    function test_RevertExternalTokenMinterRevocationWithoutAuthorityOrAdministration() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.revokeExternalTokenMinter(mintRecipient);

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.revokeExternalTokenMinter(mintRecipient);
    }

    function test_RevertExternalTokenMinterRevocationForInvalidOrInactiveAccount() public {
        _lockSoleTokenAdministration();

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.InvalidExternalTokenMinter.selector, address(0))
        );
        minterController.revokeExternalTokenMinter(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.InvalidExternalTokenMinter.selector, address(minterController)
            )
        );
        minterController.revokeExternalTokenMinter(address(minterController));

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.ExternalTokenMinterNotActive.selector, unauthorized)
        );
        minterController.revokeExternalTokenMinter(unauthorized);
    }

    function test_OwnerCannotUnlockTokenAdministrationBeforeDeadline() public {
        _lockSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationActive.selector, endsAt));
        minterController.unlockTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), endsAt);
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_AnyoneCanUnlockTokenAdministrationAtExactDeadline() public {
        _lockSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.warp(endsAt - 1);
        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationActive.selector, endsAt));
        vm.prank(unauthorized);
        minterController.unlockTokenAdministration();

        vm.warp(endsAt);
        vm.prank(unauthorized);
        minterController.unlockTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), type(uint40).max);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);

        vm.expectRevert(DeepstateMinterController.TokenAdministrationNotActive.selector);
        minterController.mint(mintRecipient, 70e18);
    }

    function test_MintWorksUntilSecondBeforeDeadlineAndRevertsAtAndAfterDeadline() public {
        _lockSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.warp(endsAt - 1);
        minterController.mint(mintRecipient, 70e18);

        vm.warp(endsAt);
        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationExpired.selector, endsAt));
        minterController.mint(mintRecipient, 70e18);

        vm.warp(endsAt + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationExpired.selector, endsAt));
        minterController.mint(mintRecipient, 70e18);

        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 30e18);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT + 100e18);
    }

    function test_UnlockUsesCurrentOwnerAfterOwnershipTransfer() public {
        _lockSoleTokenAdministration();

        minterController.transferOwnership(newGovernance);
        assertEq(minterController.owner(), newGovernance);
        assertFalse(minterController.hasAnyRole(address(this), minterController.MINTER_ROLE()));
        assertFalse(minterController.hasAnyRole(newGovernance, minterController.MINTER_ROLE()));

        vm.warp(minterController.tokenAdministrationEndsAt());
        vm.prank(unauthorized);
        minterController.unlockTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), type(uint40).max);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), newGovernance));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_OwnerMintAuthorityRotatesWithOwnership() public {
        DeepstateMinterController ownerController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, MINT_CAP, MINT_CAP
        );
        deep.grantRole(deep.MINTER_ROLE(), address(ownerController));
        _activateTokenAdministration(ownerController);

        assertFalse(ownerController.hasAnyRole(address(this), ownerController.MINTER_ROLE()));
        ownerController.mint(mintRecipient, 100e18);
        ownerController.transferOwnership(newGovernance);

        assertFalse(ownerController.hasAnyRole(address(this), ownerController.MINTER_ROLE()));
        assertFalse(ownerController.hasAnyRole(newGovernance, ownerController.MINTER_ROLE()));

        vm.expectRevert(Ownable.Unauthorized.selector);
        ownerController.mint(mintRecipient, 100e18);

        vm.prank(newGovernance);
        ownerController.mint(mintRecipient, 100e18);

        assertEq(deep.balanceOf(mintRecipient), 200e18);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 2 * Math.mulDiv(100e18, 30_00, 70_00));
    }

    function test_OwnerCanMintAfterItsMinterRoleIsRevoked() public {
        _activateTokenAdministration(minterController);
        uint256 minterRole = minterController.MINTER_ROLE();
        minterController.grantRoles(address(this), minterRole);
        minterController.revokeRoles(address(this), minterRole);

        assertFalse(minterController.hasAnyRole(address(this), minterRole));
        minterController.mint(mintRecipient, 70e18);
        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 30e18);
    }

    function test_TwoStepOwnershipHandoverDoesNotMutateRoles() public {
        minterController.grantRoles(unauthorized, minterController.MINTER_ROLE());

        vm.prank(newGovernance);
        minterController.requestOwnershipHandover();
        minterController.completeOwnershipHandover(newGovernance);

        assertEq(minterController.owner(), newGovernance);
        assertEq(minterController.rolesOf(address(this)), 0);
        assertEq(minterController.rolesOf(newGovernance), 0);
        assertEq(minterController.rolesOf(unauthorized), minterController.MINTER_ROLE());
    }

    function test_TransferOwnershipToCurrentOwnerPreservesRoles() public {
        _activateTokenAdministration(minterController);
        minterController.transferOwnership(address(this));

        assertEq(minterController.owner(), address(this));
        assertEq(minterController.rolesOf(address(this)), 0);

        minterController.mint(mintRecipient, 100e18);
        assertEq(deep.balanceOf(mintRecipient), 100e18);
    }

    function test_ControllerOwnerCannotRenounceOwnership() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        minterController.renounceOwnership();

        vm.expectRevert(DeepstateController.InvalidOwner.selector);
        minterController.transferOwnership(address(minterController));

        assertEq(minterController.owner(), address(this));
    }

    function test_RevertUnlockBeforeLockAfterUnlockOrWithoutTokenAdmin() public {
        vm.expectRevert(DeepstateMinterController.TokenAdministrationNotActive.selector);
        minterController.unlockTokenAdministration();

        _lockSoleTokenAdministration();
        bytes32 tokenAdminRole = deep.DEFAULT_ADMIN_ROLE();
        vm.prank(address(minterController));
        deep.grantRole(tokenAdminRole, address(this));
        deep.revokeRole(tokenAdminRole, address(minterController));
        vm.warp(minterController.tokenAdministrationEndsAt());

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.unlockTokenAdministration();

        deep.grantRole(tokenAdminRole, address(minterController));
        minterController.unlockTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyReturned.selector);
        minterController.unlockTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyActivated.selector);
        minterController.lockTokenAdministration();
    }

    function test_EachMintCreatesAnIndependentStream() public {
        _activateTokenAdministration(minterController);
        uint256 firstStreamId = minterController.mint(mintRecipient, 70e18);
        vm.warp(block.timestamp + 30 days);
        uint256 secondStreamId = minterController.mint(mintRecipient, 140e18);

        assertEq(firstStreamId, 2);
        assertEq(secondStreamId, 3);
        assertEq(sablier.stream(firstStreamId).depositAmount, 30e18);
        assertEq(sablier.stream(secondStreamId).depositAmount, 60e18);
        assertEq(deep.balanceOf(mintRecipient), 210e18);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 90e18);
    }

    function test_MintRoundsRecipientAllocationDown() public {
        _activateTokenAdministration(minterController);
        minterController.mint(mintRecipient, 5);

        assertEq(deep.balanceOf(mintRecipient), 5);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 2);
        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + 7);
    }

    function test_MintCapIncludesExistingRequestedAndVestedSupply() public {
        DeepstateMinterController cappedController = _newControllerWithCaps(100e18, MINT_CAP);

        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(cappedController));
        deep.grantRole(tokenMinterRole, address(this));
        deep.mint(unauthorized, 5);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.MintCapExceeded.selector, 100e18, DEFAULT_LEGACY_ENDOWMENT + 100e18 + 5
            )
        );
        cappedController.mint(mintRecipient, 70e18);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + 5);
        assertEq(sablier.nextStreamId(), 2);
        assertEq(cappedController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT);
    }

    function test_BurnDoesNotReopenGrossIssuanceCapacity() public {
        DeepstateMinterController cappedController =
            _newControllerWithCaps(DEFAULT_LEGACY_ENDOWMENT + 200e18, DEFAULT_LEGACY_ENDOWMENT + 100e18);

        cappedController.mint(mintRecipient, 70e18);
        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + 100e18);
        assertEq(cappedController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT + 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.GrossIssuanceCapExceeded.selector,
                DEFAULT_LEGACY_ENDOWMENT + 100e18,
                DEFAULT_LEGACY_ENDOWMENT + 100e18 + 4
            )
        );
        cappedController.mint(mintRecipient, 3);

        vm.prank(mintRecipient);
        deep.burn(4);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.GrossIssuanceCapExceeded.selector,
                DEFAULT_LEGACY_ENDOWMENT + 100e18,
                DEFAULT_LEGACY_ENDOWMENT + 100e18 + 4
            )
        );
        cappedController.mint(mintRecipient, 3);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + 100e18 - 4);
        assertEq(deep.balanceOf(mintRecipient), 70e18 - 4);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + 30e18);
        assertEq(cappedController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT + 100e18);
    }

    function test_MintPreservesPreexistingControllerBalance() public {
        _activateTokenAdministration(minterController);
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(minterController));
        deep.grantRole(tokenMinterRole, address(this));
        deep.mint(address(minterController), 11);

        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.balanceOf(address(minterController)), 11);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
    }

    function test_RevertWhenCallerLacksControllerMinterRole() public {
        _activateTokenAdministration(minterController);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);
    }

    function test_OwnerCanGrantAndRevokeControllerMinterRole() public {
        _activateTokenAdministration(minterController);
        minterController.grantRoles(unauthorized, minterController.MINTER_ROLE());
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);

        minterController.revokeRoles(unauthorized, minterController.MINTER_ROLE());
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.mint(mintRecipient, 100e18);
    }

    function test_ControllerMinterCanRenounceRole() public {
        uint256 minterRole = minterController.MINTER_ROLE();
        minterController.grantRoles(unauthorized, minterRole);

        vm.prank(unauthorized);
        minterController.renounceRoles(minterRole);

        assertFalse(minterController.hasAnyRole(unauthorized, minterRole));
    }

    function test_RevertWhenNonOwnerChangesMinterRole() public {
        uint256 minterRole = minterController.MINTER_ROLE();
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.grantRoles(unauthorized, minterRole);
    }

    function test_RevertForZeroMintRecipientOrDustAmount() public {
        _activateTokenAdministration(minterController);
        vm.expectRevert(DeepstateMinterController.InvalidMintRecipient.selector);
        minterController.mint(address(0), 100e18);

        vm.expectRevert(DeepstateMinterController.MintAmountTooSmall.selector);
        minterController.mint(mintRecipient, 2);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT);
        assertEq(sablier.nextStreamId(), 2);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT);
    }

    function test_RevertWhenVestingAmountExceedsSablierUint128Limit() public {
        _activateTokenAdministration(minterController);
        uint256 amount = Math.mulDiv(uint256(type(uint128).max) + 1, 70_00, 30_00, Math.Rounding.Ceil);
        uint256 vestingAmount = Math.mulDiv(amount, 30_00, 70_00);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.VestingAmountTooLarge.selector, vestingAmount));
        minterController.mint(mintRecipient, amount);
    }

    function test_MissingTokenMinterRoleRevertsAtomically() public {
        _activateTokenAdministration(minterController);
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(minterController));
        deep.revokeRole(tokenMinterRole, address(minterController));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(minterController), deep.MINTER_ROLE()
            )
        );
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT);
        assertEq(sablier.nextStreamId(), 2);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT);
    }

    function test_SablierRevertRollsBackBothMints() public {
        _activateTokenAdministration(minterController);
        sablier.setRevertCreate(true);

        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT);
        assertEq(deep.balanceOf(mintRecipient), 0);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 2);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT);
    }

    function test_SablierCannotReenterEvenWhenIncorrectlyGrantedMinterRole() public {
        _activateTokenAdministration(minterController);
        minterController.grantRoles(address(sablier), minterController.MINTER_ROLE());
        sablier.setReentry(
            address(minterController), abi.encodeCall(DeepstateMinterController.mint, (mintRecipient, 100e18))
        );

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT);
        assertEq(sablier.nextStreamId(), 2);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT);
    }

    function testFuzz_MintMaintainsThirtyPercentOfCombinedIssuance(uint128 rawAmount) public {
        _activateTokenAdministration(minterController);
        uint256 maximumAmount = Math.mulDiv(MINT_CAP - DEFAULT_LEGACY_ENDOWMENT, 70_00, 100_00);
        uint256 amount = bound(uint256(rawAmount), 3, maximumAmount);
        uint256 expectedVesting = Math.mulDiv(amount, 30_00, 70_00);

        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), DEFAULT_LEGACY_ENDOWMENT + expectedVesting);
        assertEq(deep.totalSupply(), DEFAULT_LEGACY_ENDOWMENT + amount + expectedVesting);
        assertEq(minterController.grossIssued(), DEFAULT_LEGACY_ENDOWMENT + amount + expectedVesting);
        assertEq(expectedVesting, Math.mulDiv(amount + expectedVesting, 30_00, 100_00));
        assertEq(sablier.stream(streamId).depositAmount, expectedVesting);
    }

    function testFuzz_GrossIssuanceCapIsAnExactPermanentBoundary(uint128 rawAmount, uint128 rawBurn) public {
        uint256 maximumAmount = Math.mulDiv(MINT_CAP - DEFAULT_LEGACY_ENDOWMENT, 70_00, 100_00);
        uint256 amount = bound(uint256(rawAmount), 3, maximumAmount);
        uint256 vestingAmount = Math.mulDiv(amount, 30_00, 70_00);
        uint256 grossCap = DEFAULT_LEGACY_ENDOWMENT + amount + vestingAmount;
        DeepstateMinterController cappedController = _newControllerWithCaps(MINT_CAP, grossCap);

        cappedController.mint(mintRecipient, amount);
        assertEq(cappedController.grossIssued(), grossCap);

        uint256 burnAmount = bound(uint256(rawBurn), 0, amount);
        if (burnAmount != 0) {
            vm.prank(mintRecipient);
            deep.burn(burnAmount);
        }

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.GrossIssuanceCapExceeded.selector, grossCap, grossCap + 4)
        );
        cappedController.mint(mintRecipient, 3);

        assertEq(cappedController.grossIssued(), grossCap);
        assertEq(deep.totalSupply(), grossCap - burnAmount);
    }

    function _lockSoleTokenAdministration() internal {
        _activateTokenAdministration(minterController);

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function _activateTokenAdministration(DeepstateMinterController controller) internal {
        _prepareSoleTokenAdministration(controller);
        controller.lockTokenAdministration();
    }

    function _prepareSoleTokenAdministration(DeepstateMinterController controller) internal {
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(controller));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function _assertFailedLockState(DeepstateMinterController controller) internal view {
        assertEq(controller.tokenAdministrationEndsAt(), 0);
        assertFalse(controller.legacyEndowmentCreated());
        assertEq(controller.legacyEndowmentSnapshotBlock(), 0);
        assertEq(controller.legacyEndowmentAmount(), 0);
        assertEq(controller.grossIssued(), 0);
        assertEq(deep.totalSupply(), 0);
        assertEq(deep.balanceOf(address(controller)), 0);
        assertEq(deep.allowance(address(controller), address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        assertEq(deep.defaultAdminCount(), 1);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
    }

    function _newControllerWithCaps(uint256 liveCap, uint256 grossCap)
        internal
        returns (DeepstateMinterController controller)
    {
        controller = _newUnactivatedController(liveCap, grossCap);
        _activateTokenAdministration(controller);
    }

    function _newUnactivatedController(uint256 liveCap, uint256 grossCap)
        internal
        returns (DeepstateMinterController controller)
    {
        controller = new DeepstateMinterController(
            address(this), address(deep), address(sablier), address(legacyRewarder), recipient, liveCap, grossCap
        );
    }
}
