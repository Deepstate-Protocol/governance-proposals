// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "../mocks/MockSablierLockupLinearV4.sol";

/// @dev Stateful model for the complete DEEP administration term. The handler deliberately exposes both valid and
/// invalid calls so the invariant campaign continuously tests authorization, phase boundaries and atomic rollback.
contract DeepstateMinterSystemHandler is Test {
    uint256 public constant MAX_SUPPLY = 3_000_000_000e18;

    address public constant GOVERNANCE_A = address(0xA11CE);
    address public constant GOVERNANCE_B = address(0xB0B);
    address public constant GOVERNANCE_C = address(0xCA401);
    address public constant VESTING_RECIPIENT = address(0x1AC);
    address public constant MINTER_A = address(0x1001);
    address public constant MINTER_B = address(0x1002);
    address public constant MINTER_C = address(0x1003);
    address public constant MINT_RECIPIENT_A = address(0x2001);
    address public constant MINT_RECIPIENT_B = address(0x2002);
    address public constant MINT_RECIPIENT_C = address(0x2003);

    DeepstateToken public immutable deep;
    DeepstateMinterController public immutable controller;
    MockSablierLockupLinearV4 public immutable sablier;

    // 0: not activated, 1: activated (including an elapsed-but-not-returned term), 2: administration returned.
    uint8 public phase;
    address public expectedOwner = GOVERNANCE_A;
    address public returnedTokenAdmin;
    uint40 public activationStartedAt;
    uint40 public expectedEndsAt;
    uint256 public activationSupplyBaseline;

    uint256 public externalIssued;
    uint256 public primaryIssued;
    uint256 public vestingIssued;
    uint256 public totalBurned;
    uint256 public successfulMints;
    uint256 public failedSablierMints;
    uint40 public lastSuccessfulMintAt;
    bool public lastMintSucceeded;

    mapping(address account => bool enabled) public expectedControllerMinter;
    mapping(uint256 streamId => uint256 amount) public primaryAmountForStream;

    constructor() {
        deep = new DeepstateToken(GOVERNANCE_A, "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        controller =
            new DeepstateMinterController(GOVERNANCE_A, address(deep), address(sablier), VESTING_RECIPIENT, MAX_SUPPLY);

        // Model token-level minters that governance must revoke before making the controller the sole mint path.
        vm.startPrank(GOVERNANCE_A);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_A);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_B);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_C);
        vm.stopPrank();
    }

    /// @dev Exercises issuance before activation and proves that the same accounts cannot bypass the controller once
    /// activation has revoked them.
    function externalTokenMint(uint8 minterSeed, uint8 recipientSeed, uint256 rawAmount) external {
        address tokenMinter = _minter(minterSeed);
        address to = _mintRecipient(recipientSeed);
        uint256 supplyBefore = deep.totalSupply();
        uint256 maximum = phase == 0 ? MAX_SUPPLY - supplyBefore : MAX_SUPPLY * 2;
        uint256 amount = bound(rawAmount, 0, maximum);
        bool shouldSucceed = phase == 0;

        vm.prank(tokenMinter);
        (bool success,) = address(deep).call(abi.encodeCall(DeepstateToken.mint, (to, amount)));
        assertEq(success, shouldSucceed, "token-level bypass authorization mismatch");

        if (success) {
            externalIssued += amount;
            assertEq(deep.totalSupply(), supplyBefore + amount, "external mint supply mismatch");
        } else {
            assertEq(deep.totalSupply(), supplyBefore, "failed external mint changed supply");
        }
    }

    /// @dev Represents the atomic governance ordering: revoke every known bypass minter, make the controller sole token
    /// admin, then start the two-year clock last. The handler records the current supply for its accounting model;
    /// activation itself creates no issuance or stream.
    function activate() external {
        if (phase != 0) return;

        uint256 supplyBefore = deep.totalSupply();
        uint256 streamBefore = sablier.nextStreamId();
        (bool success,) = address(this).call(abi.encodeCall(this.executeAtomicActivation, ()));
        assertTrue(success, "valid activation failed");

        phase = 1;
        activationStartedAt = uint40(block.timestamp);
        expectedEndsAt = uint40(block.timestamp + controller.TOKEN_ADMINISTRATION_DURATION());
        activationSupplyBaseline = supplyBefore;

        assertEq(controller.tokenAdministrationEndsAt(), expectedEndsAt, "incorrect administration deadline");
        assertEq(deep.totalSupply(), supplyBefore, "activation changed live supply");
        assertEq(sablier.nextStreamId(), streamBefore, "activation created a stream");
    }

    function executeAtomicActivation() external {
        require(msg.sender == address(this), "only self");
        bytes32 tokenAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        for (uint256 i; i < 3; ++i) {
            address externalMinter = _minter(i);
            if (deep.hasRole(tokenMinterRole, externalMinter)) {
                vm.prank(GOVERNANCE_A);
                deep.revokeRole(tokenMinterRole, externalMinter);
            }
        }

        vm.prank(GOVERNANCE_A);
        deep.grantRole(tokenAdminRole, address(controller));
        vm.prank(GOVERNANCE_A);
        deep.renounceRole(tokenAdminRole, GOVERNANCE_A);

        assertEq(deep.defaultAdminCount(), 1, "activation must first establish one token admin");
        assertTrue(
            deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)), "controller must administer revocations"
        );
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)), "controller minter must be self-granted");

        vm.prank(expectedOwner);
        controller.activateTokenAdministration();
    }

    function setControllerMinter(uint8 accountSeed, bool enabled) external {
        address account = _minter(accountSeed);
        uint256 role = controller.MINTER_ROLE();

        vm.prank(expectedOwner);
        if (enabled) controller.grantRoles(account, role);
        else controller.revokeRoles(account, role);

        expectedControllerMinter[account] = enabled;
    }

    function renounceControllerMinter(uint8 accountSeed) external {
        address account = _minter(accountSeed);
        uint256 role = controller.MINTER_ROLE();
        vm.prank(account);
        controller.renounceRoles(role);
        expectedControllerMinter[account] = false;
    }

    /// @dev Ownership may rotate before or during the term. Unlock must return token administration to the owner at
    /// the moment of return, not to the owner that deployed or activated the controller.
    function rotateGovernance(uint8 ownerSeed) external {
        if (phase == 2) return;

        address nextOwner = _governance(ownerSeed);
        uint256 rolesA = controller.rolesOf(MINTER_A);
        uint256 rolesB = controller.rolesOf(MINTER_B);
        uint256 rolesC = controller.rolesOf(MINTER_C);

        vm.prank(expectedOwner);
        controller.transferOwnership(nextOwner);
        expectedOwner = nextOwner;

        assertEq(controller.rolesOf(MINTER_A), rolesA, "ownership transfer changed A's roles");
        assertEq(controller.rolesOf(MINTER_B), rolesB, "ownership transfer changed B's roles");
        assertEq(controller.rolesOf(MINTER_C), rolesC, "ownership transfer changed C's roles");
    }

    function attemptInvalidOwnershipChanges(uint8 callerSeed) external {
        address ownerBefore = controller.owner();
        address caller = callerSeed & 1 == 0 ? expectedOwner : _minter(callerSeed);

        vm.prank(caller);
        (bool zeroSuccess,) =
            address(controller).call(abi.encodeWithSignature("transferOwnership(address)", address(0)));
        vm.prank(caller);
        (bool selfSuccess,) =
            address(controller).call(abi.encodeWithSignature("transferOwnership(address)", address(controller)));
        vm.prank(caller);
        (bool renounceSuccess,) = address(controller).call(abi.encodeWithSignature("renounceOwnership()"));

        assertFalse(zeroSuccess, "zero owner accepted");
        assertFalse(selfSuccess, "self owner accepted");
        assertFalse(renounceSuccess, "ownership renunciation accepted");
        assertEq(controller.owner(), ownerBefore, "invalid ownership call changed owner");
    }

    function attemptUnauthorizedRoleMutation(uint8 callerSeed, uint8 accountSeed) external {
        address caller = _minter(callerSeed);
        address account = _minter(accountSeed);
        uint256 rolesBefore = controller.rolesOf(account);
        uint256 minterRole = controller.MINTER_ROLE();

        vm.prank(caller);
        (bool success,) =
            address(controller).call(abi.encodeWithSignature("grantRoles(address,uint256)", account, minterRole));

        assertFalse(success, "non-owner changed delegated roles");
        assertEq(controller.rolesOf(account), rolesBefore, "failed role call changed roles");
    }

    function setSablierFailure(bool shouldRevert) external {
        sablier.setRevertCreate(shouldRevert);
    }

    function mint(uint8 callerSeed, uint8 recipientSeed, uint256 rawAmount) external returns (bool success) {
        address caller = callerSeed % 4 == 3 ? expectedOwner : _minter(callerSeed);
        address to = _mintRecipient(recipientSeed);
        // Zero-vesting rejection belongs to the real Sablier integration suite; this permissive local mock models
        // successful stream creation only for production-relevant mint sizes.
        uint256 amount = bound(rawAmount, 3, MAX_SUPPLY * 2);
        uint256 vestingAmount = Math.mulDiv(amount, 30_00, 70_00);
        uint256 combined = amount + vestingAmount;

        uint256 supplyBefore = deep.totalSupply();
        uint256 streamBefore = sablier.nextStreamId();
        uint256 controllerBalanceBefore = deep.balanceOf(address(controller));
        uint256 recipientBalanceBefore = deep.balanceOf(to);
        uint256 sablierBalanceBefore = deep.balanceOf(address(sablier));

        uint40 endsAt = controller.tokenAdministrationEndsAt();
        bool active = endsAt != 0 && endsAt != type(uint40).max && block.timestamp < endsAt;
        bool authorized = caller == expectedOwner || controller.hasAnyRole(caller, controller.MINTER_ROLE());
        bool validAmount = vestingAmount != 0 && vestingAmount <= type(uint128).max;
        bool withinMaxSupply = combined <= MAX_SUPPLY - supplyBefore;
        bool shouldSucceed = active && authorized && validAmount && withinMaxSupply && !sablier.revertCreate();

        bytes memory result;
        vm.prank(caller);
        (success, result) = address(controller).call(abi.encodeCall(DeepstateMinterController.mint, (to, amount)));
        assertEq(success, shouldSucceed, "controlled mint acceptance mismatch");
        lastMintSucceeded = success;

        if (success) {
            uint256 streamId = abi.decode(result, (uint256));
            assertEq(streamId, streamBefore, "unexpected stream id");
            assertEq(deep.totalSupply(), supplyBefore + combined, "mint supply delta mismatch");
            assertEq(deep.balanceOf(to), recipientBalanceBefore + amount, "primary allocation mismatch");
            assertEq(
                deep.balanceOf(address(sablier)), sablierBalanceBefore + vestingAmount, "vesting allocation mismatch"
            );
            assertEq(deep.balanceOf(address(controller)), controllerBalanceBefore, "controller retained new issuance");
            assertEq(deep.allowance(address(controller), address(sablier)), 0, "residual Sablier allowance");

            primaryIssued += amount;
            vestingIssued += vestingAmount;
            ++successfulMints;
            lastSuccessfulMintAt = uint40(block.timestamp);
            primaryAmountForStream[streamId] = amount;
        } else {
            assertEq(deep.totalSupply(), supplyBefore, "failed mint changed supply");
            assertEq(sablier.nextStreamId(), streamBefore, "failed mint consumed a stream id");
            assertEq(deep.balanceOf(to), recipientBalanceBefore, "failed mint changed primary balance");
            assertEq(deep.balanceOf(address(sablier)), sablierBalanceBefore, "failed mint changed Sablier balance");
            assertEq(
                deep.balanceOf(address(controller)), controllerBalanceBefore, "failed mint changed controller balance"
            );
            assertEq(deep.allowance(address(controller), address(sablier)), 0, "failed mint left an allowance");
            if (active && authorized && validAmount && withinMaxSupply && sablier.revertCreate()) {
                ++failedSablierMints;
            }
        }
    }

    function burn(uint8 accountSeed, uint256 rawAmount) external {
        address account = _mintRecipient(accountSeed);
        uint256 amount = bound(rawAmount, 0, deep.balanceOf(account));
        vm.prank(account);
        deep.burn(amount);
        totalBurned += amount;
    }

    function advanceTime(uint64 rawElapsed) external {
        uint256 elapsed = bound(uint256(rawElapsed), 0, 900 days);
        vm.warp(block.timestamp + elapsed);
    }

    function unlock(uint8 callerSeed) external returns (bool success) {
        address caller = callerSeed & 1 == 0 ? _minter(callerSeed) : _mintRecipient(callerSeed);
        uint40 endsAtBefore = controller.tokenAdministrationEndsAt();
        uint256 adminCountBefore = deep.defaultAdminCount();
        bool shouldSucceed = phase == 1 && block.timestamp >= endsAtBefore;

        vm.prank(caller);
        (success,) = address(controller).call(abi.encodeCall(DeepstateMinterController.unlockTokenAdministration, ()));
        assertEq(success, shouldSucceed, "unlock phase boundary mismatch");

        if (success) {
            phase = 2;
            returnedTokenAdmin = expectedOwner;
            assertEq(controller.tokenAdministrationEndsAt(), type(uint40).max, "unlock sentinel not set");
        } else {
            assertEq(controller.tokenAdministrationEndsAt(), endsAtBefore, "failed unlock changed deadline");
            assertEq(deep.defaultAdminCount(), adminCountBefore, "failed unlock changed admin count");
        }
    }

    function minter(uint256 index) external pure returns (address) {
        return _minter(index);
    }

    function mintRecipient(uint256 index) external pure returns (address) {
        return _mintRecipient(index);
    }

    function _minter(uint256 seed) internal pure returns (address) {
        uint256 index = uint256(seed) % 3;
        if (index == 0) return MINTER_A;
        if (index == 1) return MINTER_B;
        return MINTER_C;
    }

    function _mintRecipient(uint256 seed) internal pure returns (address) {
        uint256 index = uint256(seed) % 3;
        if (index == 0) return MINT_RECIPIENT_A;
        if (index == 1) return MINT_RECIPIENT_B;
        return MINT_RECIPIENT_C;
    }

    function _governance(uint8 seed) internal pure returns (address) {
        uint256 index = uint256(seed) % 3;
        if (index == 0) return GOVERNANCE_A;
        if (index == 1) return GOVERNANCE_B;
        return GOVERNANCE_C;
    }
}

