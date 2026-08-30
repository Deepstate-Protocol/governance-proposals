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
import {IDeepstateLegacyRewarder} from "./interfaces/IDeepstateLegacyRewarder.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

/// @dev Narrow read-only Router surface used to prove the legacy market is quiescent before activation.
interface IDeepstateLegacyRouterView {
    function poolHook(bytes32 poolId) external view returns (address);
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

/// @title Deepstate Minter Controller
/// @notice Allocates 30% of every authorized DEEP issuance to a vesting recipient.
/// @dev The recipient allocation is placed in a new non-cancelable, non-transferable Sablier
/// Lockup v4 linear stream. This contract temporarily administers and mints DEEP during an exact two-year window
/// while remaining owned by governance.
contract DeepstateMinterController is DeepstateController, ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant MINTER_ROLE = 1 << 0;
    uint256 public constant RECIPIENT_ALLOCATION_BPS = 30_00;
    uint256 public constant PRIMARY_ALLOCATION_BPS = 70_00;
    /// @notice Smallest combined primary-plus-vesting issuance accepted by `mint`.
    /// @dev A primary amount of 3 base units produces the first nonzero vesting amount (1 base unit).
    uint256 public constant MINIMUM_COMBINED_ISSUANCE = 4;
    uint40 public constant VESTING_DURATION = 365 days;
    uint40 public constant TOKEN_ADMINISTRATION_DURATION = 2 * 365 days;

    DeepstateToken public immutable deepstateToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    IDeepstateLegacyRewarder public immutable legacyRewarder;
    address public immutable recipient;
    /// @notice Maximum live DEEP supply this controller will permit after a mint.
    uint256 public immutable mintCap;
    /// @notice Maximum gross DEEP issuance this controller can ever create, regardless of subsequent burns.
    uint256 public immutable grossIssuanceCap;

    /// @notice Cumulative legacy-endowment, primary, and vesting DEEP minted through this controller.
    uint256 public grossIssued;

    /// @notice True after the one-time legacy-emissions endowment has been successfully streamed.
    bool public legacyEndowmentCreated;
    /// @notice Block and timestamp at which the legacy Rewarder's recorded accrual was sampled.
    uint256 public legacyEndowmentSnapshotBlock;
    uint40 public legacyEndowmentSnapshotAt;
    /// @notice Recorded cumulative accrual for each legacy pool token at the endowment snapshot.
    uint96 public legacyToken0Accrued;
    uint96 public legacyToken1Accrued;
    /// @notice DEEP minted and deposited into the one-time legacy-emissions stream.
    uint256 public legacyEndowmentAmount;
    uint256 public legacyEndowmentStreamId;

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
    event PreActivationTokenAdministrationReturned(address indexed owner, address indexed caller);
    event GrossIssuanceRecorded(uint256 amount, uint256 totalGrossIssued);
    event ExternalTokenMinterRevoked(address indexed account, address indexed caller);
    event LegacyRewarderEndowmentCreated(
        address indexed legacyRewarder,
        address indexed token0,
        address indexed token1,
        uint96 token0Accrued,
        uint96 token1Accrued,
        uint256 totalAccrued,
        uint256 endowmentAmount,
        uint256 streamId,
        uint256 snapshotBlock,
        uint40 snapshotAt
    );

