// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DeepstateMinterController} from "./DeepstateMinterController.sol";
import {IDeepstateLegacyRewarder} from "./interfaces/IDeepstateLegacyRewarder.sol";
import {ISablierLockupLinearV4} from "./interfaces/ISablierLockupLinearV4.sol";

interface IDGP001LegacyRouterView {
    function poolHook(bytes32 poolId) external view returns (address);
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

/// @title DGP-001 Bootstrap
/// @notice One-use governance action that converts 30% of the installed legacy Rewarder's recorded emissions into
/// a one-year Deepstate Inc endowment stream.
/// @dev This contract has no lasting protocol authority. Governance must grant its DEEP minter role before calling
/// `execute`; a successful execution permanently renounces that role and disables this contract.
contract DGP001Bootstrap is ReentrancyGuard {
    using SafeTransferLib for address;

    uint256 public constant ENDOWMENT_PERCENT = 30;
    uint40 public constant VESTING_DURATION = 365 days;
    uint40 public constant STREAM_GRANULARITY = 1 seconds;

    address public immutable governor;
    DeepstateToken public immutable deepstateToken;
    ISablierLockupLinearV4 public immutable sablierLockup;
    IDeepstateLegacyRewarder public immutable legacyRewarder;
    address public immutable recipient;
    DeepstateMinterController public immutable minterController;

    bool public executed;
    uint256 public snapshotBlock;
    uint40 public snapshotAt;
    address public snapshotToken0;
    address public snapshotToken1;
    uint96 public token0Accrued;
    uint96 public token1Accrued;
    uint256 public totalAccrued;
    uint256 public endowmentAmount;
    uint256 public preexistingBalanceBurned;
    uint256 public postEndowmentSupply;
    uint256 public streamId;

    event EndowmentCreated(
        address indexed legacyRewarder,
        address indexed recipient,
        uint256 indexed streamId,
        address token0,
        address token1,
        uint96 token0Accrued,
        uint96 token1Accrued,
        uint256 totalAccrued,
        uint256 endowmentAmount,
        uint256 preexistingBalanceBurned,
        uint256 postEndowmentSupply,
        uint256 snapshotBlock,
        uint40 snapshotAt
    );

    error Unauthorized(address caller);
    error AlreadyExecuted();
    error InvalidGovernor();
    error InvalidDeepstateToken();
    error InvalidSablierLockup();
    error InvalidLegacyRewarder();
    error InvalidMinterController();
    error MinterControllerConfigurationMismatch();
    error MinterControllerNotPristine(uint40 administrationEndsAt, uint256 grossIssued);
    error BootstrapMinterRoleMissing();
    error LegacyRewardTokenMismatch(address expected, address actual);
    error InvalidLegacyRewarderTokens(address token0, address token1);
    error LegacyRewarderPoolIdentityMismatch(bytes32 expected, bytes32 actual);
    error InvalidLegacyRouter(address router);
    error LegacyRewarderNotInstalled(bytes32 poolId, address expected, address actual);
    error LegacyRewarderBookNotIdle(bytes32 bookId, bool isBid, uint32 orderNonce, uint160 soldAmount);
    error LegacyRewarderCursorNotIdle(address token, uint32 orderNonce, uint64 startedAt);
    error EndowmentAmountZero();
    error MintCapExceeded(uint256 cap, uint256 attemptedSupply);
    error GrossIssuanceCapExceeded(uint256 cap, uint256 attemptedSupply);
    error ResidualTokenBalance(uint256 balance);
    error ResidualSablierAllowance(uint256 allowance);
    error MinterRoleRenunciationFailed();

    constructor(address governor_, address minterController_, address legacyRewarder_) {
        if (governor_ == address(0)) revert InvalidGovernor();
        if (minterController_ == address(0) || minterController_.code.length == 0) {
            revert InvalidMinterController();
        }
        if (legacyRewarder_ == address(0) || legacyRewarder_.code.length == 0) revert InvalidLegacyRewarder();

        DeepstateMinterController controller = DeepstateMinterController(minterController_);
        if (controller.owner() != governor_) revert MinterControllerConfigurationMismatch();

        address deepstateToken_ = address(controller.deepstateToken());
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) revert InvalidDeepstateToken();
        address sablierLockup_ = address(controller.sablierLockup());
        if (sablierLockup_ == address(0) || sablierLockup_.code.length == 0) revert InvalidSablierLockup();
        address recipient_ = controller.recipient();
        if (recipient_ == address(0)) revert MinterControllerConfigurationMismatch();

        governor = governor_;
        deepstateToken = DeepstateToken(deepstateToken_);
        sablierLockup = ISablierLockupLinearV4(sablierLockup_);
        legacyRewarder = IDeepstateLegacyRewarder(legacyRewarder_);
        recipient = recipient_;
        minterController = controller;
    }

