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

contract FactoryInvariantToken is ERC20 {
    string private _tokenName;
    string private _tokenSymbol;
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _tokenDecimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }
}

contract FactoryInvariantLegacyRewarder {
    address public deepstate;
    address public rewardToken;
    bytes32 public poolId;
    address public token0;
    address public token1;

    mapping(address token => uint32 nonce) private _rewardeeNonce;
    mapping(address token => uint64 startedAt) private _rewardeeStartedAt;
    mapping(address token => uint96 accrued) private _totalAccrued;

    constructor(address deepstate_, address rewardToken_, bytes32 poolId_, address token0_, address token1_) {
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        poolId = poolId_;
        token0 = token0_;
        token1 = token1_;
    }

    function setPoolId(bytes32 poolId_) external {
        poolId = poolId_;
    }

    function setRewardee(address token, uint32 nonce, uint64 startedAt) external {
        _rewardeeNonce[token] = nonce;
        _rewardeeStartedAt[token] = startedAt;
    }

    function setTotalAccrued(address token, uint96 accrued) external {
        _totalAccrued[token] = accrued;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        return (_rewardeeNonce[token], _rewardeeStartedAt[token]);
    }

    function totalAccrued(address token) external view returns (uint96 accrued) {
        return _totalAccrued[token];
    }
}