    error InvalidDeepstateToken();
    error InvalidSablierLockup();
    error InvalidLegacyRewarder();
    error InvalidLegacyRewarderTokens(address token0, address token1);
    error LegacyRewardTokenMismatch(address expected, address actual);
    error InvalidLegacyDeepstate(address deepstate);
    error LegacyRewarderPoolIdentityMismatch(bytes32 expectedPoolId, bytes32 actualPoolId);
    error LegacyRewarderPoolHookMismatch(bytes32 poolId, address expectedHook, address actualHook);
    error LegacyRewarderBookNotIdle(bytes32 bookId, bool isBid, uint32 orderNonce, uint160 soldAmount);
    error LegacyRewarderCursorNotIdle(address token, uint32 orderNonce, uint64 startedAt);
    error InvalidRecipient();
    error InvalidMintCap();
    error InvalidGrossIssuanceCap();
    error InvalidMintRecipient();
    error InvalidExternalTokenMinter(address account);
    error ExternalTokenMinterNotActive(address account);
    error MintAmountTooSmall();
    error VestingAmountTooLarge(uint256 amount);
    error ControllerNotTokenAdmin();
    error ControllerNotSoleTokenAdmin(uint256 adminCount);
    error TokenAdministrationAlreadyActivated();
    error TokenAdministrationAlreadyReturned();
    error TokenAdministrationNotActive();
    error TokenAdministrationActive(uint40 endsAt);
    error TokenAdministrationExpired(uint40 endsAt);
    error LegacyEndowmentAmountZero();
    error MintCapExceeded(uint256 cap, uint256 attemptedSupply);
    error GrossIssuanceCapExceeded(uint256 cap, uint256 attemptedGrossIssued);

    constructor(
        address owner_,
        address deepstateToken_,
        address sablierLockup_,
        address legacyRewarder_,
        address recipient_,
        uint256 mintCap_,
        uint256 grossIssuanceCap_
    ) DeepstateController(owner_) {
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) {
            revert InvalidDeepstateToken();
        }
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        if (legacyRewarder_ == address(0) || legacyRewarder_.code.length == 0) revert InvalidLegacyRewarder();
        (bool rewardTokenCallSucceeded, bytes memory rewardTokenResult) =
            legacyRewarder_.staticcall(abi.encodeCall(IDeepstateLegacyRewarder.rewardToken, ()));
        if (!rewardTokenCallSucceeded || rewardTokenResult.length < 32) revert InvalidLegacyRewarder();
        address legacyRewardToken = abi.decode(rewardTokenResult, (address));
        if (legacyRewardToken != deepstateToken_) {
            revert LegacyRewardTokenMismatch(deepstateToken_, legacyRewardToken);
        }
        if (recipient_ == address(0)) revert InvalidRecipient();
        if (
            mintCap_ < MINIMUM_COMBINED_ISSUANCE
                || DeepstateToken(deepstateToken_).totalSupply() > mintCap_ - MINIMUM_COMBINED_ISSUANCE
        ) {
            revert InvalidMintCap();
        }
        if (grossIssuanceCap_ < MINIMUM_COMBINED_ISSUANCE) revert InvalidGrossIssuanceCap();

        deepstateToken = DeepstateToken(deepstateToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        legacyRewarder = IDeepstateLegacyRewarder(legacyRewarder_);
        recipient = recipient_;
        mintCap = mintCap_;
        grossIssuanceCap = grossIssuanceCap_;
    }

    /// @notice Validate and endow the idle legacy market, then lock DEEP administration for the two-year term.
    /// @dev This call is the only endowment entry point. All validation, minting, streaming, and activation effects
    /// revert atomically if any dependency or live-market precondition fails.
    function lockTokenAdministration() external onlyOwner nonReentrant {
        if (tokenAdministrationEndsAt != 0) revert TokenAdministrationAlreadyActivated();

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();
        uint256 adminCount = deepstateToken.defaultAdminCount();
        if (adminCount != 1) revert ControllerNotSoleTokenAdmin(adminCount);

        if (!deepstateToken.hasRole(deepstateToken.MINTER_ROLE(), address(this))) {
            deepstateToken.grantRole(deepstateToken.MINTER_ROLE(), address(this));
        }

        _createLegacyRewarderEndowment();

        uint40 endsAt = SafeCastLib.toUint40(block.timestamp + TOKEN_ADMINISTRATION_DURATION);
        tokenAdministrationEndsAt = endsAt;
        emit TokenAdministrationActivated(endsAt);
    }

