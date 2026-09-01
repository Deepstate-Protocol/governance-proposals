// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {DeepstateRewarder} from "deepstate-protocol/DeepstateRewarder.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract FactoryTestToken is ERC20 {
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

contract FactoryNoDecimalsToken {}

contract FactoryRevertingDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert();
    }
}

contract DeepstateRewarderFactoryTest is Test {
    address internal constant LIVE_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant LIVE_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    DeepstateToken internal deep;
    DeepstateV1 internal deepstate;
    DeepstateV1Controller internal v1Controller;
    DeepstateMinterController internal minterController;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;
    FactoryTestToken internal token6;
    FactoryTestToken internal token8;
    FactoryTestToken internal token18;
    FactoryTestToken internal token18B;

    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal vestingRecipient = makeAddr("vestingRecipient");

    function setUp() public {
        vm.warp(1_000_000);
        token6 = new FactoryTestToken("Token 6", "T6", 6);
        token8 = new FactoryTestToken("Token 8", "T8", 8);
        token18 = new FactoryTestToken("Token 18", "T18", 18);
        token18B = new FactoryTestToken("Token 18 B", "T18B", 18);
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstate = new DeepstateV1();
        v1Controller = new DeepstateV1Controller(address(this), address(deepstate));
        minterController = _newMinterController();
        factory = new DeepstateRewarderFactory(address(this), address(v1Controller), address(minterController));

        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        deepstate.transferOwnership(address(v1Controller));
        v1Controller.grantRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        factory.setOperator(operator);
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.operator(), operator);
        assertEq(address(factory.deepstateV1Controller()), address(v1Controller));
        assertEq(address(factory.deepstate()), address(deepstate));
        assertEq(address(factory.minterController()), address(minterController));
        assertEq(address(factory.rewardToken()), address(deep));
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 365 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 50_000_000e18);
        assertEq(factory.MARKET_FUNDING(), 100_000_000e18);
        assertEq(factory.MAX_QUANTITY_GROWTH(), 1_000_000);
        assertTrue(minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()));
        assertTrue(v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE()));
    }

    function test_ConstructorRejectsInvalidOwner() public {
        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        new DeepstateRewarderFactory(address(0), address(v1Controller), address(minterController));
    }

    function test_OperatorDeploysGenericCanonicalPairWithPerSideWholeUnits() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 1_000_000, 5_000, true, false);
        bytes32 poolId = _poolId(config.token0, config.token1);

        vm.expectEmit(true, false, false, true, address(factory));
        emit DeepstateRewarderFactory.RewarderDeployed(
            poolId, address(0), config.token0, config.token1, config.token0Active, config.token1Active
        );
        vm.expectEmit(true, false, false, true, address(factory));
        emit DeepstateRewarderFactory.RewarderFunded(poolId, address(0), 100_000_000e18);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertEq(rewarder.owner(), address(factory));
        assertEq(rewarder.poolId(), poolId);
        assertEq(rewarder.token0(), config.token0);
        assertEq(rewarder.token1(), config.token1);
        _assertQuantities(rewarder, config);
        assertEq(deepstate.poolHook(poolId), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), uint256(rewarder.sideEmissionCap()) * 2);
        assertEq(deep.balanceOf(address(sablier)), _vesting(100_000_000e18));
    }

    function test_LiveUSDGAndNVDAAreJustAnOrdinaryExplicitPair() public {
        FactoryTestToken sixDecimals = new FactoryTestToken("USDG", "USDG", 6);
        FactoryTestToken eighteenDecimals = new FactoryTestToken("NVDA", "NVDA", 18);
        vm.etch(LIVE_USDG, address(sixDecimals).code);
        vm.etch(LIVE_NVDA, address(eighteenDecimals).code);

        DeepstateRewarderFactory.MarketConfig memory config =
            _canonicalConfig(LIVE_USDG, LIVE_NVDA, 1_000_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertEq(rewarder.token0(), LIVE_USDG);
        assertEq(rewarder.token1(), LIVE_NVDA);
        assertEq(rewarder.token0StartQuantity(), 1e6);
        assertEq(rewarder.token0MaxQuantity(), 1_000_000e6);
        assertEq(rewarder.token1StartQuantity(), 1e18);
        assertEq(rewarder.token1MaxQuantity(), 5_000e18);
    }

    function test_NativeTokenIsAllowedAsToken0AndUsesWeiScale() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _canonicalConfig(address(0), address(token18), 20_000, 5_000, true, true);

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertEq(rewarder.token0(), address(0));
        assertEq(rewarder.token0StartQuantity(), 1e18);
        assertEq(rewarder.token0MaxQuantity(), 20_000e18);
        assertEq(rewarder.token1StartQuantity(), 1e18);
        assertEq(rewarder.token1MaxQuantity(), 5_000e18);
        assertEq(deepstate.poolHook(rewarder.poolId()), address(rewarder));
    }

    function test_CallerMustSupplyCanonicalTokenOrder() public {
        address lower = address(token6) < address(token18) ? address(token6) : address(token18);
        address higher = lower == address(token6) ? address(token18) : address(token6);
        DeepstateRewarderFactory.MarketConfig memory config = DeepstateRewarderFactory.MarketConfig({
            token0: higher,
            token1: lower,
            token0MaxUnits: 5_000,
            token1MaxUnits: 5_000,
            token0Active: true,
            token1Active: true
        });

        vm.expectRevert(DeepstateRewarder.InvalidPool.selector);
        vm.prank(operator);
        factory.deployMarket(config);
    }

    function test_OperatorMayIntentionallyDeployWithBothHookSidesDisabled() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, false, false);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertEq(deepstate.poolHook(rewarder.poolId()), address(rewarder));
    }

    function test_DeploymentCooldownIsGlobalAndAllowsExactBoundary() public {
        vm.prank(operator);
        factory.deployMarket(_market(address(token6), address(token18), 5_000, 5_000, true, true));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(operator);
        factory.deployMarket(_market(address(token8), address(token18B), 5_000, 5_000, true, true));

        vm.warp(next);
        vm.prank(operator);
        DeepstateRewarderV2 second =
            factory.deployMarket(_market(address(token8), address(token18B), 5_000, 5_000, true, true));
        assertEq(deepstate.poolHook(second.poolId()), address(second));
    }

    function test_OnlyOwnerSetsOperatorAndOwnershipCannotBeRenouncedOrSelfAssigned() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.setOperator(alice);

        factory.setOperator(address(0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.deployMarket(_market(address(token6), address(token18), 5_000, 5_000, true, true));

        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        factory.renounceOwnership();
        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        factory.transferOwnership(address(factory));
    }

    function test_RemovalOnlyUnlinksAndPreservesRewarderBalanceAndAccounting() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        bytes32 poolId = rewarder.poolId();
        uint256 balance = deep.balanceOf(address(rewarder));
        uint256 supply = deep.totalSupply();

        vm.expectEmit(true, true, false, false, address(factory));
        emit DeepstateRewarderFactory.MarketHookCleared(poolId, address(rewarder));
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);

        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(deep.balanceOf(address(rewarder)), balance);
        assertEq(deep.totalSupply(), supply);
    }

    function test_RemovalIsTrustedAndUnlinksWhateverHookIsCurrentlyInstalled() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        factory.deployMarket(config);
        deepstateV1Controller().setPoolHookConfig(config.token0, config.token1, alice, true, false);

        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);
        assertEq(deepstate.poolHook(_poolId(config.token0, config.token1)), address(0));
    }

    function test_RemovingAnEmptyCanonicalPoolIsIdempotent() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);
        assertEq(deepstate.poolHook(_poolId(config.token0, config.token1)), address(0));
    }

    function test_BurnIsIndependentOfRemovalAndCallableByOperatorOrOwner() public {
        DeepstateRewarderFactory.MarketConfig memory first =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 active = factory.deployMarket(first);

        vm.prank(operator);
        factory.burnBalance(address(active));
        assertEq(deep.balanceOf(address(active)), 0);
        assertEq(deepstate.poolHook(active.poolId()), address(active));

        vm.warp(factory.nextDeploymentAt());
        DeepstateRewarderFactory.MarketConfig memory second =
            _market(address(token8), address(token18B), 5_000, 5_000, true, true);
        DeepstateRewarderV2 removed = factory.deployMarket(second);
        factory.removeMarket(second.token0, second.token1);
        assertEq(deep.balanceOf(address(removed)), 100_000_000e18);

        factory.burnBalance(address(removed));
        assertEq(deep.balanceOf(address(removed)), 0);
        assertEq(deepstate.poolHook(removed.poolId()), address(0));
    }

    function test_UnauthorizedCannotDeployRemoveOrBurn() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.deployMarket(config);

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.removeMarket(config.token0, config.token1);
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.burnBalance(address(rewarder));
    }

    function test_BurnFailureDoesNotUndoAnEarlierRemoval() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);
        uint256 balance = deep.balanceOf(address(rewarder));
        bytes memory injectedFailure = abi.encodeWithSignature("InjectedBurnFailure()");
        vm.mockCallRevert(address(deep), abi.encodeCall(DeepstateToken.burn, (balance)), injectedFailure);

        vm.expectRevert(injectedFailure);
        vm.prank(operator);
        factory.burnBalance(address(rewarder));
        vm.clearMockedCalls();

        assertEq(deepstate.poolHook(rewarder.poolId()), address(0));
        assertEq(deep.balanceOf(address(rewarder)), balance);
    }

    function test_UnlinkedPoolCanRedeployAfterCooldownWithoutTouchingThePreviousRewarder() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);

        vm.prank(operator);
        DeepstateRewarderV2 first = factory.deployMarket(config);
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);
        vm.warp(factory.nextDeploymentAt());
        vm.prank(operator);
        DeepstateRewarderV2 second = factory.deployMarket(config);

        assertNotEq(address(first), address(second));
        assertEq(deepstate.poolHook(second.poolId()), address(second));
        assertEq(deep.balanceOf(address(first)), factory.MARKET_FUNDING());
        assertEq(deep.balanceOf(address(second)), factory.MARKET_FUNDING());
    }

    function test_WholeUnitScalingWorksIndependentlyOnSixEightAndEighteenDecimalSides() public {
        FactoryTestToken[3] memory tokens = [token6, token8, token18];
        uint256[3] memory scales = [uint256(1e6), uint256(1e8), uint256(1e18)];

        for (uint256 i; i < tokens.length; ++i) {
            FactoryTestToken partner = new FactoryTestToken("Partner", "PAIR", 18);
            DeepstateRewarderFactory.MarketConfig memory config =
                _market(address(tokens[i]), address(partner), 37_000, 9_000, true, true);
            vm.prank(operator);
            DeepstateRewarderV2 rewarder = factory.deployMarket(config);
            address tested = address(tokens[i]);
            if (rewarder.token0() == tested) {
                assertEq(rewarder.token0StartQuantity(), scales[i]);
                assertEq(rewarder.token0MaxQuantity(), 37_000 * scales[i]);
            } else {
                assertEq(rewarder.token1(), tested);
                assertEq(rewarder.token1StartQuantity(), scales[i]);
                assertEq(rewarder.token1MaxQuantity(), 37_000 * scales[i]);
            }
            vm.warp(factory.nextDeploymentAt());
        }
    }

    function test_GrowthCapAppliesToEachSideAndExactBoundaryPasses() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 1_000_000, 1_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        _assertQuantities(rewarder, config);

        vm.warp(factory.nextDeploymentAt());
        DeepstateRewarderFactory.MarketConfig memory bad =
            _market(address(token8), address(token18B), 1_000_001, 5_000, true, true);
        address badToken = bad.token0MaxUnits == 1_000_001 ? bad.token0 : bad.token1;
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.QuantityGrowthTooLarge.selector, badToken, 1_000_001)
        );
        vm.prank(operator);
        factory.deployMarket(bad);
    }

    function test_InheritedRewarderRejectsEitherSideBelowOneThousandGrowth() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 999, 5_000, true, true);
        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        vm.prank(operator);
        factory.deployMarket(config);
    }

    function test_DecimalsFailuresAndUint160OverflowRevertBeforeStateChanges() public {
        FactoryNoDecimalsToken noDecimals = new FactoryNoDecimalsToken();
        FactoryRevertingDecimalsToken revertingDecimals = new FactoryRevertingDecimalsToken();

        vm.expectRevert();
        vm.prank(operator);
        factory.deployMarket(_market(address(noDecimals), address(token18), 5_000, 5_000, true, true));

        vm.expectRevert();
        vm.prank(operator);
        factory.deployMarket(_market(address(revertingDecimals), address(token18), 5_000, 5_000, true, true));

        FactoryTestToken tooManyDecimals = new FactoryTestToken("D49", "D49", 49);
        vm.expectRevert();
        vm.prank(operator);
        factory.deployMarket(_market(address(tooManyDecimals), address(token18), 5_000, 5_000, true, true));

        assertEq(factory.nextDeploymentAt(), 0);
    }

    function test_DeploymentWithoutMinterRoleRollsBackEveryFactoryStateChange() public {
        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateRewarderFactory secondFactory =
            new DeepstateRewarderFactory(address(this), address(secondController), address(minterController));
        secondRouter.transferOwnership(address(secondController));
        secondController.grantRoles(address(secondFactory), secondController.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(config);
        bytes32 poolId = _poolId(config.token0, config.token1);
        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondRouter.poolHook(poolId), address(0));
    }

    function test_DownstreamMaxSupplyFailureAtomicallyRollsBackDeployment() public {
        uint256 marketFunding = factory.MARKET_FUNDING();
        uint256 attemptedSupply = marketFunding + _vesting(marketFunding);
        uint256 maxSupply = attemptedSupply - 1;
        DeepstateToken cappedDeep = new DeepstateToken(address(this), "Capped Deepstate", "cDEEP");
        DeepstateMinterController cappedMinter = new DeepstateMinterController(
            address(this), address(cappedDeep), address(sablier), vestingRecipient, maxSupply
        );
        DeepstateV1 cappedRouter = new DeepstateV1();
        DeepstateV1Controller cappedV1Controller = new DeepstateV1Controller(address(this), address(cappedRouter));
        DeepstateRewarderFactory cappedFactory =
            new DeepstateRewarderFactory(address(this), address(cappedV1Controller), address(cappedMinter));

        cappedDeep.grantRole(cappedDeep.DEFAULT_ADMIN_ROLE(), address(cappedMinter));
        cappedDeep.renounceRole(cappedDeep.DEFAULT_ADMIN_ROLE(), address(this));
        cappedMinter.activateTokenAdministration();
        cappedMinter.grantRoles(address(cappedFactory), cappedMinter.MINTER_ROLE());
        cappedRouter.transferOwnership(address(cappedV1Controller));
        cappedV1Controller.grantRoles(address(cappedFactory), cappedV1Controller.HOOK_MANAGER_ROLE());
        cappedFactory.setOperator(operator);

        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        bytes32 poolId = _poolId(config.token0, config.token1);
        uint256 streamIdBefore = sablier.nextStreamId();

        vm.expectRevert(
            abi.encodeWithSelector(DeepstateMinterController.MaxSupplyExceeded.selector, maxSupply, attemptedSupply)
        );
        vm.prank(operator);
        cappedFactory.deployMarket(config);

        assertEq(cappedFactory.nextDeploymentAt(), 0);
        assertEq(cappedRouter.poolHook(poolId), address(0));
        assertEq(cappedDeep.totalSupply(), 0);
        assertEq(sablier.nextStreamId(), streamIdBefore);
    }

    function test_SablierOrRouterFailureRollsBackMintStreamAndFactoryState() public {
        DeepstateRewarderFactory.MarketConfig memory first =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        sablier.setRevertCreate(true);
        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        vm.prank(operator);
        factory.deployMarket(first);
        sablier.setRevertCreate(false);
        _assertNoDeployment(factory, deepstate, first);

        DeepstateV1 secondRouter = new DeepstateV1();
        DeepstateV1Controller secondController = new DeepstateV1Controller(address(this), address(secondRouter));
        DeepstateRewarderFactory secondFactory =
            new DeepstateRewarderFactory(address(this), address(secondController), address(minterController));
        minterController.grantRoles(address(secondFactory), minterController.MINTER_ROLE());
        secondRouter.transferOwnership(address(secondController));
        secondFactory.setOperator(operator);
        uint256 supplyBefore = deep.totalSupply();
        uint256 streamBefore = sablier.nextStreamId();

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(first);
        _assertNoDeployment(secondFactory, secondRouter, first);
        assertEq(deep.totalSupply(), supplyBefore);
        assertEq(sablier.nextStreamId(), streamBefore);
    }

    function test_DeployingOverAnExistingHookReplacesItWithoutTouchingThePreviousRewarder() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 first = factory.deployMarket(config);
        bytes32 poolId = _poolId(config.token0, config.token1);
        uint256 firstBalance = deep.balanceOf(address(first));

        vm.warp(factory.nextDeploymentAt());
        vm.prank(operator);
        DeepstateRewarderV2 second = factory.deployMarket(config);

        assertNotEq(address(first), address(second));
        assertEq(deepstate.poolHook(poolId), address(second));
        assertEq(deep.balanceOf(address(first)), firstBalance);
        assertEq(deep.balanceOf(address(second)), factory.MARKET_FUNDING());
    }

    function test_RemoveWithMissingControllerPermissionRevertsWithoutBurning() public {
        DeepstateRewarderFactory.MarketConfig memory config =
            _market(address(token6), address(token18), 5_000, 5_000, true, true);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);
        uint256 balance = deep.balanceOf(address(rewarder));
        v1Controller.revokeRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.removeMarket(config.token0, config.token1);

        assertEq(deepstate.poolHook(rewarder.poolId()), address(rewarder));
        assertEq(deep.balanceOf(address(rewarder)), balance);
    }

    function _market(address a, address b, uint256 aMaxUnits, uint256 bMaxUnits, bool aActive, bool bActive)
        internal
        pure
        returns (DeepstateRewarderFactory.MarketConfig memory config)
    {
        return a < b
            ? _canonicalConfig(a, b, aMaxUnits, bMaxUnits, aActive, bActive)
            : _canonicalConfig(b, a, bMaxUnits, aMaxUnits, bActive, aActive);
    }

    function _canonicalConfig(
        address token0,
        address token1,
        uint256 token0MaxUnits,
        uint256 token1MaxUnits,
        bool token0Active,
        bool token1Active
    ) internal pure returns (DeepstateRewarderFactory.MarketConfig memory config) {
        config = DeepstateRewarderFactory.MarketConfig({
            token0: token0,
            token1: token1,
            token0MaxUnits: token0MaxUnits,
            token1MaxUnits: token1MaxUnits,
            token0Active: token0Active,
            token1Active: token1Active
        });
    }

    function _assertQuantities(DeepstateRewarderV2 rewarder, DeepstateRewarderFactory.MarketConfig memory config)
        internal
        view
    {
        uint256 unit0 = config.token0 == address(0) ? 1e18 : 10 ** uint256(FactoryTestToken(config.token0).decimals());
        uint256 unit1 = config.token1 == address(0) ? 1e18 : 10 ** uint256(FactoryTestToken(config.token1).decimals());
        assertEq(rewarder.token0StartQuantity(), unit0);
        assertEq(rewarder.token0MaxQuantity(), config.token0MaxUnits * unit0);
        assertEq(rewarder.token1StartQuantity(), unit1);
        assertEq(rewarder.token1MaxQuantity(), config.token1MaxUnits * unit1);
    }

    function _assertNoDeployment(
        DeepstateRewarderFactory targetFactory,
        DeepstateV1 targetRouter,
        DeepstateRewarderFactory.MarketConfig memory config
    ) internal view {
        bytes32 poolId = _poolId(config.token0, config.token1);
        assertEq(targetFactory.nextDeploymentAt(), 0);
        assertEq(targetRouter.poolHook(poolId), address(0));
    }

    function deepstateV1Controller() internal view returns (DeepstateV1Controller) {
        return v1Controller;
    }

    function _poolId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }

    function _vesting(uint256 primaryAmount) internal pure returns (uint256) {
        return Math.mulDiv(primaryAmount, 30_00, 70_00);
    }

    function _newMinterController() internal returns (DeepstateMinterController controller) {
        controller = new DeepstateMinterController(
            address(this), address(deep), address(sablier), vestingRecipient, 20_000_000_000e18
        );
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(controller));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        controller.activateTokenAdministration();
    }
}
