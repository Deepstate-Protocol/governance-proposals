// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployDGP001 as DGP001RegistrationScript} from "./proposals/DGP001/Deploy.s.sol";

/// @notice Registers DGP-001 with the live Governor in one transaction.
contract DeployDGP001 is DGP001RegistrationScript {}