    function _createLegacyRewarderEndowment() private {
        IDeepstateLegacyRewarder rewarder = legacyRewarder;
        address legacyRewardToken = rewarder.rewardToken();
        if (legacyRewardToken != address(deepstateToken)) {
            revert LegacyRewardTokenMismatch(address(deepstateToken), legacyRewardToken);
        }
        address token0 = rewarder.token0();
        address token1 = rewarder.token1();
        if (token0 == address(0) || token0 >= token1) {
            revert InvalidLegacyRewarderTokens(token0, token1);
        }

        address legacyDeepstate = rewarder.deepstate();
        if (legacyDeepstate == address(0) || legacyDeepstate.code.length == 0) {
            revert InvalidLegacyDeepstate(legacyDeepstate);
        }
        bytes32 expectedPoolId = keccak256(abi.encode(token0, token1));
        bytes32 actualPoolId = rewarder.poolId();
        if (actualPoolId != expectedPoolId) {
            revert LegacyRewarderPoolIdentityMismatch(expectedPoolId, actualPoolId);
        }

        IDeepstateLegacyRouterView router = IDeepstateLegacyRouterView(legacyDeepstate);
        address installedHook = router.poolHook(expectedPoolId);
        if (installedHook != address(rewarder)) {
            revert LegacyRewarderPoolHookMismatch(expectedPoolId, address(rewarder), installedHook);
        }

        bytes32 activeBookId = router.activeBookId(token0, token1);
        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(activeBookId, true);
        if (bidNonce != 0 || bidAmount != 0) {
            revert LegacyRewarderBookNotIdle(activeBookId, true, bidNonce, bidAmount);
        }
        (uint32 askNonce, uint160 askAmount) = router.topOrder(activeBookId, false);
        if (askNonce != 0 || askAmount != 0) {
            revert LegacyRewarderBookNotIdle(activeBookId, false, askNonce, askAmount);
        }

        (uint32 token0Nonce, uint64 token0StartedAt) = rewarder.rewardees(token0);
        if (token0Nonce != 0 || token0StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(token0, token0Nonce, token0StartedAt);
        }
        (uint32 token1Nonce, uint64 token1StartedAt) = rewarder.rewardees(token1);
        if (token1Nonce != 0 || token1StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(token1, token1Nonce, token1StartedAt);
        }

        uint96 token0Accrued = rewarder.totalAccrued(token0);
        uint96 token1Accrued = rewarder.totalAccrued(token1);
        uint256 totalAccrued = uint256(token0Accrued) + uint256(token1Accrued);
        uint256 endowmentAmount = FixedPointMathLib.fullMulDiv(totalAccrued, RECIPIENT_ALLOCATION_BPS, 10_000);
        if (endowmentAmount == 0) revert LegacyEndowmentAmountZero();

        uint256 attemptedGrossIssued = grossIssued + endowmentAmount;
        if (attemptedGrossIssued > grossIssuanceCap) {
            revert GrossIssuanceCapExceeded(grossIssuanceCap, attemptedGrossIssued);
        }
        uint256 attemptedSupply = deepstateToken.totalSupply() + endowmentAmount;
        if (attemptedSupply > mintCap) revert MintCapExceeded(mintCap, attemptedSupply);

        uint256 snapshotBlock = block.number;
        uint40 snapshotAt = SafeCastLib.toUint40(block.timestamp);
        legacyEndowmentCreated = true;
        legacyEndowmentSnapshotBlock = snapshotBlock;
        legacyEndowmentSnapshotAt = snapshotAt;
        legacyToken0Accrued = token0Accrued;
        legacyToken1Accrued = token1Accrued;
        legacyEndowmentAmount = endowmentAmount;
        grossIssued = attemptedGrossIssued;

        deepstateToken.mint(address(this), endowmentAmount);
        address(deepstateToken).safeApproveWithRetry(address(sablierLockup), endowmentAmount);
        uint256 streamId = _createStream(SafeCastLib.toUint128(endowmentAmount), "Deepstate Inc endowment");
        legacyEndowmentStreamId = streamId;

        emit LegacyRewarderEndowmentCreated(
            address(rewarder),
            token0,
            token1,
            token0Accrued,
            token1Accrued,
            totalAccrued,
            endowmentAmount,
            streamId,
            snapshotBlock,
            snapshotAt
        );
        emit GrossIssuanceRecorded(endowmentAmount, attemptedGrossIssued);
    }

