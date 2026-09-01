// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DeepstateController} from "./DeepstateController.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @title Deepstate Minter Controller
/// @notice Adds `floor(primary amount * 30 / 70)` to every authorized DEEP mint for a vesting recipient.
/// @dev The recipient allocation is placed in a new non-cancelable, non-transferable Sablier
/// Lockup v4 linear stream. This contract temporarily administers and mints DEEP during an exact two-year window
/// while remaining owned by governance.
contract DeepstateMinterController is DeepstateController, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant MINTER_ROLE = 1 << 0;
    uint256 public constant RECIPIENT_ALLOCATION_BPS = 30_00;
    uint256 public constant PRIMARY_ALLOCATION_BPS = 70_00;
    uint40 public constant VESTING_DURATION = 365 days;
    uint40 public constant TOKEN_ADMINISTRATION_DURATION = 2 * 365 days;

    DeepstateToken public immutable deepstateToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    address public immutable recipient;
    /// @notice Maximum live DEEP supply permitted after an authorized mint.
    uint256 public immutable maxSupply;

    /// @notice Administration deadline, zero before locking, and uint40 max after permanent return.
    uint40 public tokenAdministrationEndsAt;

    event MintedWithVesting(
        address indexed caller,
        address indexed mintRecipient,
        uint256 mintAmount,
        address indexed vestingRecipient,
        uint256 vestingAmount,
        uint256 streamId
    );
    event TokenAdministrationActivated(uint40 indexed endsAt);
    event TokenAdministrationReturned(address indexed owner, address indexed caller);

    error InvalidDeepstateToken();
    error InvalidSablierLockup();
    error InvalidRecipient();
    error ControllerNotTokenAdmin();
    error ControllerNotSoleTokenAdmin(uint256 adminCount);
    error ControllerAlreadyTokenMinter();
    error TokenAdministrationAlreadyActivated();
    error TokenAdministrationAlreadyReturned();
    error TokenAdministrationNotActive();
    error TokenAdministrationActive(uint40 endsAt);
    error TokenAdministrationExpired(uint40 endsAt);
    error MaxSupplyExceeded(uint256 maxSupply, uint256 attemptedSupply);

    constructor(address owner_, address deepstateToken_, address sablierLockup_, address recipient_, uint256 maxSupply_)
        DeepstateController(owner_)
    {
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) {
            revert InvalidDeepstateToken();
        }
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        if (recipient_ == address(0)) revert InvalidRecipient();

        deepstateToken = DeepstateToken(deepstateToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        recipient = recipient_;
        maxSupply = maxSupply_;
    }

    /// @notice Activate the reusable 730-day token-administration and controlled-minting term.
    function activateTokenAdministration() external onlyOwner nonReentrant {
        if (tokenAdministrationEndsAt != 0) revert TokenAdministrationAlreadyActivated();

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();
        uint256 adminCount = deepstateToken.defaultAdminCount();
        if (adminCount != 1) revert ControllerNotSoleTokenAdmin(adminCount);

        bytes32 tokenMinterRole = deepstateToken.MINTER_ROLE();
        if (deepstateToken.hasRole(tokenMinterRole, address(this))) revert ControllerAlreadyTokenMinter();
        deepstateToken.grantRole(tokenMinterRole, address(this));

        uint40 endsAt = SafeCastLib.toUint40(block.timestamp + TOKEN_ADMINISTRATION_DURATION);
        tokenAdministrationEndsAt = endsAt;
        emit TokenAdministrationActivated(endsAt);
    }

    /// @notice Unlock DEEP administration to this contract's current governance owner after the term expires.
    /// @dev Anyone may trigger the unlock at or after the exact deadline. The controller's token-level minter role is
    /// revoked before it relinquishes token administration.
    function unlockTokenAdministration() external nonReentrant {
        uint40 endsAt = tokenAdministrationEndsAt;
        if (endsAt == 0) revert TokenAdministrationNotActive();
        if (endsAt == type(uint40).max) revert TokenAdministrationAlreadyReturned();

        address owner_ = owner();
        if (block.timestamp < endsAt) revert TokenAdministrationActive(endsAt);

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();

        tokenAdministrationEndsAt = type(uint40).max;
        // Grant first so DeepstateToken's final-admin invariant cannot strand the token.
        deepstateToken.grantRole(tokenAdminRole, owner_);
        deepstateToken.revokeRole(deepstateToken.MINTER_ROLE(), address(this));
        deepstateToken.renounceRole(tokenAdminRole, address(this));

        emit TokenAdministrationReturned(owner_, msg.sender);
    }

    /// @notice During the active administration term, mint `amount` to `to` and vest the corresponding allocation.
    /// @dev The vested amount is `floor(amount * 30 / 70)`. The pinned Sablier rejects a zero deposit. Minting is
    /// permitted only after administration is locked and strictly before its deadline.
    function mint(address to, uint256 amount)
        external
        onlyOwnerOrRoles(MINTER_ROLE)
        nonReentrant
        returns (uint256 streamId)
    {
        uint40 endsAt = tokenAdministrationEndsAt;
        if (endsAt == 0 || endsAt == type(uint40).max) revert TokenAdministrationNotActive();
        if (block.timestamp >= endsAt) revert TokenAdministrationExpired(endsAt);

        uint256 vestingAmount = FixedPointMathLib.fullMulDiv(amount, RECIPIENT_ALLOCATION_BPS, PRIMARY_ALLOCATION_BPS);
        uint256 attemptedSupply = deepstateToken.totalSupply() + amount + vestingAmount;
        if (attemptedSupply > maxSupply) revert MaxSupplyExceeded(maxSupply, attemptedSupply);
        uint128 streamAmount = SafeCastLib.toUint128(vestingAmount);

        deepstateToken.mint(to, amount);
        deepstateToken.mint(address(this), vestingAmount);

        address(deepstateToken).safeApproveWithRetry(address(sablierLockup), vestingAmount);
        streamId = sablierLockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: address(this),
                recipient: recipient,
                depositAmount: streamAmount,
                token: IERC20(address(deepstateToken)),
                cancelable: false,
                transferable: false,
                shape: "Deepstate allocation"
            }),
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            0,
            LockupLinear.Durations({cliff: 0, total: VESTING_DURATION})
        );

        emit MintedWithVesting(msg.sender, to, amount, recipient, vestingAmount, streamId);
    }
}
