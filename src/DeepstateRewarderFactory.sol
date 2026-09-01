// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DeepstateRewarderV2} from "./DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "./DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {IDeepstateMinterController} from "./interfaces/IDeepstateMinterController.sol";
import {IDeepstateV1} from "./interfaces/IDeepstateV1.sol";

/// @title Deepstate Rewarder Factory
/// @notice Governance-owned factory for operator-launched market reward programs.
/// @dev The factory must hold the minter controller's MINTER_ROLE and V1 controller's HOOK_MANAGER_ROLE.
contract DeepstateRewarderFactory is Ownable, ReentrancyGuard {
    /// @notice Reward configuration for an already-canonical token pair.
    struct MarketConfig {
        address token0;
        address token1;
        uint256 token0MaxUnits;
        uint256 token1MaxUnits;
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
    /// @notice Largest permitted ratio between either side's maximum and starting full-reward quantities.
    uint256 public constant MAX_QUANTITY_GROWTH = 1_000_000;

    DeepstateV1Controller public immutable deepstateV1Controller;
    IDeepstateV1 public immutable deepstate;
    IDeepstateMinterController public immutable minterController;
    DeepstateToken public immutable rewardToken;

    /// @notice Revocable operator permitted to launch markets, clear hooks, and burn Rewarder balances.
    address public operator;
    /// @notice Earliest timestamp at which another market may be deployed.
    uint256 public nextDeploymentAt;

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
    event MarketHookCleared(bytes32 indexed poolId, address indexed previousHook);

    error InvalidOwner();
    error QuantityGrowthTooLarge(address token, uint256 maxUnits);
    error DeploymentCooldown(uint256 nextDeploymentAt);

    constructor(address owner_, address deepstateV1Controller_, address minterController_) {
        if (owner_ == address(0)) revert InvalidOwner();

        _initializeOwner(owner_);
        deepstateV1Controller = DeepstateV1Controller(deepstateV1Controller_);
        deepstate = deepstateV1Controller.deepstate();
        minterController = IDeepstateMinterController(minterController_);
        rewardToken = DeepstateToken(minterController.deepstateToken());
    }

    modifier onlyOperatorOrOwner() {
        _checkOperatorOrOwner();
        _;
    }

    /// @notice Appoint or revoke the operator. Set zero to revoke without replacement.
    function setOperator(address newOperator) external onlyOwner {
        address previousOperator = operator;
        operator = newOperator;
        emit OperatorSet(previousOperator, newOperator);
    }

    /// @notice Deploy, fully fund, and install a rewarder for one canonical pool.
    function deployMarket(MarketConfig calldata config)
        external
        onlyOperatorOrOwner
        nonReentrant
        returns (DeepstateRewarderV2 rewarder)
    {
        address token0 = config.token0;
        address token1 = config.token1;
        _validateQuantityGrowth(token0, config.token0MaxUnits);
        _validateQuantityGrowth(token1, config.token1MaxUnits);
        (uint160 token0StartQuantity, uint160 token0MaxQuantity) = _quantitiesForUnits(token0, config.token0MaxUnits);
        (uint160 token1StartQuantity, uint160 token1MaxQuantity) = _quantitiesForUnits(token1, config.token1MaxUnits);

        bytes32 poolId = keccak256(abi.encode(token0, token1));

        uint256 next = nextDeploymentAt;
        if (block.timestamp < next) revert DeploymentCooldown(next);

        nextDeploymentAt = block.timestamp + DEPLOYMENT_COOLDOWN;

        rewarder = new DeepstateRewarderV2(
            address(this),
            address(deepstate),
            address(rewardToken),
            poolId,
            token0,
            token1,
            SIDE_EMISSION_CAP,
            EMISSION_DURATION,
            token0StartQuantity,
            token0MaxQuantity,
            token1StartQuantity,
            token1MaxQuantity
        );

        minterController.mint(address(rewarder), MARKET_FUNDING);
        deepstateV1Controller.setPoolHookConfig(
            token0, token1, address(rewarder), config.token0Active, config.token1Active
        );

        emit RewarderDeployed(poolId, address(rewarder), token0, token1, config.token0Active, config.token1Active);
        emit RewarderFunded(poolId, address(rewarder), MARKET_FUNDING);
    }

    /// @notice Unlink the current hook for a canonical token pair without touching its token balance.
    function removeMarket(address token0, address token1) external onlyOperatorOrOwner {
        bytes32 poolId = keccak256(abi.encode(token0, token1));
        address hook = deepstate.poolHook(poolId);
        deepstateV1Controller.setPoolHookConfig(token0, token1, address(0), false, false);
        emit MarketHookCleared(poolId, hook);
    }

    /// @notice Burn the full reward-token balance of a rewarder owned by this factory.
    function burnBalance(address rewarder) external onlyOperatorOrOwner {
        DeepstateRewarderV2(rewarder).burnBalance();
    }

    /// @notice Factory ownership cannot be renounced.
    function renounceOwnership() public payable override onlyOwner {
        revert NewOwnerIsZeroAddress();
    }

    function _quantitiesForUnits(address token, uint256 maxUnits)
        private
        view
        returns (uint160 startQuantity, uint160 maxQuantity)
    {
        uint256 unit = token == address(0) ? 1e18 : 10 ** uint256(IERC20Metadata(token).decimals());
        startQuantity = SafeCastLib.toUint160(unit);
        maxQuantity = SafeCastLib.toUint160(maxUnits * unit);
    }

    function _validateQuantityGrowth(address token, uint256 maxUnits) private pure {
        // One whole token is always the start. The pinned rewarder retains the natural 1,000x minimum.
        if (maxUnits > MAX_QUANTITY_GROWTH) revert QuantityGrowthTooLarge(token, maxUnits);
    }

    function _checkOperatorOrOwner() private view {
        if (msg.sender != operator) _checkOwner();
    }

    function _setOwner(address newOwner) internal override {
        if (newOwner == address(this)) revert InvalidOwner();
        super._setOwner(newOwner);
    }
}
