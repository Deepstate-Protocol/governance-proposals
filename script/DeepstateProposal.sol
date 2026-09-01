// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Deterministic action and description builder shared by every Deepstate governance proposal.
abstract contract DeepstateProposal {
    error EmptyProposal();
    error EmptyDescription();
    error ProposalLengthMismatch(uint256 targetsLength, uint256 valuesLength, uint256 calldatasLength);
    error ZeroProposer();
    error ZeroTarget(uint256 actionIndex);

    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    /// @notice Returns the exact payload that will be submitted to the Governor.
    function proposal()
        public
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        (targets, values, calldatas, description) = _buildProposal();
        if (bytes(description).length == 0) revert EmptyDescription();

        address intendedProposer = proposer();
        if (intendedProposer == address(0)) revert ZeroProposer();
        description = string.concat(description, "\n\n#proposer=", _toHexString(intendedProposer));

        _validateProposal(targets, values, calldatas);
    }

    /// @notice Returns the OpenZeppelin Governor identifier for the exact proposal payload.
    function proposalId() public view returns (uint256) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal();
        return _proposalId(targets, values, calldatas, description);
    }

    /// @notice Returns the only address authorized by the description suffix to submit this proposal.
    function proposer() public pure virtual returns (address);

    /// @dev Implemented once by each proposal-specific deployment script.
    function _buildProposal()
        internal
        view
        virtual
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description);

    function _validateProposal(address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
        internal
        pure
    {
        uint256 actionCount = targets.length;
        if (actionCount == 0) revert EmptyProposal();
        if (actionCount != values.length || actionCount != calldatas.length) {
            revert ProposalLengthMismatch(actionCount, values.length, calldatas.length);
        }
        for (uint256 i; i < actionCount; ++i) {
            if (targets[i] == address(0)) revert ZeroTarget(i);
        }
    }

    function _proposalId(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description)))));
    }

    function _toHexString(address account) private pure returns (string memory) {
        bytes20 value = bytes20(account);
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";

        for (uint256 i; i < value.length; ++i) {
            uint8 currentByte = uint8(value[i]);
            buffer[2 + i * 2] = _HEX_SYMBOLS[currentByte >> 4];
            buffer[3 + i * 2] = _HEX_SYMBOLS[currentByte & 0x0f];
        }

        return string(buffer);
    }
}