    /// @notice Return DEEP administration if governance transferred it before an activation attempt that could not
    /// complete. This recovery path is permanently disabled once the two-year term starts.
    function returnPreActivationTokenAdministration() external onlyOwner nonReentrant {
        if (tokenAdministrationEndsAt != 0) revert TokenAdministrationAlreadyActivated();

        DeepstateToken token = deepstateToken;
        bytes32 tokenAdminRole = token.DEFAULT_ADMIN_ROLE();
        if (!token.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();

        address owner_ = owner();
        if (!token.hasRole(tokenAdminRole, owner_)) token.grantRole(tokenAdminRole, owner_);

        bytes32 tokenMinterRole = token.MINTER_ROLE();
        if (token.hasRole(tokenMinterRole, address(this))) token.revokeRole(tokenMinterRole, address(this));
        token.renounceRole(tokenAdminRole, address(this));

        emit PreActivationTokenAdministrationReturned(owner_, msg.sender);
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

    /// @notice Revoke a bypass token-level minter while this controller administers DEEP.
    /// @dev This deliberately exposes no corresponding grant path and cannot revoke the controller itself.
    function revokeExternalTokenMinter(address account) external onlyOwner nonReentrant {
        if (account == address(0) || account == address(this)) revert InvalidExternalTokenMinter(account);

        bytes32 tokenAdminRole = deepstateToken.DEFAULT_ADMIN_ROLE();
        if (!deepstateToken.hasRole(tokenAdminRole, address(this))) revert ControllerNotTokenAdmin();
        bytes32 tokenMinterRole = deepstateToken.MINTER_ROLE();
        if (!deepstateToken.hasRole(tokenMinterRole, account)) revert ExternalTokenMinterNotActive(account);

        deepstateToken.revokeRole(tokenMinterRole, account);
        emit ExternalTokenMinterRevoked(account, msg.sender);
    }

    /// @notice During the active administration term, mint the 70% primary tranche `amount` to `to` and the 30%
    /// tranche into a one-year stream.
    /// @dev The recipient amount is `floor(amount * 30 / 70)`. Amounts that round it to zero revert. Minting is
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
        if (to == address(0)) revert InvalidMintRecipient();

        uint256 vestingAmount = FixedPointMathLib.fullMulDiv(amount, RECIPIENT_ALLOCATION_BPS, PRIMARY_ALLOCATION_BPS);
        if (vestingAmount == 0) revert MintAmountTooSmall();
        if (vestingAmount > type(uint128).max) revert VestingAmountTooLarge(vestingAmount);
        uint128 streamAmount = SafeCastLib.toUint128(vestingAmount);

        uint256 mintSupply = amount + vestingAmount;
        uint256 attemptedGrossIssued = grossIssued + mintSupply;
        if (attemptedGrossIssued > grossIssuanceCap) {
            revert GrossIssuanceCapExceeded(grossIssuanceCap, attemptedGrossIssued);
        }
        // Effects precede all token and Sablier interactions. Any later revert rolls this update back atomically.
        grossIssued = attemptedGrossIssued;

        uint256 attemptedSupply = deepstateToken.totalSupply() + mintSupply;
        if (attemptedSupply > mintCap) revert MintCapExceeded(mintCap, attemptedSupply);

        deepstateToken.mint(to, amount);
        deepstateToken.mint(address(this), vestingAmount);

        address(deepstateToken).safeApproveWithRetry(address(sablierLockup), vestingAmount);
        streamId = _createStream(streamAmount, "Deepstate allocation");

        emit MintedWithVesting(msg.sender, to, amount, recipient, vestingAmount, streamId);
        emit GrossIssuanceRecorded(mintSupply, attemptedGrossIssued);
    }

    function _createStream(uint128 streamAmount, string memory shape) private returns (uint256 streamId) {
        streamId = sablierLockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: address(this),
                recipient: recipient,
                depositAmount: streamAmount,
                token: IERC20(address(deepstateToken)),
                cancelable: false,
                transferable: false,
                shape: shape
            }),
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            0,
            LockupLinear.Durations({cliff: 0, total: VESTING_DURATION})
        );
    }
}
