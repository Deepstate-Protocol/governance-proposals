// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployContracts} from "../../script/DeployContracts.s.sol";
import {DeepstateAddresses} from "../../script/config/DeepstateAddresses.sol";

contract DeploymentDependencyCodeMock {}

contract DeploymentLegacyRewarderMock {
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

contract DeployContractsTest is Test {
    DeployContracts internal deploymentScript;

    function setUp() public {
        vm.chainId(DeepstateAddresses.CHAIN_ID);

        DeploymentDependencyCodeMock codeMock = new DeploymentDependencyCodeMock();
        DeploymentLegacyRewarderMock legacyRewarderMock = new DeploymentLegacyRewarderMock();
        vm.etch(DeepstateAddresses.DEEP, address(codeMock).code);
        vm.etch(DeepstateAddresses.SABLIER_LOCKUP, address(codeMock).code);
        vm.etch(DeepstateAddresses.ROUTER, address(codeMock).code);
        vm.etch(DeepstateAddresses.REWARDER, address(legacyRewarderMock).code);

        deploymentScript = new DeployContracts();
    }

    function test_RunDeploysOneCorrectlyWiredFourContractBundle() public {
        uint64 startingNonce = vm.getNonce(DEFAULT_SENDER);
        DeployContracts.Deployment memory deployed = deploymentScript.run();

        assertEq(address(deployed.minterController), vm.computeCreateAddress(DEFAULT_SENDER, startingNonce));
        assertEq(address(deployed.dgp001Bootstrap), vm.computeCreateAddress(DEFAULT_SENDER, startingNonce + 1));
        assertEq(address(deployed.v1Controller), vm.computeCreateAddress(DEFAULT_SENDER, startingNonce + 2));
        assertEq(address(deployed.rewarderFactory), vm.computeCreateAddress(DEFAULT_SENDER, startingNonce + 3));
        _assertDeployment(deployed);
    }

    function test_RunDoesNotActivateAnyGovernanceCapability() public {
        DeployContracts.Deployment memory deployed = deploymentScript.run();

        assertEq(deployed.minterController.tokenAdministrationEndsAt(), 0);
        assertEq(deployed.minterController.rolesOf(address(deployed.rewarderFactory)), 0);
        assertEq(deployed.v1Controller.rolesOf(address(deployed.rewarderFactory)), 0);
        assertEq(deployed.rewarderFactory.operator(), address(0));
        assertEq(deployed.rewarderFactory.nextDeploymentAt(), 0);
    }

    function test_RunWritesNoLiveProtocolStorage() public {
        vm.record();
        deploymentScript.run();

        _assertNoWrites(DeepstateAddresses.GOVERNOR);
        _assertNoWrites(DeepstateAddresses.DEEP);
        _assertNoWrites(DeepstateAddresses.SABLIER_LOCKUP);
        _assertNoWrites(DeepstateAddresses.ROUTER);
        _assertNoWrites(DeepstateAddresses.REWARDER);
    }

    function test_TwoRunsCreateTwoDistinctBundles() public {
        DeployContracts.Deployment memory first = deploymentScript.run();
        DeployContracts.Deployment memory second = deploymentScript.run();

        _assertDeployment(first);
        _assertDeployment(second);
        assertTrue(address(first.minterController) != address(second.minterController));
        assertTrue(address(first.dgp001Bootstrap) != address(second.dgp001Bootstrap));
        assertTrue(address(first.v1Controller) != address(second.v1Controller));
        assertTrue(address(first.rewarderFactory) != address(second.rewarderFactory));
    }

    function testFuzz_RunRejectsWrongChain(uint64 wrongChainId) public {
        vm.assume(wrongChainId != DeepstateAddresses.CHAIN_ID);
        vm.chainId(wrongChainId);

        vm.expectRevert(
            abi.encodeWithSelector(DeployContracts.UnsupportedChain.selector, wrongChainId, DeepstateAddresses.CHAIN_ID)
        );
        deploymentScript.run();
    }

    function _assertDeployment(DeployContracts.Deployment memory deployed) private view {
        address minter = address(deployed.minterController);
        address bootstrap = address(deployed.dgp001Bootstrap);
        address v1Controller = address(deployed.v1Controller);
        address factory = address(deployed.rewarderFactory);

        assertGt(minter.code.length, 0);
        assertGt(bootstrap.code.length, 0);
        assertGt(v1Controller.code.length, 0);
        assertGt(factory.code.length, 0);

        assertTrue(minter != bootstrap && minter != v1Controller && minter != factory);
        assertTrue(bootstrap != v1Controller && bootstrap != factory && v1Controller != factory);

        assertEq(deployed.minterController.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(address(deployed.minterController.deepstateToken()), DeepstateAddresses.DEEP);
        assertEq(address(deployed.minterController.sablierLockup()), DeepstateAddresses.SABLIER_LOCKUP);
        assertEq(deployed.minterController.recipient(), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(deployed.minterController.maxSupply(), DeepstateAddresses.MINTER_MAX_SUPPLY);

        assertEq(deployed.dgp001Bootstrap.governor(), DeepstateAddresses.GOVERNOR);
        assertEq(address(deployed.dgp001Bootstrap.deepstateToken()), DeepstateAddresses.DEEP);
        assertEq(deployed.dgp001Bootstrap.endowmentAmount(), 300e18);

        assertEq(deployed.v1Controller.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(address(deployed.v1Controller.deepstate()), DeepstateAddresses.ROUTER);

        assertEq(deployed.rewarderFactory.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(address(deployed.rewarderFactory.deepstateV1Controller()), v1Controller);
        assertEq(address(deployed.rewarderFactory.minterController()), minter);
        assertEq(address(deployed.rewarderFactory.deepstate()), DeepstateAddresses.ROUTER);
        assertEq(address(deployed.rewarderFactory.rewardToken()), DeepstateAddresses.DEEP);
    }

    function _assertNoWrites(address target) private view {
        (, bytes32[] memory writes) = vm.accesses(target);
        assertEq(writes.length, 0);
    }
}
