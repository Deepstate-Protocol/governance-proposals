// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {DeepstateRewarderV2} from "./DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "./DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {IDeepstateLegacyRewarder} from "./interfaces/IDeepstateLegacyRewarder.sol";
import {IDeepstateMinterController} from "./interfaces/IDeepstateMinterController.sol";
import {IDeepstateV1} from "./interfaces/IDeepstateV1.sol";

interface IDeepstateV1OrderBookView {
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

/// @title Deepstate Rewarder Factory
/// @notice Governance-owned factory for operator-launched USDG/stock market reward programs.
/// @dev The factory must hold the minter controller's MINTER_ROLE and V1 controller's HOOK_MANAGER_ROLE.
contract DeepstateRewarderFactory is Ownable, ReentrancyGuard {
    /// @notice Semantic market configuration. Token ordering and USDG quantities are factory-enforced.
    struct MarketConfig {
        address stockToken;
        uint160 stockStartQuantity;
        uint160 stockMaxQuantity;
        bool stockBuySideActive;
        bool usdGBuySideActive;
    }

    struct ResolvedMarket {
        bytes32 poolId;
        address token0;
        address token1;
        uint160 token0StartQuantity;
        uint160 token0MaxQuantity;
        uint160 token1StartQuantity;
        uint160 token1MaxQuantity;
        bool token0Active;
        bool token1Active;
    }

    /// @notice Minimum interval between successful operator or governance market deployments.
    uint256 public constant DEPLOYMENT_COOLDOWN = 3 days;
    /// @notice Duration encoded into every factory rewarder.
    uint32 public constant EMISSION_DURATION = 365 days;
    /// @notice Maximum scheduled emissions for each side, for one hundred million DEEP total per market.
    uint96 public constant SIDE_EMISSION_CAP = 50_000_000e18;
    /// @notice Complete primary DEEP funding minted atomically to each rewarder.
    uint256 public constant MARKET_FUNDING = 100_000_000e18;
    /// @notice Fixed starting full-reward quantity for six-decimal USDG.
    uint160 public constant USDG_START_QUANTITY = 1e6;
    /// @notice Fixed maximum full-reward quantity for six-decimal USDG.
    uint160 public constant USDG_MAX_QUANTITY = 1_000_000e6;
    /// @notice Largest permitted ratio between a stock side's maximum and starting full-reward quantities.
    uint256 public constant MAX_QUANTITY_GROWTH = 1_000_000;

    DeepstateV1Controller public immutable deepstateV1Controller;
    IDeepstateV1 public immutable deepstate;
    IDeepstateMinterController public immutable minterController;
    DeepstateToken public immutable rewardToken;
    /// @notice Canonical six-decimal USDG paired with every factory market.
    address public immutable usdG;
    /// @notice Lifetime primary-DEEP budget for complete market funding. Retirements never restore it.
    uint256 public immutable fundingBudget;

    /// @notice Revocable operator permitted to launch and retire factory markets.
    address public operator;
    /// @notice Earliest timestamp at which another market may be deployed.
    uint256 public nextDeploymentAt;
    /// @notice Lifetime primary DEEP committed to complete market funding.
    uint256 public fundingCommitted;

    mapping(bytes32 poolId => address rewarder) public activeRewarder;
    mapping(address rewarder => bytes32 poolId) public rewarderPool;
    /// @notice Permanent pool provenance for each retired factory rewarder.
    mapping(address rewarder => bytes32 poolId) public retiredRewarderPool;
    /// @notice True forever after this factory deploys the pool's sole rewarder.
    mapping(bytes32 poolId => bool deployed) public marketDeployed;
    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    event RewarderDeployed(
        bytes32 indexed poolId,
        address indexed rewarder,
        address token0,
        address token1,
        bool token0Active,
        bool token1Active
    );
    event RewarderFunded(bytes32 indexed poolId, address indexed rewarder, uint256 rewardAmount);
    event MarketRewarderReplaced(bytes32 indexed poolId, address indexed previousRewarder, address indexed newRewarder);
    event MarketRewarderRemoved(bytes32 indexed poolId, address indexed rewarder);

    error InvalidOwner();
    error InvalidDeepstateV1Controller();
    error DeepstateV1ControllerOwnerMismatch(address expected, address actual);
    error InvalidMinterController();
    error MinterControllerOwnerMismatch(address expected, address actual);
    error InvalidRewardToken();
    error InvalidUSDG();
    error InvalidFundingBudget();
    error InvalidStockToken();
    error InvalidStockTokenDecimals();
    error InvalidHookFlags();
    error QuantityGrowthTooLarge(address token, uint160 startQuantity, uint160 maxQuantity);
    error DeploymentCooldown(uint256 nextDeploymentAt);
    error FundingBudgetExceeded(uint256 budget, uint256 attemptedCommitment);
    error ActiveMarketExists(bytes32 poolId, address rewarder);
    error MarketAlreadyDeployed(bytes32 poolId);
    error ExistingPoolHook(bytes32 poolId, address hook);
    error InvalidExpectedExistingHook();
    error PoolBookNotIdle(bytes32 bookId, bool isBid, uint32 orderNonce, uint160 soldAmount);
    error LegacyRewarderPoolIdentityMismatch(
        bytes32 expectedPoolId,
        bytes32 actualPoolId,
        address expectedToken0,
        address actualToken0,
        address expectedToken1,
        address actualToken1
    );
    error LegacyRewarderDependencyMismatch(
        address expectedDeepstate, address actualDeepstate, address expectedRewardToken, address actualRewardToken
    );
    error LegacyRewarderCursorNotIdle(address token, uint32 orderNonce, uint64 startedAt);
    error UnexpectedPoolHook(bytes32 poolId, address expected, address actual);
    error MarketNotActive(bytes32 poolId);
    error UnexpectedRewarder(bytes32 poolId, address expected, address actual);

    constructor(
        address owner_,
        address deepstateV1Controller_,
        address minterController_,
        address usdG_,
        uint256 fundingBudget_
    ) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (deepstateV1Controller_ == address(0) || deepstateV1Controller_.code.length == 0) {
            revert InvalidDeepstateV1Controller();
        }
        if (minterController_ == address(0) || minterController_.code.length == 0) {
            revert InvalidMinterController();
        }
        if (usdG_ == address(0) || usdG_.code.length == 0 || !_hasDecimals(usdG_, 6)) revert InvalidUSDG();
        if (fundingBudget_ == 0 || fundingBudget_ % MARKET_FUNDING != 0) {
            revert InvalidFundingBudget();
        }

        _initializeOwner(owner_);
        deepstateV1Controller = DeepstateV1Controller(deepstateV1Controller_);
        address deepstateV1ControllerOwner = deepstateV1Controller.owner();
        if (deepstateV1ControllerOwner != owner_) {
            revert DeepstateV1ControllerOwnerMismatch(owner_, deepstateV1ControllerOwner);
        }
        deepstate = deepstateV1Controller.deepstate();
        minterController = IDeepstateMinterController(minterController_);
        address minterControllerOwner = minterController.owner();
        if (minterControllerOwner != owner_) {
            revert MinterControllerOwnerMismatch(owner_, minterControllerOwner);
        }
        address deepstateToken_ = minterController.deepstateToken();
        if (deepstateToken_ == address(0) || deepstateToken_.code.length == 0) revert InvalidRewardToken();
        rewardToken = DeepstateToken(deepstateToken_);
        usdG = usdG_;
        fundingBudget = fundingBudget_;
    }

