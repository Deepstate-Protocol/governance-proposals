// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DGP004TeamAllocation} from "../../../src/DGP004TeamAllocation.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {DeployDGP004} from "../../../script/proposals/DGP004/Deploy.s.sol";
import {DeepstateAddresses} from "../../../script/config/DeepstateAddresses.sol";

interface IDGP004LiveToken is IERC20, IAccessControl {
    function mint(address to, uint256 amount) external;
}

contract DGP004Test is Test {
    uint256 internal constant FORK_BLOCK = 72347663;
    bytes32 internal constant FORK_BLOCK_HASH = 0x0a6f97f400832ee49fadf10c0c68bfb8f93e28875890f792575ba4c4aed2f805;
    bytes32 internal constant EXPECTED_DESCRIPTION_HASH =
        0x595c3116afb25d7380bc137c4a00d26c678a7e7e43b737bdd090bcaa2dce1e4a;

    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 internal constant VOTE_TOP_UP = 30_000_000e18;
    uint256 internal constant ENDOWMENT_BPS = 30_00;
    uint256 internal constant PRIMARY_BPS = 70_00;

    address internal constant PROPOSER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    address internal constant ALLOCATION = 0xaa3D4f8F6753Fb3144A1d907b58b41d4d7f0a848;

    function testProposalPayload() public {
        vm.setEnv("DGP004_ALLOCATION", vm.toString(ALLOCATION));
        DeployDGP004 proposal = new DeployDGP004();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        assertEq(targets.length, 3);
        assertEq(values.length, 3);
        assertEq(calldatas.length, 3);
        assertEq(targets[0], DeepstateAddresses.TWO_DEEP);
        assertEq(targets[1], ALLOCATION);
        assertEq(targets[2], DeepstateAddresses.TWO_DEEP_GOVERNOR);
        assertEq(values[0], 0);
        assertEq(values[1], 0);
        assertEq(values[2], 0);
        assertEq(calldatas[0], abi.encodeCall(IAccessControl.grantRole, (MINTER_ROLE, ALLOCATION)));
        assertEq(calldatas[1], abi.encodeCall(DGP004TeamAllocation.execute, ()));
        assertEq(calldatas[2], abi.encodeCall(IDeepstateGovernor.updateQuorumNumerator, (4)));
        assertEq(keccak256(bytes(description)), EXPECTED_DESCRIPTION_HASH);
        assertEq(proposal.governorAddress(), DeepstateAddresses.TWO_DEEP_GOVERNOR);
        assertEq(proposal.votingTokenAddress(), DeepstateAddresses.TWO_DEEP);
        assertEq(proposal.proposalId(), proposal.expectedProposalId());
    }

    function testAuthorizedTargetCallsAndPostconditions() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH);

        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.TWO_DEEP_GOVERNOR);
        IDGP004LiveToken token = IDGP004LiveToken(DeepstateAddresses.TWO_DEEP);
        DGP004TeamAllocation allocation =
            new DGP004TeamAllocation(DeepstateAddresses.TWO_DEEP_GOVERNOR, DeepstateAddresses.TWO_DEEP);
        vm.setEnv("DGP004_ALLOCATION", vm.toString(address(allocation)));

        uint256 supplyBefore = token.totalSupply();
        uint256 recipientABefore = token.balanceOf(allocation.RECIPIENT_A());
        uint256 recipientBBefore = token.balanceOf(allocation.RECIPIENT_B());
        uint256 recipientCBefore = token.balanceOf(allocation.RECIPIENT_C());

        vm.startPrank(DeepstateAddresses.TWO_DEEP_GOVERNOR);
        token.grantRole(MINTER_ROLE, address(allocation));
        allocation.execute();
        governor.updateQuorumNumerator(4);
        vm.stopPrank();

        uint256 endowmentAmount = Math.mulDiv(allocation.TOTAL_ALLOCATION(), ENDOWMENT_BPS, PRIMARY_BPS);
        assertEq(token.balanceOf(allocation.RECIPIENT_A()) - recipientABefore, allocation.RECIPIENT_A_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_B()) - recipientBBefore, allocation.RECIPIENT_B_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_C()) - recipientCBefore, allocation.RECIPIENT_C_AMOUNT());
        assertEq(token.totalSupply() - supplyBefore, allocation.TOTAL_ALLOCATION() + endowmentAmount);
        new DeployDGP004().verifyPostconditions();
    }

    function testFullGovernorLifecycle() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), FORK_BLOCK + 1);
        assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH);

        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.TWO_DEEP_GOVERNOR);
        IDGP004LiveToken token = IDGP004LiveToken(DeepstateAddresses.TWO_DEEP);
        DGP004TeamAllocation allocation =
            new DGP004TeamAllocation(DeepstateAddresses.TWO_DEEP_GOVERNOR, DeepstateAddresses.TWO_DEEP);
        vm.setEnv("DGP004_ALLOCATION", vm.toString(address(allocation)));
        DeployDGP004 proposal = new DeployDGP004();

        proposal.validateDeployment();
        proposal.validateSubmissionPreconditions();
        assertEq(governor.quorumNumerator(), 10);
        assertFalse(token.hasRole(MINTER_ROLE, address(allocation)));

        // Supply the fork with enough delegated voting weight to exercise the complete Governor lifecycle.
        vm.prank(DeepstateAddresses.TWO_DEEP_GOVERNOR);
        token.grantRole(MINTER_ROLE, address(this));
        token.mint(PROPOSER, VOTE_TOP_UP);
        token.renounceRole(MINTER_ROLE, address(this));

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.prank(PROPOSER);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(proposalId, proposal.expectedProposalId());
        assertEq(proposalId, governor.hashProposal(targets, values, calldatas, descriptionHash));
        assertEq(governor.proposalProposer(proposalId), PROPOSER);
        assertEq(governor.state(proposalId), 0); // Pending.

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        assertEq(governor.state(proposalId), 1); // Active.

        vm.prank(PROPOSER);
        uint256 votingWeight = governor.castVote(proposalId, 1);
        assertGe(votingWeight, governor.quorum(snapshot));

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4); // Succeeded.

        uint256 supplyBefore = token.totalSupply();
        uint256 recipientABefore = token.balanceOf(allocation.RECIPIENT_A());
        uint256 recipientBBefore = token.balanceOf(allocation.RECIPIENT_B());
        uint256 recipientCBefore = token.balanceOf(allocation.RECIPIENT_C());

        proposal.validateExecutionPreconditions();
        governor.execute(targets, values, calldatas, descriptionHash);

        uint256 endowmentAmount = Math.mulDiv(allocation.TOTAL_ALLOCATION(), ENDOWMENT_BPS, PRIMARY_BPS);
        assertEq(governor.state(proposalId), 7); // Executed.
        assertTrue(allocation.executed());
        assertEq(token.balanceOf(allocation.RECIPIENT_A()) - recipientABefore, allocation.RECIPIENT_A_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_B()) - recipientBBefore, allocation.RECIPIENT_B_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_C()) - recipientCBefore, allocation.RECIPIENT_C_AMOUNT());
        assertEq(token.balanceOf(address(allocation)), 0);
        assertEq(token.totalSupply() - supplyBefore, allocation.TOTAL_ALLOCATION() + endowmentAmount);
        assertFalse(token.hasRole(MINTER_ROLE, address(allocation)));
        assertEq(governor.quorumNumerator(), 4);

        proposal.verifyExecution();
    }
}
