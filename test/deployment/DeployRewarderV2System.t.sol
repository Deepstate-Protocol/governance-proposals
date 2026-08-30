// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployRewarderV2System} from "../../script/DeployRewarderV2System.s.sol";
import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";
import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../../src/DeepstateV1Controller.sol";

contract DeploymentVerificationHarness is DeployRewarderV2System {
    function verifyMinterController(address deployed) external view {
        _verifyMinterController(deployed);
    }

    function verifyV1Controller(address deployed) external view {
        _verifyV1Controller(deployed);
    }

    function verifyFactory(address deployed, address minterController, address v1Controller) external view {
        _verifyFactory(deployed, minterController, v1Controller);
    }
}

contract DeploymentCodeMock {}

contract DeploymentUSDGMock {
    function decimals() external pure returns (uint8) {
        return 6;
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

    address internal constant EXPECTED_MINTER = 0x3512C0E8B66e463df1cE6f55BE829Bf1ECA5b1c4;
    address internal constant EXPECTED_V1_CONTROLLER = 0x268E83228EDf691950b9458f200710A2b61AD996;
    address internal constant EXPECTED_FACTORY = 0x9ec28aE171d3280dE9B295A134126935C2451A00;
    bytes32 internal constant EXPECTED_MINTER_INIT_CODE_HASH =
        0x3cd9754bbae0a797f4df364af5b4b0be2dcef16f75994ac079327af19e056526;
    bytes32 internal constant EXPECTED_V1_INIT_CODE_HASH =
        0xd25f79f39af86cde5d8b6d9cf38db7fcae0d60ff5a8d7ee9cdb4fa062d0a9e7f;
    bytes32 internal constant EXPECTED_FACTORY_INIT_CODE_HASH =
        0x7f6374300b3536877670c4cd06424afb331996c66ef87626dd0c745e7477810a;

    DeployRewarderV2System internal deployment;
    DeploymentVerificationHarness internal verificationHarness;

    function setUp() public {
        deployment = new DeployRewarderV2System();
        verificationHarness = new DeploymentVerificationHarness();
    }

    function test_PlannedAddressesAndInitCodeHashesAreReleasePinned() public view {
        (
            address minter,
            address v1Controller,
            address factory,
            bytes32 minterInitCodeHash,
            bytes32 v1InitCodeHash,
            bytes32 factoryInitCodeHash
        ) = deployment.plannedAddresses();

        assertEq(minter, EXPECTED_MINTER);
        assertEq(v1Controller, EXPECTED_V1_CONTROLLER);
        assertEq(factory, EXPECTED_FACTORY);
        assertEq(minterInitCodeHash, EXPECTED_MINTER_INIT_CODE_HASH);
        assertEq(v1InitCodeHash, EXPECTED_V1_INIT_CODE_HASH);
        assertEq(factoryInitCodeHash, EXPECTED_FACTORY_INIT_CODE_HASH);
        assertEq(minter.codehash, bytes32(0));
        assertEq(v1Controller.codehash, bytes32(0));
        assertEq(factory.codehash, bytes32(0));
    }

    function test_ManifestMatchesPinnedPlanAndPolicy() public view {
        string memory manifest = vm.readFile(MANIFEST);

        assertEq(vm.parseJsonAddress(manifest, ".contracts.minterController.predictedAddress"), EXPECTED_MINTER);
        assertEq(vm.parseJsonAddress(manifest, ".contracts.v1Controller.predictedAddress"), EXPECTED_V1_CONTROLLER);
        assertEq(vm.parseJsonAddress(manifest, ".contracts.rewarderFactory.predictedAddress"), EXPECTED_FACTORY);
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.minterController.initCodeHash"), EXPECTED_MINTER_INIT_CODE_HASH
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
            vm.parseJsonBytes32(manifest, ".contracts.v1Controller.expectedRuntimeCodeHash"),
            deployment.V1_CONTROLLER_RUNTIME_CODE_HASH()
        );
        assertEq(
            vm.parseJsonBytes32(manifest, ".contracts.rewarderFactory.expectedRuntimeCodeHash"),
            deployment.FACTORY_RUNTIME_CODE_HASH()
        );
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.minterController.salt"), deployment.MINTER_SALT());
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.v1Controller.salt"), deployment.V1_CONTROLLER_SALT());
        assertEq(vm.parseJsonBytes32(manifest, ".contracts.rewarderFactory.salt"), deployment.FACTORY_SALT());

        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.minterLiveSupplyCap")),
            DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.minterGrossIssuanceCap")),
            DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP
        );
        assertEq(
            vm.parseUint(vm.parseJsonString(manifest, ".releasePolicy.factoryInitialPrimaryFundingBudget")),
            DeepstateAddresses.FACTORY_INITIAL_PRIMARY_FUNDING_BUDGET
        );
    }

    function test_ExistingMinterMustBePristine() public {
        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        vm.etch(DeepstateAddresses.DEEP, address(codeMock).code);
        vm.etch(DeepstateAddresses.SABLIER_LOCKUP, address(codeMock).code);
        DeepstateMinterController controller = new DeepstateMinterController(
            DeepstateAddresses.GOVERNOR,
            DeepstateAddresses.DEEP,
            DeepstateAddresses.SABLIER_LOCKUP,
            DeepstateAddresses.DEEPSTATE_INC_SAFE,
            DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP,
            DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP
        );

        verificationHarness.verifyMinterController(address(controller));

        vm.store(address(controller), bytes32(uint256(0)), bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller))
        );
        verificationHarness.verifyMinterController(address(controller));

        vm.store(address(controller), bytes32(uint256(0)), bytes32(0));
        vm.store(address(controller), bytes32(uint256(1)), bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller))
        );
        verificationHarness.verifyMinterController(address(controller));
    }

    function test_ExistingV1ControllerMustMatchPinnedRuntime() public {
        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        vm.etch(DeepstateAddresses.ROUTER, address(codeMock).code);
        DeepstateV1Controller controller =
            new DeepstateV1Controller(DeepstateAddresses.GOVERNOR, DeepstateAddresses.ROUTER);

        verificationHarness.verifyV1Controller(address(controller));

        vm.etch(address(controller), address(codeMock).code);
        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, address(controller))
        );
        verificationHarness.verifyV1Controller(address(controller));
    }

    function test_ExistingFactoryMustBePristine() public {
        (
            address minterController,
            address v1Controller,,
            bytes32 unusedMinterHash,
            bytes32 unusedV1Hash,
            bytes32 unusedFactoryHash
        ) = deployment.plannedAddresses();
        unusedMinterHash;
        unusedV1Hash;
        unusedFactoryHash;

        DeploymentCodeMock codeMock = new DeploymentCodeMock();
        DeploymentMinterDependencyMock minterMock = new DeploymentMinterDependencyMock();
        DeploymentV1DependencyMock v1Mock = new DeploymentV1DependencyMock();
        DeploymentUSDGMock usdGMock = new DeploymentUSDGMock();
        vm.etch(DeepstateAddresses.DEEP, address(codeMock).code);
        vm.etch(minterController, address(minterMock).code);
        vm.etch(v1Controller, address(v1Mock).code);
        vm.etch(DeepstateAddresses.USDG, address(usdGMock).code);

        DeepstateRewarderFactory factory = new DeepstateRewarderFactory(
            DeepstateAddresses.GOVERNOR,
            v1Controller,
            minterController,
            DeepstateAddresses.USDG,
            DeepstateAddresses.FACTORY_INITIAL_PRIMARY_FUNDING_BUDGET
        );
        verificationHarness.verifyFactory(address(factory), minterController, v1Controller);

        for (uint256 slot; slot < 3; ++slot) {
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