    modifier onlyOperatorOrOwner() {
        _checkOperatorOrOwner();
        _checkGovernanceAlignment();
        _;
    }

    /// @notice Appoint or revoke the operator. Set zero to revoke without replacement.
    function setOperator(address newOperator) external onlyOwner {
        _checkGovernanceAlignment();
        address previousOperator = operator;
        operator = newOperator;
        emit OperatorSet(previousOperator, newOperator);
    }

    /// @notice Deploy, fully fund, and install the sole rewarder for one fresh USDG/stock pool.
    function deployMarket(MarketConfig calldata config)
        external
        onlyOperatorOrOwner
        nonReentrant
        returns (DeepstateRewarderV2 rewarder)
    {
        ResolvedMarket memory market = _validateAndResolveMarket(config);
        address existingHook = deepstate.poolHook(market.poolId);
        if (existingHook != address(0)) revert ExistingPoolHook(market.poolId, existingHook);
        rewarder = _deployResolvedMarket(market);
    }

    /// @notice Replace one exact existing hook with a fully funded V2 rewarder in a single governance transaction.
    /// @dev Migration is governance-only. Any failed deployment, mint, stream creation, or hook installation atomically
    /// restores the expected predecessor because the entire call reverts.
    function migrateMarket(MarketConfig calldata config, address expectedExistingHook)
        external
        onlyOwner
        nonReentrant
        returns (DeepstateRewarderV2 rewarder)
    {
        _checkGovernanceAlignment();
        if (expectedExistingHook == address(0)) revert InvalidExpectedExistingHook();

        ResolvedMarket memory market = _validateAndResolveMarket(config);
        address currentHook = deepstate.poolHook(market.poolId);
        if (currentHook != expectedExistingHook) {
            revert UnexpectedPoolHook(market.poolId, expectedExistingHook, currentHook);
        }

        _requireIdleMigrationState(market, expectedExistingHook);
        deepstateV1Controller.setPoolHookConfig(market.token0, market.token1, address(0), false, false);
        rewarder = _deployResolvedMarket(market);

        emit MarketRewarderReplaced(market.poolId, expectedExistingHook, address(rewarder));
    }

