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

contract DeepstateMinterControllerTest is Test {
    uint256 internal constant MINT_CAP = 3_000_000_000e18;

    DeepstateToken internal deep;
    DeepstateMinterController internal minterController;
    MockSablierLockupLinearV4 internal sablier;

    address internal recipient = makeAddr("recipient");
    address internal mintRecipient = makeAddr("mintRecipient");
    address internal unauthorized = makeAddr("unauthorized");
    address internal newGovernance = makeAddr("newGovernance");

    function setUp() public {
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        minterController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), recipient, MINT_CAP, MINT_CAP
        );
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(address(minterController.deepstateToken()), address(deep));
        assertEq(address(minterController.sablierLockup()), address(sablier));
        assertEq(minterController.recipient(), recipient);
        assertEq(minterController.mintCap(), MINT_CAP);
        assertEq(minterController.grossIssuanceCap(), MINT_CAP);
        assertEq(minterController.grossIssued(), 0);
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
        new DeepstateMinterController(address(0), address(deep), address(sablier), recipient, MINT_CAP, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidDeepstateToken.selector);
        new DeepstateMinterController(address(this), address(0), address(sablier), recipient, MINT_CAP, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidDeepstateToken.selector);
        new DeepstateMinterController(address(this), unauthorized, address(sablier), recipient, MINT_CAP, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), address(0), recipient, MINT_CAP, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidSablierLockup.selector);
        new DeepstateMinterController(address(this), address(deep), unauthorized, recipient, MINT_CAP, MINT_CAP);

        vm.expectRevert(DeepstateMinterController.InvalidRecipient.selector);
        new DeepstateMinterController(address(this), address(deep), address(sablier), address(0), MINT_CAP, MINT_CAP);

        for (uint256 invalidCap; invalidCap < 4; ++invalidCap) {
            vm.expectRevert(DeepstateMinterController.InvalidMintCap.selector);
            new DeepstateMinterController(
                address(this), address(deep), address(sablier), recipient, invalidCap, MINT_CAP
            );

            vm.expectRevert(DeepstateMinterController.InvalidGrossIssuanceCap.selector);
            new DeepstateMinterController(
                address(this), address(deep), address(sablier), recipient, MINT_CAP, invalidCap
            );
        }
    }

    function test_ExactMinimumCapsPermitTheSmallestMint() public {
        DeepstateMinterController boundary =
            new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, 4, 4);

        _activateTokenAdministration(boundary);
        boundary.mint(mintRecipient, 3);

        assertEq(deep.balanceOf(mintRecipient), 3);
        assertEq(deep.balanceOf(address(sablier)), 1);
        assertEq(deep.totalSupply(), 4);
        assertEq(boundary.grossIssued(), 4);
    }

    function test_ConstructorRequiresMinimumLiveSupplyHeadroom() public {
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(this), 1);

        vm.expectRevert(DeepstateMinterController.InvalidMintCap.selector);
        new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, 4, 4);

        DeepstateMinterController minimumHeadroom =
            new DeepstateMinterController(address(this), address(deep), address(sablier), recipient, 5, 5);
        assertEq(minimumHeadroom.mintCap() - deep.totalSupply(), 4);
    }

    function test_ActivationRecordsExistingSupplyAsPermanentGrossBaselineAndSelfGrantsMinterRole() public {
        uint256 baseline = 1_234_567e18;
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(unauthorized, baseline);
        _prepareSoleTokenAdministration(minterController);
        uint40 expectedEndsAt = uint40(block.timestamp + 2 * 365 days);

        vm.expectEmit(true, false, false, true, address(minterController));
        emit DeepstateMinterController.TokenAdministrationActivated(expectedEndsAt, baseline);
        minterController.activateTokenAdministration();

        assertEq(minterController.grossIssued(), baseline);
        assertEq(minterController.tokenAdministrationEndsAt(), expectedEndsAt);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertEq(deep.totalSupply(), baseline);
        assertEq(deep.balanceOf(address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_ActivationRejectsExistingControllerMinterRoleWithoutPartialState() public {
        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
        _prepareSoleTokenAdministration(minterController);

        vm.expectRevert(DeepstateMinterController.ControllerAlreadyTokenMinter.selector);
        minterController.activateTokenAdministration();

        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertEq(minterController.grossIssued(), 0);
        assertEq(minterController.tokenAdministrationEndsAt(), 0);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
        assertEq(sablier.nextStreamId(), 1);
    }

    function test_ActivationRejectsSupplyAboveLiveCapWithoutPartialState() public {
        DeepstateMinterController cappedController = _newUnactivatedController(10, 100);
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(this), 11);
        _prepareSoleTokenAdministration(cappedController);

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.MintCapExceeded.selector, uint256(10), uint256(11))
        );
        cappedController.activateTokenAdministration();

        _assertFailedActivationState(cappedController, 11);
    }

    function test_ActivationRejectsSupplyAboveGrossCapWithoutPartialState() public {
        DeepstateMinterController cappedController = _newUnactivatedController(100, 10);
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(this), 11);
        _prepareSoleTokenAdministration(cappedController);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateMinterController.GrossIssuanceCapExceeded.selector, uint256(10), uint256(11)
            )
        );
        cappedController.activateTokenAdministration();

        _assertFailedActivationState(cappedController, 11);
    }

    function test_MintAddsPrimaryAndVestingIssuanceToActivationBaseline() public {
        uint256 baseline = 5e18;
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(unauthorized, baseline);
        _activateTokenAdministration(minterController);

        minterController.mint(mintRecipient, 70e18);

        assertEq(deep.totalSupply(), baseline + 100e18);
        assertEq(minterController.grossIssued(), baseline + 100e18);
        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(address(sablier)), 30e18);
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
            address(this), mintRecipient, amount, recipient, vestingAmount, 1
        );
        vm.expectEmit(false, false, false, true, address(minterController));
        emit DeepstateMinterController.GrossIssuanceRecorded(amount + vestingAmount, amount + vestingAmount);
        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(streamId, 1);
        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), vestingAmount);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.totalSupply(), amount + vestingAmount);
        assertEq(minterController.grossIssued(), amount + vestingAmount);
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

    function test_ActivationStartsTwoYearTermAndEnsuresMinterRole() public {
        _prepareSoleTokenAdministration(minterController);

        uint40 expectedEndsAt = uint40(block.timestamp + 2 * 365 days);
        vm.expectEmit(true, false, false, true, address(minterController));
        emit DeepstateMinterController.TokenAdministrationActivated(expectedEndsAt, 0);
        minterController.activateTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), expectedEndsAt);
        assertEq(minterController.grossIssued(), 0);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
    }

    function test_RevertActivationWithoutTokenAdminOrByNonOwnerOrTwice() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(unauthorized);
        minterController.activateTokenAdministration();

        vm.expectRevert(DeepstateMinterController.ControllerNotTokenAdmin.selector);
        minterController.activateTokenAdministration();

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.ControllerNotSoleTokenAdmin.selector, uint256(2))
        );
        minterController.activateTokenAdministration();
        assertEq(minterController.tokenAdministrationEndsAt(), 0);

        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.activateTokenAdministration();

        vm.expectRevert(DeepstateMinterController.TokenAdministrationAlreadyActivated.selector);
        minterController.activateTokenAdministration();
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

    function test_OwnerCannotUnactivateTokenAdministrationBeforeDeadline() public {
        _lockSoleTokenAdministration();
        uint40 endsAt = minterController.tokenAdministrationEndsAt();

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.TokenAdministrationActive.selector, endsAt));
        minterController.unlockTokenAdministration();

        assertEq(minterController.tokenAdministrationEndsAt(), endsAt);
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);
    }

    function test_AnyoneCanUnactivateTokenAdministrationAtExactDeadline() public {
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
        assertEq(deep.balanceOf(address(sablier)), 30e18);
        assertEq(minterController.grossIssued(), 100e18);
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
            address(this), address(deep), address(sablier), recipient, MINT_CAP, MINT_CAP
        );
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
        assertEq(deep.balanceOf(address(sablier)), 2 * Math.mulDiv(100e18, 30_00, 70_00));
    }

    function test_OwnerCanMintAfterItsMinterRoleIsRevoked() public {
        _activateTokenAdministration(minterController);
        uint256 minterRole = minterController.MINTER_ROLE();
        minterController.grantRoles(address(this), minterRole);
        minterController.revokeRoles(address(this), minterRole);

        assertFalse(minterController.hasAnyRole(address(this), minterRole));
        minterController.mint(mintRecipient, 70e18);
        assertEq(deep.balanceOf(mintRecipient), 70e18);
        assertEq(deep.balanceOf(address(sablier)), 30e18);
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
        minterController.activateTokenAdministration();
    }

    function test_EachMintCreatesAnIndependentStream() public {
        _activateTokenAdministration(minterController);
        uint256 firstStreamId = minterController.mint(mintRecipient, 70e18);
        vm.warp(block.timestamp + 30 days);
        uint256 secondStreamId = minterController.mint(mintRecipient, 140e18);

        assertEq(firstStreamId, 1);
        assertEq(secondStreamId, 2);
        assertEq(sablier.stream(firstStreamId).depositAmount, 30e18);
        assertEq(sablier.stream(secondStreamId).depositAmount, 60e18);
        assertEq(deep.balanceOf(mintRecipient), 210e18);
        assertEq(deep.balanceOf(address(sablier)), 90e18);
    }

    function test_MintRoundsRecipientAllocationDown() public {
        _activateTokenAdministration(minterController);
        minterController.mint(mintRecipient, 5);

        assertEq(deep.balanceOf(mintRecipient), 5);
        assertEq(deep.balanceOf(address(sablier)), 2);
        assertEq(deep.totalSupply(), 7);
    }

    function test_MintCapIncludesExistingRequestedAndVestedSupply() public {
        DeepstateMinterController cappedController = _newControllerWithCaps(100e18, MINT_CAP);

        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        vm.prank(address(cappedController));
        deep.grantRole(tokenMinterRole, address(this));
        deep.mint(unauthorized, 5);

        vm.expectRevert(abi.encodeWithSelector(DeepstateMinterController.MintCapExceeded.selector, 100e18, 100e18 + 5));
        cappedController.mint(mintRecipient, 70e18);

        assertEq(deep.totalSupply(), 5);
        assertEq(sablier.nextStreamId(), 1);
        assertEq(cappedController.grossIssued(), 0);
    }

    function test_BurnDoesNotReopenGrossIssuanceCapacity() public {
        DeepstateMinterController cappedController = _newControllerWithCaps(200e18, 100e18);

        cappedController.mint(mintRecipient, 70e18);
        assertEq(deep.totalSupply(), 100e18);
        assertEq(cappedController.grossIssued(), 100e18);

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.GrossIssuanceCapExceeded.selector, 100e18, 100e18 + 4)
        );
        cappedController.mint(mintRecipient, 3);

        vm.prank(mintRecipient);
        deep.burn(4);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.GrossIssuanceCapExceeded.selector, 100e18, 100e18 + 4)
        );
        cappedController.mint(mintRecipient, 3);

        assertEq(deep.totalSupply(), 100e18 - 4);
        assertEq(deep.balanceOf(mintRecipient), 70e18 - 4);
        assertEq(deep.balanceOf(address(sablier)), 30e18);
        assertEq(cappedController.grossIssued(), 100e18);
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

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertEq(minterController.grossIssued(), 0);
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

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertEq(minterController.grossIssued(), 0);
    }

    function test_SablierRevertRollsBackBothMints() public {
        _activateTokenAdministration(minterController);
        sablier.setRevertCreate(true);

        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(deep.balanceOf(mintRecipient), 0);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertEq(minterController.grossIssued(), 0);
    }

    function test_SablierCannotReenterEvenWhenIncorrectlyGrantedMinterRole() public {
        _activateTokenAdministration(minterController);
        minterController.grantRoles(address(sablier), minterController.MINTER_ROLE());
        sablier.setReentry(
            address(minterController), abi.encodeCall(DeepstateMinterController.mint, (mintRecipient, 100e18))
        );

        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        minterController.mint(mintRecipient, 100e18);

        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertEq(minterController.grossIssued(), 0);
    }

    function testFuzz_MintMaintainsThirtyPercentOfCombinedIssuance(uint128 rawAmount) public {
        _activateTokenAdministration(minterController);
        uint256 maximumAmount = Math.mulDiv(MINT_CAP, 70_00, 100_00);
        uint256 amount = bound(uint256(rawAmount), 3, maximumAmount);
        uint256 expectedVesting = Math.mulDiv(amount, 30_00, 70_00);

        uint256 streamId = minterController.mint(mintRecipient, amount);

        assertEq(deep.balanceOf(mintRecipient), amount);
        assertEq(deep.balanceOf(address(sablier)), expectedVesting);
        assertEq(deep.totalSupply(), amount + expectedVesting);
        assertEq(minterController.grossIssued(), amount + expectedVesting);
        assertEq(expectedVesting, Math.mulDiv(amount + expectedVesting, 30_00, 100_00));
        assertEq(sablier.stream(streamId).depositAmount, expectedVesting);
    }

    function testFuzz_GrossIssuanceCapIsAnExactPermanentBoundary(uint128 rawAmount, uint128 rawBurn) public {
        uint256 maximumAmount = Math.mulDiv(MINT_CAP, 70_00, 100_00);
        uint256 amount = bound(uint256(rawAmount), 3, maximumAmount);
        uint256 vestingAmount = Math.mulDiv(amount, 30_00, 70_00);
        uint256 grossCap = amount + vestingAmount;
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
        controller.activateTokenAdministration();
    }

    function _prepareSoleTokenAdministration(DeepstateMinterController controller) internal {
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(controller));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function _assertFailedActivationState(DeepstateMinterController controller, uint256 expectedSupply) internal view {
        assertEq(controller.tokenAdministrationEndsAt(), 0);
        assertEq(controller.grossIssued(), 0);
        assertEq(deep.totalSupply(), expectedSupply);
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
            address(this), address(deep), address(sablier), recipient, liveCap, grossCap
        );
    }
}
