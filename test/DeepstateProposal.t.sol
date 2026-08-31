// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeepstateProposalScript} from "../script/DeepstateProposalScript.s.sol";
import {DeepstateAddresses} from "../script/config/DeepstateAddresses.sol";
import {DeepstateProposal} from "../src/DeepstateProposal.sol";

contract MockDeepstateGovernor {
    address internal constant INTENDED_PROPOSER = address(0xA11CE);
    bool internal executed;

    function name() external pure virtual returns (string memory) {
        return "DeepstateGovernor";
    }

    function token() external pure virtual returns (address) {
        return DeepstateAddresses.STATE;
    }

    function clock() external pure virtual returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START + 1;
    }

    function governanceStart() external pure virtual returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START;
    }

    function getVotes(address account, uint256) external pure virtual returns (uint256) {
        return account == INTENDED_PROPOSER ? 100 : 0;
    }

    function proposalThreshold() external pure virtual returns (uint256) {
        return 1;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external pure returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))));
    }

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256) {
        for (uint256 i; i < targets.length; ++i) {
            (bool success,) = targets[i].call{value: values[i]}(calldatas[i]);
            require(success, "mock target call failed");
        }
        executed = true;
        return uint256(keccak256(abi.encode(targets, values, calldatas, descriptionHash)));
    }

    function state(uint256) external view returns (uint8) {
        return executed ? 7 : 4;
    }

    function proposalProposer(uint256) external pure returns (address) {
        return INTENDED_PROPOSER;
    }

    function proposalNeedsQueuing(uint256) external pure returns (bool) {
        return false;
    }
}

contract PreLaunchDeepstateGovernor is MockDeepstateGovernor {
    function clock() external pure override returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START - 1;
    }

    function governanceStart() external pure override returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START;
    }
}

contract WrongNameDeepstateGovernor is MockDeepstateGovernor {
    function name() external pure override returns (string memory) {
        return "NotDeepstateGovernor";
    }
}

contract WrongTokenDeepstateGovernor is MockDeepstateGovernor {
    function token() external pure override returns (address) {
        return address(0xBAD);
    }
}

contract WrongStartDeepstateGovernor is MockDeepstateGovernor {
    function clock() external pure override returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START + 2;
    }

    function governanceStart() external pure override returns (uint48) {
        return DeepstateAddresses.GOVERNANCE_START + 1;
    }
}

contract NoVotesDeepstateGovernor is MockDeepstateGovernor {
    function getVotes(address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract ExampleProposalScript is DeepstateProposalScript {
    function proposer() public pure override returns (address) {
        return address(0xA11CE);
    }

    function expectedProposalId() public pure virtual override returns (uint256) {
        return 42_933_848_326_670_478_547_975_520_619_579_703_125_726_508_755_421_632_450_240_601_108_929_549_205_830;
    }

    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        targets[0] = address(0xBEEF);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setValue(uint256)", 42);
        description = "# Test proposal";
    }
}

contract UnpinnedExampleProposalScript is ExampleProposalScript {
    function expectedProposalId() public pure override returns (uint256) {
        return 0;
    }
}

contract DriftedExampleProposalScript is ExampleProposalScript {
    function expectedProposalId() public pure override returns (uint256) {
        return 1;
    }
}

contract GatedExampleProposalScript is ExampleProposalScript {
    bool public rejectSubmission;
    bool public rejectExecution;

    error SubmissionPreconditionFailed();
    error ExecutionPreconditionFailed();

    function setRejectSubmission(bool value) external {
        rejectSubmission = value;
    }

    function setRejectExecution(bool value) external {
        rejectExecution = value;
    }

    function _beforeSubmission() internal view override {
        if (rejectSubmission) revert SubmissionPreconditionFailed();
    }

    function _beforeExecution() internal view override {
        if (rejectExecution) revert ExecutionPreconditionFailed();
    }
}

contract ValueProposalScript is DeepstateProposalScript {
    function proposer() public pure override returns (address) {
        return address(0xA11CE);
    }

    function expectedProposalId() public pure override returns (uint256) {
        return 93_141_880_376_380_026_722_201_728_731_420_581_975_159_239_255_467_203_652_118_192_842_912_412_162_973;
    }

    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](2);
        targets[0] = address(0xCAFE);
        targets[1] = address(0xD00D);

        values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 2 ether;

        calldatas = new bytes[](2);
        description = "# Value proposal";
    }
}