    function _deployResolvedMarket(ResolvedMarket memory market) private returns (DeepstateRewarderV2 rewarder) {
        uint256 next = nextDeploymentAt;
        if (block.timestamp < next) revert DeploymentCooldown(next);

        address active = activeRewarder[market.poolId];
        if (active != address(0)) revert ActiveMarketExists(market.poolId, active);
        if (marketDeployed[market.poolId]) revert MarketAlreadyDeployed(market.poolId);

        address existingHook = deepstate.poolHook(market.poolId);
        if (existingHook != address(0)) revert ExistingPoolHook(market.poolId, existingHook);

        uint256 attemptedCommitment = fundingCommitted + MARKET_FUNDING;
        if (attemptedCommitment > fundingBudget) {
            revert FundingBudgetExceeded(fundingBudget, attemptedCommitment);
        }

        nextDeploymentAt = block.timestamp + DEPLOYMENT_COOLDOWN;
        fundingCommitted = attemptedCommitment;
        marketDeployed[market.poolId] = true;

        rewarder = new DeepstateRewarderV2(
            address(this),
            address(deepstate),
            address(rewardToken),
            market.poolId,
            market.token0,
            market.token1,
            SIDE_EMISSION_CAP,
            EMISSION_DURATION,
            market.token0StartQuantity,
            market.token0MaxQuantity,
            market.token1StartQuantity,
            market.token1MaxQuantity
        );

        activeRewarder[market.poolId] = address(rewarder);
        rewarderPool[address(rewarder)] = market.poolId;

        minterController.mint(address(rewarder), MARKET_FUNDING);
        deepstateV1Controller.setPoolHookConfig(
            market.token0, market.token1, address(rewarder), market.token0Active, market.token1Active
        );

        emit RewarderDeployed(
            market.poolId, address(rewarder), market.token0, market.token1, market.token0Active, market.token1Active
        );
        emit RewarderFunded(market.poolId, address(rewarder), MARKET_FUNDING);
    }

