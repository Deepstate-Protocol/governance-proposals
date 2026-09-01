// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "../mocks/MockSablierLockupLinearV4.sol";

contract GenericFactoryInvariantToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function name() public pure override returns (string memory) {
        return "Invariant Token";
    }

    function symbol() public pure override returns (string memory) {
        return "INV";
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract GenericFactoryHandler is Test {
    uint256 internal constant MAX_UNITS = 1_000_000;

    DeepstateRewarderFactory public immutable factory;
    DeepstateMinterController public immutable minter;
    DeepstateV1Controller public immutable v1Controller;
    DeepstateV1 public immutable router;
    DeepstateToken public immutable deep;
    MockSablierLockupLinearV4 public immutable sablier;
    address public immutable outsider;

    address[] private _token0s;
    address[] private _token1s;
    mapping(bytes32 poolId => address rewarder) public modelRewarder;
    mapping(bytes32 poolId => uint256 maxUnits) public modelToken0MaxUnits;
    mapping(bytes32 poolId => uint256 maxUnits) public modelToken1MaxUnits;
    mapping(bytes32 poolId => bool removed) public modelRemoved;
    mapping(address rewarder => bool burned) public modelRewarderBurned;
    address[] private _rewarders;

    uint256 public successfulDeployments;
    uint256 public uniqueBurns;
    uint256 public lastDeploymentAt;
    uint256 public failedDeployments;
    uint256 public unauthorizedAttempts;

    constructor(
        DeepstateRewarderFactory factory_,
        DeepstateMinterController minter_,
        DeepstateV1Controller v1Controller_,
        DeepstateV1 router_,
        DeepstateToken deep_,
        MockSablierLockupLinearV4 sablier_,
        address outsider_,
        address[] memory token0s_,
        address[] memory token1s_
    ) {
        factory = factory_;
        minter = minter_;
        v1Controller = v1Controller_;
        router = router_;
        deep = deep_;
        sablier = sablier_;
        outsider = outsider_;
        for (uint256 i; i < token0s_.length; ++i) {
            _token0s.push(token0s_[i]);
            _token1s.push(token1s_[i]);
        }
    }

    function pairCount() external view returns (uint256) {
        return _token0s.length;
    }

    function pair(uint256 index) public view returns (address token0, address token1) {
        index %= _token0s.length;
        return (_token0s[index], _token1s[index]);
    }

    function rewarderCount() external view returns (uint256) {
        return _rewarders.length;
    }

    function rewarderAt(uint256 index) external view returns (address) {
        return _rewarders[index];
    }

    function deploy(
        uint256 pairSeed,
        uint256 token0UnitsSeed,
        uint256 token1UnitsSeed,
        uint8 validitySeed,
        bool advanceToBoundary,
        bool token0Active,
        bool token1Active
    ) external {
        (address token0, address token1) = pair(pairSeed);
        uint256 token0MaxUnits = _units(token0UnitsSeed, validitySeed);
        uint256 token1MaxUnits = _units(token1UnitsSeed, validitySeed >> 2);
        if (advanceToBoundary && block.timestamp < factory.nextDeploymentAt()) {
            vm.warp(factory.nextDeploymentAt());
        }

        bytes32 poolId = _poolId(token0, token1);
        uint256 deadlineBefore = factory.nextDeploymentAt();
        uint256 supplyBefore = deep.totalSupply();
        uint256 streamsBefore = sablier.nextStreamId();
        address hookBefore = router.poolHook(poolId);

        DeepstateRewarderFactory.MarketConfig memory config = DeepstateRewarderFactory.MarketConfig({
            token0: token0,
            token1: token1,
            token0MaxUnits: token0MaxUnits,
            token1MaxUnits: token1MaxUnits,
            token0Active: token0Active,
            token1Active: token1Active
        });
        (bool success, bytes memory result) =
            address(factory).call(abi.encodeCall(DeepstateRewarderFactory.deployMarket, (config)));

        if (!success) {
            ++failedDeployments;
            assertEq(factory.nextDeploymentAt(), deadlineBefore);
            assertEq(deep.totalSupply(), supplyBefore);
            assertEq(sablier.nextStreamId(), streamsBefore);
            assertEq(router.poolHook(poolId), hookBefore);
            return;
        }

        address rewarder = abi.decode(result, (address));
        ++successfulDeployments;
        lastDeploymentAt = block.timestamp;
        modelRewarder[poolId] = rewarder;
        modelToken0MaxUnits[poolId] = token0MaxUnits;
        modelToken1MaxUnits[poolId] = token1MaxUnits;
        modelRemoved[poolId] = false;
        _rewarders.push(rewarder);

        assertGe(token0MaxUnits, 1_000);
        assertLe(token0MaxUnits, MAX_UNITS);
        assertGe(token1MaxUnits, 1_000);
        assertLe(token1MaxUnits, MAX_UNITS);
        assertEq(factory.nextDeploymentAt(), block.timestamp + factory.DEPLOYMENT_COOLDOWN());
        assertEq(router.poolHook(poolId), rewarder);
    }

    function remove(uint256 pairSeed) external {
        (address token0, address token1) = pair(pairSeed);
        bytes32 poolId = _poolId(token0, token1);
        address rewarder = modelRewarder[poolId];
        uint256 balanceBefore = rewarder == address(0) ? 0 : deep.balanceOf(rewarder);
        uint256 supplyBefore = deep.totalSupply();

        factory.removeMarket(token0, token1);
        if (rewarder != address(0)) modelRemoved[poolId] = true;

        assertEq(router.poolHook(poolId), address(0));
        assertEq(deep.totalSupply(), supplyBefore);
        if (rewarder != address(0)) assertEq(deep.balanceOf(rewarder), balanceBefore);
    }

    function burn(uint256 pairSeed) external {
        (address token0, address token1) = pair(pairSeed);
        bytes32 poolId = _poolId(token0, token1);
        address rewarder = modelRewarder[poolId];
        if (rewarder == address(0)) return;
        address hookBefore = router.poolHook(poolId);
        uint256 balanceBefore = deep.balanceOf(rewarder);

        factory.burnBalance(rewarder);
        if (balanceBefore != 0) {
            modelRewarderBurned[rewarder] = true;
            ++uniqueBurns;
        }

        assertEq(router.poolHook(poolId), hookBefore);
        assertEq(deep.balanceOf(rewarder), 0);
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 0, 10 days));
    }

    function attemptUnauthorized(uint256 pairSeed, uint8 actionSeed) external {
        (address token0, address token1) = pair(pairSeed);
        bytes32 poolId = _poolId(token0, token1);
        address rewarder = modelRewarder[poolId];
        if (rewarder == address(0)) rewarder = outsider;
        DeepstateRewarderFactory.MarketConfig memory config = DeepstateRewarderFactory.MarketConfig({
            token0: token0,
            token1: token1,
            token0MaxUnits: 5_000,
            token1MaxUnits: 5_000,
            token0Active: true,
            token1Active: true
        });
        bytes memory callData;
        if (actionSeed % 4 == 0) {
            callData = abi.encodeCall(DeepstateRewarderFactory.deployMarket, (config));
        } else if (actionSeed % 4 == 1) {
            callData = abi.encodeCall(DeepstateRewarderFactory.removeMarket, (token0, token1));
        } else if (actionSeed % 4 == 2) {
            callData = abi.encodeCall(DeepstateRewarderFactory.burnBalance, (rewarder));
        } else {
            callData = abi.encodeCall(DeepstateRewarderFactory.setOperator, (outsider));
        }

        bytes32 beforeState = _fingerprint(poolId, rewarder);
        ++unauthorizedAttempts;
        vm.prank(outsider);
        (bool success,) = address(factory).call(callData);
        assertFalse(success);
        assertEq(_fingerprint(poolId, rewarder), beforeState);
    }

    function _units(uint256 seed, uint8 mode) private pure returns (uint256) {
        mode %= 4;
        if (mode == 0) return 1_000 + seed % (MAX_UNITS - 999);
        if (mode == 1) return seed % 1_000;
        if (mode == 2) return MAX_UNITS + 1 + seed % 1_000_000;
        return 5_000;
    }

    function _fingerprint(bytes32 poolId, address rewarder) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                factory.owner(),
                factory.operator(),
                factory.nextDeploymentAt(),
                router.poolHook(poolId),
                deep.totalSupply(),
                rewarder == address(0) ? 0 : deep.balanceOf(rewarder)
            )
        );
    }

    function _poolId(address token0, address token1) private pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }
}

