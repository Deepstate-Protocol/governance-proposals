// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {DeployContracts} from "../../script/DeployContracts.s.sol";
import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";

contract InvariantDeploymentDependencyCodeMock {}

contract InvariantDeploymentLegacyRewarderMock {
    function token0() external pure returns (address) {
        return DeepstateAddresses.USDG;
    }

    function token1() external pure returns (address) {
        return DeepstateAddresses.NVDA;
    }

    function totalAccrued(address token) external pure returns (uint96) {
        if (token == DeepstateAddresses.USDG) return 700e18;
        if (token == DeepstateAddresses.NVDA) return 300e18;
        return 0;
    }
}

contract DeployContractsInvariantHandler is Test {
    uint256 internal constant MAX_BUNDLES = 4;

    DeployContracts public immutable DEPLOYMENT_SCRIPT;
    address[] public minters;
    address[] public bootstraps;
    address[] public v1Controllers;
    address[] public factories;
    bool public externalProtocolWriteViolation;

    constructor() {
        vm.chainId(DeepstateAddresses.CHAIN_ID);

        InvariantDeploymentDependencyCodeMock codeMock = new InvariantDeploymentDependencyCodeMock();
        InvariantDeploymentLegacyRewarderMock legacyRewarderMock = new InvariantDeploymentLegacyRewarderMock();
        vm.etch(DeepstateAddresses.DEEP, address(codeMock).code);
        vm.etch(DeepstateAddresses.SABLIER_LOCKUP, address(codeMock).code);
        vm.etch(DeepstateAddresses.ROUTER, address(codeMock).code);
        vm.etch(DeepstateAddresses.REWARDER, address(legacyRewarderMock).code);

        DEPLOYMENT_SCRIPT = new DeployContracts();
    }

    function deployBundle() external {
        if (minters.length >= MAX_BUNDLES) return;

        vm.record();
        DeployContracts.Deployment memory deployed = DEPLOYMENT_SCRIPT.run();
        _flagWrites(DeepstateAddresses.GOVERNOR);
        _flagWrites(DeepstateAddresses.DEEP);
        _flagWrites(DeepstateAddresses.SABLIER_LOCKUP);
        _flagWrites(DeepstateAddresses.ROUTER);
        _flagWrites(DeepstateAddresses.REWARDER);

        minters.push(address(deployed.minterController));
        bootstraps.push(address(deployed.dgp001Bootstrap));
        v1Controllers.push(address(deployed.v1Controller));
        factories.push(address(deployed.rewarderFactory));
    }

    function bundleCount() external view returns (uint256) {
        return minters.length;
    }

    function _flagWrites(address target) private {
        (, bytes32[] memory writes) = vm.accesses(target);
        if (writes.length != 0) externalProtocolWriteViolation = true;
    }
}

contract DeployContractsInvariantTest is StdInvariant, Test {
    DeployContractsInvariantHandler internal handler;

    function setUp() public {
        handler = new DeployContractsInvariantHandler();
        handler.deployBundle();
        targetContract(address(handler));
    }

    function invariant_EveryRunDeploysACompleteInternallyWiredBundle() public view {
        uint256 count = handler.bundleCount();
        assertGt(count, 0);

        for (uint256 i; i < count; ++i) {
            DeepstateMinterControllerLike minter = DeepstateMinterControllerLike(handler.minters(i));
            DGP001BootstrapLike bootstrap = DGP001BootstrapLike(handler.bootstraps(i));
            DeepstateV1ControllerLike v1Controller = DeepstateV1ControllerLike(handler.v1Controllers(i));
            DeepstateRewarderFactoryLike factory = DeepstateRewarderFactoryLike(handler.factories(i));

            assertGt(address(minter).code.length, 0);
            assertGt(address(bootstrap).code.length, 0);
            assertGt(address(v1Controller).code.length, 0);
            assertGt(address(factory).code.length, 0);

            assertEq(minter.owner(), DeepstateAddresses.GOVERNOR);
            assertEq(minter.deepstateToken(), DeepstateAddresses.DEEP);
            assertEq(minter.sablierLockup(), DeepstateAddresses.SABLIER_LOCKUP);
            assertEq(minter.recipient(), DeepstateAddresses.DEEPSTATE_INC_SAFE);
            assertEq(minter.maxSupply(), DeepstateAddresses.MINTER_MAX_SUPPLY);
            assertEq(minter.tokenAdministrationEndsAt(), 0);

            assertEq(bootstrap.governor(), DeepstateAddresses.GOVERNOR);
            assertEq(bootstrap.deepstateToken(), DeepstateAddresses.DEEP);
            assertEq(bootstrap.endowmentAmount(), 300e18);

            assertEq(v1Controller.owner(), DeepstateAddresses.GOVERNOR);
            assertEq(v1Controller.deepstate(), DeepstateAddresses.ROUTER);

            assertEq(factory.owner(), DeepstateAddresses.GOVERNOR);
            assertEq(factory.deepstateV1Controller(), address(v1Controller));
            assertEq(factory.minterController(), address(minter));
            assertEq(factory.deepstate(), DeepstateAddresses.ROUTER);
            assertEq(factory.rewardToken(), DeepstateAddresses.DEEP);
            assertEq(factory.operator(), address(0));
            assertEq(factory.nextDeploymentAt(), 0);
            assertEq(minter.rolesOf(address(factory)), 0);
            assertEq(v1Controller.rolesOf(address(factory)), 0);
        }
    }

    function invariant_OrdinaryCreateNeverReusesAnAddress() public view {
        uint256 count = handler.bundleCount();
        for (uint256 i; i < count; ++i) {
            for (uint256 j = i + 1; j < count; ++j) {
                assertTrue(handler.minters(i) != handler.minters(j));
                assertTrue(handler.bootstraps(i) != handler.bootstraps(j));
                assertTrue(handler.v1Controllers(i) != handler.v1Controllers(j));
                assertTrue(handler.factories(i) != handler.factories(j));
            }
        }
    }

    function invariant_DeploymentDoesNotWriteToLiveProtocolDependencies() public view {
        assertFalse(handler.externalProtocolWriteViolation());
    }
}

interface DeepstateMinterControllerLike {
    function owner() external view returns (address);
    function deepstateToken() external view returns (address);
    function sablierLockup() external view returns (address);
    function recipient() external view returns (address);
    function maxSupply() external view returns (uint256);
    function tokenAdministrationEndsAt() external view returns (uint40);
    function rolesOf(address account) external view returns (uint256);
}

interface DGP001BootstrapLike {
    function governor() external view returns (address);
    function deepstateToken() external view returns (address);
    function endowmentAmount() external view returns (uint128);
}

interface DeepstateV1ControllerLike {
    function owner() external view returns (address);
    function deepstate() external view returns (address);
    function rolesOf(address account) external view returns (uint256);
}

interface DeepstateRewarderFactoryLike {
    function owner() external view returns (address);
    function deepstateV1Controller() external view returns (address);
    function minterController() external view returns (address);
    function deepstate() external view returns (address);
    function rewardToken() external view returns (address);
    function operator() external view returns (address);
    function nextDeploymentAt() external view returns (uint256);
}