contract DeepstateMinterSystemInvariantTest is StdInvariant, Test {
    DeepstateMinterSystemHandler internal handler;
    DeepstateToken internal deep;
    DeepstateMinterController internal controller;
    MockSablierLockupLinearV4 internal sablier;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new DeepstateMinterSystemHandler();
        deep = handler.deep();
        controller = handler.controller();
        sablier = handler.sablier();

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.externalTokenMint.selector;
        selectors[1] = handler.activate.selector;
        selectors[2] = handler.setControllerMinter.selector;
        selectors[3] = handler.renounceControllerMinter.selector;
        selectors[4] = handler.rotateGovernance.selector;
        selectors[5] = handler.attemptInvalidOwnershipChanges.selector;
        selectors[6] = handler.attemptUnauthorizedRoleMutation.selector;
        selectors[7] = handler.setSablierFailure.selector;
        selectors[8] = handler.mint.selector;
        selectors[9] = handler.burn.selector;
        selectors[10] = handler.advanceTime.selector;
        selectors[11] = handler.unlock.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_AdministrationPhaseAndDeadlineAreOneWay() public view {
        uint8 phase = handler.phase();
        uint40 endsAt = controller.tokenAdministrationEndsAt();

        if (phase == 0) {
            assertEq(endsAt, 0);
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_A()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
        } else if (phase == 1) {
            assertEq(endsAt, handler.expectedEndsAt());
            assertEq(endsAt, handler.activationStartedAt() + controller.TOKEN_ADMINISTRATION_DURATION());
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_A()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_B()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_C()));
        } else {
            assertEq(phase, 2);
            assertEq(endsAt, type(uint40).max);
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.returnedTokenAdmin()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        }
    }

    function invariant_ControllerIsTheOnlyTrackedTokenMinterDuringTheTerm() public view {
        uint8 phase = handler.phase();
        assertEq(deep.hasRole(deep.MINTER_ROLE(), address(controller)), phase == 1);

        for (uint256 i; i < 3; ++i) {
            address minter = handler.minter(i);
            assertEq(deep.hasRole(deep.MINTER_ROLE(), minter), phase == 0);
        }
    }

    function invariant_OnlyOwnerAndExplicitControllerRolesCanMint() public view {
        assertEq(controller.owner(), handler.expectedOwner());
        assertNotEq(controller.owner(), address(0));
        assertNotEq(controller.owner(), address(controller));
        for (uint256 i; i < 3; ++i) {
            address minter = handler.minter(i);
            bool expected = handler.expectedControllerMinter(minter);
            assertEq(controller.hasAnyRole(minter, controller.MINTER_ROLE()), expected);
            assertEq(controller.rolesOf(minter) & controller.MINTER_ROLE() != 0, expected);
        }
    }

    function invariant_MintAccountingRespectsTheLiveMaxSupply() public view {
        uint8 phase = handler.phase();
        if (phase == 0) {
            assertEq(handler.activationSupplyBaseline(), 0);
            assertEq(handler.primaryIssued(), 0);
            assertEq(handler.vestingIssued(), 0);
        } else {
            assertLe(handler.activationSupplyBaseline(), handler.externalIssued());
        }

        assertEq(controller.maxSupply(), handler.MAX_SUPPLY());
        assertLe(deep.totalSupply(), controller.maxSupply());
        assertEq(
            deep.totalSupply() + handler.totalBurned(),
            handler.externalIssued() + handler.primaryIssued() + handler.vestingIssued()
        );
    }

    function invariant_EveryMintHasAnExactIndependentOneYearStream() public view {
        uint256 nextStreamId = sablier.nextStreamId();
        assertEq(nextStreamId - 1, handler.successfulMints());

        uint256 summedPrimary;
        uint256 summedVesting;
        for (uint256 streamId = 1; streamId < nextStreamId; ++streamId) {
            uint256 primaryAmount = handler.primaryAmountForStream(streamId);
            uint256 expectedVesting = Math.mulDiv(primaryAmount, 30_00, 70_00);
            MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);

            assertGe(primaryAmount, 3);
            assertEq(created.funder, address(controller));
            assertEq(created.sender, address(controller));
            assertEq(created.recipient, handler.VESTING_RECIPIENT());
            assertEq(created.token, address(deep));
            assertEq(created.depositAmount, expectedVesting);
            assertFalse(created.cancelable);
            assertFalse(created.transferable);
            assertEq(keccak256(bytes(created.shape)), keccak256("Deepstate allocation"));
            assertEq(created.startUnlockAmount, 0);
            assertEq(created.cliffUnlockAmount, 0);
            assertEq(created.granularity, 0);
            assertEq(created.cliffDuration, 0);
            assertEq(created.totalDuration, controller.VESTING_DURATION());

            summedPrimary += primaryAmount;
            summedVesting += expectedVesting;
        }

        assertEq(summedPrimary, handler.primaryIssued());
        assertEq(summedVesting, handler.vestingIssued());
        assertEq(deep.balanceOf(address(sablier)), summedVesting);
        assertEq(deep.balanceOf(address(controller)), 0);
        assertEq(deep.allowance(address(controller), address(sablier)), 0);
    }

    function invariant_NoMintSucceedsOutsideTheStrictAdministrationWindow() public view {
        uint40 lastMintAt = handler.lastSuccessfulMintAt();
        if (handler.successfulMints() != 0) {
            assertGe(lastMintAt, handler.activationStartedAt());
            assertLt(lastMintAt, handler.expectedEndsAt());
        }
        if (handler.phase() == 0) {
            assertEq(handler.successfulMints(), 0);
            assertEq(sablier.nextStreamId(), 1);
        }
    }

    function invariant_ExpirationReturnsAuthorityAndPermanentlyDisablesControllerMinting() public view {
        if (handler.phase() != 2) return;

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.returnedTokenAdmin()));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
        assertEq(controller.tokenAdministrationEndsAt(), type(uint40).max);
    }

    function test_StatefulHarnessActivationPreservesCurrentSupplyWithoutMintOrStream() public {
        handler.externalTokenMint(0, 0, 100e18);
        handler.burn(0, 40e18);
        uint256 streamBefore = sablier.nextStreamId();

        handler.activate();

        assertEq(handler.phase(), 1);
        assertEq(handler.activationSupplyBaseline(), 60e18);
        assertEq(deep.totalSupply(), 60e18);
        assertEq(sablier.nextStreamId(), streamBefore);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
    }

    function test_StatefulHarnessActivationRequiresSoleAdminAndControllerWithoutMinterRole() public {
        bytes32 tokenAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        address governanceA = handler.GOVERNANCE_A();
        vm.prank(governanceA);
        deep.grantRole(tokenAdminRole, address(controller));

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.ControllerNotSoleTokenAdmin.selector, uint256(2))
        );
        vm.prank(governanceA);
        controller.activateTokenAdministration();

        assertEq(controller.tokenAdministrationEndsAt(), 0);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));

        vm.prank(governanceA);
        deep.grantRole(tokenMinterRole, address(controller));
        vm.prank(governanceA);
        deep.renounceRole(tokenAdminRole, governanceA);

        vm.expectRevert(DeepstateMinterController.ControllerAlreadyTokenMinter.selector);
        vm.prank(governanceA);
        controller.activateTokenAdministration();

        assertEq(controller.tokenAdministrationEndsAt(), 0);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
    }

    function test_StatefulHarnessExercisesAtomicSablierFailureAndRecovery() public {
        handler.activate();
        handler.setControllerMinter(0, true);
        handler.setSablierFailure(true);

        bool failed = handler.mint(0, 0, 70e18);
        assertFalse(failed);
        assertEq(handler.failedSablierMints(), 1);
        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);

        handler.setSablierFailure(false);
        bool succeeded = handler.mint(0, 0, 70e18);
        assertTrue(succeeded);
        assertEq(deep.totalSupply(), 100e18);
        assertEq(sablier.nextStreamId(), 2);
    }

    function test_StatefulHarnessMaxSupplyIsExactAndBurningReopensHeadroom() public {
        handler.activate();
        handler.setControllerMinter(0, true);

        uint256 primaryToFillMax = Math.mulDiv(handler.MAX_SUPPLY(), 70_00, 100_00);
        assertTrue(handler.mint(0, 0, primaryToFillMax));
        assertEq(deep.totalSupply(), handler.MAX_SUPPLY());
        assertFalse(handler.mint(0, 0, 3));
        handler.burn(0, 4);
        assertEq(deep.totalSupply(), handler.MAX_SUPPLY() - 4);
        assertTrue(handler.mint(0, 0, 3));
        assertEq(deep.totalSupply(), handler.MAX_SUPPLY());
    }

    function test_StatefulHarnessEnforcesExactDeadlineAndReturnsAdministrationToCurrentOwner() public {
        handler.activate();
        handler.setControllerMinter(0, true);
        handler.rotateGovernance(1);
        uint40 endsAt = controller.tokenAdministrationEndsAt();

        vm.warp(endsAt - 1);
        assertTrue(handler.mint(0, 0, 70e18));

        vm.warp(endsAt);
        assertFalse(handler.mint(0, 0, 70e18));
        assertTrue(handler.unlock(0));
        assertEq(handler.returnedTokenAdmin(), handler.GOVERNANCE_B());
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_B()));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));

        assertFalse(handler.mint(3, 0, 70e18));
    }
}
