// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {
    DeployDGP001,
    IDeepstateRoleAdminDGP001,
    ISablierDGP001View
} from "../../../script/proposals/DGP001/Deploy.s.sol";
import {DeployRewarderV2System} from "../../../script/DeployRewarderV2System.s.sol";
import {DeepstateAddresses} from "../../../script/config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../../../src/DeepstateV1Controller.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {IDeepstateV1} from "../../../src/interfaces/IDeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface IDeepstateV1DGP001 is IDeepstateV1 {
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

interface ILegacyRewarderDGP001 {
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt);
    function totalAccrued(address token) external view returns (uint96 accrued);
}

contract DGP001DeploymentHarness is DeployRewarderV2System {
    function deployPinnedContracts() external {
        DeploymentPlan memory plan = _plan();
        _validateExistingDeployments(plan);
        _deployIfMissing(MINTER_SALT, plan.minterInitCode, plan.minterController);
        _deployIfMissing(DGP001_BOOTSTRAP_SALT, plan.bootstrapInitCode, plan.dgp001Bootstrap);
        _deployIfMissing(V1_CONTROLLER_SALT, plan.v1InitCode, plan.v1Controller);
        _deployIfMissing(FACTORY_SALT, plan.factoryInitCode, plan.rewarderFactory);
        _validateExistingDeployments(plan);
    }
}

