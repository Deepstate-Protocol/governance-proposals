// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "../mocks/MockSablierLockupLinearV4.sol";

contract MinterInvariantLegacyRouter {
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

contract MinterInvariantLegacyRewarder {
    address public immutable rewardToken;
    address public immutable deepstate;
    address public constant token0 = address(0x3001);
    address public constant token1 = address(0x3002);
    bytes32 public constant poolId = keccak256(abi.encode(token0, token1));
    uint96 public token0Accrued = 700e18;
    uint96 public token1Accrued = 300e18;
    mapping(address token => uint32 nonce) internal _rewardeeNonce;
    mapping(address token => uint64 startedAt) internal _rewardeeStartedAt;

    constructor(address rewardToken_, address deepstate_) {
        rewardToken = rewardToken_;
        deepstate = deepstate_;
    }

    function totalAccrued(address token) external view returns (uint96) {
        if (token == token0) return token0Accrued;
        if (token == token1) return token1Accrued;
        return 0;
    }

    function setTotalAccrued(uint96 token0Accrued_, uint96 token1Accrued_) external {
        token0Accrued = token0Accrued_;
        token1Accrued = token1Accrued_;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        return (_rewardeeNonce[token], _rewardeeStartedAt[token]);
    }

    function setRewardee(address token, uint32 nonce, uint64 startedAt) external {
        _rewardeeNonce[token] = nonce;
        _rewardeeStartedAt[token] = startedAt;
    }
}

/// @dev Stateful model for the complete DEEP administration term. The handler deliberately exposes both valid and
/// invalid calls so the invariant campaign continuously tests authorization, phase boundaries and atomic rollback.
contract DeepstateMinterSystemHandler is Test {
    uint256 public constant LIVE_SUPPLY_CAP = 3_000_000_000e18;
    uint256 public constant GROSS_ISSUANCE_CAP = 3_000_000_000e18;

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
    MinterInvariantLegacyRouter public immutable legacyRouter;
    MinterInvariantLegacyRewarder public immutable legacyRewarder;

    // 0: not activated, 1: activated (including an elapsed-but-not-returned term), 2: administration returned.
    uint8 public phase;
    address public expectedOwner = GOVERNANCE_A;
    address public returnedTokenAdmin;
    uint40 public activationStartedAt;
    uint40 public expectedEndsAt;

    uint256 public externalIssued;
    uint256 public legacyEndowmentIssued;
    uint256 public primaryIssued;
    uint256 public vestingIssued;
    uint256 public totalBurned;
    uint256 public successfulMints;
    uint256 public failedSablierMints;
    uint256 public externalMinterRevocations;
    uint40 public lastSuccessfulMintAt;
    bool public lastMintSucceeded;
    uint8 public legacyPreconditionFault;

    mapping(address account => bool enabled) public expectedControllerMinter;
    mapping(uint256 streamId => uint256 amount) public primaryAmountForStream;

    constructor() {
        deep = new DeepstateToken(GOVERNANCE_A, "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        legacyRouter = new MinterInvariantLegacyRouter();
        legacyRewarder = new MinterInvariantLegacyRewarder(address(deep), address(legacyRouter));
        legacyRouter.setPoolHook(legacyRewarder.poolId(), address(legacyRewarder));
        controller = new DeepstateMinterController(
            GOVERNANCE_A,
            address(deep),
            address(sablier),
            address(legacyRewarder),
            VESTING_RECIPIENT,
            LIVE_SUPPLY_CAP,
            GROSS_ISSUANCE_CAP
        );

        // Model legacy token-level minters that the activation proposal must remove before starting the term.
        vm.startPrank(GOVERNANCE_A);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_A);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_B);
        deep.grantRole(deep.MINTER_ROLE(), MINTER_C);
        vm.stopPrank();
    }

    /// @dev Randomizes the exact cumulative legacy accrual sampled by the one-time activation call.
    function setLegacyAccrual(uint96 rawToken0Accrued, uint96 rawToken1Accrued) external {
        if (phase != 0) return;
        uint96 token0Accrued = uint96(bound(uint256(rawToken0Accrued), 0, 5_000_000_000e18));
        uint96 token1Accrued = uint96(bound(uint256(rawToken1Accrued), 0, 5_000_000_000e18));
        legacyRewarder.setTotalAccrued(token0Accrued, token1Accrued);
    }

    /// @dev Randomizes whether the live legacy market satisfies the lock's fail-closed idle-state preconditions.
    function setLegacyPreconditionFault(uint8 rawFault) external {
        if (phase != 0) return;
        uint8 fault = rawFault % 6;
        legacyPreconditionFault = fault;

        bytes32 poolId = legacyRewarder.poolId();
        bytes32 bookId = legacyRouter.activeBookId(legacyRewarder.token0(), legacyRewarder.token1());
        legacyRouter.setPoolHook(poolId, address(legacyRewarder));
        legacyRouter.setTopOrder(bookId, true, 0, 0);
        legacyRouter.setTopOrder(bookId, false, 0, 0);
        legacyRewarder.setRewardee(legacyRewarder.token0(), 0, 0);
        legacyRewarder.setRewardee(legacyRewarder.token1(), 0, 0);

        if (fault == 1) legacyRouter.setPoolHook(poolId, address(0xBAD));
        else if (fault == 2) legacyRouter.setTopOrder(bookId, true, 1, 1);
        else if (fault == 3) legacyRouter.setTopOrder(bookId, false, 1, 1);
        else if (fault == 4) legacyRewarder.setRewardee(legacyRewarder.token0(), 1, 1);
        else if (fault == 5) legacyRewarder.setRewardee(legacyRewarder.token1(), 1, 1);
    }

    /// @dev Exercises legacy issuance before activation and proves that the same accounts cannot bypass the controller
    /// once activation has revoked them.
    function externalTokenMint(uint8 minterSeed, uint8 recipientSeed, uint256 rawAmount) external {
        address tokenMinter = _minter(minterSeed);
        address to = _mintRecipient(recipientSeed);
        uint256 supplyBefore = deep.totalSupply();
        // Before governance activates the controller, keep legacy issuance inside the deployment precondition. After
        // activation, attempt the same class of call without constraining it: the revoked role must reject it.
        uint256 maximum = phase == 0 ? LIVE_SUPPLY_CAP - supplyBefore : LIVE_SUPPLY_CAP * 2;
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

    /// @dev Represents the atomic governance ordering: snapshot and stream the endowment, make the controller sole
    /// token admin, revoke every known bypass minter, then start the two-year clock last.
    function activate() external {
        if (phase != 0) return;

        uint96 token0Accrued = legacyRewarder.token0Accrued();
        uint96 token1Accrued = legacyRewarder.token1Accrued();
        uint256 endowmentAmount = Math.mulDiv(uint256(token0Accrued) + uint256(token1Accrued), 30_00, 10_000);
        bool shouldSucceed = endowmentAmount != 0 && endowmentAmount <= GROSS_ISSUANCE_CAP
            && endowmentAmount <= LIVE_SUPPLY_CAP - deep.totalSupply() && !sablier.revertCreate()
            && legacyPreconditionFault == 0;

        (bool success,) = address(this).call(abi.encodeCall(this.executeAtomicActivation, ()));
        assertEq(success, shouldSucceed, "activation acceptance mismatch");
        if (!success) {
            assertFalse(controller.legacyEndowmentCreated(), "failed activation retained endowment state");
            assertEq(controller.grossIssued(), 0, "failed activation changed gross issuance");
            assertFalse(
                deep.hasRole(deep.MINTER_ROLE(), address(controller)), "failed activation retained controller minter"
            );
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), GOVERNANCE_A), "failed activation stranded token admin");
            assertFalse(
                deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)),
                "failed activation retained controller admin"
            );
            for (uint256 i; i < 3; ++i) {
                assertTrue(deep.hasRole(deep.MINTER_ROLE(), _minter(i)), "failed activation revoked legacy minter");
            }
            return;
        }

        legacyEndowmentIssued = endowmentAmount;
        phase = 1;
        activationStartedAt = uint40(block.timestamp);
        expectedEndsAt = uint40(block.timestamp + controller.TOKEN_ADMINISTRATION_DURATION());
        assertEq(controller.tokenAdministrationEndsAt(), expectedEndsAt, "incorrect administration deadline");
        assertEq(controller.legacyToken0Accrued(), token0Accrued, "token0 accrual snapshot mismatch");
        assertEq(controller.legacyToken1Accrued(), token1Accrued, "token1 accrual snapshot mismatch");
        assertEq(controller.legacyEndowmentAmount(), endowmentAmount, "legacy endowment mismatch");
    }

    function executeAtomicActivation() external {
        require(msg.sender == address(this), "only self");
        bytes32 tokenAdminRole = deep.DEFAULT_ADMIN_ROLE();
        vm.prank(GOVERNANCE_A);
        deep.grantRole(tokenAdminRole, address(controller));
        vm.prank(GOVERNANCE_A);
        deep.renounceRole(tokenAdminRole, GOVERNANCE_A);

        assertEq(deep.defaultAdminCount(), 1, "activation must first establish one token admin");
        assertTrue(
            deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)), "controller must administer revocations"
        );

        for (uint256 i; i < 3; ++i) {
            address legacyMinter = _minter(i);
            if (deep.hasRole(deep.MINTER_ROLE(), legacyMinter)) {
                vm.prank(expectedOwner);
                controller.revokeExternalTokenMinter(legacyMinter);
                ++externalMinterRevocations;
            }
        }

        vm.prank(expectedOwner);
        controller.lockTokenAdministration();
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

    /// @dev Ownership may rotate during the locked term. Unlock must return token administration to the owner at the
    /// moment of return, not to the owner that originally activated the controller.
    function rotateGovernance(uint8 ownerSeed) external {
        if (phase != 1) return;

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

        // If the selected minter is also the current governance owner, use another definitely unauthorized caller.
        if (caller == expectedOwner) caller = address(0xBAD);
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
        uint256 amount = bound(rawAmount, 0, LIVE_SUPPLY_CAP * 2);
        uint256 vestingAmount = Math.mulDiv(amount, 30_00, 70_00);
        uint256 combined = amount + vestingAmount;

        uint256 supplyBefore = deep.totalSupply();
        uint256 grossBefore = controller.grossIssued();
        uint256 streamBefore = sablier.nextStreamId();
        uint256 controllerBalanceBefore = deep.balanceOf(address(controller));
        uint256 recipientBalanceBefore = deep.balanceOf(to);
        uint256 sablierBalanceBefore = deep.balanceOf(address(sablier));

        uint40 endsAt = controller.tokenAdministrationEndsAt();
        bool active = endsAt != 0 && endsAt != type(uint40).max && block.timestamp < endsAt;
        bool authorized = caller == expectedOwner || controller.hasAnyRole(caller, controller.MINTER_ROLE());
        bool validAmount = vestingAmount != 0 && vestingAmount <= type(uint128).max;
        bool withinGrossCap = combined <= GROSS_ISSUANCE_CAP - grossBefore;
        bool withinLiveCap = combined <= LIVE_SUPPLY_CAP - supplyBefore;
        bool shouldSucceed =
            active && authorized && validAmount && withinGrossCap && withinLiveCap && !sablier.revertCreate();

        bytes memory result;
        vm.prank(caller);
        (success, result) = address(controller).call(abi.encodeCall(DeepstateMinterController.mint, (to, amount)));
        assertEq(success, shouldSucceed, "controlled mint acceptance mismatch");
        lastMintSucceeded = success;

        if (success) {
            uint256 streamId = abi.decode(result, (uint256));
            assertEq(streamId, streamBefore, "unexpected stream id");
            assertEq(deep.totalSupply(), supplyBefore + combined, "mint supply delta mismatch");
            assertEq(controller.grossIssued(), grossBefore + combined, "gross issuance delta mismatch");
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
            assertEq(controller.grossIssued(), grossBefore, "failed mint changed gross issuance");
            assertEq(sablier.nextStreamId(), streamBefore, "failed mint consumed a stream id");
            assertEq(deep.balanceOf(to), recipientBalanceBefore, "failed mint changed primary balance");
            assertEq(deep.balanceOf(address(sablier)), sablierBalanceBefore, "failed mint changed Sablier balance");
            assertEq(
                deep.balanceOf(address(controller)), controllerBalanceBefore, "failed mint changed controller balance"
            );
            assertEq(deep.allowance(address(controller), address(sablier)), 0, "failed mint left an allowance");
            if (active && authorized && validAmount && withinGrossCap && withinLiveCap && sablier.revertCreate()) {
                ++failedSablierMints;
            }
        }
    }

    function burn(uint8 accountSeed, uint256 rawAmount) external {
        address account = _mintRecipient(accountSeed);
        uint256 balance = deep.balanceOf(account);
        uint256 amount = bound(rawAmount, 0, balance);
        uint256 grossBefore = controller.grossIssued();

        vm.prank(account);
        deep.burn(amount);
        totalBurned += amount;

        assertEq(controller.grossIssued(), grossBefore, "burn reopened gross issuance accounting");
    }

    function advanceTime(uint32 rawElapsed) external {
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

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.externalTokenMint.selector;
        selectors[1] = handler.setLegacyAccrual.selector;
        selectors[2] = handler.setLegacyPreconditionFault.selector;
        selectors[3] = handler.activate.selector;
        selectors[4] = handler.setControllerMinter.selector;
        selectors[5] = handler.renounceControllerMinter.selector;
        selectors[6] = handler.rotateGovernance.selector;
        selectors[7] = handler.attemptInvalidOwnershipChanges.selector;
        selectors[8] = handler.attemptUnauthorizedRoleMutation.selector;
        selectors[9] = handler.setSablierFailure.selector;
        selectors[10] = handler.mint.selector;
        selectors[11] = handler.burn.selector;
        selectors[12] = handler.advanceTime.selector;
        selectors[13] = handler.unlock.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_AdministrationPhaseAndDeadlineAreOneWay() public view {
        uint8 phase = handler.phase();
        uint40 endsAt = controller.tokenAdministrationEndsAt();

        if (phase == 0) {
            assertEq(endsAt, 0);
            assertFalse(controller.legacyEndowmentCreated());
            assertEq(controller.grossIssued(), 0);
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_A()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        } else if (phase == 1) {
            assertTrue(controller.legacyEndowmentCreated());
            assertEq(endsAt, handler.expectedEndsAt());
            assertEq(endsAt, handler.activationStartedAt() + controller.TOKEN_ADMINISTRATION_DURATION());
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_A()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_B()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_C()));
        } else {
            assertEq(phase, 2);
            assertTrue(controller.legacyEndowmentCreated());
            assertEq(endsAt, type(uint40).max);
            assertEq(deep.defaultAdminCount(), 1);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.returnedTokenAdmin()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        }
    }

    function invariant_ControllerIsTheOnlyTrackedTokenMinterDuringTheTerm() public view {
        uint8 phase = handler.phase();
        bool activeOrElapsed = phase == 1;
        assertEq(deep.hasRole(deep.MINTER_ROLE(), address(controller)), activeOrElapsed);
        assertEq(handler.externalMinterRevocations(), phase == 0 ? 0 : 3);

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

    function invariant_MintAccountingRespectsBothPermanentCaps() public view {
        uint256 gross = controller.grossIssued();
        assertEq(gross, handler.legacyEndowmentIssued() + handler.primaryIssued() + handler.vestingIssued());
        assertLe(gross, controller.grossIssuanceCap());
        assertLe(deep.totalSupply(), controller.mintCap());
        assertEq(deep.totalSupply() + handler.totalBurned(), handler.externalIssued() + gross);
    }

    function invariant_EveryMintHasAnExactIndependentOneYearStream() public view {
        uint256 nextStreamId = sablier.nextStreamId();
        uint256 endowmentStreamCount = controller.legacyEndowmentCreated() ? 1 : 0;
        assertEq(nextStreamId - 1, handler.successfulMints() + endowmentStreamCount);

        uint256 summedPrimary;
        uint256 summedVesting;
        for (uint256 streamId = 1; streamId < nextStreamId; ++streamId) {
            MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);
            if (streamId == controller.legacyEndowmentStreamId()) {
                assertEq(created.funder, address(controller));
                assertEq(created.sender, address(controller));
                assertEq(created.recipient, handler.VESTING_RECIPIENT());
                assertEq(created.token, address(deep));
                assertEq(created.depositAmount, handler.legacyEndowmentIssued());
                assertFalse(created.cancelable);
                assertFalse(created.transferable);
                assertEq(keccak256(bytes(created.shape)), keccak256("Deepstate Inc endowment"));
                assertEq(created.startUnlockAmount, 0);
                assertEq(created.cliffUnlockAmount, 0);
                assertEq(created.granularity, 0);
                assertEq(created.cliffDuration, 0);
                assertEq(created.totalDuration, 365 days);
                continue;
            }
            uint256 primaryAmount = handler.primaryAmountForStream(streamId);
            uint256 expectedVesting = Math.mulDiv(primaryAmount, 30_00, 70_00);

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
            assertEq(created.totalDuration, 365 days);

            summedPrimary += primaryAmount;
            summedVesting += expectedVesting;
        }

        assertEq(summedPrimary, handler.primaryIssued());
        assertEq(summedVesting, handler.vestingIssued());
        assertEq(deep.balanceOf(address(sablier)), handler.legacyEndowmentIssued() + summedVesting);
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
            assertEq(controller.grossIssued(), 0);
            assertEq(sablier.nextStreamId(), 1);
        }
    }

    function invariant_LegacyEndowmentIsOneTimeExactAndPrecedesTheAdministrationTerm() public view {
        if (!controller.legacyEndowmentCreated()) {
            assertEq(handler.phase(), 0);
            assertEq(controller.legacyEndowmentAmount(), 0);
            assertEq(controller.legacyEndowmentStreamId(), 0);
            return;
        }

        uint256 totalAccrued = uint256(controller.legacyToken0Accrued()) + uint256(controller.legacyToken1Accrued());
        uint256 expectedEndowment = Math.mulDiv(totalAccrued, 30_00, 10_000);
        assertEq(controller.legacyEndowmentAmount(), expectedEndowment);
        assertEq(handler.legacyEndowmentIssued(), expectedEndowment);
        assertEq(controller.legacyEndowmentSnapshotAt(), handler.activationStartedAt());
        assertEq(controller.legacyEndowmentStreamId(), 1);
        assertTrue(handler.phase() == 1 || handler.phase() == 2);
    }

    function invariant_ExpirationReturnsAuthorityAndPermanentlyDisablesControllerMinting() public view {
        if (handler.phase() != 2) return;

        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.returnedTokenAdmin()));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
        assertEq(controller.tokenAdministrationEndsAt(), type(uint40).max);
    }

    function test_StatefulHarnessExercisesAtomicSablierFailureAndRecovery() public {
        handler.activate();
        handler.setControllerMinter(0, true);
        handler.setSablierFailure(true);

        bool failed = handler.mint(0, 0, 70e18);
        assertFalse(failed);
        assertEq(handler.failedSablierMints(), 1);
        assertEq(deep.totalSupply(), handler.legacyEndowmentIssued());
        assertEq(controller.grossIssued(), handler.legacyEndowmentIssued());
        assertEq(sablier.nextStreamId(), 2);

        handler.setSablierFailure(false);
        bool succeeded = handler.mint(0, 0, 70e18);
        assertTrue(succeeded);
        assertEq(deep.totalSupply(), handler.legacyEndowmentIssued() + 100e18);
        assertEq(controller.grossIssued(), handler.legacyEndowmentIssued() + 100e18);
        assertEq(sablier.nextStreamId(), 3);
    }

    function test_StatefulHarnessActivationRequiresNonzeroAtomicEndowment() public {
        handler.setLegacyAccrual(0, 0);
        handler.activate();

        assertEq(handler.phase(), 0);
        assertFalse(controller.legacyEndowmentCreated());
        assertEq(controller.grossIssued(), 0);
        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));

        handler.setLegacyAccrual(700e18, 300e18);
        handler.setSablierFailure(true);
        handler.activate();
        assertEq(handler.phase(), 0);
        assertFalse(controller.legacyEndowmentCreated());
        assertEq(deep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), 1);

        handler.setSablierFailure(false);
        handler.activate();
        assertEq(handler.phase(), 1);
        assertTrue(controller.legacyEndowmentCreated());
        assertEq(controller.legacyEndowmentAmount(), 300e18);
        assertEq(controller.grossIssued(), 300e18);
        assertEq(deep.totalSupply(), 300e18);
        assertEq(sablier.nextStreamId(), 2);
    }

    function test_StatefulHarnessRejectsEveryNonIdleLegacyMarketStateAtomically() public {
        for (uint8 fault = 1; fault < 6; ++fault) {
            handler.setLegacyPreconditionFault(fault);
            handler.activate();

            assertEq(handler.phase(), 0);
            assertFalse(controller.legacyEndowmentCreated());
            assertEq(controller.tokenAdministrationEndsAt(), 0);
            assertEq(controller.grossIssued(), 0);
            assertEq(deep.totalSupply(), 0);
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), handler.GOVERNANCE_A()));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(controller)));
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(controller)));
        }

        handler.setLegacyPreconditionFault(0);
        handler.activate();
        assertEq(handler.phase(), 1);
        assertTrue(controller.legacyEndowmentCreated());
    }

    function test_StatefulHarnessGrossCapCannotBeReopenedByBurning() public {
        handler.activate();
        handler.setControllerMinter(0, true);

        uint256 remainingGross = handler.GROSS_ISSUANCE_CAP() - handler.legacyEndowmentIssued();
        uint256 primaryToFillGross = Math.mulDiv(remainingGross, 70_00, 100_00);
        assertTrue(handler.mint(0, 0, primaryToFillGross));
        assertEq(controller.grossIssued(), handler.GROSS_ISSUANCE_CAP());
        handler.burn(0, primaryToFillGross);
        assertEq(deep.totalSupply(), handler.legacyEndowmentIssued() + remainingGross - primaryToFillGross);
        assertFalse(handler.mint(0, 0, 3));
        assertEq(controller.grossIssued(), handler.GROSS_ISSUANCE_CAP());
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
