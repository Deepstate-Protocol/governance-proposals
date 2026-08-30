// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeepstateAddresses} from "./config/DeepstateAddresses.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ISablierLockupDeploymentIdentity {
    function comptroller() external view returns (address);
    function nativeToken() external view returns (address);
}

/// @notice Deterministic, idempotent release entrypoint for the three Rewarder V2 system contracts.
/// @dev `run()` is read-only and only prints the plan. Deployment requires deliberately selecting `deploy()`, setting
/// DEEPSTATE_CONFIRM_CREATE2_DEPLOYMENT=true, and passing Foundry's separate `--broadcast` flag.
contract DeployRewarderV2System is Script {
    uint256 private constant MINIMUM_COMBINED_ISSUANCE = 4;

    struct DeploymentPlan {
        address minterController;
        address v1Controller;
        address rewarderFactory;
        bytes32 minterInitCodeHash;
        bytes32 v1InitCodeHash;
        bytes32 factoryInitCodeHash;
        bytes minterInitCode;
        bytes v1InitCode;
        bytes factoryInitCode;
    }

    bytes32 public constant MINTER_SALT = 0x304c43c720fd4782c53fdae386391a6648ceb66d5392726bdc48bc3afbb7e029;
    bytes32 public constant V1_CONTROLLER_SALT = 0x082f06fa60ca7855e107a32607127f39acece481342eb9696ae09f1139dbe01a;
    bytes32 public constant FACTORY_SALT = 0xa12385de33bf96081bec74e7fa1a97a0559c8d62d2d152d12f9f6be35ffb018a;
    bytes32 public constant MINTER_RUNTIME_CODE_HASH =
        0x1ee95cbabbe86c1b22538cd152807c3b9a6f91653e5e901255d2ef9362ab826b;
    bytes32 public constant V1_CONTROLLER_RUNTIME_CODE_HASH =
        0x4a0cd3f52cc0439045246c716fef929520d7899c7e4cfae76878703bd0540fcc;
    bytes32 public constant FACTORY_RUNTIME_CODE_HASH =
        0xbfc29be7fcebeb221bf328f1d663d5e8a751dff91afd64cfc0a9872888872d9f;

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
        _deployIfMissing(V1_CONTROLLER_SALT, plan.v1InitCode, plan.v1Controller);
        _deployIfMissing(FACTORY_SALT, plan.factoryInitCode, plan.rewarderFactory);
        vm.stopBroadcast();

        _verifyMinterController(plan.minterController);
        _verifyV1Controller(plan.v1Controller);
        _verifyFactory(plan.rewarderFactory, plan.minterController, plan.v1Controller);
        _logPlan(plan);
        console2.log("CREATE2 deployment complete or already present; no governance permissions were activated");
    }

    /// @notice Return the three deterministic addresses and their creation-code hashes for manifest generation.
    function plannedAddresses()
        external
        pure
        returns (
            address minterController,
            address v1Controller,
            address rewarderFactory,
            bytes32 minterInitCodeHash,
            bytes32 v1InitCodeHash,
            bytes32 factoryInitCodeHash
        )
    {
        DeploymentPlan memory plan = _plan();
        return (
            plan.minterController,
            plan.v1Controller,
            plan.rewarderFactory,
            plan.minterInitCodeHash,
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
                DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP,
                DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP
            )
        );
        plan.minterInitCodeHash = keccak256(plan.minterInitCode);
        plan.minterController = _create2Address(MINTER_SALT, plan.minterInitCodeHash);

        plan.v1InitCode = abi.encodePacked(
            type(DeepstateV1Controller).creationCode, abi.encode(DeepstateAddresses.GOVERNOR, DeepstateAddresses.ROUTER)
        );
        plan.v1InitCodeHash = keccak256(plan.v1InitCode);
        plan.v1Controller = _create2Address(V1_CONTROLLER_SALT, plan.v1InitCodeHash);

        plan.factoryInitCode = abi.encodePacked(
            type(DeepstateRewarderFactory).creationCode,
            abi.encode(
                DeepstateAddresses.GOVERNOR,
                plan.v1Controller,
                plan.minterController,
                DeepstateAddresses.USDG,
                DeepstateAddresses.FACTORY_INITIAL_PRIMARY_FUNDING_BUDGET
            )
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
        if (!_hasMinimumMintHeadroom(DeepstateAddresses.DEEP, DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP)) {
            revert InvalidDeployedConfiguration(DeepstateAddresses.DEEP);
        }
    }

    /// @dev Internal so tests can prove the checked runtime, immutable configuration, and mutable release scalars at
    /// an occupied target. Complete Controller role absence additionally requires the event-history release gate.
    function _validateExistingDeployments(DeploymentPlan memory plan) internal view {
        if (plan.minterController.code.length != 0) _verifyMinterController(plan.minterController);
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
                || controller.mintCap() != DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP
                || controller.grossIssuanceCap() != DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP
                || controller.MINIMUM_COMBINED_ISSUANCE() != MINIMUM_COMBINED_ISSUANCE
                || !_hasMinimumMintHeadroom(address(controller.deepstateToken()), controller.mintCap())
                || controller.grossIssued() != 0 || controller.tokenAdministrationEndsAt() != 0
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
                || factory.usdG() != DeepstateAddresses.USDG
                || factory.initialFundingBudget() != DeepstateAddresses.FACTORY_INITIAL_PRIMARY_FUNDING_BUDGET
                || factory.operator() != address(0) || factory.nextDeploymentAt() != 0
                || factory.initialFundingCommitted() != 0
                || DeepstateMinterController(minterController).rolesOf(deployed) != 0
                || DeepstateV1Controller(v1Controller).rolesOf(deployed) != 0
        ) {
            revert InvalidDeployedConfiguration(deployed);
        }
    }

    function _requireCodeHash(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) revert CodeHashMismatch(target, expected, actual);
    }

    function _hasMinimumMintHeadroom(address token, uint256 cap) private view returns (bool) {
        return
            cap >= MINIMUM_COMBINED_ISSUANCE && DeepstateToken(token).totalSupply() <= cap - MINIMUM_COMBINED_ISSUANCE;
    }

    function _logPlan(DeploymentPlan memory plan) private view {
        console2.log("Chain ID", block.chainid);
        console2.log("CREATE2 deployer", DeepstateAddresses.CREATE2_DEPLOYER);
        console2.log("Minter Controller", plan.minterController);
        console2.log("Minter init-code hash");
        console2.logBytes32(plan.minterInitCodeHash);
        console2.log("Minter runtime code hash (zero until deployed)");
        console2.logBytes32(plan.minterController.codehash);
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
        console2.log("Live DEEP supply cap", DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP);
        console2.log("Controller gross issuance cap", DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP);
        console2.log(
            "Factory initial primary-funding budget", DeepstateAddresses.FACTORY_INITIAL_PRIMARY_FUNDING_BUDGET
        );
    }
}