abstract contract TestProposal is DeepstateProposal {
    function proposer() public pure virtual override returns (address) {
        return address(0xA11CE);
    }
}

contract EmptyProposal is TestProposal {
    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](0);
        values = new uint256[](0);
        calldatas = new bytes[](0);
        description = "# Empty";
    }
}

contract MismatchedProposal is TestProposal {
    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        targets[0] = address(1);
        values = new uint256[](0);
        calldatas = new bytes[](1);
        description = "# Mismatched";
    }
}

contract UndescribedProposal is TestProposal {
    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        targets[0] = address(1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        description = "";
    }
}

contract ZeroTargetProposal is TestProposal {
    function _buildProposal()
        internal
        pure
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](1);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        description = "# Zero target";
    }
}

contract ZeroProposerProposal is ZeroTargetProposal {
    function proposer() public pure override returns (address) {
        return address(0);
    }
}

contract DeepstateProposalTest is Test {
    ExampleProposalScript internal proposalScript;

    function setUp() public {
        proposalScript = new ExampleProposalScript();
    }

    function testBuildsDeterministicProposalId() public view {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposalScript.proposal();

        uint256 expected = uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))));
        assertEq(proposalScript.proposalId(), expected);
        assertEq(proposalScript.proposalId(), proposalScript.expectedProposalId());
    }

    function testDescriptionEndsWithExactProposerRestriction() public view {
        (,,, string memory description) = proposalScript.proposal();
        assertEq(description, "# Test proposal\n\n#proposer=0x00000000000000000000000000000000000a11ce");
    }

    function testRejectsEmptyProposal() public {
        EmptyProposal invalidProposal = new EmptyProposal();
        vm.expectRevert(DeepstateProposal.EmptyProposal.selector);
        invalidProposal.proposal();
    }

    function testRejectsMismatchedArrays() public {
        MismatchedProposal invalidProposal = new MismatchedProposal();
        vm.expectRevert(abi.encodeWithSelector(DeepstateProposal.ProposalLengthMismatch.selector, 1, 0, 1));
        invalidProposal.proposal();
    }

    function testRejectsEmptyDescription() public {
        UndescribedProposal invalidProposal = new UndescribedProposal();
        vm.expectRevert(DeepstateProposal.EmptyDescription.selector);
        invalidProposal.proposal();
    }

    function testRejectsZeroTarget() public {
        ZeroTargetProposal invalidProposal = new ZeroTargetProposal();
        vm.expectRevert(abi.encodeWithSelector(DeepstateProposal.ZeroTarget.selector, 0));
        invalidProposal.proposal();
    }

    function testRejectsZeroProposer() public {
        ZeroProposerProposal invalidProposal = new ZeroProposerProposal();
        vm.expectRevert(DeepstateProposal.ZeroProposer.selector);
        invalidProposal.proposal();
    }

    function testRejectsUnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.UnsupportedChain.selector, uint256(1), DeepstateAddresses.CHAIN_ID
            )
        );
        proposalScript.validateDeployment();
    }

    function testRejectsMissingGovernorCode() public {
        vm.chainId(DeepstateAddresses.CHAIN_ID);
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateProposalScript.MissingGovernorCode.selector, DeepstateAddresses.GOVERNOR)
        );
        proposalScript.validateDeployment();
    }

    function testRejectsUnexpectedGovernorName() public {
        _installGovernor(address(new WrongNameDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(DeepstateProposalScript.UnexpectedGovernorName.selector, "NotDeepstateGovernor")
        );
        proposalScript.validateDeployment();
    }

    function testRejectsUnexpectedVotingToken() public {
        _installGovernor(address(new WrongTokenDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.UnexpectedVotingToken.selector, address(0xBAD), DeepstateAddresses.STATE
            )
        );
        proposalScript.validateDeployment();
    }

    function testRejectsUnexpectedGovernanceStart() public {
        _installGovernor(address(new WrongStartDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.UnexpectedGovernanceStart.selector,
                DeepstateAddresses.GOVERNANCE_START + 1,
                DeepstateAddresses.GOVERNANCE_START
            )
        );
        proposalScript.validateDeployment();
    }

    function testRejectsSubmissionBeforeGovernanceStarts() public {
        _installGovernor(address(new PreLaunchDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.GovernanceNotStarted.selector,
                DeepstateAddresses.GOVERNANCE_START - 1,
                DeepstateAddresses.GOVERNANCE_START
            )
        );
        proposalScript.validateDeployment();
    }

    function testRejectsUnpinnedProposal() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        UnpinnedExampleProposalScript unpinnedProposal = new UnpinnedExampleProposalScript();
        vm.expectRevert(DeepstateProposalScript.UnpinnedProposalId.selector);
        unpinnedProposal.run();
    }

    function testRejectsProposalIdDrift() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        DriftedExampleProposalScript driftedProposal = new DriftedExampleProposalScript();
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.ProposalIdMismatch.selector, proposalScript.proposalId(), uint256(1)
            )
        );
        driftedProposal.run();
    }

    function testRejectsInsufficientProposerVotes() public {
        _installGovernor(address(new NoVotesDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.InsufficientProposerVotes.selector, address(0xA11CE), uint256(0), uint256(1)
            )
        );
        proposalScript.run();
    }

    function testSubmitsToValidatedLiveAddress() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        assertEq(proposalScript.run(), proposalScript.proposalId());
    }

    function testProposalSpecificPreconditionsGateSubmissionAndExecution() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        GatedExampleProposalScript gatedProposal = new GatedExampleProposalScript();

        gatedProposal.setRejectSubmission(true);
        vm.expectRevert(GatedExampleProposalScript.SubmissionPreconditionFailed.selector);
        gatedProposal.run();

        gatedProposal.setRejectSubmission(false);
        assertEq(gatedProposal.run(), gatedProposal.proposalId());

        gatedProposal.setRejectExecution(true);
        vm.expectRevert(GatedExampleProposalScript.ExecutionPreconditionFailed.selector);
        gatedProposal.execute();

        gatedProposal.setRejectExecution(false);
        assertEq(gatedProposal.execute(), gatedProposal.proposalId());
    }

    function testVerifiesRegisteredProposal() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        (uint256 registeredProposalId, uint8 currentState) = proposalScript.verifySubmission();
        assertEq(registeredProposalId, proposalScript.proposalId());
        assertEq(currentState, 4);
    }

    function testRejectsExecutionVerificationBeforeExecution() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepstateProposalScript.InvalidExecutionState.selector, proposalScript.proposalId(), uint8(4)
            )
        );
        proposalScript.verifyExecution();
    }

    function testExecutesSucceededProposal() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        assertEq(proposalScript.execute(), proposalScript.proposalId());
        assertEq(proposalScript.verifyExecution(), proposalScript.proposalId());
    }

    function testExecutionForwardsValuesAndPreservesGovernorBalance() public {
        _installGovernor(address(new MockDeepstateGovernor()));
        ValueProposalScript valueProposal = new ValueProposalScript();

        address firstReceiver = address(0xCAFE);
        address secondReceiver = address(0xD00D);
        uint256 governorBalance = 5 ether;
        uint256 firstBalance = 7 ether;
        uint256 secondBalance = 11 ether;
        vm.deal(DeepstateAddresses.GOVERNOR, governorBalance);
        vm.deal(firstReceiver, firstBalance);
        vm.deal(secondReceiver, secondBalance);
        vm.deal(DEFAULT_SENDER, 3 ether);

        assertEq(valueProposal.execute(), valueProposal.proposalId());
        assertEq(firstReceiver.balance, firstBalance + 1 ether);
        assertEq(secondReceiver.balance, secondBalance + 2 ether);
        assertEq(DeepstateAddresses.GOVERNOR.balance, governorBalance);
    }

    function _installGovernor(address implementation) private {
        vm.chainId(DeepstateAddresses.CHAIN_ID);
        vm.etch(DeepstateAddresses.GOVERNOR, implementation.code);
    }
}