contract DGP001Test is Test {
    uint256 internal constant FORK_BLOCK = 50358350;
    bytes32 internal constant FORK_BLOCK_HASH = 0xb03f9d4fce26314175d042ab6a65bfaafb83cad8c95a40c345901113153bf6c3;
    bytes32 internal constant EXPECTED_DESCRIPTION_HASH =
        0x13d578a939920f9bd50d7ee2fdfd457e50f699561ddec01d953473851cd9cd2f;
    address internal constant QUORUM_VOTER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;

    uint256 private constant _MARKET_FUNDING = 100_000_000e18;
    uint256 private constant _MARKET_VESTING = _MARKET_FUNDING * 30 / 70;
    uint256 private constant _POOL_STATE_MAPPING_SLOT = 2;
    uint256 private constant _BOTH_HOOK_FLAGS = (uint256(1) << 254) | (uint256(1) << 255);
    bytes32 private constant _PINNED_ACTIVE_BOOK_ID =
        0xdf941c235503a5d2e67aee5dea00f2965f99421c0d034bd77f924c05c66bf399;

    DeployDGP001 internal proposal;
    DGP001DeploymentHarness internal deployment;

    function setUp() public {
        proposal = new DeployDGP001();
        deployment = new DGP001DeploymentHarness();
        vm.makePersistent(address(proposal), address(deployment));
    }

    function _setUpFork() private {
        if (vm.envOr("DGP001_TEST_LATEST_FORK", false)) {
            // Diagnostic-only escape hatch for non-archive public RPCs. Release CI never sets this variable and must
            // execute the pinned branch below against the configured archive endpoint.
            vm.createSelectFork(vm.rpcUrl("robinhood"));
        } else {
            vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK + 1);
            assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH);
            vm.rollFork(FORK_BLOCK);
            assertEq(block.number, FORK_BLOCK);
        }
        assertEq(block.chainid, DeepstateAddresses.CHAIN_ID);

        deployment.run();
        deployment.deployPinnedContracts();
        _assertPristineDeployment();
    }

    function testProposalPayload() public view {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        assertEq(targets.length, 10);
        assertEq(values.length, 10);
        assertEq(calldatas.length, 10);
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 0);
        }

        assertEq(targets[0], DeepstateAddresses.DEEP);
        assertEq(targets[1], DeepstateAddresses.DGP001_BOOTSTRAP);
        assertEq(targets[2], DeepstateAddresses.DEEP);
        assertEq(targets[3], DeepstateAddresses.DEEP);
        assertEq(targets[4], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[5], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[6], DeepstateAddresses.ROUTER);
        assertEq(targets[7], DeepstateAddresses.V1_CONTROLLER);
        assertEq(targets[8], DeepstateAddresses.REWARDER_FACTORY);
        assertEq(targets[9], DeepstateAddresses.REWARDER_FACTORY);

        assertEq(
            calldatas[0],
            abi.encodeCall(IAccessControl.grantRole, (keccak256("MINTER_ROLE"), DeepstateAddresses.DGP001_BOOTSTRAP))
        );
        assertEq(calldatas[1], abi.encodeCall(DGP001Bootstrap.execute, ()));
        assertEq(
            calldatas[2], abi.encodeCall(IAccessControl.grantRole, (bytes32(0), DeepstateAddresses.MINTER_CONTROLLER))
        );
        assertEq(calldatas[3], abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), DeepstateAddresses.GOVERNOR)));
        assertEq(calldatas[4], abi.encodeCall(DeepstateMinterController.activateTokenAdministration, ()));
        assertEq(
            calldatas[5],
            abi.encodeCall(IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, uint256(1)))
        );
        assertEq(calldatas[6], abi.encodeCall(IDeepstateV1.transferOwnership, (DeepstateAddresses.V1_CONTROLLER)));
        assertEq(
            calldatas[7],
            abi.encodeCall(IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, uint256(1)))
        );
        DeepstateRewarderFactory.MarketConfig memory market = DeepstateRewarderFactory.MarketConfig({
            stockToken: DeepstateAddresses.NVDA,
            stockStartQuantity: 1e18,
            stockMaxQuantity: 5_000e18,
            stockBuySideActive: true,
            usdGBuySideActive: true
        });
        assertEq(
            calldatas[8], abi.encodeCall(DeepstateRewarderFactory.migrateMarket, (market, DeepstateAddresses.REWARDER))
        );
        assertEq(
            calldatas[9], abi.encodeCall(DeepstateRewarderFactory.setOperator, (DeepstateAddresses.DEEPSTATE_INC_SAFE))
        );

        assertEq(proposal.proposer(), QUORUM_VOTER);
        assertEq(keccak256(bytes(description)), EXPECTED_DESCRIPTION_HASH);
        assertEq(proposal.proposalId(), proposal.expectedProposalId());
    }

    function testAuthorizedTargetCallsAndPostconditions() public {
        _setUpFork();
        proposal.validateSubmissionPreconditions();
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = proposal.proposal();

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);

        uint256 supplyBefore = deep.totalSupply();
        uint256 nextStreamId = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP).nextStreamId();
        uint256 expectedEndowment = _currentLegacyEndowment();

        _executeAction(targets, values, calldatas, 0);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));

        _executeAction(targets, values, calldatas, 1);
        assertTrue(bootstrap.executed());
        assertEq(bootstrap.endowmentAmount(), expectedEndowment);
        assertEq(bootstrap.streamId(), nextStreamId);
        assertEq(bootstrap.postEndowmentSupply(), supplyBefore + expectedEndowment);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));

        _executeAction(targets, values, calldatas, 2);
        assertEq(deep.defaultAdminCount(), 2);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));

        _executeAction(targets, values, calldatas, 3);
        assertEq(deep.defaultAdminCount(), 1);
        assertFalse(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));

        _executeAction(targets, values, calldatas, 4);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
        assertEq(minter.tokenAdministrationEndsAt(), block.timestamp + 730 days);
        assertEq(minter.grossIssued(), supplyBefore + expectedEndowment);

        _executeAction(targets, values, calldatas, 5);
        assertEq(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.REWARDER_FACTORY));

        _executeAction(targets, values, calldatas, 6);
        assertEq(router.owner(), DeepstateAddresses.V1_CONTROLLER);

        _executeAction(targets, values, calldatas, 7);
        assertEq(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);

        _executeAction(targets, values, calldatas, 8);
        address rewarder = factory.activeRewarder(DeepstateAddresses.NVDA_USDG_POOL_ID);
        assertNotEq(rewarder, address(0));
        assertEq(deep.balanceOf(rewarder), _MARKET_FUNDING);
        assertEq(factory.fundingCommitted(), _MARKET_FUNDING);
        assertEq(minter.grossIssued(), deep.totalSupply());
        if (!vm.envOr("DGP001_TEST_PRUNED_RPC", false)) {
            assertEq(uint256(vm.load(DeepstateAddresses.ROUTER, _poolStateSlot())) & _BOTH_HOOK_FLAGS, _BOTH_HOOK_FLAGS);
        }

        _executeAction(targets, values, calldatas, 9);
        assertEq(factory.operator(), DeepstateAddresses.DEEPSTATE_INC_SAFE);

        assertEq(deep.totalSupply() - supplyBefore, expectedEndowment + _MARKET_FUNDING + _MARKET_VESTING);
        assertEq(ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP).nextStreamId(), nextStreamId + 2);
        proposal.verifyPostconditions();
    }

    function testFullGovernorLifecycle() public {
        _setUpFork();
        proposal.validateSubmissionPreconditions();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        vm.prank(proposal.proposer());
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(proposalId, proposal.expectedProposalId());
        assertEq(governor.proposalProposer(proposalId), proposal.proposer());
        assertFalse(governor.proposalNeedsQueuing(proposalId));

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        assertGe(governor.getVotes(QUORUM_VOTER, snapshot), governor.quorum(snapshot));
        vm.prank(QUORUM_VOTER);
        governor.castVote(proposalId, 1);

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4);

        // Operationally prepare the market only after voting succeeds, then reopen every execution-time gate.
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(governor.state(proposalId), 7);
        assertEq(proposal.verifyExecution(), proposalId);
    }

    function testGovernorExecutionRollsBackEveryEarlierActionWhenMigrationMintFails() public {
        _setUpFork();
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        uint256 proposalId = _passProposalToSucceeded(governor, targets, values, calldatas, description);

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);

        uint256 supplyBefore = deep.totalSupply();
        uint256 streamBefore = lockup.nextStreamId();
        uint64 factoryNonceBefore = vm.getNonce(DeepstateAddresses.REWARDER_FACTORY);
        bool prunedRpc = vm.envOr("DGP001_TEST_PRUNED_RPC", false);
        bytes32 poolStateBefore = prunedRpc ? bytes32(0) : vm.load(DeepstateAddresses.ROUTER, _poolStateSlot());
        vm.mockCallRevert(
            DeepstateAddresses.MINTER_CONTROLLER,
            abi.encodeWithSelector(DeepstateMinterController.mint.selector),
            abi.encodeWithSignature("InjectedMigrationMintFailure()")
        );

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        if (prunedRpc) {
            vm.mockCall(
                DeepstateAddresses.ROUTER,
                abi.encodeCall(IDeepstateV1.poolHook, (DeepstateAddresses.NVDA_USDG_POOL_ID)),
                abi.encode(DeepstateAddresses.REWARDER)
            );
        }

        assertEq(governor.state(proposalId), 4);
        assertEq(deep.totalSupply(), supplyBefore);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
        assertFalse(bootstrap.executed());
        assertEq(bootstrap.snapshotBlock(), 0);
        assertEq(bootstrap.snapshotAt(), 0);
        assertEq(bootstrap.snapshotToken0(), address(0));
        assertEq(bootstrap.snapshotToken1(), address(0));
        assertEq(bootstrap.token0Accrued(), 0);
        assertEq(bootstrap.token1Accrued(), 0);
        assertEq(bootstrap.totalAccrued(), 0);
        assertEq(bootstrap.endowmentAmount(), 0);
        assertEq(bootstrap.preexistingBalanceBurned(), 0);
        assertEq(bootstrap.postEndowmentSupply(), 0);
        assertEq(bootstrap.streamId(), 0);
        assertEq(deep.balanceOf(DeepstateAddresses.DGP001_BOOTSTRAP), 0);
        assertEq(deep.allowance(DeepstateAddresses.DGP001_BOOTSTRAP, DeepstateAddresses.SABLIER_LOCKUP), 0);
        assertEq(minter.grossIssued(), 0);
        assertEq(minter.tokenAdministrationEndsAt(), 0);
        assertEq(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 0);
        assertEq(
            DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER).rolesOf(DeepstateAddresses.REWARDER_FACTORY), 0
        );
        assertEq(router.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), DeepstateAddresses.REWARDER);
        if (!prunedRpc) assertEq(vm.load(DeepstateAddresses.ROUTER, _poolStateSlot()), poolStateBefore);
        assertEq(factory.operator(), address(0));
        assertEq(factory.fundingCommitted(), 0);
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(factory.activeRewarder(DeepstateAddresses.NVDA_USDG_POOL_ID), address(0));
        assertEq(lockup.nextStreamId(), streamBefore);
        assertEq(vm.getNonce(DeepstateAddresses.REWARDER_FACTORY), factoryNonceBefore);
    }

    function _assertPristineDeployment() private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);

        assertEq(DeepstateAddresses.MINTER_CONTROLLER.codehash, DeepstateAddresses.MINTER_CONTROLLER_CODEHASH);
        assertEq(DeepstateAddresses.DGP001_BOOTSTRAP.codehash, DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH);
        assertEq(DeepstateAddresses.V1_CONTROLLER.codehash, DeepstateAddresses.V1_CONTROLLER_CODEHASH);
        assertEq(DeepstateAddresses.REWARDER_FACTORY.codehash, DeepstateAddresses.REWARDER_FACTORY_CODEHASH);
        assertEq(minter.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(bootstrap.governor(), DeepstateAddresses.GOVERNOR);
        assertEq(address(bootstrap.deepstateToken()), DeepstateAddresses.DEEP);
        assertEq(address(bootstrap.sablierLockup()), DeepstateAddresses.SABLIER_LOCKUP);
        assertEq(address(bootstrap.legacyRewarder()), DeepstateAddresses.REWARDER);
        assertEq(address(bootstrap.minterController()), DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(bootstrap.recipient(), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(v1Controller.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(factory.owner(), DeepstateAddresses.GOVERNOR);
        assertFalse(bootstrap.executed());
        assertEq(bootstrap.snapshotBlock(), 0);
        assertEq(bootstrap.snapshotAt(), 0);
        assertEq(bootstrap.snapshotToken0(), address(0));
        assertEq(bootstrap.snapshotToken1(), address(0));
        assertEq(bootstrap.token0Accrued(), 0);
        assertEq(bootstrap.token1Accrued(), 0);
        assertEq(bootstrap.totalAccrued(), 0);
        assertEq(bootstrap.endowmentAmount(), 0);
        assertEq(bootstrap.preexistingBalanceBurned(), 0);
        assertEq(bootstrap.postEndowmentSupply(), 0);
        assertEq(bootstrap.streamId(), 0);
        assertEq(minter.grossIssued(), 0);
        assertEq(minter.tokenAdministrationEndsAt(), 0);
        assertEq(factory.operator(), address(0));
        assertEq(factory.fundingCommitted(), 0);
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(router.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), DeepstateAddresses.REWARDER);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
    }

    function _executeAction(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, uint256 index)
        private
    {
        vm.prank(DeepstateAddresses.GOVERNOR);
        (bool success, bytes memory result) = targets[index].call{value: values[index]}(calldatas[index]);
        assertTrue(success, string(result));
    }

    function _passProposalToSucceeded(
        IDeepstateGovernor governor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.prank(proposal.proposer());
        proposalId = governor.propose(targets, values, calldatas, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        vm.prank(QUORUM_VOTER);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4);
    }

    function _clearLegacyMarket() private {
        IDeepstateV1DGP001 router = IDeepstateV1DGP001(DeepstateAddresses.ROUTER);
        bytes32 bookId = _PINNED_ACTIVE_BOOK_ID;

        // The reviewed fork is deliberately pre-deployment and the live book is not yet operationally prepared.
        // Model the observable result of the user/keeper claimant-registration and cancellation phase while leaving
        // immutable identities and cumulative legacy accrual untouched. A final release fork must observe these four
        // zeroes naturally before the proposal is executed.
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.activeBookId, (DeepstateAddresses.USDG, DeepstateAddresses.NVDA)),
            abi.encode(bookId)
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.topOrder, (bookId, true)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.topOrder, (bookId, false)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP001.rewardees, (DeepstateAddresses.USDG)),
            abi.encode(uint32(0), uint64(0))
        );

        if (vm.envOr("DGP001_TEST_PRUNED_RPC", false)) {
            // Diagnostic-only fallback for the official pruned RPC. Trusted release CI never sets this variable and
            // therefore executes both real Router hook writes and inspects the packed side flags on an archive fork.
            address expectedRewarder = vm.computeCreateAddress(
                DeepstateAddresses.REWARDER_FACTORY, vm.getNonce(DeepstateAddresses.REWARDER_FACTORY)
            );
            vm.mockCall(DeepstateAddresses.ROUTER, IDeepstateV1.setPoolHookConfig.selector, bytes(""));
            bytes[] memory hookReturns = new bytes[](9);
            hookReturns[0] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[1] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[2] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[3] = abi.encode(address(0));
            for (uint256 i = 4; i < hookReturns.length; ++i) {
                hookReturns[i] = abi.encode(expectedRewarder);
            }
            vm.mockCalls(
                DeepstateAddresses.ROUTER,
                abi.encodeCall(IDeepstateV1.poolHook, (DeepstateAddresses.NVDA_USDG_POOL_ID)),
                hookReturns
            );
        }
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP001.rewardees, (DeepstateAddresses.NVDA)),
            abi.encode(uint32(0), uint64(0))
        );

        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(bookId, true);
        (uint32 askNonce, uint160 askAmount) = router.topOrder(bookId, false);
        assertEq(bidNonce, 0);
        assertEq(bidAmount, 0);
        assertEq(askNonce, 0);
        assertEq(askAmount, 0);

        ILegacyRewarderDGP001 legacy = ILegacyRewarderDGP001(DeepstateAddresses.REWARDER);
        (uint32 usdGNonce, uint64 usdGStartedAt) = legacy.rewardees(DeepstateAddresses.USDG);
        (uint32 nvdaNonce, uint64 nvdaStartedAt) = legacy.rewardees(DeepstateAddresses.NVDA);
        assertEq(usdGNonce, 0);
        assertEq(usdGStartedAt, 0);
        assertEq(nvdaNonce, 0);
        assertEq(nvdaStartedAt, 0);
    }

    function _currentLegacyEndowment() private view returns (uint256) {
        ILegacyRewarderDGP001 legacy = ILegacyRewarderDGP001(DeepstateAddresses.REWARDER);
        return (uint256(legacy.totalAccrued(DeepstateAddresses.USDG))
                + uint256(legacy.totalAccrued(DeepstateAddresses.NVDA))) * 30 / 100;
    }

    function _poolStateSlot() private pure returns (bytes32) {
        return keccak256(abi.encode(DeepstateAddresses.NVDA_USDG_POOL_ID, _POOL_STATE_MAPPING_SLOT));
    }
}
