// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {DeployRewarderV2System} from "../../script/DeployRewarderV2System.s.sol";
import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../../src/DeepstateV1Controller.sol";

contract OfflineDeploymentCodeMock {}

contract OfflineDeploymentDeepMock {
    function MINTER_ROLE() external pure returns (bytes32) {
        return keccak256("MINTER_ROLE");
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return false;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

contract OfflineDeploymentLegacyRewarderMock {
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

contract DeployRewarderV2SystemInvariantHarness is DeployRewarderV2System {
    function deployMinterFromPlan() external {
        DeploymentPlan memory plan = _plan();
        _deployIfMissing(MINTER_SALT, plan.minterInitCode, plan.minterController);
    }

    function deployBootstrapFromPlan() external {
        DeploymentPlan memory plan = _plan();
        _deployIfMissing(DGP001_BOOTSTRAP_SALT, plan.bootstrapInitCode, plan.dgp001Bootstrap);
    }

    function deployV1FromPlan() external {
        DeploymentPlan memory plan = _plan();
        _deployIfMissing(V1_CONTROLLER_SALT, plan.v1InitCode, plan.v1Controller);
    }

    function deployFactoryFromPlan() external {
        DeploymentPlan memory plan = _plan();
        _deployIfMissing(FACTORY_SALT, plan.factoryInitCode, plan.rewarderFactory);
    }

    function validateExistingFromPlan() external view {
        _validateExistingDeployments(_plan());
    }

    function verifyMinterFromPlan() external view {
        DeploymentPlan memory plan = _plan();
        _verifyMinterController(plan.minterController);
    }

    function verifyBootstrapFromPlan() external view {
        DeploymentPlan memory plan = _plan();
        _verifyBootstrap(plan.dgp001Bootstrap);
    }

    function verifyV1FromPlan() external view {
        DeploymentPlan memory plan = _plan();
        _verifyV1Controller(plan.v1Controller);
    }

    function verifyFactoryFromPlan() external view {
        DeploymentPlan memory plan = _plan();
        _verifyFactory(plan.rewarderFactory, plan.minterController, plan.v1Controller);
    }
}

contract DeployRewarderV2SystemInvariantHandler is Test {
    // Runtime of Arachnid's canonical deterministic deployment proxy. Its hash is independently pinned by the
    // production preflight; etching it here exercises the real salt || init-code call path entirely offline.
    bytes internal constant CREATE2_PROXY_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployRewarderV2SystemInvariantHarness public immutable deployment;

    address public immutable minter;
    address public immutable bootstrap;
    address public immutable v1Controller;
    address public immutable factory;
    bytes32 public immutable minterInitCodeHash;
    bytes32 public immutable bootstrapInitCodeHash;
    bytes32 public immutable v1InitCodeHash;
    bytes32 public immutable factoryInitCodeHash;

    uint256 public minterAttempts;
    uint256 public bootstrapAttempts;
    uint256 public v1Attempts;
    uint256 public factoryAttempts;
    uint256 public recordedDeploymentActions;
    bool public externalProtocolWriteViolation;

    constructor() {
        deployment = new DeployRewarderV2SystemInvariantHarness();
        (
            minter,
            bootstrap,
            v1Controller,
            factory,
            minterInitCodeHash,
            bootstrapInitCodeHash,
            v1InitCodeHash,
            factoryInitCodeHash
        ) = deployment.plannedAddresses();

        OfflineDeploymentCodeMock codeMock = new OfflineDeploymentCodeMock();
        OfflineDeploymentDeepMock deepMock = new OfflineDeploymentDeepMock();
        OfflineDeploymentLegacyRewarderMock legacyRewarderMock = new OfflineDeploymentLegacyRewarderMock();

        vm.etch(DeepstateAddresses.DEEP, address(deepMock).code);
        vm.etch(DeepstateAddresses.SABLIER_LOCKUP, address(codeMock).code);
        vm.etch(DeepstateAddresses.ROUTER, address(codeMock).code);
        vm.etch(DeepstateAddresses.REWARDER, address(legacyRewarderMock).code);
        vm.etch(DeepstateAddresses.CREATE2_DEPLOYER, CREATE2_PROXY_RUNTIME);
    }

    function deployOne(uint8 component) external {
        if (component % 4 == 0) {
            ++minterAttempts;
            _deployMinterRecorded();
        } else if (component % 4 == 1) {
            ++bootstrapAttempts;
            _deployBootstrapRecorded();
        } else if (component % 4 == 2) {
            ++v1Attempts;
            _deployV1Recorded();
        } else {
            ++factoryAttempts;
            // Deploying the Factory before both dependencies exists must fail without leaving code behind. Once both
            // controllers exist, the same action completes the partial release.
            vm.record();
            try deployment.deployFactoryFromPlan() {} catch {}
            _recordExternalProtocolWrites();
        }
    }

    function recoverRelease(uint8 first, uint8 second) external {
        // Arbitrary partial work is followed by the production order. Every exact deployment is safely skipped.
        this.deployOne(first);
        this.deployOne(second);
        ++minterAttempts;
        _deployMinterRecorded();
        ++bootstrapAttempts;
        _deployBootstrapRecorded();
        ++v1Attempts;
        _deployV1Recorded();
        ++factoryAttempts;
        _deployFactoryRecorded();
    }

    function _deployMinterRecorded() private {
        vm.record();
        deployment.deployMinterFromPlan();
        _recordExternalProtocolWrites();
    }

    function _deployV1Recorded() private {
        vm.record();
        deployment.deployV1FromPlan();
        _recordExternalProtocolWrites();
    }

    function _deployBootstrapRecorded() private {
        vm.record();
        deployment.deployBootstrapFromPlan();
        _recordExternalProtocolWrites();
    }

    function _deployFactoryRecorded() private {
        vm.record();
        deployment.deployFactoryFromPlan();
        _recordExternalProtocolWrites();
    }

    function _recordExternalProtocolWrites() private {
        ++recordedDeploymentActions;
        _flagWrites(DeepstateAddresses.GOVERNOR);
        _flagWrites(DeepstateAddresses.DEEP);
        _flagWrites(DeepstateAddresses.ROUTER);
        _flagWrites(DeepstateAddresses.REWARDER);
        _flagWrites(DeepstateAddresses.USDG);
        _flagWrites(DeepstateAddresses.USDG_IMPLEMENTATION);
        _flagWrites(DeepstateAddresses.SABLIER_LOCKUP);
        _flagWrites(DeepstateAddresses.SABLIER_COMPTROLLER);
        _flagWrites(DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION);
        _flagWrites(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        _flagWrites(DeepstateAddresses.CREATE2_DEPLOYER);
    }

    function _flagWrites(address dependency) private {
        (, bytes32[] memory writes) = vm.accesses(dependency);
        if (writes.length != 0) externalProtocolWriteViolation = true;
    }
}

contract DeployRewarderV2SystemInvariantTest is StdInvariant, Test {
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

    DeployRewarderV2SystemInvariantHandler internal handler;
    DeployRewarderV2SystemInvariantHarness internal deployment;

    function setUp() public {
        handler = new DeployRewarderV2SystemInvariantHandler();
        deployment = handler.deployment();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.deployOne.selector;
        selectors[1] = handler.recoverRelease.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ReleasePlanIsIndependentOfCallerTimeNonceAndPartialState() public view {
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
    }

    function invariant_EveryOccupiedReleaseAddressContainsReviewedRuntimeAndScalarState() public view {
        if (EXPECTED_MINTER.code.length != 0) {
            assertEq(EXPECTED_MINTER.codehash, deployment.MINTER_RUNTIME_CODE_HASH());
            deployment.verifyMinterFromPlan();
        }
        if (EXPECTED_BOOTSTRAP.code.length != 0) {
            assertEq(EXPECTED_BOOTSTRAP.codehash, deployment.DGP001_BOOTSTRAP_RUNTIME_CODE_HASH());
            deployment.verifyBootstrapFromPlan();
        }
        if (EXPECTED_V1_CONTROLLER.code.length != 0) {
            assertEq(EXPECTED_V1_CONTROLLER.codehash, deployment.V1_CONTROLLER_RUNTIME_CODE_HASH());
            deployment.verifyV1FromPlan();
        }
        if (EXPECTED_FACTORY.code.length != 0) {
            assertEq(EXPECTED_FACTORY.codehash, deployment.FACTORY_RUNTIME_CODE_HASH());
            deployment.verifyFactoryFromPlan();
        }
        deployment.validateExistingFromPlan();
    }

    function invariant_FactoryCanExistOnlyAfterBothControllerDependencies() public view {
        if (EXPECTED_FACTORY.code.length != 0) {
            assertGt(EXPECTED_MINTER.code.length, 0);
            assertGt(EXPECTED_V1_CONTROLLER.code.length, 0);
        }
    }

    function invariant_DeploymentNeverActivatesGovernancePermissionsOrMutableState() public view {
        assertFalse(handler.externalProtocolWriteViolation());

        if (EXPECTED_MINTER.code.length != 0) {
            DeepstateMinterController minter = DeepstateMinterController(EXPECTED_MINTER);
            assertEq(minter.owner(), DeepstateAddresses.GOVERNOR);
            assertEq(minter.maxSupply(), DeepstateAddresses.MINTER_MAX_SUPPLY);
            assertEq(minter.tokenAdministrationEndsAt(), 0);
        }
        if (EXPECTED_BOOTSTRAP.code.length != 0) {
            DGP001Bootstrap bootstrap = DGP001Bootstrap(EXPECTED_BOOTSTRAP);
            assertEq(bootstrap.governor(), DeepstateAddresses.GOVERNOR);
            assertEq(address(bootstrap.deepstateToken()), DeepstateAddresses.DEEP);
            assertEq(bootstrap.endowmentAmount(), 300e18);
            assertFalse(
                bootstrap.deepstateToken().hasRole(bootstrap.deepstateToken().MINTER_ROLE(), EXPECTED_BOOTSTRAP)
            );
        }
        if (EXPECTED_V1_CONTROLLER.code.length != 0) {
            assertEq(DeepstateV1Controller(EXPECTED_V1_CONTROLLER).owner(), DeepstateAddresses.GOVERNOR);
        }
        if (EXPECTED_FACTORY.code.length != 0) {
            DeepstateRewarderFactory factory = DeepstateRewarderFactory(EXPECTED_FACTORY);
            assertEq(factory.owner(), DeepstateAddresses.GOVERNOR);
            assertEq(factory.operator(), address(0));
            assertEq(factory.nextDeploymentAt(), 0);
            assertEq(DeepstateMinterController(EXPECTED_MINTER).rolesOf(EXPECTED_FACTORY), 0);
            assertEq(DeepstateV1Controller(EXPECTED_V1_CONTROLLER).rolesOf(EXPECTED_FACTORY), 0);
        }
    }

    function test_DeployRequiresAnExplicitIndependentConfirmation() public {
        vm.setEnv("DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT", "false");
        vm.expectRevert(DeployRewarderV2System.DeploymentNotConfirmed.selector);
        deployment.deploy();
    }

    function testFuzz_ReadOnlyAndConfirmedDeploymentRejectEveryWrongChain(uint64 wrongChainId) public {
        vm.assume(wrongChainId != DeepstateAddresses.CHAIN_ID);
        vm.chainId(wrongChainId);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployRewarderV2System.UnsupportedChain.selector, wrongChainId, DeepstateAddresses.CHAIN_ID
            )
        );
        deployment.run();

        vm.setEnv("DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT", "true");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployRewarderV2System.UnsupportedChain.selector, wrongChainId, DeepstateAddresses.CHAIN_ID
            )
        );
        deployment.deploy();
    }

    function test_IncompatibleOccupiedTargetFailsClosed() public {
        OfflineDeploymentCodeMock incompatible = new OfflineDeploymentCodeMock();
        vm.etch(EXPECTED_MINTER, address(incompatible).code);

        vm.expectRevert(
            abi.encodeWithSelector(DeployRewarderV2System.InvalidDeployedConfiguration.selector, EXPECTED_MINTER)
        );
        deployment.validateExistingFromPlan();
    }

    function test_BootstrapDeploymentIsIndependentOfTheMinterController() public {
        deployment.deployBootstrapFromPlan();
        assertGt(EXPECTED_BOOTSTRAP.code.length, 0);
        assertEq(EXPECTED_MINTER.code.length, 0);
        deployment.verifyBootstrapFromPlan();
    }

    function test_FactoryCannotDeployBeforeBothControllerDependencies() public {
        vm.expectRevert();
        deployment.deployFactoryFromPlan();
        assertEq(EXPECTED_FACTORY.code.length, 0);

        deployment.deployMinterFromPlan();
        vm.expectRevert();
        deployment.deployFactoryFromPlan();
        assertEq(EXPECTED_FACTORY.code.length, 0);

        deployment.deployV1FromPlan();
        deployment.deployFactoryFromPlan();
        deployment.verifyFactoryFromPlan();
    }

    function test_ProductionOrderDeploysEveryContractAndIsIdempotent() public {
        deployment.deployMinterFromPlan();
        deployment.deployBootstrapFromPlan();
        deployment.deployV1FromPlan();
        deployment.deployFactoryFromPlan();

        deployment.deployMinterFromPlan();
        deployment.deployBootstrapFromPlan();
        deployment.deployV1FromPlan();
        deployment.deployFactoryFromPlan();

        deployment.validateExistingFromPlan();
        deployment.verifyMinterFromPlan();
        deployment.verifyBootstrapFromPlan();
        deployment.verifyV1FromPlan();
        deployment.verifyFactoryFromPlan();
    }

    function test_DeploymentActionsWriteNoExternalProtocolDependencyStorage() public {
        handler.recoverRelease(2, 1);
        assertGt(handler.recordedDeploymentActions(), 0);
        assertFalse(handler.externalProtocolWriteViolation());
    }

    function test_PartialDeploymentRecoversIdempotently() public {
        deployment.deployV1FromPlan();
        deployment.deployMinterFromPlan();
        deployment.deployBootstrapFromPlan();
        deployment.deployV1FromPlan();
        deployment.deployMinterFromPlan();
        deployment.deployBootstrapFromPlan();
        deployment.deployFactoryFromPlan();
        deployment.deployFactoryFromPlan();

        deployment.validateExistingFromPlan();
        assertEq(EXPECTED_MINTER.codehash, deployment.MINTER_RUNTIME_CODE_HASH());
        assertEq(EXPECTED_BOOTSTRAP.codehash, deployment.DGP001_BOOTSTRAP_RUNTIME_CODE_HASH());
        assertEq(EXPECTED_V1_CONTROLLER.codehash, deployment.V1_CONTROLLER_RUNTIME_CODE_HASH());
        assertEq(EXPECTED_FACTORY.codehash, deployment.FACTORY_RUNTIME_CODE_HASH());
    }
}
