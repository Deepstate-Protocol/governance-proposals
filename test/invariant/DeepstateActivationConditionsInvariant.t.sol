// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../src/DeepstateV1Controller.sol";
import {MockSablierLockupLinearV4} from "../mocks/MockSablierLockupLinearV4.sol";

contract ActivationConditionsToken is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/// @dev Immutable identity and controllable accrued totals needed to model the deployed V1 Rewarder at an idle handoff.
contract ActivationLegacyRewarder {
    address public immutable deepstate;
    address public immutable rewardToken;
    bytes32 public immutable poolId;
    address public immutable token0;
    address public immutable token1;

    mapping(address token => uint96 accrued) public totalAccrued;

    constructor(
        address deepstate_,
        address rewardToken_,
        bytes32 poolId_,
        address token0_,
        address token1_,
        uint96 token0Accrued_,
        uint96 token1Accrued_
    ) {
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        poolId = poolId_;
        token0 = token0_;
        token1 = token1_;
        totalAccrued[token0_] = token0Accrued_;
        totalAccrued[token1_] = token1Accrued_;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        require(token == token0 || token == token1, "invalid token");
        return (0, 0);
    }
}

/// @dev Local execution model for the two dictated governance transitions. This is not a substitute for the
/// eventual pinned archive-fork proposal tests: it proves that the intended ordered calls compose against the current
/// contracts and that the resulting authority/economic state resists unauthorized calls.
contract DeepstateActivationConditionsHandler is Test {
    uint256 public constant EXISTING_REWARDER_ALLOCATION = 1_000_000_000e18;
    uint96 public constant LEGACY_TOKEN0_ACCRUED = 76_668_471_827185259478605328;
    uint96 public constant LEGACY_TOKEN1_ACCRUED = 71_607_902_174090642172829949;
    uint256 public constant ENDOWMENT = (uint256(LEGACY_TOKEN0_ACCRUED) + uint256(LEGACY_TOKEN1_ACCRUED)) * 30 / 100;
    uint256 public constant VOLUNTEER_PRIMARY = 10_000_000e18;
    uint256 public constant VOLUNTEER_A_AMOUNT = 3_333_333_333333333333333334;
    uint256 public constant VOLUNTEER_B_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VOLUNTEER_C_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VOLUNTEER_VESTING = 4_285_714_285714285714285714;
    uint256 public constant MARKET_PRIMARY = 100_000_000e18;
    uint256 public constant MARKET_VESTING = 42_857_142_857142857142857142;
    uint256 public constant LIVE_AND_GROSS_CAP = 3_000_000_000e18;
    uint256 public constant FACTORY_FUNDING_BUDGET = 1_000_000_000e18;
    uint256 public constant LEGACY_POOL_HOOK_FLAGS = (uint256(1) << 254) | (uint256(1) << 255);
    uint256 internal constant _POOL_STATE_MAPPING_SLOT = 2;

    address public constant INC_SAFE = 0x83fB2739abd9963c5341E4A176D93a7E5Ee73445;
    address public constant VOLUNTEER_A = 0x1fb3A8192d00aDe0ddC0EEcB4D872149Eb9C4157;
    address public constant VOLUNTEER_B = 0x5715d61f99487abD65D1091b5d3a46c1b2879355;
    address public constant VOLUNTEER_C = 0xEb01dF2A97A966f96B1765c78ccD97f3412765F0;
    address public constant FEE_RECIPIENT = address(0xFEE);
    address public constant LEGACY_BYPASS_MINTER = address(0x4000);
    address public constant OUTSIDER = address(0x5000);

    DeepstateToken public immutable deep;
    MockSablierLockupLinearV4 public immutable sablier;
    DeepstateV1 public immutable router;
    DeepstateMinterController public immutable minterController;
    DeepstateV1Controller public immutable v1Controller;
    DeepstateRewarderFactory public immutable factory;
    ActivationConditionsToken public immutable usdG;
    ActivationConditionsToken public immutable stock;
    ActivationLegacyRewarder public immutable legacyRewarder;

    bytes32 public immutable legacyPoolId;
    bytes32 public immutable legacyPoolStateSlot;
    address public immutable legacyToken0;
    address public immutable legacyToken1;
    address public immutable rewarderV2;
    uint40 public immutable administrationEndsAt;
    uint256 public unauthorizedAttempts;
    bool public unauthorizedMutation;

    constructor() {
        vm.warp(1_000_000);
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        router = new DeepstateV1();
        usdG = new ActivationConditionsToken("USDG", "USDG", 6);
        stock = new ActivationConditionsToken("NVIDIA", "NVDA", 18);

        (address token0, address token1) =
            address(usdG) < address(stock) ? (address(usdG), address(stock)) : (address(stock), address(usdG));
        legacyToken0 = token0;
        legacyToken1 = token1;
        bytes32 poolId = router.poolId(token0, token1);
        legacyPoolId = poolId;
        legacyPoolStateSlot = keccak256(abi.encode(poolId, _POOL_STATE_MAPPING_SLOT));
        legacyRewarder = new ActivationLegacyRewarder(
            address(router), address(deep), poolId, token0, token1, LEGACY_TOKEN0_ACCRUED, LEGACY_TOKEN1_ACCRUED
        );

        // Model the live one-billion-DEEP Rewarder allocation before deploying or activating the Minter Controller.
        // The existing Rewarder remains funded after its exact hook is atomically replaced.
        deep.grantRole(deep.MINTER_ROLE(), address(this));
        deep.mint(address(legacyRewarder), EXISTING_REWARDER_ALLOCATION);

        minterController = new DeepstateMinterController(
            address(this),
            address(deep),
            address(sablier),
            address(legacyRewarder),
            INC_SAFE,
            LIVE_AND_GROSS_CAP,
            LIVE_AND_GROSS_CAP
        );
        v1Controller = new DeepstateV1Controller(address(this), address(router));
        factory = new DeepstateRewarderFactory(
            address(this), address(v1Controller), address(minterController), address(usdG), FACTORY_FUNDING_BUDGET
        );

        router.setFeeConfig(FEE_RECIPIENT, 10);
        router.setPoolHookConfig(token0, token1, address(legacyRewarder), true, true);

        rewarderV2 = _executeCombinedActivation();
        administrationEndsAt = minterController.tokenAdministrationEndsAt();
        _executeVolunteerAllocation();
    }

    function attemptDirectTokenMint(uint8 actorSeed, uint128 amountSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        _assertFailedWithoutMutation(
            actor, address(deep), abi.encodeCall(DeepstateToken.mint, (actor, uint256(amountSeed) + 1))
        );
    }

    function attemptControlledMint(uint8 actorSeed, uint128 amountSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        uint256 amount = bound(uint256(amountSeed), 3, type(uint128).max);
        _assertFailedWithoutMutation(
            actor, address(minterController), abi.encodeCall(DeepstateMinterController.mint, (actor, amount))
        );
    }

    function attemptFeeChange(uint8 actorSeed, uint16 bpsSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        uint16 bps = uint16(bound(bpsSeed, 0, 100));
        _assertFailedWithoutMutation(
            actor, address(v1Controller), abi.encodeCall(DeepstateV1Controller.setDeepstateFeeConfig, (actor, bps))
        );
    }

    function attemptV1HookChange(uint8 actorSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        _assertFailedWithoutMutation(
            actor,
            address(v1Controller),
            abi.encodeCall(
                DeepstateV1Controller.setPoolHookConfig, (legacyToken0, legacyToken1, address(0), false, false)
            )
        );
    }

    function attemptDirectRouterHookChange(uint8 actorSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        _assertFailedWithoutMutation(
            actor,
            address(router),
            abi.encodeCall(DeepstateV1.setPoolHookConfig, (legacyToken0, legacyToken1, address(0), false, false))
        );
    }

    function attemptRouterOwnershipChange(uint8 actorSeed, uint8 nextOwnerSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        address nextOwner = _unauthorizedActor(nextOwnerSeed);
        _assertFailedWithoutMutation(
            actor, address(v1Controller), abi.encodeCall(DeepstateV1Controller.transferDeepstateOwnership, (nextOwner))
        );
        _assertFailedWithoutMutation(
            actor, address(router), abi.encodeWithSignature("transferOwnership(address)", nextOwner)
        );
    }

    function attemptPrivilegeMutation(uint8 actorSeed, uint8 targetSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        address target = _unauthorizedActor(targetSeed);
        _assertFailedWithoutMutation(
            actor,
            address(minterController),
            abi.encodeWithSignature("grantRoles(address,uint256)", target, minterController.MINTER_ROLE())
        );
        _assertFailedWithoutMutation(
            actor, address(v1Controller), abi.encodeWithSignature("grantRoles(address,uint256)", target, 1)
        );
        _assertFailedWithoutMutation(
            actor, address(factory), abi.encodeCall(DeepstateRewarderFactory.setOperator, (target))
        );
    }

    function advanceWithinMintWindow(uint32 elapsedSeed) external {
        uint256 maximum = uint256(administrationEndsAt) - 1 - block.timestamp;
        vm.warp(block.timestamp + bound(uint256(elapsedSeed), 0, maximum));
    }

    function attemptEarlyUnlock(uint8 actorSeed) external {
        address actor = _unauthorizedActor(actorSeed);
        _assertFailedWithoutMutation(
            actor, address(minterController), abi.encodeCall(DeepstateMinterController.unlockTokenAdministration, ())
        );
    }

    function _executeCombinedActivation() internal returns (address deployedRewarder) {
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        deep.grantRole(tokenMinterRole, LEGACY_BYPASS_MINTER);

        // Every bypass is removed before governance gives up administration. The controller self-grants its sole
        // token-level minter role and creates the accrued-emissions endowment inside the atomic lock call.
        deep.revokeRole(tokenMinterRole, address(this));
        deep.revokeRole(tokenMinterRole, LEGACY_BYPASS_MINTER);
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.lockTokenAdministration();
        assertEq(minterController.legacyEndowmentAmount(), ENDOWMENT);

        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        router.transferOwnership(address(v1Controller));
        v1Controller.grantRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        DeepstateRewarderV2 migrated = factory.migrateMarket(
            DeepstateRewarderFactory.MarketConfig({
                stockToken: address(stock),
                stockStartQuantity: 1e18,
                stockMaxQuantity: 5_000e18,
                stockBuySideActive: true,
                usdGBuySideActive: true
            }),
            address(legacyRewarder)
        );
        factory.setOperator(INC_SAFE);
        deployedRewarder = address(migrated);
    }

    function _executeVolunteerAllocation() internal {
        minterController.mint(address(this), VOLUNTEER_PRIMARY);
        assertEq(VOLUNTEER_A_AMOUNT + VOLUNTEER_B_AMOUNT + VOLUNTEER_C_AMOUNT, VOLUNTEER_PRIMARY);
        assertTrue(deep.transfer(VOLUNTEER_A, VOLUNTEER_A_AMOUNT));
        assertTrue(deep.transfer(VOLUNTEER_B, VOLUNTEER_B_AMOUNT));
        assertTrue(deep.transfer(VOLUNTEER_C, VOLUNTEER_C_AMOUNT));
    }

    function _assertFailedWithoutMutation(address actor, address target, bytes memory callData) internal {
        ++unauthorizedAttempts;
        uint256 supplyBefore = deep.totalSupply();
        uint256 grossBefore = minterController.grossIssued();
        uint256 streamsBefore = sablier.nextStreamId();
        uint256 minterRolesBefore = minterController.rolesOf(address(factory));
        uint256 hookRolesBefore = v1Controller.rolesOf(address(factory));
        address operatorBefore = factory.operator();
        address routerOwnerBefore = router.owner();
        bytes32 legacyPoolStateBefore = vm.load(address(router), legacyPoolStateSlot);
        uint256 existingRewarderBalanceBefore = deep.balanceOf(address(legacyRewarder));
        (address feeRecipientBefore, uint16 feeBpsBefore) = router.feeConfig();

        vm.prank(actor);
        (bool success,) = target.call(callData);
        if (success) unauthorizedMutation = true;
        if (deep.totalSupply() != supplyBefore) unauthorizedMutation = true;
        if (minterController.grossIssued() != grossBefore) unauthorizedMutation = true;
        if (sablier.nextStreamId() != streamsBefore) unauthorizedMutation = true;
        if (minterController.rolesOf(address(factory)) != minterRolesBefore) unauthorizedMutation = true;
        if (v1Controller.rolesOf(address(factory)) != hookRolesBefore) unauthorizedMutation = true;
        if (factory.operator() != operatorBefore) unauthorizedMutation = true;
        if (router.owner() != routerOwnerBefore) unauthorizedMutation = true;
        if (vm.load(address(router), legacyPoolStateSlot) != legacyPoolStateBefore) unauthorizedMutation = true;
        if (deep.balanceOf(address(legacyRewarder)) != existingRewarderBalanceBefore) unauthorizedMutation = true;
        (address feeRecipientAfter, uint16 feeBpsAfter) = router.feeConfig();
        if (feeRecipientAfter != feeRecipientBefore || feeBpsAfter != feeBpsBefore) unauthorizedMutation = true;
    }

    function _unauthorizedActor(uint8 seed) internal pure returns (address) {
        uint256 index = uint256(seed) % 5;
        if (index == 0) return INC_SAFE;
        if (index == 1) return VOLUNTEER_A;
        if (index == 2) return VOLUNTEER_B;
        if (index == 3) return VOLUNTEER_C;
        return OUTSIDER;
    }
}

