// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DeployDGP001, IDeepstateV1DGP001View} from "../../../script/proposals/DGP001/Deploy.s.sol";
import {DeployDGP002, ISablierDGP002View} from "../../../script/proposals/DGP002/Deploy.s.sol";
import {DeployRewarderV2System} from "../../../script/DeployRewarderV2System.s.sol";
import {DeepstateAddresses} from "../../../script/config/DeepstateAddresses.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ILegacyRewarderDGP002 {
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt);
}

contract DGP002DeploymentHarness is DeployRewarderV2System {
    function deployPinnedContracts() external {
        DeploymentPlan memory plan = _plan();
        _validateExistingDeployments(plan);
        _deployIfMissing(MINTER_SALT, plan.minterInitCode, plan.minterController);
        _deployIfMissing(V1_CONTROLLER_SALT, plan.v1InitCode, plan.v1Controller);
        _deployIfMissing(FACTORY_SALT, plan.factoryInitCode, plan.rewarderFactory);
        _validateExistingDeployments(plan);
    }
}

contract DGP002Test is Test {
    uint256 internal constant FORK_BLOCK = 50358350;
    bytes32 internal constant FORK_BLOCK_HASH = 0xb03f9d4fce26314175d042ab6a65bfaafb83cad8c95a40c345901113153bf6c3;
    bytes32 internal constant EXPECTED_DESCRIPTION_HASH =
        0x61ab68ce84efae2591aeaa698a08e2774851631675e4ae53951936c02388f94d;
    address internal constant QUORUM_VOTER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;

    uint256 private constant _COMBINED_ISSUANCE = 14_285_714_285714285714285713;
    bytes32 private constant _MINTED_WITH_VESTING_TOPIC =
        keccak256("MintedWithVesting(address,address,uint256,address,uint256,uint256)");
    bytes32 private constant _GROSS_ISSUANCE_RECORDED_TOPIC = keccak256("GrossIssuanceRecorded(uint256,uint256)");
    bytes32 private constant _TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _PINNED_ACTIVE_BOOK_ID =
        0xdf941c235503a5d2e67aee5dea00f2965f99421c0d034bd77f924c05c66bf399;

    DeployDGP001 internal dgp001;
    DeployDGP002 internal proposal;
    DGP002DeploymentHarness internal deployment;

    struct Snapshot {
        uint256 supply;
        uint256 grossIssued;
        uint256 nextStreamId;
        uint256 governorBalance;
        uint256 sablierDeepBalance;
        uint256 safeStreamBalance;
        uint256 volunteerABalance;
        uint256 volunteerBBalance;
        uint256 volunteerCBalance;
    }

    function setUp() public {
        dgp001 = new DeployDGP001();
        proposal = new DeployDGP002();
        deployment = new DGP002DeploymentHarness();
        vm.makePersistent(address(dgp001), address(proposal), address(deployment));
    }

    function testProposalPayload() public view {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        assertEq(targets.length, 3);
        assertEq(values.length, 3);
        assertEq(calldatas.length, 3);
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 0);
        }

        assertEq(targets[0], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[1], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[2], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(
            calldatas[0],
            abi.encodeCall(DeepstateMinterController.mint, (proposal.VOLUNTEER_A(), proposal.VOLUNTEER_A_AMOUNT()))
        );
        assertEq(
            calldatas[1],
            abi.encodeCall(DeepstateMinterController.mint, (proposal.VOLUNTEER_B(), proposal.VOLUNTEER_B_AMOUNT()))
        );
        assertEq(
            calldatas[2],
            abi.encodeCall(DeepstateMinterController.mint, (proposal.VOLUNTEER_C(), proposal.VOLUNTEER_C_AMOUNT()))
        );

        assertEq(proposal.proposer(), QUORUM_VOTER);
        assertEq(
            proposal.VOLUNTEER_A_AMOUNT() + proposal.VOLUNTEER_B_AMOUNT() + proposal.VOLUNTEER_C_AMOUNT(), 10_000_000e18
        );
        assertEq(proposal.VESTING_PER_MINT(), 1_428_571_428571428571428571);
        assertEq(proposal.TOTAL_VESTING_AMOUNT(), 4_285_714_285714285714285713);
        assertEq(keccak256(bytes(description)), EXPECTED_DESCRIPTION_HASH);
        assertEq(proposal.proposalId(), proposal.expectedProposalId());
    }

    function testAuthorizedTargetCallsAndPostconditions() public {
        _setUpActivatedFork();
        proposal.validateSubmissionPreconditions();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = proposal.proposal();
        Snapshot memory beforeState = _snapshot();

        _executeAction(targets, values, calldatas, 0);
        Snapshot memory afterMint = _snapshot();
        assertEq(afterMint.supply - beforeState.supply, proposal.VOLUNTEER_A_AMOUNT() + proposal.VESTING_PER_MINT());
        assertEq(
            afterMint.grossIssued - beforeState.grossIssued, proposal.VOLUNTEER_A_AMOUNT() + proposal.VESTING_PER_MINT()
        );
        assertEq(afterMint.nextStreamId, beforeState.nextStreamId + 1);
        assertEq(afterMint.governorBalance, beforeState.governorBalance);
        assertEq(afterMint.volunteerABalance - beforeState.volunteerABalance, proposal.VOLUNTEER_A_AMOUNT());
        assertEq(afterMint.volunteerBBalance, beforeState.volunteerBBalance);
        assertEq(afterMint.volunteerCBalance, beforeState.volunteerCBalance);
        _assertVolunteerStream(beforeState.nextStreamId, block.timestamp);

        _executeAction(targets, values, calldatas, 1);
        Snapshot memory afterSecondMint = _snapshot();
        assertEq(afterSecondMint.nextStreamId, beforeState.nextStreamId + 2);
        assertEq(afterSecondMint.volunteerBBalance - beforeState.volunteerBBalance, proposal.VOLUNTEER_B_AMOUNT());
        _assertVolunteerStream(beforeState.nextStreamId + 1, block.timestamp);

        _executeAction(targets, values, calldatas, 2);
        _assertSuccessfulDGP002Deltas(beforeState);
        _assertVolunteerStream(beforeState.nextStreamId + 2, block.timestamp);
        proposal.verifyPostconditions();
    }

    function testFullGovernorLifecycle() public {
        _setUpActivatedFork();
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
        proposal.validateExecutionPreconditions();
        Snapshot memory beforeState = _snapshot();
        uint256 executedAt = block.timestamp;

        vm.recordLogs();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        Vm.Log[] memory executionLogs = vm.getRecordedLogs();

        assertEq(governor.state(proposalId), 7);
        assertEq(proposal.verifyExecution(), proposalId);
        _assertSuccessfulDGP002Deltas(beforeState);
        _assertMintReceipt(executionLogs, beforeState);
        _assertVolunteerStream(beforeState.nextStreamId, executedAt);
        _assertVolunteerStream(beforeState.nextStreamId + 1, executedAt);
        _assertVolunteerStream(beforeState.nextStreamId + 2, executedAt);

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(governor.state(proposalId), 7);
    }

    function testGovernorExecutionRollsBackEarlierMintsAndStreamsWhenFinalMintFails() public {
        _setUpActivatedFork();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        uint256 proposalId =
            _passProposalToSucceeded(governor, proposal.proposer(), targets, values, calldatas, description);
        proposal.validateExecutionPreconditions();
        Snapshot memory beforeState = _snapshot();

        vm.mockCallRevert(
            DeepstateAddresses.MINTER_CONTROLLER, calldatas[2], abi.encodeWithSignature("InjectedFinalMintFailure()")
        );
        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        Snapshot memory afterState = _snapshot();
        assertEq(governor.state(proposalId), 4);
        assertEq(afterState.supply, beforeState.supply);
        assertEq(afterState.grossIssued, beforeState.grossIssued);
        assertEq(afterState.nextStreamId, beforeState.nextStreamId);
        assertEq(afterState.governorBalance, beforeState.governorBalance);
        assertEq(afterState.sablierDeepBalance, beforeState.sablierDeepBalance);
        assertEq(afterState.safeStreamBalance, beforeState.safeStreamBalance);
        assertEq(afterState.volunteerABalance, beforeState.volunteerABalance);
        assertEq(afterState.volunteerBBalance, beforeState.volunteerBBalance);
        assertEq(afterState.volunteerCBalance, beforeState.volunteerCBalance);
        assertEq(DeepstateToken(DeepstateAddresses.DEEP).balanceOf(DeepstateAddresses.MINTER_CONTROLLER), 0);
        assertEq(
            DeepstateToken(DeepstateAddresses.DEEP)
                .allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP),
            0
        );
    }

    function testSubmissionPreflightRejectsSablierComptrollerImplementationDrift() public {
        _setUpActivatedFork();
        vm.store(
            DeepstateAddresses.SABLIER_COMPTROLLER,
            _ERC1967_IMPLEMENTATION_SLOT,
            bytes32(uint256(uint160(address(0xBEEF))))
        );

        vm.expectRevert(abi.encodeWithSelector(DeployDGP002.PreconditionFailed.selector, 55));
        proposal.validateSubmissionPreconditions();
    }

    function _setUpActivatedFork() private {
        vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH);
        vm.rollFork(FORK_BLOCK);
        assertEq(block.number, FORK_BLOCK);
        assertEq(block.chainid, DeepstateAddresses.CHAIN_ID);

        deployment.run();
        deployment.deployPinnedContracts();
        _executeDGP001ThroughGovernor();
        vm.clearMockedCalls();
    }

    function _executeDGP001ThroughGovernor() private {
        dgp001.validateSubmissionPreconditions();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            dgp001.proposal();

        uint256 proposalId =
            _passProposalToSucceeded(governor, dgp001.proposer(), targets, values, calldatas, description);
        assertEq(proposalId, dgp001.expectedProposalId());

        _clearLegacyMarket();
        dgp001.validateActivationPreconditions();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(governor.state(proposalId), 7);

        // DGP-001's exact immediate-state verifier must run before DGP-002 legitimately increases issuance.
        assertEq(dgp001.verifyExecution(), proposalId);
    }

    function _passProposalToSucceeded(
        IDeepstateGovernor governor,
        address intendedProposer,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.prank(intendedProposer);
        proposalId = governor.propose(targets, values, calldatas, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        assertGe(governor.getVotes(QUORUM_VOTER, snapshot), governor.quorum(snapshot));
        vm.prank(QUORUM_VOTER);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4);
    }

    function _clearLegacyMarket() private {
        IDeepstateV1DGP001View router = IDeepstateV1DGP001View(DeepstateAddresses.ROUTER);
        bytes32 bookId = _PINNED_ACTIVE_BOOK_ID;

        // This sequential test starts before either proposal. It models the operational cancellation phase required
        // by DGP-001 while retaining real Router hook writes and every other archive-fork dependency interaction.
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001View.activeBookId, (DeepstateAddresses.USDG, DeepstateAddresses.NVDA)),
            abi.encode(bookId)
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001View.topOrder, (bookId, true)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001View.topOrder, (bookId, false)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP002.rewardees, (DeepstateAddresses.USDG)),
            abi.encode(uint32(0), uint64(0))
        );
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP002.rewardees, (DeepstateAddresses.NVDA)),
            abi.encode(uint32(0), uint64(0))
        );

        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(bookId, true);
        (uint32 askNonce, uint160 askAmount) = router.topOrder(bookId, false);
        assertEq(bidNonce, 0);
        assertEq(bidAmount, 0);
        assertEq(askNonce, 0);
        assertEq(askAmount, 0);
    }

    function _executeAction(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, uint256 index)
        private
    {
        vm.prank(DeepstateAddresses.GOVERNOR);
        (bool success, bytes memory result) = targets[index].call{value: values[index]}(calldatas[index]);
        assertTrue(success, string(result));
    }

    function _snapshot() private view returns (Snapshot memory state_) {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        state_.supply = deep.totalSupply();
        state_.grossIssued = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER).grossIssued();
        state_.nextStreamId = ISablierDGP002View(DeepstateAddresses.SABLIER_LOCKUP).nextStreamId();
        state_.governorBalance = deep.balanceOf(DeepstateAddresses.GOVERNOR);
        state_.sablierDeepBalance = deep.balanceOf(DeepstateAddresses.SABLIER_LOCKUP);
        state_.safeStreamBalance =
            ISablierDGP002View(DeepstateAddresses.SABLIER_LOCKUP).balanceOf(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        state_.volunteerABalance = deep.balanceOf(proposal.VOLUNTEER_A());
        state_.volunteerBBalance = deep.balanceOf(proposal.VOLUNTEER_B());
        state_.volunteerCBalance = deep.balanceOf(proposal.VOLUNTEER_C());
    }

    function _assertSuccessfulDGP002Deltas(Snapshot memory beforeState) private view {
        Snapshot memory afterState = _snapshot();
        assertEq(afterState.supply - beforeState.supply, _COMBINED_ISSUANCE);
        assertEq(afterState.grossIssued - beforeState.grossIssued, _COMBINED_ISSUANCE);
        assertEq(afterState.nextStreamId, beforeState.nextStreamId + 3);
        assertEq(afterState.governorBalance, beforeState.governorBalance);
        assertEq(afterState.sablierDeepBalance - beforeState.sablierDeepBalance, proposal.TOTAL_VESTING_AMOUNT());
        assertEq(afterState.safeStreamBalance - beforeState.safeStreamBalance, 3);
        assertEq(afterState.volunteerABalance - beforeState.volunteerABalance, proposal.VOLUNTEER_A_AMOUNT());
        assertEq(afterState.volunteerBBalance - beforeState.volunteerBBalance, proposal.VOLUNTEER_B_AMOUNT());
        assertEq(afterState.volunteerCBalance - beforeState.volunteerCBalance, proposal.VOLUNTEER_C_AMOUNT());
    }

    function _assertVolunteerStream(uint256 streamId, uint256 expectedStart) private view {
        ISablierDGP002View lockup = ISablierDGP002View(DeepstateAddresses.SABLIER_LOCKUP);
        assertEq(lockup.ownerOf(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getRecipient(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getSender(streamId), DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(address(lockup.getUnderlyingToken(streamId)), DeepstateAddresses.DEEP);
        assertEq(lockup.getDepositedAmount(streamId), proposal.VESTING_PER_MINT());
        assertEq(lockup.getStartTime(streamId), expectedStart);
        assertEq(lockup.getEndTime(streamId), expectedStart + 365 days);
        assertEq(lockup.getCliffTime(streamId), 0);
        assertFalse(lockup.isCancelable(streamId));
        assertFalse(lockup.isTransferable(streamId));
        assertEq(lockup.getGranularity(streamId), 1);
    }

    function _assertMintReceipt(Vm.Log[] memory logs, Snapshot memory beforeState) private view {
        uint256 mintEventCount;
        uint256 grossEventCount;
        uint256 cumulativeIssuance;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != DeepstateAddresses.MINTER_CONTROLLER || entry.topics.length == 0) continue;

            if (entry.topics[0] == _MINTED_WITH_VESTING_TOPIC) {
                assertLt(mintEventCount, 3);
                (uint256 mintAmount, uint256 vestingAmount, uint256 streamId) =
                    abi.decode(entry.data, (uint256, uint256, uint256));
                assertEq(address(uint160(uint256(entry.topics[1]))), DeepstateAddresses.GOVERNOR);
                assertEq(address(uint160(uint256(entry.topics[2]))), _volunteerAt(mintEventCount));
                assertEq(address(uint160(uint256(entry.topics[3]))), DeepstateAddresses.DEEPSTATE_INC_SAFE);
                assertEq(mintAmount, _volunteerAmountAt(mintEventCount));
                assertEq(vestingAmount, proposal.VESTING_PER_MINT());
                assertEq(streamId, beforeState.nextStreamId + mintEventCount);
                ++mintEventCount;
            } else if (entry.topics[0] == _GROSS_ISSUANCE_RECORDED_TOPIC) {
                assertLt(grossEventCount, 3);
                (uint256 issued, uint256 totalGrossIssued) = abi.decode(entry.data, (uint256, uint256));
                uint256 expectedIssued = _volunteerAmountAt(grossEventCount) + proposal.VESTING_PER_MINT();
                cumulativeIssuance += expectedIssued;
                assertEq(issued, expectedIssued);
                assertEq(totalGrossIssued, beforeState.grossIssued + cumulativeIssuance);
                ++grossEventCount;
            }
        }

        assertEq(mintEventCount, 3);
        assertEq(grossEventCount, 3);
        _assertDeepTransferReceipt(logs);
    }

    function _assertDeepTransferReceipt(Vm.Log[] memory logs) private view {
        uint256 primaryMintCount;
        uint256 vestingMintCount;
        uint256 vestingDepositCount;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != DeepstateAddresses.DEEP || entry.topics.length != 3
                    || entry.topics[0] != _TRANSFER_TOPIC
            ) continue;

            address from = address(uint160(uint256(entry.topics[1])));
            address to = address(uint160(uint256(entry.topics[2])));
            uint256 amount = abi.decode(entry.data, (uint256));
            if (from == address(0) && to == _volunteerAt(primaryMintCount)) {
                assertLt(primaryMintCount, 3);
                assertEq(amount, _volunteerAmountAt(primaryMintCount));
                ++primaryMintCount;
            } else if (from == address(0) && to == DeepstateAddresses.MINTER_CONTROLLER) {
                assertEq(amount, proposal.VESTING_PER_MINT());
                ++vestingMintCount;
            } else if (from == DeepstateAddresses.MINTER_CONTROLLER && to == DeepstateAddresses.SABLIER_LOCKUP) {
                assertEq(amount, proposal.VESTING_PER_MINT());
                ++vestingDepositCount;
            }
        }

        assertEq(primaryMintCount, 3);
        assertEq(vestingMintCount, 3);
        assertEq(vestingDepositCount, 3);
    }

    function _volunteerAt(uint256 index) private view returns (address) {
        if (index == 0) return proposal.VOLUNTEER_A();
        if (index == 1) return proposal.VOLUNTEER_B();
        return proposal.VOLUNTEER_C();
    }

    function _volunteerAmountAt(uint256 index) private view returns (uint256) {
        if (index == 0) return proposal.VOLUNTEER_A_AMOUNT();
        if (index == 1) return proposal.VOLUNTEER_B_AMOUNT();
        return proposal.VOLUNTEER_C_AMOUNT();
    }
}
