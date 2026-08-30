// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarder} from "deepstate-protocol/DeepstateRewarder.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {IDeepstateMinterController} from "../src/interfaces/IDeepstateMinterController.sol";
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

contract InvalidRewardTokenMinterController is IDeepstateMinterController {
    address internal immutable _deepstateToken;
    address internal immutable _owner;

    constructor(address deepstateToken_) {
        _deepstateToken = deepstateToken_;
        _owner = msg.sender;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function deepstateToken() external view returns (address) {
        return _deepstateToken;
    }

    function mint(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract FactoryLegacyRewarderCursorMock {
    address public deepstate;
    address public rewardToken;
    bytes32 public poolId;
    address public token0;
    address public token1;
    mapping(address token => uint32 nonce) internal _nonce;
    mapping(address token => uint64 startedAt) internal _startedAt;
    mapping(address token => uint96 accrued) internal _totalAccrued;

    function configure(address deepstate_, address rewardToken_, bytes32 poolId_, address token0_, address token1_)
        external
    {
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        poolId = poolId_;
        token0 = token0_;
        token1 = token1_;
    }

    function setRewardee(address token, uint32 nonce, uint64 startedAt) external {
        _nonce[token] = nonce;
        _startedAt[token] = startedAt;
    }

    function setTotalAccrued(address token, uint96 accrued) external {
        _totalAccrued[token] = accrued;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        return (_nonce[token], _startedAt[token]);
    }

    function totalAccrued(address token) external view returns (uint96 accrued) {
        return _totalAccrued[token];
    }
}

contract DeepstateRewarderFactoryTest is Test {
    uint256 internal constant FUNDING_BUDGET = 1_000_000_000e18;
    address internal constant LIVE_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant LIVE_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    DeepstateToken internal deep;
    DeepstateV1 internal deepstate;
    DeepstateV1Controller internal deepstateV1Controller;
    DeepstateMinterController internal minterController;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;
    FactoryTestToken internal usdG;
    FactoryTestToken internal stockA;
    FactoryTestToken internal stockB;
    FactoryTestToken internal stockC;

    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal vestingRecipient = makeAddr("vestingRecipient");
    uint256 internal initialSupply;
    uint256 internal initialGrossIssued;
    uint256 internal initialSablierBalance;
    uint256 internal initialNextStreamId;

    function setUp() public {
        vm.warp(1_000_000);

        usdG = new FactoryTestToken("USDG", "USDG", 6);
        stockA = new FactoryTestToken("Stock A", "STKA", 18);
        stockB = new FactoryTestToken("Stock B", "STKB", 18);
        stockC = new FactoryTestToken("Stock C", "STKC", 18);
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstate = new DeepstateV1();
        deepstateV1Controller = new DeepstateV1Controller(address(this), address(deepstate));
        minterController = _newMinterController(address(this), deep);
        initialSupply = deep.totalSupply();
        initialGrossIssued = minterController.grossIssued();
        initialSablierBalance = deep.balanceOf(address(sablier));
        initialNextStreamId = sablier.nextStreamId();
        factory = new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), address(usdG), FUNDING_BUDGET
        );

        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        deepstate.transferOwnership(address(deepstateV1Controller));
        deepstateV1Controller.grantRoles(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE());
        factory.setOperator(operator);
    }

    function test_ImmutableConfigurationAndInitialAuthority() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.operator(), operator);
        assertEq(address(factory.deepstateV1Controller()), address(deepstateV1Controller));
        assertEq(address(factory.deepstate()), address(deepstate));
        assertEq(address(factory.minterController()), address(minterController));
        assertEq(address(factory.rewardToken()), address(deep));
        assertEq(factory.usdG(), address(usdG));
        assertEq(factory.fundingBudget(), FUNDING_BUDGET);
        assertEq(factory.fundingCommitted(), 0);
        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 365 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 50_000_000e18);
        assertEq(factory.MARKET_FUNDING(), 100_000_000e18);
        assertEq(factory.USDG_START_QUANTITY(), 1e6);
        assertEq(factory.USDG_MAX_QUANTITY(), 1_000_000e6);
        assertEq(factory.MAX_QUANTITY_GROWTH(), 1_000_000);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(factory)));
        assertTrue(minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()));
        assertEq(deepstate.owner(), address(deepstateV1Controller));
        assertTrue(deepstateV1Controller.hasAnyRole(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE()));
    }

    function test_ConstructorValidation() public {
        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        new DeepstateRewarderFactory(
            address(0), address(deepstateV1Controller), address(minterController), address(usdG), FUNDING_BUDGET
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidDeepstateV1Controller.selector);
        new DeepstateRewarderFactory(
            address(this), address(0), address(minterController), address(usdG), FUNDING_BUDGET
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidDeepstateV1Controller.selector);
        new DeepstateRewarderFactory(address(this), alice, address(minterController), address(usdG), FUNDING_BUDGET);

        DeepstateV1Controller independentlyOwnedController = new DeepstateV1Controller(alice, address(deepstate));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.DeepstateV1ControllerOwnerMismatch.selector, address(this), alice
            )
        );
        new DeepstateRewarderFactory(
            address(this),
            address(independentlyOwnedController),
            address(minterController),
            address(usdG),
            FUNDING_BUDGET
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidMinterController.selector);
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(0), address(usdG), FUNDING_BUDGET
        );

        DeepstateMinterController mismatchedMinter = new DeepstateMinterController(
            alice,
            address(deep),
            address(sablier),
            address(minterController.legacyRewarder()),
            vestingRecipient,
            20_000_000_000e18,
            20_000_000_000e18
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.MinterControllerOwnerMismatch.selector, address(this), alice
            )
        );
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(mismatchedMinter), address(usdG), FUNDING_BUDGET
        );

        InvalidRewardTokenMinterController zeroTokenController = new InvalidRewardTokenMinterController(address(0));
        vm.expectRevert(DeepstateRewarderFactory.InvalidRewardToken.selector);
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(zeroTokenController), address(usdG), FUNDING_BUDGET
        );

        FactoryTestToken wrongDecimals = new FactoryTestToken("Wrong", "WRONG", 18);
        vm.expectRevert(DeepstateRewarderFactory.InvalidUSDG.selector);
        new DeepstateRewarderFactory(
            address(this),
            address(deepstateV1Controller),
            address(minterController),
            address(wrongDecimals),
            FUNDING_BUDGET
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidUSDG.selector);
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), alice, FUNDING_BUDGET
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidFundingBudget.selector);
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), address(usdG), 0
        );

        vm.expectRevert(DeepstateRewarderFactory.InvalidFundingBudget.selector);
        new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), address(usdG), 100_000_000e18 + 1
        );
    }

    function test_OperatorDeploysSemanticMarketWithInternallySortedFixedUSDGSchedule() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(address(stockA));
        config.stockBuySideActive = true;
        config.usdGBuySideActive = false;
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        bool token0Active = token0 == address(stockA);
        bool token1Active = token1 == address(stockA);

        vm.expectEmit(true, false, false, true, address(factory));
        emit DeepstateRewarderFactory.MarketDeployed(poolId, address(0), token0, token1, token0Active, token1Active);
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        assertGt(address(rewarder).code.length, 0);
        assertEq(rewarder.owner(), address(factory));
        assertEq(rewarder.poolId(), poolId);
        assertEq(rewarder.token0(), token0);
        assertEq(rewarder.token1(), token1);
        if (token0 == address(stockA)) {
            assertEq(rewarder.token0StartQuantity(), 1e18);
            assertEq(rewarder.token0MaxQuantity(), 5_000e18);
            assertEq(rewarder.token1StartQuantity(), 1e6);
            assertEq(rewarder.token1MaxQuantity(), 1_000_000e6);
        } else {
            assertEq(rewarder.token0StartQuantity(), 1e6);
            assertEq(rewarder.token0MaxQuantity(), 1_000_000e6);
            assertEq(rewarder.token1StartQuantity(), 1e18);
            assertEq(rewarder.token1MaxQuantity(), 5_000e18);
        }
        assertEq(deepstate.poolHook(poolId), address(rewarder));
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(factory.rewarderPool(address(rewarder)), poolId);
        assertTrue(factory.marketDeployed(poolId));
        assertEq(factory.fundingCommitted(), 100_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), uint256(rewarder.sideEmissionCap()) * 2);
        assertEq(deep.balanceOf(address(sablier)), initialSablierBalance + _vestingAllocation(100_000_000e18));
    }

    function test_LiveUSDGAddressSortsBeforeLiveNVDAAndKeepsSemanticConfiguration() public {
        FactoryTestToken sixDecimals = new FactoryTestToken("USDG", "USDG", 6);
        FactoryTestToken eighteenDecimals = new FactoryTestToken("NVDA", "NVDA", 18);
        vm.etch(LIVE_USDG, address(sixDecimals).code);
        vm.etch(LIVE_NVDA, address(eighteenDecimals).code);

        DeepstateRewarderFactory liveOrderFactory = new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), LIVE_USDG, 100_000_000e18
        );
        minterController.grantRoles(address(liveOrderFactory), minterController.MINTER_ROLE());
        deepstateV1Controller.grantRoles(address(liveOrderFactory), deepstateV1Controller.HOOK_MANAGER_ROLE());

        DeepstateRewarderFactory.MarketConfig memory config = _market(LIVE_NVDA);
        config.stockBuySideActive = false;
        config.usdGBuySideActive = true;
        DeepstateRewarderV2 rewarder = liveOrderFactory.deployMarket(config);

        assertLt(uint160(LIVE_USDG), uint160(LIVE_NVDA));
        assertEq(rewarder.token0(), LIVE_USDG);
        assertEq(rewarder.token1(), LIVE_NVDA);
        assertEq(rewarder.token0StartQuantity(), 1e6);
        assertEq(rewarder.token0MaxQuantity(), 1_000_000e6);
        assertEq(rewarder.token1StartQuantity(), 1e18);
        assertEq(rewarder.token1MaxQuantity(), 5_000e18);
    }

    function test_DeploymentCooldownIsGlobalAndAllowsExactBoundary() public {
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        uint256 next = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, next));
        vm.prank(operator);
        factory.deployMarket(_market(address(stockB)));

        vm.warp(next);
        vm.prank(operator);
        factory.deployMarket(_market(address(stockB)));

        assertEq(factory.fundingCommitted(), 200_000_000e18);
    }

    function test_OnlyGovernanceSetsOperatorAndCanRevokeImmediately() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.setOperator(alice);

        factory.setOperator(address(0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        factory.deployMarket(_market(address(stockA)));
        assertEq(factory.operator(), address(0));
    }

    function test_FactoryOwnershipCannotBeRenounced() public {
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        factory.renounceOwnership();

        vm.expectRevert(DeepstateRewarderFactory.InvalidOwner.selector);
        factory.transferOwnership(address(factory));

        assertEq(factory.owner(), address(this));
    }

    function test_FactoryOwnershipCanOnlyRotateToTheControllersCommonOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.DeepstateV1ControllerOwnerMismatch.selector, alice, address(this)
            )
        );
        factory.transferOwnership(alice);

        deepstateV1Controller.transferOwnership(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.DeepstateV1ControllerOwnerMismatch.selector, address(this), alice
            )
        );
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.DeepstateV1ControllerOwnerMismatch.selector, address(this), alice
            )
        );
        factory.setOperator(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.MinterControllerOwnerMismatch.selector, alice, address(this)
            )
        );
        factory.transferOwnership(alice);

        minterController.transferOwnership(alice);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), alice);
        assertEq(deepstateV1Controller.owner(), alice);
        assertEq(minterController.owner(), alice);
        assertEq(factory.operator(), operator);
        assertTrue(minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()));
        assertTrue(deepstateV1Controller.hasAnyRole(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE()));

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));
        assertEq(factory.activeRewarder(rewarder.poolId()), address(rewarder));

        vm.prank(alice);
        factory.setOperator(address(0));
        assertEq(factory.operator(), address(0));
    }

    function test_FundingBudgetIsMonotonicAndNeverRestoredByRetirement() public {
        DeepstateRewarderFactory limitedFactory = _newAuthorizedFactory(100_000_000e18);
        limitedFactory.setOperator(operator);

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = limitedFactory.deployMarket(_market(address(stockA)));
        vm.prank(operator);
        limitedFactory.removeMarket(address(stockA), address(rewarder));

        vm.warp(limitedFactory.nextDeploymentAt());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.FundingBudgetExceeded.selector, 100_000_000e18, 200_000_000e18
            )
        );
        vm.prank(operator);
        limitedFactory.deployMarket(_market(address(stockB)));

        assertEq(limitedFactory.fundingCommitted(), 100_000_000e18);
    }

    function test_RemovedPoolCanNeverBeRedeployed() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));
        bytes32 poolId = rewarder.poolId();
        vm.prank(operator);
        factory.removeMarket(address(stockA), address(rewarder));

        vm.warp(factory.nextDeploymentAt());
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.MarketAlreadyDeployed.selector, poolId));
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        assertTrue(factory.marketDeployed(poolId));
        assertEq(factory.activeRewarder(poolId), address(0));
    }

    function test_GovernanceMigratesExactIdlePredecessorAndFullyFundsV2Atomically() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        DeepstateRewarderV2 rewarder = factory.migrateMarket(_market(address(stockA)), address(predecessor));

        assertEq(deepstate.poolHook(poolId), address(rewarder));
        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertEq(factory.rewarderPool(address(rewarder)), poolId);
        assertTrue(factory.marketDeployed(poolId));
        assertEq(factory.fundingCommitted(), 100_000_000e18);
        assertEq(factory.nextDeploymentAt(), block.timestamp + 3 days);
        assertEq(rewarder.sideEmissionCap(), 50_000_000e18);
        assertEq(rewarder.emissionDuration(), 365 days);
        assertEq(deep.balanceOf(address(rewarder)), 100_000_000e18);
        assertEq(deep.balanceOf(address(rewarder)), uint256(rewarder.sideEmissionCap()) * 2);
        assertEq(deep.balanceOf(address(sablier)), initialSablierBalance + _vestingAllocation(100_000_000e18));
    }

    function test_OperatorCannotMigrateExistingHook() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.fundingCommitted(), 0);
    }

    function test_MigrationRequiresExactNonzeroPredecessor() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        vm.expectRevert(DeepstateRewarderFactory.InvalidExpectedExistingHook.selector);
        factory.migrateMarket(_market(address(stockA)), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.UnexpectedPoolHook.selector, poolId, alice, address(predecessor)
            )
        );
        factory.migrateMarket(_market(address(stockA)), alice);

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.fundingCommitted(), 0);
    }

    function test_MigrationRequiresPredecessorIdentityToMatchPoolRouterAndRewardToken() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        bytes32 wrongPoolId = bytes32(uint256(poolId) + 1);
        predecessor.configure(address(deepstate), address(deep), wrongPoolId, token0, token1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderPoolIdentityMismatch.selector,
                poolId,
                wrongPoolId,
                token0,
                token0,
                token1,
                token1
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        predecessor.configure(address(deepstate), address(deep), poolId, token1, token0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderPoolIdentityMismatch.selector,
                poolId,
                poolId,
                token0,
                token1,
                token1,
                token0
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        predecessor.configure(alice, address(deep), poolId, token0, token1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderDependencyMismatch.selector,
                address(deepstate),
                alice,
                address(deep),
                address(deep)
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        predecessor.configure(address(deepstate), alice, poolId, token0, token1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderDependencyMismatch.selector,
                address(deepstate),
                address(deepstate),
                address(deep),
                alice
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_MigrationRejectsAnyLiveBidOrAskBeforeClearingThePredecessor() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        bytes32 bookId = deepstate.activeBookId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        vm.mockCall(
            address(deepstate),
            abi.encodeWithSelector(DeepstateV1.topOrder.selector, bookId, true),
            abi.encode(uint32(7), uint160(11e18))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.PoolBookNotIdle.selector, bookId, true, uint32(7), uint160(11e18)
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));
        vm.clearMockedCalls();

        vm.mockCall(
            address(deepstate),
            abi.encodeWithSelector(DeepstateV1.topOrder.selector, bookId, false),
            abi.encode(uint32(8), uint160(13e18))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.PoolBookNotIdle.selector, bookId, false, uint32(8), uint160(13e18)
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));
        vm.clearMockedCalls();

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_MigrationRejectsEitherNonzeroLegacyRewardCursor() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);

        predecessor.setRewardee(token0, 17, 1_234);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderCursorNotIdle.selector, token0, uint32(17), uint64(1_234)
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        predecessor.setRewardee(token0, 0, 0);
        predecessor.setRewardee(token1, 0, 9_876);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.LegacyRewarderCursorNotIdle.selector, token1, uint32(0), uint64(9_876)
            )
        );
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_MigrationRestoresPredecessorWhenFundingDependencyFails() public {
        FactoryLegacyRewarderCursorMock predecessor = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        bytes32 poolId = _poolId(token0, token1);
        predecessor.configure(address(deepstate), address(deep), poolId, token0, token1);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(predecessor), true, true);
        sablier.setRevertCreate(true);

        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        factory.migrateMarket(_market(address(stockA)), address(predecessor));

        assertEq(deepstate.poolHook(poolId), address(predecessor));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertFalse(factory.marketDeployed(poolId));
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
        assertEq(minterController.grossIssued(), initialGrossIssued);
        assertEq(sablier.nextStreamId(), initialNextStreamId);
    }

    function test_OperatorRemovesExpectedMarketAndBurnsAllFunding() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));
        bytes32 poolId = rewarder.poolId();

        vm.expectEmit(false, false, false, true, address(rewarder));
        emit DeepstateRewarderV2.RewarderRetiredAndBalanceBurned(100_000_000e18);
        vm.expectEmit(true, true, false, false, address(factory));
        emit DeepstateRewarderFactory.MarketRemoved(poolId, address(rewarder));
        vm.prank(operator);
        factory.removeMarket(address(stockA), address(rewarder));

        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(factory.rewarderPool(address(rewarder)), bytes32(0));
        assertEq(factory.retiredRewarderPool(address(rewarder)), poolId);
        assertTrue(rewarder.retired());
        assertEq(rewarder.owner(), address(0));
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(deep.totalSupply(), initialSupply + _vestingAllocation(100_000_000e18));
    }

    function test_RemovalExpectedRewarderAndReplacementHookChecksFailSafely() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));
        bytes32 poolId = rewarder.poolId();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.UnexpectedRewarder.selector, poolId, alice, address(rewarder)
            )
        );
        vm.prank(operator);
        factory.removeMarket(address(stockA), alice);

        deepstateV1Controller.setPoolHookConfig(rewarder.token0(), rewarder.token1(), alice, true, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.UnexpectedPoolHook.selector, poolId, address(rewarder), alice
            )
        );
        vm.prank(operator);
        factory.removeMarket(address(stockA), address(rewarder));

        assertEq(factory.activeRewarder(poolId), address(rewarder));
        assertFalse(rewarder.retired());
    }

    function test_GovernanceCanCleanUpAfterHookAlreadyClearedAndPermissionRevoked() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));
        deepstateV1Controller.setPoolHookConfig(rewarder.token0(), rewarder.token1(), address(0), false, false);
        deepstateV1Controller.revokeRoles(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE());

        factory.removeMarket(address(stockA), address(rewarder));

        assertTrue(rewarder.retired());
        assertEq(factory.activeRewarder(rewarder.poolId()), address(0));
    }

    function test_InvalidSemanticMarketConfigurationRevertsBeforeDeployment() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(address(0));
        vm.expectRevert(DeepstateRewarderFactory.InvalidStockToken.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(address(usdG));
        vm.expectRevert(DeepstateRewarderFactory.InvalidStockToken.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(alice);
        vm.expectRevert(DeepstateRewarderFactory.InvalidStockToken.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        FactoryTestToken wrongDecimals = new FactoryTestToken("Wrong", "WRONG", 8);
        config = _market(address(wrongDecimals));
        vm.expectRevert(DeepstateRewarderFactory.InvalidStockTokenDecimals.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(address(stockA));
        config.stockBuySideActive = false;
        config.usdGBuySideActive = false;
        vm.expectRevert(DeepstateRewarderFactory.InvalidHookFlags.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        config = _market(address(stockA));
        config.stockStartQuantity = 0;
        vm.expectRevert(DeepstateRewarder.InvalidQuantitySchedule.selector);
        vm.prank(operator);
        factory.deployMarket(config);

        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_StockQuantityRampVariesPerPoolAndAcceptsExactGrowthBoundary() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(address(stockA));
        config.stockStartQuantity = 37e18;
        config.stockMaxQuantity = uint160(uint256(config.stockStartQuantity) * 1_000_000);

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(config);

        if (rewarder.token0() == address(stockA)) {
            assertEq(rewarder.token0StartQuantity(), 37e18);
            assertEq(rewarder.token0MaxQuantity(), 37_000_000e18);
        } else {
            assertEq(rewarder.token1StartQuantity(), 37e18);
            assertEq(rewarder.token1MaxQuantity(), 37_000_000e18);
        }
    }

    function test_StockQuantityGrowthCapRejectsExtremeRatioBeforeMinting() public {
        DeepstateRewarderFactory.MarketConfig memory config = _market(address(stockA));
        config.stockMaxQuantity = 1_000_001e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateRewarderFactory.QuantityGrowthTooLarge.selector,
                address(stockA),
                config.stockStartQuantity,
                config.stockMaxQuantity
            )
        );
        vm.prank(operator);
        factory.deployMarket(config);

        assertEq(factory.fundingCommitted(), 0);
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_DeploymentWithoutMinterRoleRevertsAllFactoryCommitmentsAtomically() public {
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondV1Controller = new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondV1Controller), address(minterController), address(usdG), FUNDING_BUDGET
        );
        secondDeepstate.transferOwnership(address(secondV1Controller));
        secondV1Controller.grantRoles(address(secondFactory), secondV1Controller.HOOK_MANAGER_ROLE());
        secondFactory.setOperator(operator);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(_market(address(stockA)));

        bytes32 poolId = _stockPoolId(address(stockA));
        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondFactory.fundingCommitted(), 0);
        assertFalse(secondFactory.marketDeployed(poolId));
        assertEq(secondFactory.activeRewarder(poolId), address(0));
    }

    function test_SablierFailureRollsBackBudgetPermanentFlagRewarderAndMintAtomically() public {
        bytes32 poolId = _stockPoolId(address(stockA));
        sablier.setRevertCreate(true);

        vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.fundingCommitted(), 0);
        assertFalse(factory.marketDeployed(poolId));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(deep.totalSupply(), initialSupply);
    }

    function test_RouterConfigurationFailureRollsBackMintStreamAndFactoryCommitmentsAtomically() public {
        DeepstateV1 secondDeepstate = new DeepstateV1();
        DeepstateV1Controller secondV1Controller = new DeepstateV1Controller(address(this), address(secondDeepstate));
        DeepstateRewarderFactory secondFactory = new DeepstateRewarderFactory(
            address(this), address(secondV1Controller), address(minterController), address(usdG), FUNDING_BUDGET
        );
        secondDeepstate.transferOwnership(address(secondV1Controller));
        minterController.grantRoles(address(secondFactory), minterController.MINTER_ROLE());
        secondFactory.setOperator(operator);
        bytes32 poolId = _stockPoolId(address(stockA));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(operator);
        secondFactory.deployMarket(_market(address(stockA)));

        assertEq(secondFactory.nextDeploymentAt(), 0);
        assertEq(secondFactory.fundingCommitted(), 0);
        assertFalse(secondFactory.marketDeployed(poolId));
        assertEq(secondFactory.activeRewarder(poolId), address(0));
        assertEq(secondDeepstate.poolHook(poolId), address(0));
        assertEq(deep.totalSupply(), initialSupply);
        assertEq(minterController.grossIssued(), initialGrossIssued);
        assertEq(sablier.nextStreamId(), initialNextStreamId);
    }

    function test_CannotDeployOverExistingRouterHook() public {
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        deepstateV1Controller.setPoolHookConfig(token0, token1, alice, true, false);
        bytes32 poolId = _poolId(token0, token1);

        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.ExistingPoolHook.selector, poolId, alice));
        vm.prank(operator);
        factory.deployMarket(_market(address(stockA)));

        assertEq(factory.fundingCommitted(), 0);
    }

    function test_UnauthorizedAccountCannotDeployOrRemoveMarket() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.deployMarket(_market(address(stockA)));

        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market(address(stockA)));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        factory.removeMarket(address(stockA), address(rewarder));
    }

    function test_RemoveUnknownMarketAndInvalidSemanticStockRevert() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateRewarderFactory.MarketNotActive.selector, _stockPoolId(address(stockA)))
        );
        vm.prank(operator);
        factory.removeMarket(address(stockA), alice);

        vm.expectRevert(DeepstateRewarderFactory.InvalidStockToken.selector);
        vm.prank(operator);
        factory.removeMarket(address(usdG), alice);
    }

    function _newAuthorizedFactory(uint256 budget) internal returns (DeepstateRewarderFactory result) {
        result = new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), address(usdG), budget
        );
        minterController.grantRoles(address(result), minterController.MINTER_ROLE());
        deepstateV1Controller.grantRoles(address(result), deepstateV1Controller.HOOK_MANAGER_ROLE());
    }

    function _market(address stockToken) internal pure returns (DeepstateRewarderFactory.MarketConfig memory config) {
        config = DeepstateRewarderFactory.MarketConfig({
            stockToken: stockToken,
            stockStartQuantity: 1e18,
            stockMaxQuantity: 5_000e18,
            stockBuySideActive: true,
            usdGBuySideActive: true
        });
    }

    function _stockPoolId(address stockToken) internal view returns (bytes32) {
        (address token0, address token1) = _sort(stockToken, address(usdG));
        return _poolId(token0, token1);
    }

    function _sort(address a, address b) internal pure returns (address token0, address token1) {
        return a < b ? (a, b) : (b, a);
    }

    function _poolId(address token0, address token1) internal pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }

    function _vestingAllocation(uint256 primaryAmount) internal pure returns (uint256) {
        return Math.mulDiv(primaryAmount, 30_00, 70_00);
    }

    function _newMinterController(address admin, DeepstateToken token)
        internal
        returns (DeepstateMinterController controller_)
    {
        FactoryLegacyRewarderCursorMock legacyRewarder = new FactoryLegacyRewarderCursorMock();
        (address token0, address token1) = _sort(address(stockA), address(usdG));
        legacyRewarder.configure(address(deepstate), address(token), _poolId(token0, token1), token0, token1);
        // Four base units of recorded legacy accrual produce the smallest nonzero 30% endowment.
        legacyRewarder.setTotalAccrued(token0, 4);
        deepstate.setPoolHookConfig(token0, token1, address(legacyRewarder), true, true);
        controller_ = new DeepstateMinterController(
            admin,
            address(token),
            address(sablier),
            address(legacyRewarder),
            vestingRecipient,
            20_000_000_000e18,
            20_000_000_000e18
        );
        token.grantRole(token.MINTER_ROLE(), address(controller_));
        token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(controller_));
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), address(this));
        vm.prank(admin);
        controller_.lockTokenAdministration();
        deepstate.setPoolHookConfig(token0, token1, address(0), false, false);
    }
}