/// @dev Stateful model for the Factory, both controllers, the Router, and the minting dependency.
/// Every action catches expected reverts. A reverted lifecycle call is required to leave all
/// relevant Factory, Router, token, Sablier, and Rewarder state unchanged.
contract DeepstateFactorySystemHandler is Test {
    uint256 public constant FUNDING_BUDGET = 1_000_000_000e18;
    uint256 public constant MINT_CAP = 6_000_000_000e18;
    uint256 public constant GROSS_ISSUANCE_CAP = 10_000_000_000e18;
    uint256 public constant ROUTER_TOKEN0_ACTIVE_FLAG = uint256(1) << 254;
    uint256 public constant ROUTER_TOKEN1_ACTIVE_FLAG = uint256(1) << 255;
    uint256 private constant _ROUTER_HOOK_FLAGS = ROUTER_TOKEN0_ACTIVE_FLAG | ROUTER_TOKEN1_ACTIVE_FLAG;
    uint256 private constant _ROUTER_POOL_STATE_MAPPING_SLOT = 2;

    address public constant GOVERNANCE_A = address(0xA11CE);
    address public constant GOVERNANCE_B = address(0xB0B);
    address public constant GOVERNANCE_C = address(0xCA11);
    address public constant OPERATOR_A = address(0x0A01);
    address public constant OPERATOR_B = address(0x0B02);
    address public constant UNAUTHORIZED = address(0xBAD);
    address public constant ROUTER_CUSTODIAN = address(0xC0570D1A);
    address public constant FOREIGN_HOOK = address(0xF0E1);
    address public constant DIRECT_MINT_RECIPIENT = address(0xD1EC7);
    address public constant VESTING_RECIPIENT = address(0x1AC);

    DeepstateToken public immutable deep;
    DeepstateV1 public immutable deepstate;
    DeepstateV1Controller public immutable v1Controller;
    DeepstateMinterController public immutable minterController;
    DeepstateRewarderFactory public immutable factory;
    MockSablierLockupLinearV4 public immutable sablier;
    FactoryInvariantToken public immutable usdG;
    FactoryInvariantToken public immutable invalidDecimalsStock;

    address[] private _stocks;
    uint256[] private _successfulDeploymentTimestamps;
    uint256[] private _factoryStreamIds;

    mapping(address stock => bool deployed) public modelEverDeployed;
    mapping(address stock => address rewarder) public modelRewarder;
    mapping(address stock => uint160 startQuantity) public modelStartQuantity;
    mapping(address stock => uint160 maxQuantity) public modelMaxQuantity;
    mapping(address stock => bool removed) public modelRemoved;
    mapping(address stock => uint256 flags) public modelHookFlags;
    mapping(uint256 streamId => uint256 primaryAmount) public modelFactoryPrimaryForStream;

    uint256 public successfulDeployments;
    uint256 public successfulMarketMigrations;
    uint256 public successfulRemovals;
    uint256 public successfulMintCalls;
    uint256 public totalVestingMinted;
    uint256 public totalRewarderFundingBurned;
    uint256 public successfulOwnershipMigrations;

    uint256 public authorizationViolations;
    uint256 public governanceAlignmentViolations;
    uint256 public delegatedRoleViolations;
    uint256 public routerOwnershipViolations;
    uint256 public marketValidationViolations;
    uint256 public cooldownViolations;
    uint256 public budgetViolations;
    uint256 public lifecycleViolations;
    uint256 public mintWindowOrCapViolations;
    uint256 public sablierDependencyViolations;
    uint256 public ownershipMigrationViolations;
    uint256 public migrationGuardViolations;

    struct DeploySnapshot {
        uint256 committed;
        uint256 nextDeploymentAt;
        uint256 totalSupply;
        uint256 grossIssued;
        uint256 nextStreamId;
        uint256 sablierBalance;
        bytes32 poolId;
        address activeRewarder;
        address hook;
        uint256 routerPoolState;
        bool marketDeployed;
    }

    struct FundingSnapshot {
        uint256 committed;
        uint256 nextDeploymentAt;
        uint256 totalSupply;
        uint256 grossIssued;
        uint256 nextStreamId;
        uint256 sablierBalance;
        uint256 rewarderBalance;
        bytes32 poolId;
        bytes32 rewarderPool;
        bytes32 retiredRewarderPool;
        address activeRewarder;
        address hook;
        uint256 routerPoolState;
        bool marketDeployed;
        bool rewarderRetired;
        address rewarderOwner;
    }

    constructor() {
        usdG = new FactoryInvariantToken("Invariant USDG", "iUSDG", 6);
        invalidDecimalsStock = new FactoryInvariantToken("Invalid Stock", "BAD8", 8);
        for (uint256 i; i < 11; ++i) {
            _stocks.push(address(new FactoryInvariantToken("Invariant Stock", "STOCK", 18)));
        }

        deep = new DeepstateToken(address(this), "Invariant Deepstate", "iDEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstate = new DeepstateV1();
        v1Controller = new DeepstateV1Controller(address(this), address(deepstate));
        (address legacyToken0, address legacyToken1) = _sort(_stocks[0], address(usdG));
        FactoryInvariantLegacyRewarder legacyRewarder = new FactoryInvariantLegacyRewarder(
            address(deepstate),
            address(deep),
            keccak256(abi.encode(legacyToken0, legacyToken1)),
            legacyToken0,
            legacyToken1
        );
        legacyRewarder.setTotalAccrued(legacyToken0, 4);
        deepstate.setPoolHookConfig(legacyToken0, legacyToken1, address(legacyRewarder), true, true);
        minterController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), VESTING_RECIPIENT, MINT_CAP, GROSS_ISSUANCE_CAP
        );
        factory = new DeepstateRewarderFactory(
            address(this), address(v1Controller), address(minterController), address(usdG), FUNDING_BUDGET
        );

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.activateTokenAdministration();
        deepstate.setPoolHookConfig(legacyToken0, legacyToken1, address(0), false, false);

        deepstate.transferOwnership(address(v1Controller));
        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        v1Controller.grantRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        factory.setOperator(OPERATOR_A);
    }

    function stockCount() external view returns (uint256) {
        return _stocks.length;
    }

    function stock(uint256 index) external view returns (address) {
        return _stocks[index];
    }

    function successfulDeploymentTimestamp(uint256 index) external view returns (uint256) {
        return _successfulDeploymentTimestamps[index];
    }

    function factoryStreamCount() external view returns (uint256) {
        return _factoryStreamIds.length;
    }

    function factoryStreamId(uint256 index) external view returns (uint256) {
        return _factoryStreamIds[index];
    }

    function routerPoolState(address stockToken) public view returns (uint256) {
        bytes32 poolStateSlot = keccak256(abi.encode(_poolId(stockToken), _ROUTER_POOL_STATE_MAPPING_SLOT));
        return uint256(vm.load(address(deepstate), poolStateSlot));
    }

    function routerHookFlags(address stockToken) public view returns (uint256) {
        return routerPoolState(stockToken) & _ROUTER_HOOK_FLAGS;
    }

    function attemptDeploy(uint256 tokenSeed, uint256 startSeed, uint256 scheduleSeed, uint8 flagSeed, uint8 callerSeed)
        external
    {
        (address stockToken, bool recognizedStock) = _candidateStock(tokenSeed);
        (uint160 startQuantity, uint160 maxQuantity, bool validSchedule) = _quantitySchedule(startSeed, scheduleSeed);
        bool stockBuySideActive = flagSeed & 1 != 0;
        bool usdGBuySideActive = flagSeed & 2 != 0;
        bool validConfig = recognizedStock && validSchedule && (stockBuySideActive || usdGBuySideActive);

        DeepstateRewarderFactory.MarketConfig memory config = DeepstateRewarderFactory.MarketConfig({
            stockToken: stockToken,
            stockStartQuantity: startQuantity,
            stockMaxQuantity: maxQuantity,
            stockBuySideActive: stockBuySideActive,
            usdGBuySideActive: usdGBuySideActive
        });

        address caller = _lifecycleCaller(callerSeed);
        bool authorized =
            caller == factory.owner() || (factory.operator() != address(0) && caller == factory.operator());
        bool aligned = _governanceAligned();
        bool hasMinterRole = minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE());
        bool hasHookRole = v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        bool routerOwned = deepstate.owner() == address(v1Controller);
        bool canMint = _canMint(factory.MARKET_FUNDING());
        bool sablierWorking = !sablier.revertCreate();

        DeploySnapshot memory before_ = _deploySnapshot(stockToken);
        vm.prank(caller);
        (bool success, bytes memory result) = address(factory).call(abi.encodeCall(factory.deployMarket, (config)));

        if (!success) {
            _assertFailedDeployAtomic(before_, stockToken);
            return;
        }

        address rewarder = abi.decode(result, (address));
        if (!authorized) ++authorizationViolations;
        if (!aligned) ++governanceAlignmentViolations;
        if (!hasMinterRole || !hasHookRole) ++delegatedRoleViolations;
        if (!routerOwned) ++routerOwnershipViolations;
        if (!validConfig) ++marketValidationViolations;
        if (block.timestamp < before_.nextDeploymentAt) ++cooldownViolations;
        if (before_.committed + factory.MARKET_FUNDING() > factory.fundingBudget()) ++budgetViolations;
        if (
            before_.activeRewarder != address(0) || before_.marketDeployed || before_.hook != address(0)
                || modelEverDeployed[stockToken]
        ) ++lifecycleViolations;
        if (!canMint) ++mintWindowOrCapViolations;
        if (!sablierWorking) ++sablierDependencyViolations;

        ++successfulDeployments;
        ++successfulMintCalls;
        totalVestingMinted += _vesting(factory.MARKET_FUNDING());
        _successfulDeploymentTimestamps.push(block.timestamp);
        _recordAndAssertFactoryStream(before_.nextStreamId, factory.MARKET_FUNDING());

        if (recognizedStock) {
            modelEverDeployed[stockToken] = true;
            modelRewarder[stockToken] = rewarder;
            modelStartQuantity[stockToken] = startQuantity;
            modelMaxQuantity[stockToken] = maxQuantity;
            modelHookFlags[stockToken] = _semanticHookFlags(stockToken, stockBuySideActive, usdGBuySideActive);
        }

        bytes32 poolId = _poolId(stockToken);
        assertEq(factory.fundingCommitted(), before_.committed + factory.MARKET_FUNDING());
        assertEq(factory.nextDeploymentAt(), block.timestamp + factory.DEPLOYMENT_COOLDOWN());
        assertEq(deep.totalSupply(), before_.totalSupply + _combined(factory.MARKET_FUNDING()));
        assertEq(minterController.grossIssued(), before_.grossIssued + _combined(factory.MARKET_FUNDING()));
        assertEq(sablier.nextStreamId(), before_.nextStreamId + 1);
        assertTrue(factory.marketDeployed(poolId));
        assertEq(factory.activeRewarder(poolId), rewarder);
        assertEq(factory.rewarderPool(rewarder), poolId);
        assertEq(deepstate.poolHook(poolId), rewarder);
        assertEq(routerHookFlags(stockToken), _semanticHookFlags(stockToken, stockBuySideActive, usdGBuySideActive));
        assertEq(deep.balanceOf(rewarder), factory.MARKET_FUNDING());
    }

    /// @dev Higher-probability valid transition used alongside the adversarial arbitrary-config action.
    function deployValidMarket(uint256 stockSeed, uint256 startSeed, bool asOperator) external {
        this.attemptDeploy(stockSeed % _stocks.length, startSeed, 1_003, 3, asOperator ? 1 : 0);
    }

    /// @dev Installs a realistic legacy predecessor, then exercises the governance-only atomic migration path.
    /// Modes cover the valid path, a live legacy cursor, a mismatched pool identity, a wrong expected hook, and zero.
    function attemptMigrateLegacyMarket(uint256 stockSeed, uint256 startSeed, uint8 callerSeed, uint8 modeSeed)
        external
    {
        address stockToken = _stocks[stockSeed % _stocks.length];
        bytes32 poolId = _poolId(stockToken);
        if (factory.marketDeployed(poolId)) return;

        (address token0, address token1) = _sort(stockToken, address(usdG));
        FactoryInvariantLegacyRewarder predecessor =
            new FactoryInvariantLegacyRewarder(address(deepstate), address(deep), poolId, token0, token1);
        uint8 mode = modeSeed % 5;
        if (mode == 1) predecessor.setRewardee(token0, 1, 1);
        else if (mode == 2) predecessor.setPoolId(bytes32(uint256(poolId) + 1));

        _installExternalHook(stockToken, address(predecessor), true, true);
        modelHookFlags[stockToken] = _ROUTER_HOOK_FLAGS;

        uint160 startQuantity = uint160(bound(startSeed, 1, 1e24));
        uint160 maxQuantity = uint160(uint256(startQuantity) * 1_000);
        DeepstateRewarderFactory.MarketConfig memory config = DeepstateRewarderFactory.MarketConfig({
            stockToken: stockToken,
            stockStartQuantity: startQuantity,
            stockMaxQuantity: maxQuantity,
            stockBuySideActive: true,
            usdGBuySideActive: true
        });

        address expectedHook = mode == 3 ? FOREIGN_HOOK : (mode == 4 ? address(0) : address(predecessor));
        address caller = _lifecycleCaller(callerSeed);
        bool authorized = caller == factory.owner();
        bool aligned = _governanceAligned();
        bool hasMinterRole = minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE());
        bool hasHookRole = v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        bool routerOwned = deepstate.owner() == address(v1Controller);
        bool canMint = _canMint(factory.MARKET_FUNDING());
        bool sablierWorking = !sablier.revertCreate();

        DeploySnapshot memory before_ = _deploySnapshot(stockToken);
        vm.prank(caller);
        (bool success, bytes memory result) =
            address(factory).call(abi.encodeCall(factory.migrateMarket, (config, expectedHook)));

        if (!success) {
            _assertFailedDeployAtomic(before_, stockToken);
            return;
        }

        address rewarder = abi.decode(result, (address));
        if (!authorized) ++authorizationViolations;
        if (!aligned) ++governanceAlignmentViolations;
        if (!hasMinterRole || !hasHookRole) ++delegatedRoleViolations;
        if (!routerOwned) ++routerOwnershipViolations;
        if (mode != 0 || before_.hook != address(predecessor)) ++migrationGuardViolations;
        if (block.timestamp < before_.nextDeploymentAt) ++cooldownViolations;
        if (before_.committed + factory.MARKET_FUNDING() > factory.fundingBudget()) ++budgetViolations;
        if (before_.activeRewarder != address(0) || before_.marketDeployed || modelEverDeployed[stockToken]) {
            ++lifecycleViolations;
        }
        if (!canMint) ++mintWindowOrCapViolations;
        if (!sablierWorking) ++sablierDependencyViolations;

        ++successfulDeployments;
        ++successfulMarketMigrations;
        ++successfulMintCalls;
        totalVestingMinted += _vesting(factory.MARKET_FUNDING());
        _successfulDeploymentTimestamps.push(block.timestamp);
        _recordAndAssertFactoryStream(before_.nextStreamId, factory.MARKET_FUNDING());

        modelEverDeployed[stockToken] = true;
        modelRewarder[stockToken] = rewarder;
        modelStartQuantity[stockToken] = startQuantity;
        modelMaxQuantity[stockToken] = maxQuantity;
        modelHookFlags[stockToken] = _ROUTER_HOOK_FLAGS;

        assertEq(factory.fundingCommitted(), before_.committed + factory.MARKET_FUNDING());
        assertEq(factory.nextDeploymentAt(), block.timestamp + factory.DEPLOYMENT_COOLDOWN());
        assertEq(deep.totalSupply(), before_.totalSupply + _combined(factory.MARKET_FUNDING()));
        assertEq(minterController.grossIssued(), before_.grossIssued + _combined(factory.MARKET_FUNDING()));
        assertEq(sablier.nextStreamId(), before_.nextStreamId + 1);
        assertTrue(factory.marketDeployed(poolId));
        assertEq(factory.activeRewarder(poolId), rewarder);
        assertEq(factory.rewarderPool(rewarder), poolId);
        assertEq(deepstate.poolHook(poolId), rewarder);
        assertEq(deep.balanceOf(rewarder), factory.MARKET_FUNDING());
    }

    function migrateValidLegacyMarket(uint256 stockSeed, uint256 startSeed) external {
        this.attemptMigrateLegacyMarket(stockSeed, startSeed, 0, 0);
    }

    function attemptRemove(uint256 stockSeed, uint8 callerSeed, uint8 expectedRewarderSeed) external {
        address stockToken = _stocks[stockSeed % _stocks.length];
        bytes32 poolId = _poolId(stockToken);
        address active = factory.activeRewarder(poolId);
        address expectedRewarder =
            expectedRewarderSeed % 3 == 0 ? active : (expectedRewarderSeed % 3 == 1 ? FOREIGN_HOOK : address(0));
        address caller = _lifecycleCaller(callerSeed);
        address hook = deepstate.poolHook(poolId);

        bool authorized =
            caller == factory.owner() || (factory.operator() != address(0) && caller == factory.operator());
        bool aligned = _governanceAligned();
        bool validLifecycle = active != address(0) && expectedRewarder == active
            && factory.rewarderPool(active) == poolId && (hook == active || hook == address(0));
        bool hookChangePermitted = hook != active
            || (deepstate.owner() == address(v1Controller)
                && v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE()));

        FundingSnapshot memory before_ = _fundingSnapshot(stockToken);
        vm.prank(caller);
        (bool success,) = address(factory).call(abi.encodeCall(factory.removeMarket, (stockToken, expectedRewarder)));

        if (!success) {
            _assertFailedFundingAtomic(before_, stockToken);
            return;
        }

        if (!authorized) ++authorizationViolations;
        if (!aligned) ++governanceAlignmentViolations;
        if (!validLifecycle || modelRemoved[stockToken]) ++lifecycleViolations;
        if (!hookChangePermitted) {
            if (deepstate.owner() != address(v1Controller)) ++routerOwnershipViolations;
            else ++delegatedRoleViolations;
        }

        ++successfulRemovals;
        totalRewarderFundingBurned += before_.rewarderBalance;
        modelRemoved[stockToken] = true;
        modelHookFlags[stockToken] = 0;

        assertEq(factory.fundingCommitted(), before_.committed);
        assertEq(factory.nextDeploymentAt(), before_.nextDeploymentAt);
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(factory.rewarderPool(active), bytes32(0));
        assertEq(factory.retiredRewarderPool(active), poolId);
        assertEq(deepstate.poolHook(poolId), address(0));
        assertEq(routerHookFlags(stockToken), 0);
        assertTrue(DeepstateRewarderV2(active).retired());
        assertEq(DeepstateRewarderV2(active).owner(), address(0));
        assertEq(deep.balanceOf(active), 0);
        assertEq(deep.totalSupply(), before_.totalSupply - before_.rewarderBalance);
        assertEq(minterController.grossIssued(), before_.grossIssued);
    }

    function removeExpectedActiveMarket(uint256 stockSeed, bool asOperator) external {
        this.attemptRemove(stockSeed, asOperator ? 1 : 0, 0);
    }

    /// @dev Governance may deliberately replace or clear hooks. This exercises the Factory's
    /// expected-hook checks and the special cleanup path for an already-cleared hook.
    function configureExternalHook(uint256 stockSeed, uint8 hookSeed) external {
        address stockToken = _stocks[stockSeed % _stocks.length];
        bytes32 poolId = _poolId(stockToken);
        address active = factory.activeRewarder(poolId);
        address hook;
        if (hookSeed % 3 == 1) hook = FOREIGN_HOOK;
        else if (hookSeed % 3 == 2 && active != address(0)) hook = active;

        _installExternalHook(stockToken, hook, hook != address(0), false);
        modelHookFlags[stockToken] = hook == address(0) ? 0 : ROUTER_TOKEN0_ACTIVE_FLAG;
        assertEq(routerHookFlags(stockToken), modelHookFlags[stockToken]);
    }

    function _installExternalHook(address stockToken, address hook, bool token0Active, bool token1Active) private {
        (address token0, address token1) = _sort(stockToken, address(usdG));
        if (deepstate.owner() == address(v1Controller)) {
            vm.prank(v1Controller.owner());
            v1Controller.setPoolHookConfig(token0, token1, hook, token0Active, token1Active);
        } else {
            address routerOwner = deepstate.owner();
            vm.prank(routerOwner);
            deepstate.setPoolHookConfig(token0, token1, hook, token0Active, token1Active);
        }
    }

    function toggleMinterRole(bool enabled) external {
        vm.startPrank(minterController.owner());
        if (enabled) minterController.grantRoles(address(factory), minterController.MINTER_ROLE());
        else minterController.revokeRoles(address(factory), minterController.MINTER_ROLE());
        vm.stopPrank();
    }

    function toggleHookManagerRole(bool enabled) external {
        vm.startPrank(v1Controller.owner());
        if (enabled) v1Controller.grantRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        else v1Controller.revokeRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());
        vm.stopPrank();
    }

    function toggleRouterOwnership() external {
        address routerOwner = deepstate.owner();
        if (routerOwner == address(v1Controller)) {
            vm.prank(v1Controller.owner());
            v1Controller.transferDeepstateOwnership(ROUTER_CUSTODIAN);
        } else {
            vm.prank(routerOwner);
            deepstate.transferOwnership(address(v1Controller));
        }
    }

    function changeControllerOwner(uint8 controllerSeed, uint256 governanceSeed) external {
        if (controllerSeed & 1 == 0) {
            address currentOwner = v1Controller.owner();
            address nextOwner = _differentGovernance(governanceSeed, currentOwner);
            vm.prank(currentOwner);
            v1Controller.transferOwnership(nextOwner);
        } else {
            address currentOwner = minterController.owner();
            address nextOwner = _differentGovernance(governanceSeed, currentOwner);
            vm.prank(currentOwner);
            minterController.transferOwnership(nextOwner);
        }
    }

    function realignControllers() external {
        address targetOwner = factory.owner();
        address v1Owner = v1Controller.owner();
        address minterOwner = minterController.owner();
        if (v1Owner != targetOwner) {
            vm.prank(v1Owner);
            v1Controller.transferOwnership(targetOwner);
        }
        if (minterOwner != targetOwner) {
            vm.prank(minterOwner);
            minterController.transferOwnership(targetOwner);
        }
    }

    /// @dev Exercises a complete governance migration and proves delegated permissions plus the
    /// independently revocable operator survive ownership rotation exactly as documented.
    function migrateAlignedGovernance(uint256 governanceSeed) external {
        if (!_governanceAligned()) return;
        address oldOwner = factory.owner();
        address newOwner = _differentGovernance(governanceSeed, oldOwner);
        address operatorBefore = factory.operator();
        bool minterRoleBefore = minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE());
        bool hookRoleBefore = v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE());

        vm.prank(oldOwner);
        v1Controller.transferOwnership(newOwner);
        vm.prank(oldOwner);
        minterController.transferOwnership(newOwner);
        vm.prank(oldOwner);
        factory.transferOwnership(newOwner);

        ++successfulOwnershipMigrations;
        if (
            factory.owner() != newOwner || v1Controller.owner() != newOwner || minterController.owner() != newOwner
                || factory.operator() != operatorBefore
                || minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()) != minterRoleBefore
                || v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE()) != hookRoleBefore
        ) ++ownershipMigrationViolations;
    }

    /// @dev Attempts a one-step Factory transfer in arbitrary controller-owner states. A successful
    /// transfer is valid only after both controllers already share the proposed owner.
    function attemptFactoryOwnershipTransfer(uint256 governanceSeed) external {
        address oldOwner = factory.owner();
        address newOwner = _differentGovernance(governanceSeed, oldOwner);
        bool valid = v1Controller.owner() == newOwner && minterController.owner() == newOwner;
        address operatorBefore = factory.operator();
        bool minterRoleBefore = minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE());
        bool hookRoleBefore = v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE());

        vm.prank(oldOwner);
        (bool success,) = address(factory).call(abi.encodeCall(factory.transferOwnership, (newOwner)));
        if (success) {
            ++successfulOwnershipMigrations;
            if (!valid || factory.owner() != newOwner) ++ownershipMigrationViolations;
            if (
                factory.operator() != operatorBefore
                    || minterController.hasAnyRole(address(factory), minterController.MINTER_ROLE()) != minterRoleBefore
                    || v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE()) != hookRoleBefore
            ) ++ownershipMigrationViolations;
        } else {
            assertFalse(valid);
            assertEq(factory.owner(), oldOwner);
            assertEq(factory.operator(), operatorBefore);
        }
    }

    function attemptSetOperator(uint8 operatorSeed, uint8 callerSeed) external {
        address newOperator = operatorSeed % 3 == 0 ? address(0) : (operatorSeed % 3 == 1 ? OPERATOR_A : OPERATOR_B);
        address caller = callerSeed % 2 == 0 ? factory.owner() : UNAUTHORIZED;
        address oldOperator = factory.operator();
        bool aligned = _governanceAligned();

        vm.prank(caller);
        (bool success,) = address(factory).call(abi.encodeCall(factory.setOperator, (newOperator)));
        if (success) {
            if (caller != factory.owner()) ++authorizationViolations;
            if (!aligned) ++governanceAlignmentViolations;
            assertEq(factory.operator(), newOperator);
        } else {
            assertEq(factory.operator(), oldOperator);
        }
    }

    function toggleSablierFailure(bool shouldRevert) external {
        sablier.setRevertCreate(shouldRevert);
    }

    function advanceTime(uint32 elapsedSeed) external {
        vm.warp(block.timestamp + bound(uint256(elapsedSeed), 0, 60 days));
    }

    function advanceToDeploymentBoundary() external {
        uint256 next = factory.nextDeploymentAt();
        if (next > block.timestamp) vm.warp(next);
    }

    function expireMintWindow() external {
        uint40 endsAt = minterController.tokenAdministrationEndsAt();
        if (endsAt != 0 && endsAt != type(uint40).max && block.timestamp < endsAt) vm.warp(endsAt);
    }

    function attemptDirectMint(uint256 amountSeed, bool authorizedCaller) external {
        uint256 amount = bound(amountSeed, 1, 2_000_000_000e18);
        address caller = authorizedCaller ? minterController.owner() : UNAUTHORIZED;
        uint256 supplyBefore = deep.totalSupply();
        uint256 grossBefore = minterController.grossIssued();
        uint256 streamBefore = sablier.nextStreamId();

        vm.prank(caller);
        (bool success,) =
            address(minterController).call(abi.encodeCall(minterController.mint, (DIRECT_MINT_RECIPIENT, amount)));
        if (!success) {
            assertEq(deep.totalSupply(), supplyBefore);
            assertEq(minterController.grossIssued(), grossBefore);
            assertEq(sablier.nextStreamId(), streamBefore);
            return;
        }

        if (!authorizedCaller) ++authorizationViolations;
        ++successfulMintCalls;
        totalVestingMinted += _vesting(amount);
        assertEq(deep.totalSupply(), supplyBefore + _combined(amount));
        assertEq(minterController.grossIssued(), grossBefore + _combined(amount));
        assertEq(sablier.nextStreamId(), streamBefore + 1);
    }

    /// @dev Consumes as much of the tighter live-supply/gross-issuance headroom as the 70/30
    /// algebra permits. Subsequent funding actions must fail atomically until a burn restores only
    /// live-supply headroom; gross headroom is never restored.
    function consumeMintHeadroom() external {
        sablier.setRevertCreate(false);
        uint256 supplyHeadroom = minterController.mintCap() - deep.totalSupply();
        uint256 grossHeadroom = minterController.grossIssuanceCap() - minterController.grossIssued();
        uint256 headroom = supplyHeadroom < grossHeadroom ? supplyHeadroom : grossHeadroom;
        if (headroom < minterController.MINIMUM_COMBINED_ISSUANCE()) return;

        uint256 primaryAmount = headroom * minterController.PRIMARY_ALLOCATION_BPS() / 10_000;
        if (_vesting(primaryAmount) == 0 || _combined(primaryAmount) > headroom) return;

        uint256 supplyBefore = deep.totalSupply();
        uint256 grossBefore = minterController.grossIssued();
        uint256 streamBefore = sablier.nextStreamId();
        vm.prank(minterController.owner());
        (bool success,) = address(minterController)
            .call(abi.encodeCall(minterController.mint, (DIRECT_MINT_RECIPIENT, primaryAmount)));
        if (!success) {
            assertEq(deep.totalSupply(), supplyBefore);
            assertEq(minterController.grossIssued(), grossBefore);
            assertEq(sablier.nextStreamId(), streamBefore);
            return;
        }

        ++successfulMintCalls;
        totalVestingMinted += _vesting(primaryAmount);
        assertLt(
            _mintHeadroom(),
            _combined(factory.MARKET_FUNDING()),
            "headroom consumption must disable another market funding mint"
        );
    }

    function _deploySnapshot(address stockToken) private view returns (DeploySnapshot memory snapshot) {
        snapshot.committed = factory.fundingCommitted();
        snapshot.nextDeploymentAt = factory.nextDeploymentAt();
        snapshot.totalSupply = deep.totalSupply();
        snapshot.grossIssued = minterController.grossIssued();
        snapshot.nextStreamId = sablier.nextStreamId();
        snapshot.sablierBalance = deep.balanceOf(address(sablier));
        if (stockToken != address(0) && stockToken != address(usdG)) {
            snapshot.poolId = _poolId(stockToken);
            snapshot.activeRewarder = factory.activeRewarder(snapshot.poolId);
            snapshot.hook = deepstate.poolHook(snapshot.poolId);
            snapshot.routerPoolState = routerPoolState(stockToken);
            snapshot.marketDeployed = factory.marketDeployed(snapshot.poolId);
        }
    }

    function _fundingSnapshot(address stockToken) private view returns (FundingSnapshot memory snapshot) {
        snapshot.committed = factory.fundingCommitted();
        snapshot.nextDeploymentAt = factory.nextDeploymentAt();
        snapshot.totalSupply = deep.totalSupply();
        snapshot.grossIssued = minterController.grossIssued();
        snapshot.nextStreamId = sablier.nextStreamId();
        snapshot.sablierBalance = deep.balanceOf(address(sablier));
        snapshot.poolId = _poolId(stockToken);
        snapshot.activeRewarder = factory.activeRewarder(snapshot.poolId);
        snapshot.hook = deepstate.poolHook(snapshot.poolId);
        snapshot.routerPoolState = routerPoolState(stockToken);
        snapshot.marketDeployed = factory.marketDeployed(snapshot.poolId);
        if (snapshot.activeRewarder != address(0)) {
            snapshot.rewarderPool = factory.rewarderPool(snapshot.activeRewarder);
            snapshot.retiredRewarderPool = factory.retiredRewarderPool(snapshot.activeRewarder);
            snapshot.rewarderBalance = deep.balanceOf(snapshot.activeRewarder);
            snapshot.rewarderRetired = DeepstateRewarderV2(snapshot.activeRewarder).retired();
            snapshot.rewarderOwner = DeepstateRewarderV2(snapshot.activeRewarder).owner();
        }
    }

    function _assertFailedDeployAtomic(DeploySnapshot memory before_, address stockToken) private view {
        assertEq(factory.fundingCommitted(), before_.committed);
        assertEq(factory.nextDeploymentAt(), before_.nextDeploymentAt);
        assertEq(deep.totalSupply(), before_.totalSupply);
        assertEq(minterController.grossIssued(), before_.grossIssued);
        assertEq(sablier.nextStreamId(), before_.nextStreamId);
        assertEq(deep.balanceOf(address(sablier)), before_.sablierBalance);
        if (stockToken != address(0) && stockToken != address(usdG)) {
            assertEq(factory.activeRewarder(before_.poolId), before_.activeRewarder);
            assertEq(factory.marketDeployed(before_.poolId), before_.marketDeployed);
            assertEq(deepstate.poolHook(before_.poolId), before_.hook);
            assertEq(routerPoolState(stockToken), before_.routerPoolState);
        }
    }

    function _assertFailedFundingAtomic(FundingSnapshot memory before_, address stockToken) private view {
        assertEq(factory.fundingCommitted(), before_.committed);
        assertEq(factory.nextDeploymentAt(), before_.nextDeploymentAt);
        assertEq(deep.totalSupply(), before_.totalSupply);
        assertEq(minterController.grossIssued(), before_.grossIssued);
        assertEq(sablier.nextStreamId(), before_.nextStreamId);
        assertEq(deep.balanceOf(address(sablier)), before_.sablierBalance);
        assertEq(factory.activeRewarder(before_.poolId), before_.activeRewarder);
        assertEq(factory.marketDeployed(before_.poolId), before_.marketDeployed);
        assertEq(deepstate.poolHook(before_.poolId), before_.hook);
        assertEq(routerPoolState(stockToken), before_.routerPoolState);
        assertEq(_poolId(stockToken), before_.poolId);
        if (before_.activeRewarder != address(0)) {
            assertEq(factory.rewarderPool(before_.activeRewarder), before_.rewarderPool);
            assertEq(factory.retiredRewarderPool(before_.activeRewarder), before_.retiredRewarderPool);
            assertEq(deep.balanceOf(before_.activeRewarder), before_.rewarderBalance);
            assertEq(DeepstateRewarderV2(before_.activeRewarder).retired(), before_.rewarderRetired);
            assertEq(DeepstateRewarderV2(before_.activeRewarder).owner(), before_.rewarderOwner);
        }
    }

    function _recordAndAssertFactoryStream(uint256 streamId, uint256 primaryAmount) private {
        _factoryStreamIds.push(streamId);
        modelFactoryPrimaryForStream[streamId] = primaryAmount;
        _assertFactoryStream(streamId, primaryAmount);
    }

    function _assertFactoryStream(uint256 streamId, uint256 primaryAmount) private view {
        MockSablierLockupLinearV4.Stream memory created = sablier.stream(streamId);
        assertEq(created.funder, address(minterController));
        assertEq(created.sender, address(minterController));
        assertEq(created.recipient, VESTING_RECIPIENT);
        assertEq(created.token, address(deep));
        assertEq(created.depositAmount, _vesting(primaryAmount));
        assertFalse(created.cancelable);
        assertFalse(created.transferable);
        assertEq(keccak256(bytes(created.shape)), keccak256("Deepstate allocation"));
        assertEq(created.startUnlockAmount, 0);
        assertEq(created.cliffUnlockAmount, 0);
        assertEq(created.granularity, 0);
        assertEq(created.cliffDuration, 0);
        assertEq(created.totalDuration, 365 days);
    }

    function _semanticHookFlags(address stockToken, bool stockBuySideActive, bool usdGBuySideActive)
        private
        view
        returns (uint256 flags)
    {
        bool stockIsToken0 = stockToken < address(usdG);
        bool token0Active = stockIsToken0 ? stockBuySideActive : usdGBuySideActive;
        bool token1Active = stockIsToken0 ? usdGBuySideActive : stockBuySideActive;
        if (token0Active) flags |= ROUTER_TOKEN0_ACTIVE_FLAG;
        if (token1Active) flags |= ROUTER_TOKEN1_ACTIVE_FLAG;
    }

    function _candidateStock(uint256 tokenSeed) private view returns (address token, bool recognized) {
        uint256 choice = tokenSeed % (_stocks.length + 4);
        if (choice < _stocks.length) return (_stocks[choice], true);
        if (choice == _stocks.length) return (address(invalidDecimalsStock), false);
        if (choice == _stocks.length + 1) return (address(usdG), false);
        if (choice == _stocks.length + 2) return (UNAUTHORIZED, false);
        return (address(0), false);
    }

    function _quantitySchedule(uint256 startSeed, uint256 scheduleSeed)
        private
        pure
        returns (uint160 startQuantity, uint160 maxQuantity, bool valid)
    {
        startQuantity = uint160(bound(startSeed, 1, 1e24));
        uint256 mode = scheduleSeed % 5;
        if (mode == 0) return (0, uint160(1_000e18), false);
        if (mode == 1) return (startQuantity, startQuantity, false);

        uint256 growth;
        if (mode == 2) growth = bound(scheduleSeed, 2, 999);
        else if (mode == 3) growth = bound(scheduleSeed, 1_000, 1_000_000);
        else growth = 1_000_001;
        // startQuantity is bounded to 1e24 and growth to 1,000,001, well below uint160.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        maxQuantity = uint160(uint256(startQuantity) * growth);
        valid = mode == 3;
    }

    function _lifecycleCaller(uint8 callerSeed) private view returns (address) {
        if (callerSeed % 3 == 0) return factory.owner();
        if (callerSeed % 3 == 1 && factory.operator() != address(0)) return factory.operator();
        return UNAUTHORIZED;
    }

    function _governanceAligned() private view returns (bool) {
        address owner = factory.owner();
        return v1Controller.owner() == owner && minterController.owner() == owner;
    }

    function _differentGovernance(uint256 seed, address currentOwner) private pure returns (address nextOwner) {
        uint256 choice = seed % 3;
        nextOwner = choice == 0 ? GOVERNANCE_A : (choice == 1 ? GOVERNANCE_B : GOVERNANCE_C);
        if (nextOwner == currentOwner) {
            nextOwner = choice == 0 ? GOVERNANCE_B : (choice == 1 ? GOVERNANCE_C : GOVERNANCE_A);
        }
    }

    function _canMint(uint256 primaryAmount) private view returns (bool) {
        uint40 endsAt = minterController.tokenAdministrationEndsAt();
        if (endsAt == 0 || endsAt == type(uint40).max || block.timestamp >= endsAt) return false;
        uint256 combined = _combined(primaryAmount);
        if (deep.totalSupply() + combined > minterController.mintCap()) return false;
        if (minterController.grossIssued() + combined > minterController.grossIssuanceCap()) return false;
        return true;
    }

    function _mintHeadroom() private view returns (uint256) {
        uint256 supplyHeadroom = minterController.mintCap() - deep.totalSupply();
        uint256 grossHeadroom = minterController.grossIssuanceCap() - minterController.grossIssued();
        return supplyHeadroom < grossHeadroom ? supplyHeadroom : grossHeadroom;
    }

    function _combined(uint256 primaryAmount) private pure returns (uint256) {
        return primaryAmount + _vesting(primaryAmount);
    }

    function _vesting(uint256 primaryAmount) private pure returns (uint256) {
        return primaryAmount * 30 / 70;
    }

    function _poolId(address stockToken) private view returns (bytes32) {
        (address token0, address token1) = _sort(stockToken, address(usdG));
        return keccak256(abi.encode(token0, token1));
    }

    function _sort(address a, address b) private pure returns (address token0, address token1) {
        return a < b ? (a, b) : (b, a);
    }
}

