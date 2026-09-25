// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {DeepstateAddresses} from "./config/DeepstateAddresses.sol";
import {DGP004TeamAllocation} from "../src/DGP004TeamAllocation.sol";

contract DeployDGP004Allocation is Script {
    function run() public returns (DGP004TeamAllocation allocation) {
        vm.startBroadcast();
        allocation = new DGP004TeamAllocation(DeepstateAddresses.TWO_DEEP_GOVERNOR, DeepstateAddresses.TWO_DEEP);
        vm.stopBroadcast();
        console2.log("DGP004_ALLOCATION", address(allocation));
    }
}
