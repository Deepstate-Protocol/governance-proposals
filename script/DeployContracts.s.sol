// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeepstateAddresses} from "./config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";

/// @notice Deploys the four contracts required by DGP-001 with ordinary CREATE deployments.
contract DeployContracts is Script {
    struct Deployment {
        DeepstateMinterController minterController;
        DGP001Bootstrap dgp001Bootstrap;
        DeepstateV1Controller v1Controller;
        DeepstateRewarderFactory rewarderFactory;
    }

    error UnsupportedChain(uint256 actual, uint256 expected);

    /// @notice Deploy all four contracts from one Foundry script invocation.
    function run() public returns (Deployment memory deployment) {
        if (block.chainid != DeepstateAddresses.CHAIN_ID) {
            revert UnsupportedChain(block.chainid, DeepstateAddresses.CHAIN_ID);
        }

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        deployment.minterController = new DeepstateMinterController(
            DeepstateAddresses.GOVERNOR,
            DeepstateAddresses.DEEP,
            DeepstateAddresses.SABLIER_LOCKUP,
            DeepstateAddresses.DEEPSTATE_INC_SAFE,
            DeepstateAddresses.MINTER_MAX_SUPPLY
        );

        deployment.dgp001Bootstrap =
            new DGP001Bootstrap(DeepstateAddresses.GOVERNOR, DeepstateAddresses.DEEP, DeepstateAddresses.REWARDER);

        deployment.v1Controller = new DeepstateV1Controller(DeepstateAddresses.GOVERNOR, DeepstateAddresses.ROUTER);

        deployment.rewarderFactory = new DeepstateRewarderFactory(
            DeepstateAddresses.GOVERNOR, address(deployment.v1Controller), address(deployment.minterController)
        );

        vm.stopBroadcast();

        console2.log("DeepstateMinterController", address(deployment.minterController));
        console2.log("DGP001Bootstrap", address(deployment.dgp001Bootstrap));
        console2.log("DeepstateV1Controller", address(deployment.v1Controller));
        console2.log("DeepstateRewarderFactory", address(deployment.rewarderFactory));
        console2.log("DGP-001 endowment amount", deployment.dgp001Bootstrap.endowmentAmount());
    }
}