contract DeepstateFactorySystemInvariantTest is StdInvariant, Test {
    DeepstateFactorySystemHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new DeepstateFactorySystemHandler();

        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = handler.attemptDeploy.selector;
        selectors[1] = handler.deployValidMarket.selector;
        selectors[2] = handler.attemptMigrateLegacyMarket.selector;
        selectors[3] = handler.migrateValidLegacyMarket.selector;
        selectors[4] = handler.attemptRemove.selector;
        selectors[5] = handler.removeExpectedActiveMarket.selector;
        selectors[6] = handler.configureExternalHook.selector;
        selectors[7] = handler.toggleMinterRole.selector;
        selectors[8] = handler.toggleHookManagerRole.selector;
        selectors[9] = handler.toggleRouterOwnership.selector;
        selectors[10] = handler.changeControllerOwner.selector;
        selectors[11] = handler.realignControllers.selector;
        selectors[12] = handler.migrateAlignedGovernance.selector;
        selectors[13] = handler.attemptFactoryOwnershipTransfer.selector;
        selectors[14] = handler.attemptSetOperator.selector;
        selectors[15] = handler.toggleSablierFailure.selector;
        selectors[16] = handler.advanceTime.selector;
        selectors[17] = handler.advanceToDeploymentBoundary.selector;
        selectors[18] = handler.expireMintWindow.selector;
        selectors[19] = handler.attemptDirectMint.selector;
        selectors[20] = handler.consumeMintHeadroom.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_NoAuthorityOrDependencyBoundaryIsBypassed() public view {
        assertEq(handler.authorizationViolations(), 0);
        assertEq(handler.governanceAlignmentViolations(), 0);
        assertEq(handler.delegatedRoleViolations(), 0);
        assertEq(handler.routerOwnershipViolations(), 0);
        assertEq(handler.mintWindowOrCapViolations(), 0);
        assertEq(handler.sablierDependencyViolations(), 0);
        assertEq(handler.migrationGuardViolations(), 0);
    }

    function invariant_OnlyValidFreshMarketsDeployAtTheCooldownAndWithinBudget() public view {
        assertEq(handler.marketValidationViolations(), 0);
        assertEq(handler.cooldownViolations(), 0);
        assertEq(handler.budgetViolations(), 0);
        assertEq(handler.lifecycleViolations(), 0);

        DeepstateRewarderFactory factory = handler.factory();
        assertEq(factory.fundingCommitted(), handler.successfulDeployments() * factory.MARKET_FUNDING());
        assertLe(factory.fundingCommitted(), factory.fundingBudget());

        uint256 deployments = handler.successfulDeployments();
        if (deployments == 0) {
            assertEq(factory.nextDeploymentAt(), 0);
        } else {
            uint256 lastDeployment = handler.successfulDeploymentTimestamp(deployments - 1);
            assertEq(factory.nextDeploymentAt(), lastDeployment + factory.DEPLOYMENT_COOLDOWN());
            for (uint256 i = 1; i < deployments; ++i) {
                assertGe(
                    handler.successfulDeploymentTimestamp(i),
                    handler.successfulDeploymentTimestamp(i - 1) + factory.DEPLOYMENT_COOLDOWN()
                );
            }
        }
    }

    function invariant_EveryMarketHasPermanentProvenanceAndCanonicalConfiguration() public view {
        DeepstateRewarderFactory factory = handler.factory();
        DeepstateV1 deepstate = handler.deepstate();
        DeepstateToken deep = handler.deep();
        address usdG = address(handler.usdG());

        for (uint256 i; i < handler.stockCount(); ++i) {
            address stockToken = handler.stock(i);
            (address token0, address token1) = _sort(stockToken, usdG);
            bytes32 poolId = keccak256(abi.encode(token0, token1));
            bool everDeployed = handler.modelEverDeployed(stockToken);
            address rewarderAddress = handler.modelRewarder(stockToken);

            assertEq(handler.routerHookFlags(stockToken), handler.modelHookFlags(stockToken));
            assertEq(factory.marketDeployed(poolId), everDeployed);

            if (!everDeployed) {
                assertEq(factory.activeRewarder(poolId), address(0));
                assertEq(rewarderAddress, address(0));
                continue;
            }

            DeepstateRewarderV2 rewarder = DeepstateRewarderV2(rewarderAddress);
            assertGt(rewarderAddress.code.length, 0);
            assertEq(rewarder.poolId(), poolId);
            assertEq(rewarder.token0(), token0);
            assertEq(rewarder.token1(), token1);
            assertEq(rewarder.deepstate(), address(deepstate));
            assertEq(rewarder.rewardToken(), address(deep));
            assertEq(rewarder.sideEmissionCap(), factory.SIDE_EMISSION_CAP());
            assertEq(rewarder.emissionDuration(), factory.EMISSION_DURATION());

            if (token0 == usdG) {
                assertEq(rewarder.token0StartQuantity(), factory.USDG_START_QUANTITY());
                assertEq(rewarder.token0MaxQuantity(), factory.USDG_MAX_QUANTITY());
                assertEq(rewarder.token1StartQuantity(), handler.modelStartQuantity(stockToken));
                assertEq(rewarder.token1MaxQuantity(), handler.modelMaxQuantity(stockToken));
            } else {
                assertEq(rewarder.token0StartQuantity(), handler.modelStartQuantity(stockToken));
                assertEq(rewarder.token0MaxQuantity(), handler.modelMaxQuantity(stockToken));
                assertEq(rewarder.token1StartQuantity(), factory.USDG_START_QUANTITY());
                assertEq(rewarder.token1MaxQuantity(), factory.USDG_MAX_QUANTITY());
            }
            assertGe(handler.modelMaxQuantity(stockToken), uint256(handler.modelStartQuantity(stockToken)) * 1_000);
            assertLe(handler.modelMaxQuantity(stockToken), uint256(handler.modelStartQuantity(stockToken)) * 1_000_000);

            if (handler.modelRemoved(stockToken)) {
                assertEq(factory.activeRewarder(poolId), address(0));
                assertEq(factory.rewarderPool(rewarderAddress), bytes32(0));
                assertEq(factory.retiredRewarderPool(rewarderAddress), poolId);
                assertTrue(rewarder.retired());
                assertEq(rewarder.owner(), address(0));
                assertEq(deep.balanceOf(rewarderAddress), 0);
            } else {
                assertEq(factory.activeRewarder(poolId), rewarderAddress);
                assertEq(factory.rewarderPool(rewarderAddress), poolId);
                assertEq(factory.retiredRewarderPool(rewarderAddress), bytes32(0));
                assertFalse(rewarder.retired());
                assertEq(rewarder.owner(), address(factory));
                assertEq(deep.balanceOf(rewarderAddress), factory.MARKET_FUNDING());
                assertEq(deep.balanceOf(rewarderAddress), uint256(factory.SIDE_EMISSION_CAP()) * 2);
            }
        }
    }

    function invariant_MigrationsAreGovernanceOnlyAndConsumeTheSameLifetimeBudget() public view {
        assertLe(handler.successfulMarketMigrations(), handler.successfulDeployments());
        assertEq(handler.migrationGuardViolations(), 0);
        assertEq(
            handler.factory().fundingCommitted(), handler.successfulDeployments() * handler.factory().MARKET_FUNDING()
        );
    }

    function invariant_RetirementNeverRestoresBudgetAndPermanentlyPreventsRedeployment() public view {
        assertLe(handler.successfulRemovals(), handler.successfulDeployments());
        assertEq(
            handler.factory().fundingCommitted(), handler.successfulDeployments() * handler.factory().MARKET_FUNDING()
        );
        for (uint256 i; i < handler.stockCount(); ++i) {
            address stockToken = handler.stock(i);
            if (handler.modelRemoved(stockToken)) {
                assertTrue(handler.modelEverDeployed(stockToken));
                assertTrue(handler.factory().marketDeployed(_poolId(stockToken, address(handler.usdG()))));
            }
        }
    }

    function invariant_MintAndBurnAccountingRemainsConservedUnderEveryLifecycleSequence() public view {
        DeepstateToken deep = handler.deep();
        DeepstateMinterController minterController = handler.minterController();
        assertLe(deep.totalSupply(), minterController.mintCap());
        assertLe(minterController.grossIssued(), minterController.grossIssuanceCap());
        assertEq(deep.totalSupply() + handler.totalRewarderFundingBurned(), minterController.grossIssued());
        assertEq(deep.balanceOf(address(handler.sablier())), handler.totalVestingMinted());
        assertEq(handler.sablier().nextStreamId(), handler.successfulMintCalls() + 1);
        assertEq(handler.factoryStreamCount(), handler.successfulDeployments());
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(handler.factory())));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minterController)));
        assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));
        assertEq(deep.defaultAdminCount(), 1);

        for (uint256 i; i < handler.factoryStreamCount(); ++i) {
            uint256 streamId = handler.factoryStreamId(i);
            _assertFactoryStream(streamId, handler.modelFactoryPrimaryForStream(streamId));
        }
    }

    function invariant_ProductionPolicyConstantsRemainExact() public view {
        DeepstateRewarderFactory factory = handler.factory();
        DeepstateMinterController minterController = handler.minterController();

        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 365 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 50_000_000e18);
        assertEq(factory.MARKET_FUNDING(), 100_000_000e18);
        assertEq(factory.USDG_START_QUANTITY(), 1e6);
        assertEq(factory.USDG_MAX_QUANTITY(), 1_000_000e6);
        assertEq(factory.MAX_QUANTITY_GROWTH(), 1_000_000);
        assertEq(factory.fundingBudget(), 1_000_000_000e18);
        assertEq(minterController.RECIPIENT_ALLOCATION_BPS(), 3_000);
        assertEq(minterController.PRIMARY_ALLOCATION_BPS(), 7_000);
        assertEq(minterController.VESTING_DURATION(), 365 days);
        assertEq(minterController.TOKEN_ADMINISTRATION_DURATION(), 730 days);
        assertEq(handler.v1Controller().HOOK_MANAGER_ROLE(), 1);
    }

    function invariant_GovernanceRotationNeverMutatesOperatorOrDelegatedPermissionsImplicitly() public view {
        assertEq(handler.ownershipMigrationViolations(), 0);
        address operator = handler.factory().operator();
        assertTrue(operator == address(0) || operator == handler.OPERATOR_A() || operator == handler.OPERATOR_B());
    }

    function test_Reachability_CompoundDeployRemoveAndPermanentRedeployRejection() public {
        address stockToken = handler.stock(0);
        bytes32 poolId = _poolId(stockToken, address(handler.usdG()));

        // Activate only the semantic stock-buy side so address sorting cannot hide a flag swap.
        handler.attemptDeploy(0, 37e18, 1_003, 1, 0);
        address rewarder = handler.factory().activeRewarder(poolId);
        assertNotEq(rewarder, address(0));
        assertEq(handler.successfulDeployments(), 1);
        assertEq(handler.factoryStreamCount(), 1);
        _assertFactoryStream(handler.factoryStreamId(0), 100_000_000e18);
        uint256 expectedFlag = stockToken < address(handler.usdG())
            ? handler.ROUTER_TOKEN0_ACTIVE_FLAG()
            : handler.ROUTER_TOKEN1_ACTIVE_FLAG();
        assertEq(handler.routerHookFlags(stockToken), expectedFlag);

        assertEq(handler.deep().balanceOf(rewarder), 100_000_000e18);

        handler.removeExpectedActiveMarket(0, true);
        assertEq(handler.successfulRemovals(), 1);
        assertEq(handler.factory().activeRewarder(poolId), address(0));
        assertEq(handler.routerHookFlags(stockToken), 0);
        assertTrue(DeepstateRewarderV2(rewarder).retired());

        handler.advanceToDeploymentBoundary();
        handler.deployValidMarket(0, 1e18, false);
        assertEq(handler.successfulDeployments(), 1);
        assertEq(handler.factory().activeRewarder(poolId), address(0));
        assertTrue(handler.factory().marketDeployed(poolId));
    }

    function test_Reachability_DeployFailuresAreAtomicAndRecoverable() public {
        address firstStock = handler.stock(0);
        address nextStock = handler.stock(1);
        bytes32 nextPoolId = _poolId(nextStock, address(handler.usdG()));
        handler.deployValidMarket(0, 1e18, false);

        // Global cooldown.
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        handler.advanceToDeploymentBoundary();

        // Existing hook.
        handler.configureExternalHook(1, 1);
        uint256 foreignHookState = handler.routerPoolState(nextStock);
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        assertEq(handler.routerPoolState(nextStock), foreignHookState);
        handler.configureExternalHook(1, 0);

        // Missing delegated mint authority.
        handler.toggleMinterRole(false);
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        handler.toggleMinterRole(true);

        // Missing delegated hook authority.
        handler.toggleHookManagerRole(false);
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        handler.toggleHookManagerRole(true);

        // V1 Controller no longer owns the Router.
        handler.toggleRouterOwnership();
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        handler.toggleRouterOwnership();

        // Sablier creation failure after Factory effects begin.
        handler.toggleSablierFailure(true);
        handler.deployValidMarket(1, 1e18, false);
        _assertOnlyFirstMarketDeployed(nextPoolId);
        handler.toggleSablierFailure(false);

        handler.deployValidMarket(1, 1e18, false);
        assertEq(handler.successfulDeployments(), 2);
        assertNotEq(handler.factory().activeRewarder(nextPoolId), address(0));
        assertEq(handler.factoryStreamCount(), 2);
        assertEq(handler.deep().balanceOf(address(handler.sablier())), 2 * (uint256(100_000_000e18) * 30 / 70));
        assertEq(
            handler.factory().activeRewarder(_poolId(firstStock, address(handler.usdG()))),
            handler.modelRewarder(firstStock)
        );
    }

    function test_Reachability_InvalidInputsUnauthorizedCallerAndOwnerMisalignmentFailAtomically() public {
        address stockToken = handler.stock(0);
        bytes32 poolId = _poolId(stockToken, address(handler.usdG()));

        // An arbitrary caller cannot deploy an otherwise valid market.
        handler.attemptDeploy(0, 1e18, 1_003, 3, 2);
        _assertNoMarketDeployment(stockToken, poolId);

        // A market must select at least one hook side and respect both ramp boundaries.
        handler.attemptDeploy(0, 1e18, 1_003, 0, 0);
        _assertNoMarketDeployment(stockToken, poolId);
        handler.attemptDeploy(0, 1e18, 2, 3, 0);
        _assertNoMarketDeployment(stockToken, poolId);
        handler.attemptDeploy(0, 1e18, 4, 3, 0);
        _assertNoMarketDeployment(stockToken, poolId);

        // The candidate must be a distinct 18-decimal contract.
        handler.attemptDeploy(11, 1e18, 1_003, 3, 0);
        _assertNoMarketDeployment(address(handler.invalidDecimalsStock()), bytes32(0));
        handler.attemptDeploy(12, 1e18, 1_003, 3, 0);
        _assertNoMarketDeployment(address(handler.usdG()), bytes32(0));
        handler.attemptDeploy(14, 1e18, 1_003, 3, 0);
        _assertNoMarketDeployment(address(0), bytes32(0));

        // A controller-owner mismatch disables the owner and operator until governance realigns.
        handler.changeControllerOwner(0, 0);
        handler.deployValidMarket(0, 1e18, true);
        _assertNoMarketDeployment(stockToken, poolId);
        handler.realignControllers();
        handler.deployValidMarket(0, 1e18, true);
        assertEq(handler.successfulDeployments(), 1);
        assertNotEq(handler.factory().activeRewarder(poolId), address(0));
    }

    function test_Reachability_AlignedGovernanceMigrationPreservesOperatorAndDelegatedRoles() public {
        address operatorBefore = handler.factory().operator();
        handler.migrateAlignedGovernance(0);

        address newOwner = handler.factory().owner();
        assertEq(handler.successfulOwnershipMigrations(), 1);
        assertEq(handler.v1Controller().owner(), newOwner);
        assertEq(handler.minterController().owner(), newOwner);
        assertEq(handler.factory().operator(), operatorBefore);
        assertTrue(
            handler.minterController().hasAnyRole(address(handler.factory()), handler.minterController().MINTER_ROLE())
        );
        assertTrue(
            handler.v1Controller().hasAnyRole(address(handler.factory()), handler.v1Controller().HOOK_MANAGER_ROLE())
        );

        // The unchanged operator and delegated permissions remain usable under the new owner.
        handler.deployValidMarket(0, 1e18, true);
        assertEq(handler.successfulDeployments(), 1);
    }

    function test_Reachability_MigrationGuardsAreAtomicAndOnlyGovernanceCanReplaceTheExactPredecessor() public {
        address stockToken = handler.stock(0);
        bytes32 poolId = _poolId(stockToken, address(handler.usdG()));

        handler.attemptMigrateLegacyMarket(0, 1e18, 1, 0);
        assertEq(handler.successfulDeployments(), 0);
        assertEq(handler.successfulMarketMigrations(), 0);
        assertNotEq(handler.deepstate().poolHook(poolId), address(0));

        handler.attemptMigrateLegacyMarket(0, 1e18, 0, 3);
        handler.attemptMigrateLegacyMarket(0, 1e18, 0, 1);
        handler.attemptMigrateLegacyMarket(0, 1e18, 0, 2);
        assertEq(handler.successfulDeployments(), 0);
        assertEq(handler.factory().fundingCommitted(), 0);

        handler.toggleSablierFailure(true);
        handler.migrateValidLegacyMarket(0, 1e18);
        assertEq(handler.successfulDeployments(), 0);
        assertNotEq(handler.deepstate().poolHook(poolId), address(0));
        handler.toggleSablierFailure(false);

        handler.migrateValidLegacyMarket(0, 1e18);
        address rewarder = handler.factory().activeRewarder(poolId);
        assertEq(handler.successfulDeployments(), 1);
        assertEq(handler.successfulMarketMigrations(), 1);
        assertEq(handler.factory().fundingCommitted(), 100_000_000e18);
        assertEq(handler.deepstate().poolHook(poolId), rewarder);
        assertEq(handler.deep().balanceOf(rewarder), 100_000_000e18);
        assertEq(handler.factoryStreamCount(), 1);
    }

    function test_Reachability_RemovalGuardsExerciseEveryExpectedState() public {
        address stockToken = handler.stock(0);
        bytes32 poolId = _poolId(stockToken, address(handler.usdG()));
        handler.deployValidMarket(0, 1e18, false);
        address rewarder = handler.factory().activeRewarder(poolId);

        // A removal naming the wrong Rewarder is rejected without touching full market funding.
        handler.attemptRemove(0, 0, 1);
        assertEq(handler.successfulRemovals(), 0);
        assertEq(handler.deep().balanceOf(rewarder), 100_000_000e18);

        // A foreign hook blocks removal. A pre-cleared hook permits cleanup even after role revocation.
        handler.configureExternalHook(0, 1);
        handler.removeExpectedActiveMarket(0, true);
        assertEq(handler.successfulRemovals(), 0);
        handler.configureExternalHook(0, 0);
        handler.toggleHookManagerRole(false);
        handler.removeExpectedActiveMarket(0, true);
        assertEq(handler.successfulRemovals(), 1);
        assertTrue(DeepstateRewarderV2(rewarder).retired());
        assertEq(
            handler.routerPoolState(stockToken)
                & (handler.ROUTER_TOKEN0_ACTIVE_FLAG() | handler.ROUTER_TOKEN1_ACTIVE_FLAG()),
            0
        );
    }

    function test_Reachability_CapAndExactDeadlineFailuresAreAtomic() public {
        handler.consumeMintHeadroom();
        uint256 supplyAtCap = handler.deep().totalSupply();
        uint256 grossBefore = handler.minterController().grossIssued();
        uint256 streamBefore = handler.sablier().nextStreamId();
        handler.deployValidMarket(0, 1e18, false);
        assertEq(handler.successfulDeployments(), 0);
        assertEq(handler.deep().totalSupply(), supplyAtCap);
        assertEq(handler.minterController().grossIssued(), grossBefore);
        assertEq(handler.sablier().nextStreamId(), streamBefore);

        // A fresh system reaches the exact deadline independently of cap exhaustion.
        DeepstateFactorySystemHandler expired = new DeepstateFactorySystemHandler();
        expired.expireMintWindow();
        uint256 expiredSupply = expired.deep().totalSupply();
        expired.deployValidMarket(0, 1e18, false);
        assertEq(expired.successfulDeployments(), 0);
        assertEq(expired.deep().totalSupply(), expiredSupply);
        assertEq(expired.factory().fundingCommitted(), 0);
        assertEq(expired.sablier().nextStreamId(), 1);
    }

    function test_Reachability_ProductionBudgetIsLifetimeAndRetirementDoesNotRestoreIt() public {
        for (uint256 i; i < 10; ++i) {
            handler.deployValidMarket(i, 1e18, false);
            assertEq(handler.successfulDeployments(), i + 1);
            handler.advanceToDeploymentBoundary();
        }
        assertEq(handler.factory().fundingCommitted(), 1_000_000_000e18);
        assertEq(handler.factoryStreamCount(), 10);

        handler.deployValidMarket(10, 1e18, false);
        assertEq(handler.successfulDeployments(), 10);
        assertEq(handler.factory().activeRewarder(_poolId(handler.stock(10), address(handler.usdG()))), address(0));

        handler.removeExpectedActiveMarket(0, false);
        assertEq(handler.factory().fundingCommitted(), 1_000_000_000e18);
        handler.deployValidMarket(10, 1e18, false);
        assertEq(handler.successfulDeployments(), 10);
        assertEq(handler.factory().fundingCommitted(), 1_000_000_000e18);
    }

    function _assertOnlyFirstMarketDeployed(bytes32 nextPoolId) private view {
        assertEq(handler.successfulDeployments(), 1);
        assertEq(handler.factory().fundingCommitted(), 100_000_000e18);
        assertEq(handler.factory().activeRewarder(nextPoolId), address(0));
        assertFalse(handler.factory().marketDeployed(nextPoolId));
        assertEq(handler.factoryStreamCount(), 1);
        assertEq(handler.sablier().nextStreamId(), 2);
    }

    function _assertNoMarketDeployment(address stockToken, bytes32 poolId) private view {
        assertEq(handler.successfulDeployments(), 0);
        assertEq(handler.factory().fundingCommitted(), 0);
        assertEq(handler.factory().nextDeploymentAt(), 0);
        assertEq(handler.factoryStreamCount(), 0);
        assertEq(handler.sablier().nextStreamId(), 1);
        if (poolId != bytes32(0)) {
            assertEq(handler.factory().activeRewarder(poolId), address(0));
            assertFalse(handler.factory().marketDeployed(poolId));
            assertEq(handler.deepstate().poolHook(poolId), address(0));
            assertEq(handler.routerHookFlags(stockToken), 0);
        }
    }

    function _poolId(address stockToken, address usdG) private pure returns (bytes32) {
        (address token0, address token1) = _sort(stockToken, usdG);
        return keccak256(abi.encode(token0, token1));
    }

    function _sort(address a, address b) private pure returns (address token0, address token1) {
        return a < b ? (a, b) : (b, a);
    }

    function _assertFactoryStream(uint256 streamId, uint256 primaryAmount) private view {
        MockSablierLockupLinearV4.Stream memory created = handler.sablier().stream(streamId);
        assertEq(created.funder, address(handler.minterController()));
        assertEq(created.sender, address(handler.minterController()));
        assertEq(created.recipient, handler.VESTING_RECIPIENT());
        assertEq(created.token, address(handler.deep()));
        assertEq(created.depositAmount, primaryAmount * 30 / 70);
        assertFalse(created.cancelable);
        assertFalse(created.transferable);
        assertEq(keccak256(bytes(created.shape)), keccak256("Deepstate allocation"));
        assertEq(created.startUnlockAmount, 0);
        assertEq(created.cliffUnlockAmount, 0);
        assertEq(created.granularity, 0);
        assertEq(created.cliffDuration, 0);
        assertEq(created.totalDuration, 365 days);
    }
}
