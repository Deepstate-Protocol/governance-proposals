// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeepstateAddresses} from "../src/DeepstateAddresses.sol";
import {DeepstateProposal} from "../src/DeepstateProposal.sol";
import {IDeepstateGovernor} from "../src/interfaces/IDeepstateGovernor.sol";

/// @notice Safe submission entrypoint inherited by each proposal-specific deployment script.
abstract contract DeepstateProposalScript is Script, DeepstateProposal {
    error GovernanceNotStarted(uint48 currentTimepoint, uint48 governanceStart);
    error GovernorIdentityCallFailed(bytes4 selector);
    error InsufficientProposerVotes(address proposer, uint256 votes, uint256 threshold);
    error InvalidExecutionState(uint256 proposalId, uint8 currentState);
    error MissingGovernorCode(address governor);
    error ProposalIdMismatch(uint256 generatedProposalId, uint256 expectedProposalId);
    error ProposalNotRegistered(uint256 proposalId);
    error ProposalNotSucceeded(uint256 proposalId, uint8 currentState);
    error ProposalRequiresQueuing(uint256 proposalId);
    error RegisteredProposerMismatch(address registeredProposer, address expectedProposer);
    error UnexpectedGovernanceStart(uint48 actualGovernanceStart, uint48 expectedGovernanceStart);
    error UnexpectedGovernorName(string actualName);
    error UnexpectedVotingToken(address actualToken, address expectedToken);
    error UnpinnedProposalId();
    error UnsupportedChain(uint256 actualChainId, uint256 expectedChainId);

    bytes32 private constant _EXPECTED_GOVERNOR_NAME_HASH = keccak256("DeepstateGovernor");
    uint8 private constant _PROPOSAL_STATE_EXECUTED = 7;
    uint8 private constant _PROPOSAL_STATE_SUCCEEDED = 4;

    /// @notice Validates the live deployment, then submits the exact proposal payload.
    function run() public returns (uint256 submittedProposalId) {
        IDeepstateGovernor governor = _validatedGovernor();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal();
        uint256 pinnedProposalId = _validatedProposalId(_proposalId(targets, values, calldatas, description));
        _validateProposerVotes(governor);

        vm.startBroadcast();
        submittedProposalId = governor.propose(targets, values, calldatas, description);
        vm.stopBroadcast();

        assert(submittedProposalId == pinnedProposalId);
        assert(governor.proposalProposer(submittedProposalId) == proposer());
        console2.log("Deepstate proposal submitted");
        console2.log("Proposal ID", submittedProposalId);
    }

    /// @notice Executes the exact pinned payload after it reaches the Succeeded state.
    /// @dev The caller supplies the sum of action values; the Governor's preexisting ETH balance is preserved.
    function execute() public returns (uint256 executedProposalId) {
        IDeepstateGovernor governor = _validatedGovernor();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal();
        uint256 pinnedProposalId = _validatedProposalId(_proposalId(targets, values, calldatas, description));
        uint8 currentState = _verifiedProposal(governor, pinnedProposalId);
        if (currentState != _PROPOSAL_STATE_SUCCEEDED) {
            revert ProposalNotSucceeded(pinnedProposalId, currentState);
        }
        if (governor.proposalNeedsQueuing(pinnedProposalId)) revert ProposalRequiresQueuing(pinnedProposalId);

        uint256 executionValue;
        for (uint256 i; i < values.length; ++i) {
            executionValue += values[i];
        }

        vm.startBroadcast();
        executedProposalId =
            governor.execute{value: executionValue}(targets, values, calldatas, keccak256(bytes(description)));
        vm.stopBroadcast();

        assert(executedProposalId == pinnedProposalId);
        uint8 executedState = governor.state(executedProposalId);
        if (executedState != _PROPOSAL_STATE_EXECUTED) {
            revert InvalidExecutionState(executedProposalId, executedState);
        }
        _afterExecution();
        console2.log("Deepstate proposal executed");
        console2.log("Proposal ID", executedProposalId);
    }

    /// @notice Verifies that the pinned proposal exists onchain and was registered by its intended proposer.
    function verifySubmission() public view returns (uint256 pinnedProposalId, uint8 currentState) {
        IDeepstateGovernor governor = _validatedGovernor();
        pinnedProposalId = _validatedProposalId(proposalId());
        currentState = _verifiedProposal(governor, pinnedProposalId);
    }

    /// @notice Reopens the executed proposal over RPC and verifies its durable live postconditions.
    function verifyExecution() public view returns (uint256 pinnedProposalId) {
        IDeepstateGovernor governor = _validatedGovernor();
        pinnedProposalId = _validatedProposalId(proposalId());
        uint8 currentState = _verifiedProposal(governor, pinnedProposalId);
        if (currentState != _PROPOSAL_STATE_EXECUTED) {
            revert InvalidExecutionState(pinnedProposalId, currentState);
        }
        if (governor.proposalNeedsQueuing(pinnedProposalId)) revert ProposalRequiresQueuing(pinnedProposalId);

        _afterExecution();
        console2.log("Verified executed proposal ID", pinnedProposalId);
    }

    /// @notice Logs the generated ID before it is copied into `expectedProposalId()` for release pinning.
    function printProposal() public view returns (uint256 generatedProposalId) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal();
        generatedProposalId = _proposalId(targets, values, calldatas, description);
        console2.log("Generated proposal ID", generatedProposalId);
        console2.log("Final description hash");
        console2.logBytes32(keccak256(bytes(description)));
        console2.log("Intended proposer", proposer());
    }

    /// @notice Returns the proposal ID reviewed and pinned in the concrete proposal script.
    function expectedProposalId() public pure virtual returns (uint256);

    /// @dev Override to add proposal-specific live postcondition checks after execution.
    function _afterExecution() internal view virtual {}

    /// @notice Performs read-only identity and launch checks against the configured live Governor.
    function validateDeployment() public view returns (IDeepstateGovernor governor) {
        return _validatedGovernor();
    }

    function _validatedGovernor() internal view returns (IDeepstateGovernor governor) {
        uint256 expectedChainId = DeepstateAddresses.CHAIN_ID;
        if (block.chainid != expectedChainId) revert UnsupportedChain(block.chainid, expectedChainId);

        address governorAddress = DeepstateAddresses.GOVERNOR;
        if (governorAddress.code.length == 0) revert MissingGovernorCode(governorAddress);
        governor = IDeepstateGovernor(governorAddress);

        string memory actualName;
        try governor.name() returns (string memory returnedName) {
            actualName = returnedName;
        } catch {
            revert GovernorIdentityCallFailed(IDeepstateGovernor.name.selector);
        }
        if (keccak256(bytes(actualName)) != _EXPECTED_GOVERNOR_NAME_HASH) {
            revert UnexpectedGovernorName(actualName);
        }

        address actualToken;
        try governor.token() returns (address returnedToken) {
            actualToken = returnedToken;
        } catch {
            revert GovernorIdentityCallFailed(IDeepstateGovernor.token.selector);
        }
        address expectedToken = DeepstateAddresses.STATE;
        if (actualToken != expectedToken) revert UnexpectedVotingToken(actualToken, expectedToken);

        uint48 currentTimepoint;
        uint48 start;
        try governor.clock() returns (uint48 returnedTimepoint) {
            currentTimepoint = returnedTimepoint;
        } catch {
            revert GovernorIdentityCallFailed(IDeepstateGovernor.clock.selector);
        }
        try governor.governanceStart() returns (uint48 returnedStart) {
            start = returnedStart;
        } catch {
            revert GovernorIdentityCallFailed(IDeepstateGovernor.governanceStart.selector);
        }
        uint48 expectedStart = DeepstateAddresses.GOVERNANCE_START;
        if (start != expectedStart) revert UnexpectedGovernanceStart(start, expectedStart);
        if (currentTimepoint < start) revert GovernanceNotStarted(currentTimepoint, start);
    }

    function _validatedProposalId(uint256 generatedProposalId) internal pure returns (uint256) {
        uint256 expected = expectedProposalId();
        if (expected == 0) revert UnpinnedProposalId();
        if (generatedProposalId != expected) revert ProposalIdMismatch(generatedProposalId, expected);
        return generatedProposalId;
    }

    function _validateProposerVotes(IDeepstateGovernor governor) private view {
        address intendedProposer = proposer();
        uint48 currentTimepoint = governor.clock();
        uint256 threshold = governor.proposalThreshold();
        uint256 votes = governor.getVotes(intendedProposer, currentTimepoint - 1);
        if (votes < threshold) revert InsufficientProposerVotes(intendedProposer, votes, threshold);
    }

    function _verifiedProposal(IDeepstateGovernor governor, uint256 pinnedProposalId)
        private
        view
        returns (uint8 currentState)
    {
        try governor.state(pinnedProposalId) returns (uint8 returnedState) {
            currentState = returnedState;
        } catch {
            revert ProposalNotRegistered(pinnedProposalId);
        }

        address expectedProposer = proposer();
        address registeredProposer = governor.proposalProposer(pinnedProposalId);
        if (registeredProposer != expectedProposer) {
            revert RegisteredProposerMismatch(registeredProposer, expectedProposer);
        }

        console2.log("Verified proposal ID", pinnedProposalId);
        console2.log("Proposal state", uint256(currentState));
    }
}