contract DeepstateFactorySystemInvariantTest is StdInvariant, Test {
    uint256 internal constant MARKET_FUNDING = 100_000_000e18;
    uint256 internal constant MARKET_VESTING = 42_857_142_857142857142857142;

    DeepstateToken internal deep;
    DeepstateV1 internal router;
    DeepstateV1Controller internal v1Controller;
    DeepstateMinterController internal minter;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;
    GenericFactoryHandler internal handler;
    address internal outsider = makeAddr("outsider");
    address[] internal token0s;
    address[] internal token1s;

    function setUp() public {
        vm.warp(1_000_000);
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        router = new DeepstateV1();
        sablier = new MockSablierLockupLinearV4();
        v1Controller = new DeepstateV1Controller(address(this), address(router));
        minter = new DeepstateMinterController(
            address(this), address(deep), address(sablier), makeAddr("recipient"), 3_000_000_000e18
        );
        factory = new DeepstateRewarderFactory(address(this), address(v1Controller), address(minter));

        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minter));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minter.activateTokenAdministration();
        minter.grantRoles(address(factory), minter.MINTER_ROLE());
        router.transferOwnership(address(v1Controller));
        v1Controller.grantRoles(address(factory), v1Controller.HOOK_MANAGER_ROLE());

        _createPairs();
        handler =
            new GenericFactoryHandler(factory, minter, v1Controller, router, deep, sablier, outsider, token0s, token1s);
        factory.setOperator(address(handler));
        targetContract(address(handler));
    }

    function invariant_AuthorityAndProductionPolicyRemainBounded() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.operator(), address(handler));
        assertEq(router.owner(), address(v1Controller));
        assertTrue(minter.hasAnyRole(address(factory), minter.MINTER_ROLE()));
        assertEq(minter.maxSupply(), 3_000_000_000e18);
        assertLe(deep.totalSupply(), minter.maxSupply());
        assertTrue(v1Controller.hasAnyRole(address(factory), v1Controller.HOOK_MANAGER_ROLE()));
        assertEq(factory.DEPLOYMENT_COOLDOWN(), 3 days);
        assertEq(factory.EMISSION_DURATION(), 365 days);
        assertEq(factory.SIDE_EMISSION_CAP(), 50_000_000e18);
        assertEq(factory.MARKET_FUNDING(), MARKET_FUNDING);
        assertEq(factory.MAX_QUANTITY_GROWTH(), 1_000_000);
    }

    function invariant_RouterIsCanonicalAndEverySuccessfulPairKeepsPermanentHistory() public view {
        for (uint256 i; i < token0s.length; ++i) {
            bytes32 poolId = _poolId(token0s[i], token1s[i]);
            address rewarderAddress = handler.modelRewarder(poolId);
            if (rewarderAddress == address(0)) {
                assertEq(router.poolHook(poolId), address(0));
                continue;
            }

            if (handler.modelRemoved(poolId)) assertEq(router.poolHook(poolId), address(0));
            else assertEq(router.poolHook(poolId), rewarderAddress);

            DeepstateRewarderV2 rewarder = DeepstateRewarderV2(rewarderAddress);
            assertEq(rewarder.owner(), address(factory));
            assertEq(rewarder.poolId(), poolId);
            assertEq(rewarder.token0(), token0s[i]);
            assertEq(rewarder.token1(), token1s[i]);
            uint256 unit0 = _unit(token0s[i]);
            uint256 unit1 = _unit(token1s[i]);
            assertEq(rewarder.token0StartQuantity(), unit0);
            assertEq(rewarder.token1StartQuantity(), unit1);
            assertEq(rewarder.token0MaxQuantity(), handler.modelToken0MaxUnits(poolId) * unit0);
            assertEq(rewarder.token1MaxQuantity(), handler.modelToken1MaxUnits(poolId) * unit1);
            if (handler.modelRewarderBurned(rewarderAddress)) assertEq(deep.balanceOf(rewarderAddress), 0);
            else assertEq(deep.balanceOf(rewarderAddress), MARKET_FUNDING);
        }

        for (uint256 i; i < handler.rewarderCount(); ++i) {
            address rewarderAddress = handler.rewarderAt(i);
            assertEq(DeepstateRewarderV2(rewarderAddress).owner(), address(factory));
            if (handler.modelRewarderBurned(rewarderAddress)) assertEq(deep.balanceOf(rewarderAddress), 0);
            else assertEq(deep.balanceOf(rewarderAddress), MARKET_FUNDING);
        }
    }

    function invariant_MintBurnAndCooldownAccountingRemainConserved() public view {
        uint256 deployments = handler.successfulDeployments();
        uint256 burns = handler.uniqueBurns();
        assertEq(deep.totalSupply(), deployments * (MARKET_FUNDING + MARKET_VESTING) - burns * MARKET_FUNDING);
        assertEq(deep.balanceOf(address(sablier)), deployments * MARKET_VESTING);
        if (deployments == 0) assertEq(factory.nextDeploymentAt(), 0);
        else assertEq(factory.nextDeploymentAt(), handler.lastDeploymentAt() + 3 days);
    }

    function test_Reachability_NativeDeployUnlinkThenBurnAreIndependent() public {
        handler.deploy(0, 19_000, 4_000, 3, true, true, true);
        (address token0, address token1) = handler.pair(0);
        bytes32 poolId = _poolId(token0, token1);
        address rewarder = handler.modelRewarder(poolId);
        assertEq(token0, address(0));
        assertNotEq(rewarder, address(0));
        assertEq(DeepstateRewarderV2(rewarder).token0StartQuantity(), 1e18);

        handler.remove(0);
        assertEq(router.poolHook(poolId), address(0));
        assertEq(deep.balanceOf(rewarder), MARKET_FUNDING);
        handler.burn(0);
        assertEq(router.poolHook(poolId), address(0));
        assertEq(deep.balanceOf(rewarder), 0);
    }

    function test_Reachability_CooldownAndLiveHookReplacement() public {
        handler.deploy(1, 5_000, 5_000, 3, true, true, true);
        (address token0, address token1) = handler.pair(1);
        bytes32 poolId = _poolId(token0, token1);
        address first = handler.modelRewarder(poolId);

        handler.deploy(1, 5_000, 5_000, 3, false, true, true);
        assertEq(handler.modelRewarder(poolId), first);

        vm.warp(factory.nextDeploymentAt());
        handler.deploy(1, 6_000, 7_000, 3, true, true, true);
        address second = handler.modelRewarder(poolId);
        assertNotEq(second, first);
        assertEq(router.poolHook(poolId), second);
        assertEq(deep.balanceOf(first), MARKET_FUNDING);
        assertEq(deep.balanceOf(second), MARKET_FUNDING);
    }

    function test_Reachability_UnauthorizedSelectorsLeaveStateUntouched() public {
        for (uint8 action; action < 4; ++action) {
            handler.attemptUnauthorized(0, action);
        }
        assertEq(handler.unauthorizedAttempts(), 4);
    }

    function _createPairs() private {
        GenericFactoryInvariantToken nativePartner = new GenericFactoryInvariantToken(18);
        token0s.push(address(0));
        token1s.push(address(nativePartner));
        for (uint256 i; i < 11; ++i) {
            GenericFactoryInvariantToken a = new GenericFactoryInvariantToken(uint8(6 + i % 3 * 2));
            GenericFactoryInvariantToken b = new GenericFactoryInvariantToken(18);
            if (address(a) < address(b)) {
                token0s.push(address(a));
                token1s.push(address(b));
            } else {
                token0s.push(address(b));
                token1s.push(address(a));
            }
        }
    }

    function _unit(address token) private view returns (uint256) {
        return token == address(0) ? 1e18 : 10 ** uint256(GenericFactoryInvariantToken(token).decimals());
    }

    function _poolId(address token0, address token1) private pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1));
    }
}
