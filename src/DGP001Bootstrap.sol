// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {IDeepstateLegacyRewarder} from "./interfaces/IDeepstateLegacyRewarder.sol";

/// @title DGP-001 Bootstrap
/// @notice Freezes 30% of the legacy Rewarder's recorded emissions at deployment for a one-off governance mint.
/// @dev The Governor proposal temporarily grants this contract DEEP's minter role, calls `mint`, and revokes the role
/// in the same atomic execution. All subsequent endowment and protocol operations belong directly in that multicall.
contract DGP001Bootstrap {
    address public immutable governor;
    DeepstateToken public immutable deepstateToken;
    /// @notice The one-off amount frozen from legacy accrual when this contract is deployed.
    /// @dev Constructor-only storage keeps the runtime bytecode hash independent of deployment-time accrual.
    uint128 public endowmentAmount;

    error Unauthorized(address caller);

    constructor(address governor_, address deepstateToken_, address legacyRewarder_) {
        IDeepstateLegacyRewarder rewarder = IDeepstateLegacyRewarder(legacyRewarder_);
        uint256 totalAccrued =
            uint256(rewarder.totalAccrued(rewarder.token0())) + uint256(rewarder.totalAccrued(rewarder.token1()));

        governor = governor_;
        deepstateToken = DeepstateToken(deepstateToken_);
        // Each accrued value is uint96, so 30% of their sum always fits uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        endowmentAmount = uint128(totalAccrued * 30 / 100);
    }

    /// @notice Mint the deployment-time endowment amount directly to the Governor for use by its atomic proposal.
    function mint() external {
        if (msg.sender != governor) revert Unauthorized(msg.sender);
        deepstateToken.mint(governor, endowmentAmount);
    }
}
