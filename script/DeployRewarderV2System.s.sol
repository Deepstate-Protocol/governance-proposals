// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeepstateAddresses} from "./config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ISablierLockupDeploymentIdentity {
    function comptroller() external view returns (address);
    function nativeToken() external view returns (address);
}

interface ILegacyRewarderDeploymentIdentity {
    function owner() external view returns (address);
    function deepstate() external view returns (address);
    function rewardToken() external view returns (address);
    function poolId() external view returns (bytes32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function sideEmissionCap() external view returns (uint96);
    function emissionDuration() external view returns (uint32);
    function token0StartQuantity() external view returns (uint160);
    function token0MaxQuantity() external view returns (uint160);
    function token1StartQuantity() external view returns (uint160);
    function token1MaxQuantity() external view returns (uint160);
    function totalAccrued(address token) external view returns (uint96);
}

interface IRouterDeploymentIdentity {
    function poolHook(bytes32 poolId) external view returns (address);
}

/// @notice Deterministic, idempotent release entrypoint for the four Rewarder V2 system contracts.
/// @dev `run()` is read-only and only prints the plan. Deployment requires deliberately selecting `deploy()`, setting
/// DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT=true, and passing Foundry's separate `--broadcast` flag.
contract DeployRewarderV2System is Script {
    uint256 public constant MAXIMUM_LEGACY_ENDOWMENT = 300_000_000e18;
    uint256 public constant ACTIVATION_MARKET_PRIMARY_FUNDING = 100_000_000e18;
    uint256 public constant ACTIVATION_MARKET_VESTING = ACTIVATION_MARKET_PRIMARY_FUNDING * 30 / 70;
    uint256 public constant MINIMUM_ACTIVATION_ISSUANCE_HEADROOM =
        DeepstateAddresses.MINIMUM_ACTIVATION_ISSUANCE_HEADROOM;

    struct DeploymentPlan {
        address minterController;
        address dgp001Bootstrap;
        address v1Controller;
        address rewarderFactory;
        bytes32 minterInitCodeHash;
        bytes32 bootstrapInitCodeHash;
        bytes32 v1InitCodeHash;
        bytes32 factoryInitCodeHash;
        bytes minterInitCode;
        bytes bootstrapInitCode;
        bytes v1InitCode;
        bytes factoryInitCode;
    }

    bytes32 public constant MINTER_SALT = 0x304c43c720fd4782c53fdae386391a6648ceb66d5392726bdc48bc3afbb7e029;
    bytes32 public constant DGP001_BOOTSTRAP_SALT = 0xa9d987fd2fc64a5101bf906ead9f947a9630478782ca6ed34786b4d62a940fd9;
    bytes32 public constant V1_CONTROLLER_SALT = 0x082f06fa60ca7855e107a32607127f39acece481342eb9696ae09f1139dbe01a;
    bytes32 public constant FACTORY_SALT = 0xa12385de33bf96081bec74e7fa1a97a0559c8d62d2d152d12f9f6be35ffb018a;
    bytes32 public constant MINTER_RUNTIME_CODE_HASH = DeepstateAddresses.MINTER_CONTROLLER_CODEHASH;
    bytes32 public constant DGP001_BOOTSTRAP_RUNTIME_CODE_HASH = DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH;
    bytes32 public constant V1_CONTROLLER_RUNTIME_CODE_HASH = DeepstateAddresses.V1_CONTROLLER_CODEHASH;
    bytes32 public constant FACTORY_RUNTIME_CODE_HASH = DeepstateAddresses.REWARDER_FACTORY_CODEHASH;

    error CodeHashMismatch(address target, bytes32 expected, bytes32 actual);
    error Create2DeploymentFailed(address expected);
    error DeploymentNotConfirmed();
    error InvalidDeployedConfiguration(address target);
    error UnsupportedChain(uint256 actual, uint256 expected);

    /// @notice Validate immutable live dependencies and print the exact CREATE2 release plan without changing state.
    function run() public view {
        _validateLiveDependencies();
        DeploymentPlan memory plan = _plan();
        _validateExistingDeployments(plan);
        _logPlan(plan);
        console2.log("Read-only plan complete; no deployment transaction was broadcast");
    }

    /// @notice Explicit deployment path. Existing exact deployments are verified and skipped.
    /// @dev A real deployment additionally requires Foundry's `--broadcast`; without it this function is a simulation.
    function deploy() public {
        if (!vm.envOr("DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT", false)) revert DeploymentNotConfirmed();
        _validateLiveDependencies();
        DeploymentPlan memory plan = _plan();
        _validateExistingDeployments(plan);

        vm.startBroadcast();
        _deployIfMissing(MINTER_SALT, plan.minterInitCode, plan.minterController);
        _deployIfMissing(DGP001_BOOTSTRAP_SALT, plan.bootstrapInitCode, plan.dgp001Bootstrap);
        _deployIfMissing(V1_CONTROLLER_SALT, plan.v1InitCode, plan.v1Controller);
        _deployIfMissing(FACTORY_SALT, plan.factoryInitCode, plan.rewarderFactory);
        vm.stopBroadcast();

        _verifyMinterController(plan.minterController);
        _verifyBootstrap(plan.dgp001Bootstrap);
        _verifyV1Controller(plan.v1Controller);
        _verifyFactory(plan.rewarderFactory, plan.minterController, plan.v1Controller);
        _logPlan(plan);
        console2.log("CREATE2 deployment complete or already present; no governance permissions were activated");
    }

    /// @notice Return the four deterministic addresses and their creation-code hashes for manifest generation.
    function plannedAddresses()
        external
        pure
        returns (
            address minterController,
            address dgp001Bootstrap,
            address v1Controller,
            address rewarderFactory,
            bytes32 minterInitCodeHash,
            bytes32 bootstrapInitCodeHash,
            bytes32 v1InitCodeHash,
            bytes32 factoryInitCodeHash
        )
    {
        DeploymentPlan memory plan = _plan();
        return (
            plan.minterController,
            plan.dgp001Bootstrap,
            plan.v1Controller,
            plan.rewarderFactory,
            plan.minterInitCodeHash,
            plan.bootstrapInitCodeHash,
            plan.v1InitCodeHash,
            plan.factoryInitCodeHash
        );
    }

    /// @dev Internal so the release plan can be exercised end-to-end by the offline deployment state machine.
    function _plan() internal pure returns (DeploymentPlan memory plan) {
        plan.minterInitCode = abi.encodePacked(
            type(DeepstateMinterController).creationCode,
            abi.encode(
                DeepstateAddresses.GOVERNOR,
                DeepstateAddresses.DEEP,
                DeepstateAddresses.SABLIER_LOCKUP,
                DeepstateAddresses.DEEPSTATE_INC_SAFE,
                DeepstateAddresses.MINTER_MAX_SUPPLY
            )
        );
        plan.minterInitCodeHash = keccak256(plan.minterInitCode);
        plan.minterController = _create2Address(MINTER_SALT, plan.minterInitCodeHash);

        plan.bootstrapInitCode = abi.encodePacked(
            type(DGP001Bootstrap).creationCode,
            abi.encode(DeepstateAddresses.GOVERNOR, DeepstateAddresses.DEEP, DeepstateAddresses.REWARDER)
        );
        plan.bootstrapInitCodeHash = keccak256(plan.bootstrapInitCode);
        plan.dgp001Bootstrap = _create2Address(DGP001_BOOTSTRAP_SALT, plan.bootstrapInitCodeHash);

        plan.v1InitCode = abi.encodePacked(
            type(DeepstateV1Controller).creationCode, abi.encode(DeepstateAddresses.GOVERNOR, DeepstateAddresses.ROUTER)
        );
        plan.v1InitCodeHash = keccak256(plan.v1InitCode);
        plan.v1Controller = _create2Address(V1_CONTROLLER_SALT, plan.v1InitCodeHash);

        plan.factoryInitCode = abi.encodePacked(
            type(DeepstateRewarderFactory).creationCode,
            abi.encode(DeepstateAddresses.GOVERNOR, plan.v1Controller, plan.minterController)
        );
        plan.factoryInitCodeHash = keccak256(plan.factoryInitCode);
        plan.rewarderFactory = _create2Address(FACTORY_SALT, plan.factoryInitCodeHash);
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), DeepstateAddresses.CREATE2_DEPLOYER, salt, initCodeHash))
                )
            )
        );
    }

    /// @dev Internal so partial deployment and idempotent recovery can be invariant-tested without bypassing
    /// the production entrypoint's live-dependency and confirmation gates.
    function _deployIfMissing(bytes32 salt, bytes memory initCode, address expected) internal {
        if (expected.code.length != 0) return;
        (bool success, bytes memory result) = DeepstateAddresses.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
        if (expected.code.length == 0) revert Create2DeploymentFailed(expected);
    }

    function _validateLiveDependencies() private view {
        if (block.chainid != DeepstateAddresses.CHAIN_ID) {
            revert UnsupportedChain(block.chainid, DeepstateAddresses.CHAIN_ID);
        }
        _requireCodeHash(DeepstateAddresses.GOVERNOR, DeepstateAddresses.GOVERNOR_CODEHASH);
        _requireCodeHash(DeepstateAddresses.DEEP, DeepstateAddresses.DEEP_CODEHASH);
        _requireCodeHash(DeepstateAddresses.ROUTER, DeepstateAddresses.ROUTER_CODEHASH);
        _requireCodeHash(DeepstateAddresses.REWARDER, DeepstateAddresses.REWARDER_CODEHASH);
        _requireCodeHash(DeepstateAddresses.USDG, DeepstateAddresses.USDG_CODEHASH);
        _requireCodeHash(DeepstateAddresses.USDG_IMPLEMENTATION, DeepstateAddresses.USDG_IMPLEMENTATION_CODEHASH);
        _requireCodeHash(DeepstateAddresses.DEEPSTATE_INC_SAFE, DeepstateAddresses.DEEPSTATE_INC_SAFE_CODEHASH);
        _requireCodeHash(DeepstateAddresses.SABLIER_LOCKUP, DeepstateAddresses.SABLIER_LOCKUP_CODEHASH);
        _requireCodeHash(DeepstateAddresses.SABLIER_COMPTROLLER, DeepstateAddresses.SABLIER_COMPTROLLER_CODEHASH);
        _requireCodeHash(
            DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION,
            DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH
        );
        _requireCodeHash(DeepstateAddresses.CREATE2_DEPLOYER, DeepstateAddresses.CREATE2_DEPLOYER_CODEHASH);

        address comptroller = ISablierLockupDeploymentIdentity(DeepstateAddresses.SABLIER_LOCKUP).comptroller();
        if (comptroller != DeepstateAddresses.SABLIER_COMPTROLLER) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.SABLIER_LOCKUP);
        }
        if (
            ISablierLockupDeploymentIdentity(DeepstateAddresses.SABLIER_LOCKUP).nativeToken() == DeepstateAddresses.DEEP
        ) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.SABLIER_LOCKUP);
        }
        _verifyLegacyRewarder();
        if (
            IRouterDeploymentIdentity(DeepstateAddresses.ROUTER).poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID)
                != DeepstateAddresses.REWARDER
        ) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.ROUTER);
        }
        if (!_hasActivationSupplyHeadroom(DeepstateAddresses.DEEP, DeepstateAddresses.MINTER_MAX_SUPPLY)) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.DEEP);
        }
    }

    /// @dev Internal so tests can prove the checked runtime, immutable configuration, and mutable release scalars at
    /// an occupied target. Complete Controller role absence additionally requires the event-history release gate.
    function _validateExistingDeployments(DeploymentPlan memory plan) internal view {
        if (
            plan.minterController != DeepstateAddresses.MINTER_CONTROLLER
                || plan.dgp001Bootstrap != DeepstateAddresses.DGP001_BOOTSTRAP
                || plan.v1Controller != DeepstateAddresses.V1_CONTROLLER
                || plan.rewarderFactory != DeepstateAddresses.REWARDER_FACTORY
        ) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.CREATE2_DEPLOYER);
        }
        if (plan.minterController.code.length != 0) _verifyMinterController(plan.minterController);
        if (plan.dgp001Bootstrap.code.length != 0) {
            _verifyBootstrap(plan.dgp001Bootstrap);
        }
        if (plan.v1Controller.code.length != 0) _verifyV1Controller(plan.v1Controller);
        if (plan.rewarderFactory.code.length != 0) {
            _verifyFactory(plan.rewarderFactory, plan.minterController, plan.v1Controller);
        }
    }

    function _verifyMinterController(address deployed) internal view {
        DeepstateMinterController controller = DeepstateMinterController(deployed);
        if (
            deployed.codehash != MINTER_RUNTIME_CODE_HASH || controller.owner() != DeepstateAddresses.GOVERNOR
                || address(controller.deepstateToken()) != DeepstateAddresses.DEEP
                || address(controller.sablierLockup()) != DeepstateAddresses.SABLIER_LOCKUP
                || controller.recipient() != DeepstateAddresses.DEEPSTATE_INC_SAFE
                || controller.maxSupply() != DeepstateAddresses.MINTER_MAX_SUPPLY
                || !_hasActivationSupplyHeadroom(address(controller.deepstateToken()), controller.maxSupply())
                || controller.tokenAdministrationEndsAt() != 0
        ) {
            revert InvalidDeployedConfiguration(deployed);
        }
    }

    function _verifyBootstrap(address deployed) internal view {
        DGP001Bootstrap bootstrap = DGP001Bootstrap(deployed);
        DeepstateToken token = DeepstateToken(DeepstateAddresses.DEEP);
        if (
            deployed.codehash != DGP001_BOOTSTRAP_RUNTIME_CODE_HASH
                || bootstrap.governor() != DeepstateAddresses.GOVERNOR
                || address(bootstrap.deepstateToken()) != DeepstateAddresses.DEEP || bootstrap.endowmentAmount() == 0
                || bootstrap.endowmentAmount() > MAXIMUM_LEGACY_ENDOWMENT
                || token.hasRole(token.MINTER_ROLE(), deployed)
        ) {
            revert InvalidDeployedConfiguration(deployed);
        }
    }

    function _verifyV1Controller(address deployed) internal view {
        DeepstateV1Controller controller = DeepstateV1Controller(deployed);
        if (
            deployed.codehash != V1_CONTROLLER_RUNTIME_CODE_HASH || controller.owner() != DeepstateAddresses.GOVERNOR
                || address(controller.deepstate()) != DeepstateAddresses.ROUTER
        ) {
            revert InvalidDeployedConfiguration(deployed);
        }
    }

    function _verifyFactory(address deployed, address minterController, address v1Controller) internal view {
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(deployed);
        if (
            deployed.codehash != FACTORY_RUNTIME_CODE_HASH || factory.owner() != DeepstateAddresses.GOVERNOR
                || address(factory.deepstateV1Controller()) != v1Controller
                || address(factory.minterController()) != minterController
                || address(factory.deepstate()) != DeepstateAddresses.ROUTER
                || address(factory.rewardToken()) != DeepstateAddresses.DEEP
                || factory.MARKET_FUNDING() != ACTIVATION_MARKET_PRIMARY_FUNDING
                || factory.SIDE_EMISSION_CAP() != 50_000_000e18 || factory.EMISSION_DURATION() != 365 days
                || factory.DEPLOYMENT_COOLDOWN() != 3 days || factory.MAX_QUANTITY_GROWTH() != 1_000_000
                || factory.operator() != address(0) || factory.nextDeploymentAt() != 0
                || DeepstateMinterController(minterController).rolesOf(deployed) != 0
                || DeepstateV1Controller(v1Controller).rolesOf(deployed) != 0
        ) {
            revert InvalidDeployedConfiguration(deployed);
        }
    }

    function _verifyLegacyRewarder() internal view {
        ILegacyRewarderDeploymentIdentity legacy = ILegacyRewarderDeploymentIdentity(DeepstateAddresses.REWARDER);
        if (
            legacy.owner() != DeepstateAddresses.GOVERNOR || legacy.deepstate() != DeepstateAddresses.ROUTER
                || legacy.rewardToken() != DeepstateAddresses.DEEP
                || legacy.poolId() != DeepstateAddresses.NVDA_USDG_POOL_ID || legacy.token0() != DeepstateAddresses.USDG
                || legacy.token1() != DeepstateAddresses.NVDA
                || legacy.sideEmissionCap() != DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP
                || legacy.emissionDuration() != DeepstateAddresses.LEGACY_REWARDER_EMISSION_DURATION
                || legacy.token0StartQuantity() != DeepstateAddresses.LEGACY_USDG_START_QUANTITY
                || legacy.token0MaxQuantity() != DeepstateAddresses.LEGACY_USDG_MAX_QUANTITY
                || legacy.token1StartQuantity() != DeepstateAddresses.LEGACY_NVDA_START_QUANTITY
                || legacy.token1MaxQuantity() != DeepstateAddresses.LEGACY_NVDA_MAX_QUANTITY
        ) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.REWARDER);
        }

        // Both calls are required to decode successfully; the upper bound protects the immutable side cap assumption.
        uint96 token0Accrued = legacy.totalAccrued(DeepstateAddresses.USDG);
        uint96 token1Accrued = legacy.totalAccrued(DeepstateAddresses.NVDA);
        if (
            token0Accrued > DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP
                || token1Accrued > DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP
        ) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.REWARDER);
        }
        uint256 endowmentAmount = (uint256(token0Accrued) + uint256(token1Accrued)) * 30 / 100;
        if (endowmentAmount == 0 || endowmentAmount > MAXIMUM_LEGACY_ENDOWMENT) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.REWARDER);
        }
    }

    function _requireCodeHash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(target, expected, actual);
    }

    function _hasActivationSupplyHeadroom(address token, uint256 maxSupply) private view returns (bool) {
        return maxSupply >= MINIMUM_ACTIVATION_ISSUANCE_HEADROOM
            && DeepstateToken(token).totalSupply() <= maxSupply - MINIMUM_ACTIVATION_ISSUANCE_HEADROOM;
    }

    function _logPlan(DeploymentPlan memory plan) private view {
        console2.log("Chain ID", block.chainid);
        console2.log("CREATE2 deployer", DeepstateAddresses.CREATE2_DEPLOYER);
        console2.log("Minter Controller", plan.minterController);
        console2.log("Minter init-code hash");
        console2.logBytes32(plan.minterInitCodeHash);
        console2.log("Minter runtime code hash (zero until deployed)");
        console2.logBytes32(plan.minterController.codehash);
        console2.log("DGP-001 Bootstrap", plan.dgp001Bootstrap);
        console2.log("DGP-001 Bootstrap init-code hash");
        console2.logBytes32(plan.bootstrapInitCodeHash);
        console2.log("DGP-001 Bootstrap runtime code hash (zero until deployed)");
        console2.logBytes32(plan.dgp001Bootstrap.codehash);
        console2.log("V1 Controller", plan.v1Controller);
        console2.log("V1 Controller init-code hash");
        console2.logBytes32(plan.v1InitCodeHash);
        console2.log("V1 Controller runtime code hash (zero until deployed)");
        console2.logBytes32(plan.v1Controller.codehash);
        console2.log("Rewarder Factory", plan.rewarderFactory);
        console2.log("Rewarder Factory init-code hash");
        console2.logBytes32(plan.factoryInitCodeHash);
        console2.log("Rewarder Factory runtime code hash (zero until deployed)");
        console2.logBytes32(plan.rewarderFactory.codehash);
        console2.log("Maximum DEEP supply", DeepstateAddresses.MINTER_MAX_SUPPLY);
        console2.log("Minimum activation issuance headroom", MINIMUM_ACTIVATION_ISSUANCE_HEADROOM);
    }
}
