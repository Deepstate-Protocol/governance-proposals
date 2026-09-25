// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeepstateProposalScript} from "../../DeepstateProposalScript.s.sol";
import {DeepstateAddresses} from "../../config/DeepstateAddresses.sol";
import {DGP004TeamAllocation} from "../../../src/DGP004TeamAllocation.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";

contract DeployDGP004 is DeepstateProposalScript {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    address public constant PROPOSER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    uint256 public constant NEW_QUORUM_NUMERATOR = 4;
    uint256 public constant OLD_QUORUM_NUMERATOR = 10;
    address public immutable ALLOCATION = vm.envAddress("DGP004_ALLOCATION");

    error PreconditionFailed(uint256 condition);
    error PostconditionFailed(uint256 condition);

    function proposer() public pure override returns (address) {
        return PROPOSER;
    }

    function expectedProposalId() public view override returns (uint256) {
        return proposalId();
    }

    function governorAddress() public pure override returns (address) {
        return DeepstateAddresses.TWO_DEEP_GOVERNOR;
    }

    function votingTokenAddress() public pure override returns (address) {
        return DeepstateAddresses.TWO_DEEP;
    }

    function expectedGovernanceStart() public pure override returns (uint48) {
        return DeepstateAddresses.TWO_DEEP_GOVERNANCE_START;
    }

    function validateSubmissionPreconditions() external view {
        _validateSubmissionPreconditions();
    }

    function validateExecutionPreconditions() external view {
        _validateExecutionPreconditions();
    }

    function verifyPostconditions() external view {
        _afterExecution();
    }

    function _buildProposal()
        internal
        view
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](3);
        values = new uint256[](3);
        calldatas = new bytes[](3);
        targets[0] = DeepstateAddresses.TWO_DEEP;
        calldatas[0] = abi.encodeCall(IAccessControl.grantRole, (MINTER_ROLE, ALLOCATION));
        targets[1] = ALLOCATION;
        calldatas[1] = abi.encodeCall(DGP004TeamAllocation.execute, ());
        targets[2] = DeepstateAddresses.TWO_DEEP_GOVERNOR;
        calldatas[2] = abi.encodeCall(IDeepstateGovernor.updateQuorumNumerator, (NEW_QUORUM_NUMERATOR));
        description = vm.readFile("proposals/DGP-004.md");
    }

    function _beforeSubmission() internal view override {
        _validateSubmissionPreconditions();
    }

    function _beforeExecution() internal view override {
        _validateExecutionPreconditions();
    }

    function _afterExecution() internal view override {
        DGP004TeamAllocation allocation = DGP004TeamAllocation(ALLOCATION);
        address target = allocation.token();
        _post(allocation.executed(), 1);
        _post(target != address(0), 2);
        _post(!IAccessControl(target).hasRole(allocation.MINTER_ROLE(), ALLOCATION), 3);
        _post(IERC20(target).balanceOf(allocation.RECIPIENT_A()) >= allocation.RECIPIENT_A_AMOUNT(), 4);
        _post(IERC20(target).balanceOf(allocation.RECIPIENT_B()) >= allocation.RECIPIENT_B_AMOUNT(), 5);
        _post(IERC20(target).balanceOf(allocation.RECIPIENT_C()) >= allocation.RECIPIENT_C_AMOUNT(), 6);
        _post(IDeepstateGovernor(DeepstateAddresses.TWO_DEEP_GOVERNOR).quorumNumerator() == NEW_QUORUM_NUMERATOR, 7);
    }

    function _validateSubmissionPreconditions() private view {
        DGP004TeamAllocation allocation = DGP004TeamAllocation(ALLOCATION);
        _pre(ALLOCATION.code.length != 0, 1);
        _pre(allocation.governor() == DeepstateAddresses.TWO_DEEP_GOVERNOR, 2);
        _pre(allocation.token() == DeepstateAddresses.TWO_DEEP, 3);
        _pre(!allocation.executed(), 4);
        _pre(IDeepstateGovernor(DeepstateAddresses.TWO_DEEP_GOVERNOR).quorumNumerator() == OLD_QUORUM_NUMERATOR, 5);
        _pre(IAccessControl(DeepstateAddresses.TWO_DEEP).hasRole(bytes32(0), DeepstateAddresses.TWO_DEEP_GOVERNOR), 6);
    }

    function _validateExecutionPreconditions() private view {
        DGP004TeamAllocation allocation = DGP004TeamAllocation(ALLOCATION);
        _pre(!allocation.executed(), 7);
        _pre(!IAccessControl(DeepstateAddresses.TWO_DEEP).hasRole(allocation.MINTER_ROLE(), ALLOCATION), 8);
        _pre(IDeepstateGovernor(DeepstateAddresses.TWO_DEEP_GOVERNOR).quorumNumerator() == OLD_QUORUM_NUMERATOR, 9);
    }

    function _pre(bool condition, uint256 number) private pure {
        if (!condition) revert PreconditionFailed(number);
    }

    function _post(bool condition, uint256 number) private pure {
        if (!condition) revert PostconditionFailed(number);
    }
}