    function _requireIdleMigrationState(ResolvedMarket memory market, address expectedExistingHook) private view {
        IDeepstateLegacyRewarder predecessor = IDeepstateLegacyRewarder(expectedExistingHook);
        bytes32 predecessorPoolId = predecessor.poolId();
        address predecessorToken0 = predecessor.token0();
        address predecessorToken1 = predecessor.token1();
        if (
            predecessorPoolId != market.poolId || predecessorToken0 != market.token0
                || predecessorToken1 != market.token1
        ) {
            revert LegacyRewarderPoolIdentityMismatch(
                market.poolId, predecessorPoolId, market.token0, predecessorToken0, market.token1, predecessorToken1
            );
        }

        address predecessorDeepstate = predecessor.deepstate();
        address predecessorRewardToken = predecessor.rewardToken();
        if (predecessorDeepstate != address(deepstate) || predecessorRewardToken != address(rewardToken)) {
            revert LegacyRewarderDependencyMismatch(
                address(deepstate), predecessorDeepstate, address(rewardToken), predecessorRewardToken
            );
        }

        IDeepstateV1OrderBookView orderBook = IDeepstateV1OrderBookView(address(deepstate));
        bytes32 bookId = orderBook.activeBookId(market.token0, market.token1);
        (uint32 bidNonce, uint160 bidAmount) = orderBook.topOrder(bookId, true);
        if (bidNonce != 0 || bidAmount != 0) revert PoolBookNotIdle(bookId, true, bidNonce, bidAmount);

        (uint32 askNonce, uint160 askAmount) = orderBook.topOrder(bookId, false);
        if (askNonce != 0 || askAmount != 0) revert PoolBookNotIdle(bookId, false, askNonce, askAmount);

        (uint32 token0Nonce, uint64 token0StartedAt) = predecessor.rewardees(market.token0);
        if (token0Nonce != 0 || token0StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(market.token0, token0Nonce, token0StartedAt);
        }

        (uint32 token1Nonce, uint64 token1StartedAt) = predecessor.rewardees(market.token1);
        if (token1Nonce != 0 || token1StartedAt != 0) {
            revert LegacyRewarderCursorNotIdle(market.token1, token1Nonce, token1StartedAt);
        }
    }

    /// @notice Remove a factory market, permanently retire its rewarder, and burn its remaining DEEP balance.
    /// @dev Retirement deliberately makes every accrued but unpaid claim permanently unclaimable.
    function removeMarket(address stockToken, address expectedRewarder) external onlyOperatorOrOwner nonReentrant {
        (bytes32 poolId_, address token0, address token1) = _resolvePool(stockToken);
        address rewarder = activeRewarder[poolId_];
        if (rewarder == address(0)) revert MarketNotActive(poolId_);
        if (rewarder != expectedRewarder) revert UnexpectedRewarder(poolId_, expectedRewarder, rewarder);
        if (rewarderPool[rewarder] != poolId_) revert UnexpectedRewarder(poolId_, expectedRewarder, rewarder);

        address currentHook = deepstate.poolHook(poolId_);
        // Effects precede all retirement interactions. A failure below reverts these updates atomically.
        delete activeRewarder[poolId_];
        delete rewarderPool[rewarder];
        retiredRewarderPool[rewarder] = poolId_;

        if (currentHook == rewarder) {
            deepstateV1Controller.setPoolHookConfig(token0, token1, address(0), false, false);
        } else if (currentHook != address(0)) {
            revert UnexpectedPoolHook(poolId_, rewarder, currentHook);
        }

        DeepstateRewarderV2(rewarder).retireAndBurnBalance();

        emit MarketRewarderRemoved(poolId_, rewarder);
    }

    /// @notice Factory ownership cannot be renounced.
    function renounceOwnership() public payable override onlyOwner {
        revert NewOwnerIsZeroAddress();
    }