    /// @notice Snapshot legacy emissions, create the Deepstate Inc stream, and permanently disable this bootstrap.
    function execute() external nonReentrant returns (uint256 createdStreamId) {
        if (msg.sender != governor) revert Unauthorized(msg.sender);
        if (executed) revert AlreadyExecuted();

        DeepstateToken token = deepstateToken;
        bytes32 minterRole = token.MINTER_ROLE();
        if (!token.hasRole(minterRole, address(this))) revert BootstrapMinterRoleMissing();

        _requireMinterControllerConfiguration();
        uint40 administrationEndsAt = minterController.tokenAdministrationEndsAt();
        uint256 controllerGrossIssued = minterController.grossIssued();
        if (administrationEndsAt != 0 || controllerGrossIssued != 0) {
            revert MinterControllerNotPristine(administrationEndsAt, controllerGrossIssued);
        }

        IDeepstateLegacyRewarder rewarder = legacyRewarder;
        address actualRewardToken = rewarder.rewardToken();
        if (actualRewardToken != address(token)) {
            revert LegacyRewardTokenMismatch(address(token), actualRewardToken);
        }

        address token0 = rewarder.token0();
        address token1 = rewarder.token1();
        if (token0 == address(0) || token0 >= token1) revert InvalidLegacyRewarderTokens(token0, token1);

        bytes32 expectedPoolId = keccak256(abi.encode(token0, token1));
        bytes32 actualPoolId = rewarder.poolId();
        if (actualPoolId != expectedPoolId) {
            revert LegacyRewarderPoolIdentityMismatch(expectedPoolId, actualPoolId);
        }

        address routerAddress = rewarder.deepstate();
        if (routerAddress == address(0) || routerAddress.code.length == 0) revert InvalidLegacyRouter(routerAddress);
        IDGP001LegacyRouterView router = IDGP001LegacyRouterView(routerAddress);
        address installedRewarder = router.poolHook(expectedPoolId);
        if (installedRewarder != address(rewarder)) {
            revert LegacyRewarderNotInstalled(expectedPoolId, address(rewarder), installedRewarder);
        }

        bytes32 activeBook = router.activeBookId(token0, token1);
        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(activeBook, true);
        if (bidNonce != 0 || bidAmount != 0) {
            revert LegacyRewarderBookNotIdle(activeBook, true, bidNonce, bidAmount);
        }
        (uint32 askNonce, uint160 askAmount) = router.topOrder(activeBook, false);
        if (askNonce != 0 || askAmount != 0) {
            revert LegacyRewarderBookNotIdle(activeBook, false, askNonce, askAmount);
        }

        (uint32 token0Nonce, uint64 token0StartedAt) = rewarder.rewardees(token0);
        if (token0Nonce != 0 || token0StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(token0, token0Nonce, token0StartedAt);
        }
        (uint32 token1Nonce, uint64 token1StartedAt) = rewarder.rewardees(token1);
        if (token1Nonce != 0 || token1StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(token1, token1Nonce, token1StartedAt);
        }

        uint96 accrued0 = rewarder.totalAccrued(token0);
        uint96 accrued1 = rewarder.totalAccrued(token1);
        uint256 accruedTotal = uint256(accrued0) + uint256(accrued1);
        uint256 amount = FixedPointMathLib.fullMulDiv(accruedTotal, ENDOWMENT_PERCENT, 100);
        if (amount == 0) revert EndowmentAmountZero();

        // The deterministic address is public before deployment, so anyone can send DEEP here. Burning an unsolicited
        // balance prevents ERC20 dust from blocking the one-use execution or changing the exact endowment amount.
        uint256 preexistingBalance = token.balanceOf(address(this));
        if (preexistingBalance != 0) token.burn(preexistingBalance);

        uint256 resultingSupply = token.totalSupply() + amount;
        uint256 liveSupplyCap = minterController.mintCap();
        if (resultingSupply > liveSupplyCap) revert MintCapExceeded(liveSupplyCap, resultingSupply);
        uint256 grossCap = minterController.grossIssuanceCap();
        if (resultingSupply > grossCap) revert GrossIssuanceCapExceeded(grossCap, resultingSupply);

        uint256 blockNumber = block.number;
        uint40 timestamp = SafeCastLib.toUint40(block.timestamp);

        // Effects precede the token and Sablier interactions. Any failure below rolls every field back atomically.
        executed = true;
        snapshotBlock = blockNumber;
        snapshotAt = timestamp;
        snapshotToken0 = token0;
        snapshotToken1 = token1;
        token0Accrued = accrued0;
        token1Accrued = accrued1;
        totalAccrued = accruedTotal;
        endowmentAmount = amount;
        preexistingBalanceBurned = preexistingBalance;
        postEndowmentSupply = resultingSupply;

        token.mint(address(this), amount);
        address(token).safeApproveWithRetry(address(sablierLockup), amount);
        createdStreamId = sablierLockup.createWithDurationsLL(
            Lockup.CreateWithDurations({
                sender: address(this),
                recipient: recipient,
                depositAmount: SafeCastLib.toUint128(amount),
                token: IERC20(address(token)),
                cancelable: false,
                transferable: false,
                shape: "Deepstate Inc endowment"
            }),
            LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
            STREAM_GRANULARITY,
            LockupLinear.Durations({cliff: 0, total: VESTING_DURATION})
        );
        streamId = createdStreamId;

        token.renounceRole(minterRole, address(this));

        uint256 residualBalance = token.balanceOf(address(this));
        if (residualBalance != 0) revert ResidualTokenBalance(residualBalance);
        uint256 residualAllowance = token.allowance(address(this), address(sablierLockup));
        if (residualAllowance != 0) revert ResidualSablierAllowance(residualAllowance);
        if (token.hasRole(minterRole, address(this))) revert MinterRoleRenunciationFailed();

        emit EndowmentCreated(
            address(rewarder),
            recipient,
            createdStreamId,
            token0,
            token1,
            accrued0,
            accrued1,
            accruedTotal,
            amount,
            preexistingBalance,
            resultingSupply,
            blockNumber,
            timestamp
        );
    }

    function _requireMinterControllerConfiguration() private view {
        DeepstateMinterController controller = minterController;
        if (
            controller.owner() != governor || address(controller.deepstateToken()) != address(deepstateToken)
                || address(controller.sablierLockup()) != address(sablierLockup) || controller.recipient() != recipient
        ) {
            revert MinterControllerConfigurationMismatch();
        }
    }
}