contract DeepstateActivationConditionsInvariantTest is StdInvariant, Test {
    DeepstateActivationConditionsHandler internal handler;
    DeepstateToken internal deep;
    MockSablierLockupLinearV4 internal sablier;
    DeepstateMinterController internal minterController;
    DeepstateV1Controller internal v1Controller;
    DeepstateRewarderFactory internal factory;
    DeepstateV1 internal router;

    function setUp() public {
        handler = new DeepstateActivationConditionsHandler();
        deep = handler.deep();
        sablier = handler.sablier();
        minterController = handler.minterController();
        v1Controller = handler.v1Controller();
        factory = handler.factory();
        router = handler.router();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.attemptDirectTokenMint.selector;
        selectors[1] = handler.attemptControlledMint.selector;
        selectors[2] = handler.attemptFeeChange.selector;
        selectors[3] = handler.attemptPrivilegeMutation.selector;
        selectors[4] = handler.attemptV1HookChange.selector;
        selectors[5] = handler.attemptDirectRouterHookChange.selector;
        selectors[6] = handler.attemptRouterOwnershipChange.selector;
        selectors[7] = handler.advanceWithinMintWindow.selector;
        selectors[8] = handler.attemptEarlyUnlock.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ExactEndowmentAndVolunteerEconomicsRemainTrue() public view {
        assertFalse(handler.unauthorizedMutation());
        assertEq(sablier.nextStreamId(), 4);
        assertEq(
            handler.ENDOWMENT(),
            (uint256(handler.LEGACY_TOKEN0_ACCRUED()) + uint256(handler.LEGACY_TOKEN1_ACCRUED())) * 30 / 100
        );

        MockSablierLockupLinearV4.Stream memory endowment = sablier.stream(1);
        _assertLinearStream(endowment, address(minterController), handler.ENDOWMENT(), "Deepstate Inc endowment");
        MockSablierLockupLinearV4.Stream memory marketVesting = sablier.stream(2);
        _assertLinearStream(marketVesting, address(minterController), handler.MARKET_VESTING(), "Deepstate allocation");
        MockSablierLockupLinearV4.Stream memory volunteerVesting = sablier.stream(3);
        _assertLinearStream(
            volunteerVesting, address(minterController), handler.VOLUNTEER_VESTING(), "Deepstate allocation"
        );

        assertEq(deep.balanceOf(handler.VOLUNTEER_A()), handler.VOLUNTEER_A_AMOUNT());
        assertEq(deep.balanceOf(handler.VOLUNTEER_B()), handler.VOLUNTEER_B_AMOUNT());
        assertEq(deep.balanceOf(handler.VOLUNTEER_C()), handler.VOLUNTEER_C_AMOUNT());
        assertEq(deep.balanceOf(address(handler.legacyRewarder())), handler.EXISTING_REWARDER_ALLOCATION());
        assertEq(deep.balanceOf(handler.rewarderV2()), handler.MARKET_PRIMARY());
        assertEq(deep.balanceOf(address(handler)), 0);
        assertEq(deep.balanceOf(address(minterController)), 0);
        assertEq(deep.allowance(address(minterController), address(sablier)), 0);
        assertEq(
            deep.balanceOf(address(sablier)),
            handler.ENDOWMENT() + handler.MARKET_VESTING() + handler.VOLUNTEER_VESTING()
        );
        uint256 expectedSupply = handler.EXISTING_REWARDER_ALLOCATION() + handler.ENDOWMENT() + handler.MARKET_PRIMARY()
            + handler.MARKET_VESTING() + handler.VOLUNTEER_PRIMARY() + handler.VOLUNTEER_VESTING();
        assertEq(deep.totalSupply(), expectedSupply);
        uint256 expectedGross = handler.ENDOWMENT() + handler.MARKET_PRIMARY() + handler.MARKET_VESTING()
            + handler.VOLUNTEER_PRIMARY() + handler.VOLUNTEER_VESTING();
        assertEq(minterController.grossIssued(), expectedGross);
        assertTrue(minterController.legacyEndowmentCreated());
        assertEq(minterController.legacyToken0Accrued(), handler.LEGACY_TOKEN0_ACCRUED());
        assertEq(minterController.legacyToken1Accrued(), handler.LEGACY_TOKEN1_ACCRUED());
        assertEq(minterController.legacyEndowmentAmount(), handler.ENDOWMENT());
        assertEq(minterController.legacyEndowmentStreamId(), 1);
        assertEq(minterController.mintCap() - deep.totalSupply(), handler.LIVE_AND_GROSS_CAP() - expectedSupply);
        assertEq(
            minterController.grossIssuanceCap() - minterController.grossIssued(),
            handler.LIVE_AND_GROSS_CAP() - expectedGross
        );
    }

    function invariant_ActivatedAuthorityIsExactlyBoundedAndExistingRouterStateIsPreserved() public view {
        assertFalse(handler.unauthorizedMutation());
        assertEq(minterController.owner(), address(handler));
        assertEq(v1Controller.owner(), address(handler));
        assertEq(factory.owner(), address(handler));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(handler)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(handler)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(factory)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), handler.LEGACY_BYPASS_MINTER()));

        assertEq(minterController.rolesOf(address(factory)), minterController.MINTER_ROLE());
        assertEq(v1Controller.rolesOf(address(factory)), v1Controller.HOOK_MANAGER_ROLE());
        assertEq(factory.operator(), handler.INC_SAFE());
        assertEq(router.owner(), address(v1Controller));
        assertEq(router.poolHook(handler.legacyPoolId()), handler.rewarderV2());
        assertEq(uint256(vm.load(address(router), handler.legacyPoolStateSlot())), handler.LEGACY_POOL_HOOK_FLAGS());
        (address feeRecipient, uint16 feeBps) = router.feeConfig();
        assertEq(feeRecipient, handler.FEE_RECIPIENT());
        assertEq(feeBps, 10);

        assertEq(factory.fundingBudget(), handler.FACTORY_FUNDING_BUDGET());
        assertEq(factory.fundingCommitted(), handler.MARKET_PRIMARY());
        assertEq(factory.nextDeploymentAt(), 1_000_000 + 3 days);
        assertEq(factory.activeRewarder(handler.legacyPoolId()), handler.rewarderV2());
        assertEq(factory.rewarderPool(handler.rewarderV2()), handler.legacyPoolId());
        assertTrue(factory.marketDeployed(handler.legacyPoolId()));
        DeepstateRewarderV2 migrated = DeepstateRewarderV2(handler.rewarderV2());
        assertEq(migrated.owner(), address(factory));
        assertEq(migrated.sideEmissionCap(), 50_000_000e18);
        assertEq(migrated.emissionDuration(), 365 days);
        assertEq(migrated.token0(), handler.legacyToken0());
        assertEq(migrated.token1(), handler.legacyToken1());
        assertEq(deep.balanceOf(address(handler.legacyRewarder())), handler.EXISTING_REWARDER_ALLOCATION());
        bytes32 activeBookId = router.activeBookId(handler.legacyToken0(), handler.legacyToken1());
        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(activeBookId, true);
        (uint32 askNonce, uint160 askAmount) = router.topOrder(activeBookId, false);
        assertEq(bidNonce, 0);
        assertEq(bidAmount, 0);
        assertEq(askNonce, 0);
        assertEq(askAmount, 0);
        (uint32 token0Cursor,) = handler.legacyRewarder().rewardees(handler.legacyToken0());
        (uint32 token1Cursor,) = handler.legacyRewarder().rewardees(handler.legacyToken1());
        assertEq(token0Cursor, 0);
        assertEq(token1Cursor, 0);
        assertEq(minterController.tokenAdministrationEndsAt(), handler.administrationEndsAt());
        assertLt(block.timestamp, handler.administrationEndsAt());
    }

    function test_EveryUnauthorizedAttackSelectorIsNonVacuousAndLeavesStateUnchanged() public {
        bytes32 beforeState = _systemFingerprint();
        uint256 attemptsBefore = handler.unauthorizedAttempts();

        handler.attemptDirectTokenMint(0, 1);
        handler.attemptControlledMint(1, 70e18);
        handler.attemptFeeChange(2, 25);
        handler.attemptPrivilegeMutation(3, 4);
        handler.attemptV1HookChange(4);
        handler.attemptDirectRouterHookChange(0);
        handler.attemptRouterOwnershipChange(1, 2);
        handler.attemptEarlyUnlock(3);

        // Eight attack selectors issue eleven unauthorized low-level calls: privilege mutation issues three and
        // Router ownership mutation issues two. Every one must fail without changing the system fingerprint.
        assertEq(handler.unauthorizedAttempts() - attemptsBefore, 11);
        assertFalse(handler.unauthorizedMutation());
        assertEq(_systemFingerprint(), beforeState);
    }

    function _systemFingerprint() internal view returns (bytes32) {
        (address feeRecipient, uint16 feeBps) = router.feeConfig();
        return keccak256(
            abi.encode(
                deep.totalSupply(),
                minterController.grossIssued(),
                sablier.nextStreamId(),
                deep.balanceOf(address(handler.legacyRewarder())),
                deep.balanceOf(handler.rewarderV2()),
                deep.balanceOf(handler.VOLUNTEER_A()),
                deep.balanceOf(handler.VOLUNTEER_B()),
                deep.balanceOf(handler.VOLUNTEER_C()),
                deep.balanceOf(address(sablier)),
                minterController.rolesOf(address(factory)),
                v1Controller.rolesOf(address(factory)),
                factory.operator(),
                router.owner(),
                router.poolHook(handler.legacyPoolId()),
                vm.load(address(router), handler.legacyPoolStateSlot()),
                factory.fundingCommitted(),
                factory.nextDeploymentAt(),
                feeRecipient,
                feeBps,
                minterController.tokenAdministrationEndsAt()
            )
        );
    }

    function _assertLinearStream(
        MockSablierLockupLinearV4.Stream memory stream,
        address expectedFunder,
        uint256 expectedAmount,
        string memory expectedShape
    ) internal view {
        assertEq(stream.funder, expectedFunder);
        assertEq(stream.sender, expectedFunder);
        assertEq(stream.recipient, handler.INC_SAFE());
        assertEq(stream.token, address(deep));
        assertEq(stream.depositAmount, expectedAmount);
        assertFalse(stream.cancelable);
        assertFalse(stream.transferable);
        assertEq(keccak256(bytes(stream.shape)), keccak256(bytes(expectedShape)));
        assertEq(stream.startUnlockAmount, 0);
        assertEq(stream.cliffUnlockAmount, 0);
        assertEq(stream.granularity, 0);
        assertEq(stream.cliffDuration, 0);
        assertEq(stream.totalDuration, 365 days);
    }
}