    function _validateAndResolveMarket(MarketConfig calldata config)
        private
        view
        returns (ResolvedMarket memory market)
    {
        address stockToken = config.stockToken;
        if (stockToken == address(0) || stockToken == usdG || stockToken.code.length == 0) {
            revert InvalidStockToken();
        }
        if (!_hasDecimals(stockToken, 18)) revert InvalidStockTokenDecimals();
        if (!config.stockBuySideActive && !config.usdGBuySideActive) revert InvalidHookFlags();
        _validateQuantityGrowth(stockToken, config.stockStartQuantity, config.stockMaxQuantity);

        (market.poolId, market.token0, market.token1) = _resolvePool(stockToken);
        if (market.token0 == usdG) {
            market.token0StartQuantity = USDG_START_QUANTITY;
            market.token0MaxQuantity = USDG_MAX_QUANTITY;
            market.token1StartQuantity = config.stockStartQuantity;
            market.token1MaxQuantity = config.stockMaxQuantity;
            market.token0Active = config.usdGBuySideActive;
            market.token1Active = config.stockBuySideActive;
        } else {
            market.token0StartQuantity = config.stockStartQuantity;
            market.token0MaxQuantity = config.stockMaxQuantity;
            market.token1StartQuantity = USDG_START_QUANTITY;
            market.token1MaxQuantity = USDG_MAX_QUANTITY;
            market.token0Active = config.stockBuySideActive;
            market.token1Active = config.usdGBuySideActive;
        }
    }

    function _validateQuantityGrowth(address token, uint160 startQuantity, uint160 maxQuantity) private pure {
        // The pinned rewarder validates zero, ordering, and the 1,000x minimum. Multiplication is
        // performed as uint256 so the uint160 configuration values cannot overflow this upper bound.
        if (startQuantity == 0 || maxQuantity <= startQuantity) return;
        if (uint256(maxQuantity) > uint256(startQuantity) * MAX_QUANTITY_GROWTH) {
            revert QuantityGrowthTooLarge(token, startQuantity, maxQuantity);
        }
    }

    function _resolvePool(address stockToken) private view returns (bytes32 poolId_, address token0, address token1) {
        if (stockToken == address(0) || stockToken == usdG) revert InvalidStockToken();
        (token0, token1) = stockToken < usdG ? (stockToken, usdG) : (usdG, stockToken);
        poolId_ = keccak256(abi.encode(token0, token1));
    }

    function _hasDecimals(address token, uint8 expected) private view returns (bool) {
        (bool success, bytes memory result) = token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!success || result.length < 32) return false;
        return abi.decode(result, (uint256)) == expected;
    }

    function _checkOperatorOrOwner() private view {
        if (msg.sender != operator) _checkOwner();
    }

    function _checkGovernanceAlignment() private view {
        address owner_ = owner();
        address deepstateV1ControllerOwner = deepstateV1Controller.owner();
        if (deepstateV1ControllerOwner != owner_) {
            revert DeepstateV1ControllerOwnerMismatch(owner_, deepstateV1ControllerOwner);
        }
        address minterControllerOwner = minterController.owner();
        if (minterControllerOwner != owner_) {
            revert MinterControllerOwnerMismatch(owner_, minterControllerOwner);
        }
    }

    /// @dev Every direct or two-step ownership transfer must preserve the controllers' common governance owner.
    function _setOwner(address newOwner) internal override {
        if (newOwner == address(this)) revert InvalidOwner();
        if (newOwner != address(0)) {
            address deepstateV1ControllerOwner = deepstateV1Controller.owner();
            if (deepstateV1ControllerOwner != newOwner) {
                revert DeepstateV1ControllerOwnerMismatch(newOwner, deepstateV1ControllerOwner);
            }
            address minterControllerOwner = minterController.owner();
            if (minterControllerOwner != newOwner) {
                revert MinterControllerOwnerMismatch(newOwner, minterControllerOwner);
            }
        }
        super._setOwner(newOwner);
    }
}
