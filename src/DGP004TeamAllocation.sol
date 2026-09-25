// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDGP004MintableToken is IERC20, IAccessControl {
    function mint(address to, uint256 amount) external;
}

/// @notice One-use DGP-004 allocation of the canonical 2DEEP token.
contract DGP004TeamAllocation {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public constant RECIPIENT_A = 0x1fb3A8192d00aDe0ddC0EEcB4D872149Eb9C4157;
    address public constant RECIPIENT_B = 0x5715d61f99487abD65D1091b5d3a46c1b2879355;
    address public constant RECIPIENT_C = 0xAF297Fcb531Ab662D9c2076f597D1bD424C7d2dd;

    uint256 public constant RECIPIENT_A_AMOUNT = 3_333_333_333333333333333334;
    uint256 public constant RECIPIENT_B_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant RECIPIENT_C_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant TOTAL_ALLOCATION = 10_000_000e18;

    address public immutable governor;
    address public immutable token;

    bool public executed;

    event AllocationExecuted(address indexed token, uint256 totalAllocation);

    error AlreadyExecuted();
    error OnlyGovernor();

    constructor(address governor_, address token_) {
        governor = governor_;
        token = token_;
    }

    /// @notice Mint and distribute the exact DGP-004 allocation, then permanently surrender mint authority.
    function execute() external {
        if (msg.sender != governor) revert OnlyGovernor();
        if (executed) revert AlreadyExecuted();

        executed = true;
        IDGP004MintableToken mintToken = IDGP004MintableToken(token);
        mintToken.mint(address(this), TOTAL_ALLOCATION);

        IERC20(token).safeTransfer(RECIPIENT_A, RECIPIENT_A_AMOUNT);
        IERC20(token).safeTransfer(RECIPIENT_B, RECIPIENT_B_AMOUNT);
        IERC20(token).safeTransfer(RECIPIENT_C, RECIPIENT_C_AMOUNT);

        mintToken.renounceRole(MINTER_ROLE, address(this));
        emit AllocationExecuted(token, TOTAL_ALLOCATION);
    }
}
