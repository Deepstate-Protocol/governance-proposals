// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";

/// @title Deepstate Controller
/// @notice Shared governance ownership and delegated-role authority for protocol controllers.
abstract contract DeepstateController is OwnableRoles {
    error InvalidOwner();

    constructor(address owner_) {
        if (owner_ == address(0)) revert InvalidOwner();
        _initializeOwner(owner_);
    }

    /// @notice Controller ownership cannot be renounced.
    function renounceOwnership() public payable virtual override onlyOwner {
        revert NewOwnerIsZeroAddress();
    }

    /// @dev A controller cannot exercise owner-only recovery paths on itself, so self-ownership would be permanent.
    function _setOwner(address newOwner) internal virtual override {
        if (newOwner == address(this)) revert InvalidOwner();
        super._setOwner(newOwner);
    }
}
