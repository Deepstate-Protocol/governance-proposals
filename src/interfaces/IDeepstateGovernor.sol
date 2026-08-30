// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal interface for the live Deepstate Governor.
interface IDeepstateGovernor {
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external returns (uint256 proposalId);

    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external payable returns (uint256 proposalId);

    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external pure returns (uint256 proposalId);

    function name() external view returns (string memory);

    function token() external view returns (address);

    function governanceStart() external view returns (uint48);

    function clock() external view returns (uint48);

    function getVotes(address account, uint256 timepoint) external view returns (uint256);

    function proposalThreshold() external view returns (uint256);

    function votingDelay() external view returns (uint256);

    function votingPeriod() external view returns (uint256);

    function proposalSnapshot(uint256 proposalId) external view returns (uint256);

    function proposalDeadline(uint256 proposalId) external view returns (uint256);

    function proposalProposer(uint256 proposalId) external view returns (address);

    function proposalNeedsQueuing(uint256 proposalId) external view returns (bool);

    function state(uint256 proposalId) external view returns (uint8);

    function castVote(uint256 proposalId, uint8 support) external returns (uint256 votingWeight);

    function quorum(uint256 timepoint) external view returns (uint256);

    function lateQuorumVoteExtension() external view returns (uint48);

    function quorumNumerator() external view returns (uint256);

    function COUNTING_MODE() external view returns (string memory);

    function CLOCK_MODE() external view returns (string memory);
}
