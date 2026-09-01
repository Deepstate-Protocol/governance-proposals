// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployRewarderV2System} from "../../script/DeployRewarderV2System.s.sol";
import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../../src/DeepstateV1Controller.sol";

contract DeploymentVerificationHarness is DeployRewarderV2System {
    function verifyMinterController(address deployed) external view {
        _verifyMinterController(deployed);
    }

    function verifyBootstrap(address deployed) external view {
        _verifyBootstrap(deployed);
    }

    function verifyV1Controller(address deployed) external view {
        _verifyV1Controller(deployed);
    }

    function verifyFactory(address deployed, address minterController, address v1Controller) external view {
        _verifyFactory(deployed, minterController, v1Controller);
    }

    function verifyLegacyRewarder() external view {
        _verifyLegacyRewarder();
    }
}

contract DeploymentCodeMock {}

contract DeploymentDeepstateTokenMock {
    function MINTER_ROLE() external pure returns (bytes32) {
        return keccak256("MINTER_ROLE");
    }

    function hasRole(bytes32, address) external pure virtual returns (bool) {
        return false;
    }

    function totalSupply() external pure virtual returns (uint256) {
        return 0;
    }
}

contract DeploymentDeepstateTokenWithRoleMock is DeploymentDeepstateTokenMock {
    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }
}

contract DeploymentDeepstateTokenWithoutHeadroomMock is DeploymentDeepstateTokenMock {
    function totalSupply() external pure override returns (uint256) {
        return DeepstateAddresses.MINTER_MAX_SUPPLY
            - (300_000_000e18 + 100_000_000e18 + uint256(100_000_000e18) * 30 / 70) + 1;
    }
}

contract DeploymentLegacyRewarderMock {
    function owner() external pure returns (address) {
        return DeepstateAddresses.GOVERNOR;
    }

    function deepstate() external pure returns (address) {
        return DeepstateAddresses.ROUTER;
    }

    function rewardToken() external pure returns (address) {
        return DeepstateAddresses.DEEP;
    }

    function poolId() external pure returns (bytes32) {
        return DeepstateAddresses.NVDA_USDG_POOL_ID;
    }

    function token0() external pure returns (address) {
        return DeepstateAddresses.USDG;
    }

    function token1() external pure returns (address) {
        return DeepstateAddresses.NVDA;
    }

    function sideEmissionCap() external pure returns (uint96) {
        return DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP;
    }

    function emissionDuration() external pure returns (uint32) {
        return DeepstateAddresses.LEGACY_REWARDER_EMISSION_DURATION;
    }

    function token0StartQuantity() external pure returns (uint160) {
        return DeepstateAddresses.LEGACY_USDG_START_QUANTITY;
    }

    function token0MaxQuantity() external pure returns (uint160) {
        return DeepstateAddresses.LEGACY_USDG_MAX_QUANTITY;
    }

    function token1StartQuantity() external pure returns (uint160) {
        return DeepstateAddresses.LEGACY_NVDA_START_QUANTITY;
    }

    function token1MaxQuantity() external pure returns (uint160) {
        return DeepstateAddresses.LEGACY_NVDA_MAX_QUANTITY;
    }

    function totalAccrued(address token) external pure returns (uint96) {
        if (token == DeepstateAddresses.USDG) return 700e18;
        if (token == DeepstateAddresses.NVDA) return 300e18;
        revert();
    }
}

contract DeploymentMinterDependencyMock {
    function owner() external pure returns (address) {
        return DeepstateAddresses.GOVERNOR;
    }

    function deepstateToken() external pure returns (address) {
        return DeepstateAddresses.DEEP;
    }

    function rolesOf(address) external pure virtual returns (uint256) {
        return 0;
    }
}

contract DeploymentV1DependencyMock {
    function owner() external pure returns (address) {
        return DeepstateAddresses.GOVERNOR;
    }

    function deepstate() external pure returns (address) {
        return DeepstateAddresses.ROUTER;
    }

    function rolesOf(address) external pure virtual returns (uint256) {
        return 0;
    }
}

contract DeploymentMinterDependencyWithRoleMock is DeploymentMinterDependencyMock {
    function rolesOf(address) external pure override returns (uint256) {
        return 1;
    }
}

