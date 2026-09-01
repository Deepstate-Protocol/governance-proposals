// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployDGP002 as DGP002RegistrationScript} from "./proposals/DGP002/Deploy.s.sol";

/// @notice Registers DGP-002 with the live Governor in one transaction.
contract DeployDGP002 is DGP002RegistrationScript {}