contract DeploymentV1DependencyWithRoleMock is DeploymentV1DependencyMock {
    function rolesOf(address) external pure override returns (uint256) {
        return 1;
    }
}

contract DeployRewarderV2SystemTest is Test {
    string internal constant MANIFEST = "deployments/robinhood-4663/rewarder-v2.template.json";

    address internal constant EXPECTED_MINTER = 0x5f32dB3327fecFB1390FAE0686e771b14DfB83aa;
    address internal constant EXPECTED_BOOTSTRAP = 0x310594e99815E00F7a8c866bd1578DC2Db00C975;
    address internal constant EXPECTED_V1_CONTROLLER = 0x8900cd1D03Aaa1F9d4B7649a268985E0C48B4476;
    address internal constant EXPECTED_FACTORY = 0xA847C1fE66D31b8f6416741971F89a958d9AC2D9;
    bytes32 internal constant EXPECTED_MINTER_INIT_CODE_HASH =
        0xf474c741a197c764621efb61e47e135b3901c53d1dd3bd2e5db4a63e15a7ca51;
    bytes32 internal constant EXPECTED_BOOTSTRAP_INIT_CODE_HASH =
        0x51621e9b0a57fec483593d59d66e7355beb5def5a11476b9e4be4cb61ee0171d;
    bytes32 internal constant EXPECTED_V1_INIT_CODE_HASH =
        0x178de4fee3bfd6b50a70f2710907253ab68e1ecfdac3a9acf5b44880fd61ad32;
    bytes32 internal constant EXPECTED_FACTORY_INIT_CODE_HASH =
        0x6c742d3e580c46a1e42b1dea97da9fe55604eb86c25956f335f83a3b38cab13a;

    DeployRewarderV2System internal deployment;
    DeploymentVerificationHarness internal verificationHarness;

    function setUp() public {
        deployment = new DeployRewarderV2System();
        verificationHarness = new DeploymentVerificationHarness();
    }

    function test_PlannedAddressesAndInitCodeHashesAreReleasePinned() public view {
        (
            address minter,
            address bootstrap,
            address v1Controller,
            address factory,
            bytes32 minterInitCodeHash,
            bytes32 bootstrapInitCodeHash,
            bytes32 v1InitCodeHash,
            bytes32 factoryInitCodeHash
        ) = deployment.plannedAddresses();

        assertEq(minter, EXPECTED_MINTER);
        assertEq(bootstrap, EXPECTED_BOOTSTRAP);
        assertEq(v1Controller, EXPECTED_V1_CONTROLLER);
        assertEq(factory, EXPECTED_FACTORY);
        assertEq(minterInitCodeHash, EXPECTED_MINTER_INIT_CODE_HASH);
        assertEq(bootstrapInitCodeHash, EXPECTED_BOOTSTRAP_INIT_CODE_HASH);
        assertEq(v1InitCodeHash, EXPECTED_V1_INIT_CODE_HASH);
        assertEq(factoryInitCodeHash, EXPECTED_FACTORY_INIT_CODE_HASH);
        assertEq(minter.codehash, bytes32(0));
        assertEq(bootstrap.codehash, bytes32(0));
        assertEq(v1Controller.codehash, bytes32(0));
        assertEq(factory.codehash, bytes32(0));
    }

    function test_ManifestMatchesPinnedPlanAndPolicy() public view {
        string memory manifest = vm.readFile(MANIFEST);

        assertEq(vm.parseJsonAddress(manifest, ".contracts.minterController.predictedAddress"), EXPECTED_MINTER);
        assertEq(vm.parseJsonAddress(manifest, ".contracts.dgp001Bootstrap.predictedAddress"), EXPECTED_BOOTSTRAP);
        assertEq(vm.parseJsonAddress(manifest, ".contracts.v1Controller.predictedAddress"), EXPECTED_V1_CONTROLLER);
        assertEq(vm.parseJsonAddress(manifest, ".contracts.rewarderFactory.predictedAddress"), EXPECTED_FACTORY);
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.minterController.initCodeHash"), EXPECTED_MINTER_INIT_CODE_HASH
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.dgp001Bootstrap.initCodeHash"), EXPECTED_BOOTSTRAP_INIT_CODE_HASH
        );
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.v1Controller.initCodeHash"), EXPECTED_V1_INIT_CODE_HASH);
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.rewarderFactory.initCodeHash"), EXPECTED_FACTORY_INIT_CODE_HASH
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.minterController.expectedRuntimeCodeHash"),
            deployment.MINTER_RUNTIME_CODE_HASH()
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.dgp001Bootstrap.expectedRuntimeCodeHash"),
            deployment.DGP001_BOOTSTRAP_RUNTIME_CODE_HASH()
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.v1Controller.expectedRuntimeCodeHash"),
            deployment.V1_CONTROLLER_RUNTIME_CODE_HASH()
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.rewarderFactory.expectedRuntimeCodeHash"),
            deployment.FACTORY_RUNTIME_CODE_HASH()
        );
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.minterController.salt"), deployment.MINTER_SALT());
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.dgp001Bootstrap.salt"), deployment.DGP001_BOOTSTRAP_SALT());
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.v1Controller.salt"), deployment.V1_CONTROLLER_SALT());
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.rewarderFactory.salt"), deployment.FACTORY_SALT());

        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.minterMaxSupply")),
            DeepstateAddresses.MINTER_MAX_SUPPLY
        );
        assertEq(vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.factoryMarketFunding")), 100_000_000e18);
        assertEq(vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.factorySideEmissionCap")), 50_000_000e18);
        assertEq(vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.factoryEmissionDurationSeconds")), 365 days);
        assertFalse(vm.parseJsonBool(manifest, ".releasePolicy.governanceTopUpSupported"));
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.maximumLegacyEndowment")),
            deployment.MAXIMUM_LEGACY_ENDOWMENT()
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.minimumActivationIssuanceHeadroom")),
            deployment.MINIMUM_ACTIVATION_ISSUANCE_HEADROOM()
        );
        assertEq(deployment.MAXIMUM_LEGACY_ENDOWMENT(), 2 * 500_000_000e18 * 30 / 100);
        assertEq(deployment.ACTIVATION_MARKET_PRIMARY_FUNDING(), 100_000_000e18);
        assertEq(deployment.ACTIVATION_MARKET_VESTING(), uint256(100_000_000e18) * 30 / 70);
        assertEq(
            deployment.MINIMUM_ACTIVATION_ISSUANCE_HEADROOM(),
            300_000_000e18 + 100_000_000e18 + uint256(100_000_000e18) * 30 / 70
        );
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.address"), DeepstateAddresses.REWARDER);
        assertEq(
            vm.parseJsonBytes32(manifest, ".liveDependencies.legacyRewarder.runtimeCodeHash"),
            DeepstateAddresses.REWARDER_CODEHASH
        );
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.owner"), DeepstateAddresses.GOVERNOR);
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.rewardToken"), DeepstateAddresses.DEEP);
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.router"), DeepstateAddresses.ROUTER);
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.token0"), DeepstateAddresses.USDG);
        assertEq(vm.parseJsonAddress(manifest, ".liveDependencies.legacyRewarder.token1"), DeepstateAddresses.NVDA);
        assertEq(
            vm.parseJsonBytes32(manifest, ".liveDependencies.legacyRewarder.poolId"),
            DeepstateAddresses.NVDA_USDG_POOL_ID
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.sideEmissionCap")),
            DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.emissionDurationSeconds")),
            DeepstateAddresses.LEGACY_REWARDER_EMISSION_DURATION
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.token0StartQuantity")),
            DeepstateAddresses.LEGACY_USDG_START_QUANTITY
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.token0MaxQuantity")),
            DeepstateAddresses.LEGACY_USDG_MAX_QUANTITY
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.token1StartQuantity")),
            DeepstateAddresses.LEGACY_NVDA_START_QUANTITY
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".liveDependencies.legacyRewarder.token1MaxQuantity")),
            DeepstateAddresses.LEGACY_NVDA_MAX_QUANTITY
        );
        assertTrue(vm.parseJsonBool(manifest, ".liveDependencies.legacyRewarder.totalAccruedCallRequired"));

        string[] memory minterArguments =
            vm.parseJsonStringArray(manifest, ".contracts.minterController.constructorArguments");
        assertEq(minterArguments.length, 5);
        assertEq(vm.parseAddress(minterArguments[0]), DeepstateAddresses.GOVERNOR);
        assertEq(vm.parseAddress(minterArguments[1]), DeepstateAddresses.DEEP);
        assertEq(vm.parseAddress(minterArguments[2]), DeepstateAddresses.SABLIER_LOCKUP);
        assertEq(vm.parseAddress(minterArguments[3]), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(vm.parseUint(minterArguments[4]), DeepstateAddresses.MINTER_MAX_SUPPLY);

        string[] memory bootstrapArguments =
            vm.parseJsonStringArray(manifest, ".contracts.dgp001Bootstrap.constructorArguments");
        assertEq(bootstrapArguments.length, 3);
        assertEq(vm.parseAddress(bootstrapArguments[0]), DeepstateAddresses.GOVERNOR);
        assertEq(vm.parseAddress(bootstrapArguments[1]), DeepstateAddresses.DEEP);
        assertEq(vm.parseAddress(bootstrapArguments[2]), DeepstateAddresses.REWARDER);

        string[] memory v1Arguments = vm.parseJsonStringArray(manifest, ".contracts.v1Controller.constructorArguments");
        assertEq(v1Arguments.length, 2);
        assertEq(vm.parseAddress(v1Arguments[0]), DeepstateAddresses.GOVERNOR);
        assertEq(vm.parseAddress(v1Arguments[1]), DeepstateAddresses.ROUTER);

        string[] memory factoryArguments =
            vm.parseJsonStringArray(manifest, ".contracts.rewarderFactory.constructorArguments");
        assertEq(factoryArguments.length, 3);
        assertEq(vm.parseAddress(factoryArguments[0]), DeepstateAddresses.GOVERNOR);
        assertEq(vm.parseAddress(factoryArguments[1]), EXPECTED_V1_CONTROLLER);
        assertEq(vm.parseAddress(factoryArguments[2]), EXPECTED_MINTER);
        assertNotEq(
            vm.parseJsonAddress(manifest, ".liveDependencies.sablierLockupV4.nativeToken"), DeepstateAddresses.DEEP
        );
    }

    function test_LegacyRewarderIdentityAndAccrualSurfaceAreReleasePinned() public {
        DeploymentLegacyRewarderMock legacyMock = new DeploymentLegacyRewarderMock();
        vm.etch(DeepstateAddresses.REWARDER, address(legacyMock).code);

        verificationHarness.verifyLegacyRewarder();

        DeploymentCodeMock incompatible = new DeploymentCodeMock();
        vm.etch(DeepstateAddresses.REWARDER, address(incompatible).code);
        vm.expectRevert();
        verificationHarness.verifyLegacyRewarder();
    }

    function test_ExistingMinterMustBePristine() public {
        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        DeploymentDeepstateTokenMock tokenMock = new DeploymentDeepstateTokenMock();
        DeploymentLegacyRewarderMock legacyMock = new DeploymentLegacyRewarderMock();
        vm.etch(DeepstateAddresses.DEEP, address(tokenMock).code);
        vm.etch(DeepstateAddresses.SABLIER_LOCKUP, address(codeMock).code);
        vm.etch(DeepstateAddresses.REWARDER, address(legacyMock).code);
        DeepstateMinterController controller = new DeepstateMinterController(
            DeepstateAddresses.GOVERNOR,
            DeepstateAddresses.DEEP,
            DeepstateAddresses.SABLIER_LOCKUP,
            DeepstateAddresses.DEEPSTATE_INC_SAFE,
            DeepstateAddresses.MINTER_MAX_SUPPLY
        );

        assertEq(address(controller).codehash, deployment.MINTER_RUNTIME_CODE_HASH());
        verificationHarness.verifyMinterController(address(controller));

        DeploymentDeepstateTokenWithoutHeadroomMock tokenWithoutHeadroom =
            new DeploymentDeepstateTokenWithoutHeadroomMock();
        vm.etch(DeepstateAddresses.DEEP, address(tokenWithoutHeadroom).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller))
        );
        verificationHarness.verifyMinterController(address(controller));
        vm.etch(DeepstateAddresses.DEEP, address(tokenMock).code);

        for (uint256 slot; slot < 1; ++slot) {
            vm.store(address(controller), bytes32(slot), bytes32(uint256(1)));
            vm.expectRevert(
                abi.encodeWithSelector(
                    DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller)
                )
            );
            verificationHarness.verifyMinterController(address(controller));
            vm.store(address(controller), bytes32(slot), bytes32(0));
        }
    }

    function test_ExistingBootstrapMustMatchPinnedRuntimeConfigurationAndPristineState() public {
        DeploymentDeepstateTokenMock tokenMock = new DeploymentDeepstateTokenMock();
        DeploymentLegacyRewarderMock legacyMock = new DeploymentLegacyRewarderMock();
        vm.etch(DeepstateAddresses.DEEP, address(tokenMock).code);
        vm.etch(DeepstateAddresses.REWARDER, address(legacyMock).code);

        DGP001Bootstrap bootstrap =
            new DGP001Bootstrap(DeepstateAddresses.GOVERNOR, DeepstateAddresses.DEEP, DeepstateAddresses.REWARDER);

        assertEq(address(bootstrap).codehash, deployment.DGP001_BOOTSTRAP_RUNTIME_CODE_HASH());
        verificationHarness.verifyBootstrap(address(bootstrap));
        assertEq(bootstrap.endowmentAmount(), 300e18);

        DeploymentDeepstateTokenWithRoleMock tokenWithRole = new DeploymentDeepstateTokenWithRoleMock();
        vm.etch(DeepstateAddresses.DEEP, address(tokenWithRole).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(bootstrap))
        );
        verificationHarness.verifyBootstrap(address(bootstrap));

        vm.etch(DeepstateAddresses.DEEP, address(tokenMock).code);
        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        vm.etch(address(bootstrap), address(codeMock).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(bootstrap))
        );
        verificationHarness.verifyBootstrap(address(bootstrap));
    }

    function test_ExistingV1ControllerMustMatchPinnedRuntime() public {
        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        vm.etch(DeepstateAddresses.ROUTER, address(codeMock).code);
        DeepstateV1Controller controller =
            new DeepstateV1Controller(DeepstateAddresses.GOVERNOR, DeepstateAddresses.ROUTER);

        assertEq(address(controller).codehash, deployment.V1_CONTROLLER_RUNTIME_CODE_HASH());
        verificationHarness.verifyV1Controller(address(controller));

        vm.etch(address(controller), address(codeMock).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller))
        );
        verificationHarness.verifyV1Controller(address(controller));
    }

    function test_ExistingFactoryMustBePristine() public {
        (
            address minterController,,
            address v1Controller,,
            bytes32 unusedMinterHash,
            bytes32 unusedBootstrapHash,
            bytes32 unusedV1Hash,
            bytes32 unusedFactoryHash
        ) = deployment.plannedAddresses();
        unusedMinterHash;
        unusedBootstrapHash;
        unusedV1Hash;
        unusedFactoryHash;

        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        DeploymentMinterDependencyMock minterMock = new DeploymentMinterDependencyMock();
        DeploymentV1DependencyMock v1Mock = new DeploymentV1DependencyMock();
        vm.etch(DeepstateAddresses.DEEP, address(codeMock).code);
        vm.etch(minterController, address(minterMock).code);
        vm.etch(v1Controller, address(v1Mock).code);

        DeepstateRewarderFactory factory =
            new DeepstateRewarderFactory(DeepstateAddresses.GOVERNOR, v1Controller, minterController);
        assertEq(address(factory).codehash, deployment.FACTORY_RUNTIME_CODE_HASH());
        verificationHarness.verifyFactory(address(factory), minterController, v1Controller);

        for (uint256 slot; slot < 2; ++slot) {
            vm.store(address(factory), bytes32(slot), bytes32(uint256(1)));
            vm.expectRevert(
                abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(factory))
            );
            verificationHarness.verifyFactory(address(factory), minterController, v1Controller);
            vm.store(address(factory), bytes32(slot), bytes32(0));
        }

        DeploymentMinterDependencyWithRoleMock minterWithRole = new DeploymentMinterDependencyWithRoleMock();
        vm.etch(minterController, address(minterWithRole).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(factory))
        );
        verificationHarness.verifyFactory(address(factory), minterController, v1Controller);

        vm.etch(minterController, address(minterMock).code);
        DeploymentV1DependencyWithRoleMock v1WithRole = new DeploymentV1DependencyWithRoleMock();
        vm.etch(v1Controller, address(v1WithRole).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(factory))
        );
        verificationHarness.verifyFactory(address(factory), minterController, v1Controller);
    }
}
