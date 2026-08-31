// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepstateProposalScript} from "../../DeepstateProposalScript.s.sol";
import {DeepstateAddresses} from "../../config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../../src/DeepstateV1Controller.sol";
import {IDeepstateLegacyRewarder} from "../../../src/interfaces/IDeepstateLegacyRewarder.sol";
import {IDeepstateV1} from "../../../src/interfaces/IDeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ISablierDGP001View {
    function comptroller() external view returns (address);
    function nativeToken() external view returns (address);
    function ownerOf(uint256 streamId) external view returns (address owner);
    function getRecipient(uint256 streamId) external view returns (address recipient);
    function getSender(uint256 streamId) external view returns (address sender);
    function getUnderlyingToken(uint256 streamId) external view returns (IERC20 token);
    function getDepositedAmount(uint256 streamId) external view returns (uint128 depositedAmount);
    function getStartTime(uint256 streamId) external view returns (uint40 startTime);
    function getEndTime(uint256 streamId) external view returns (uint40 endTime);
    function getCliffTime(uint256 streamId) external view returns (uint40 cliffTime);
    function getGranularity(uint256 streamId) external view returns (uint40 granularity);
    function isCancelable(uint256 streamId) external view returns (bool result);
    function isTransferable(uint256 streamId) external view returns (bool result);
    function nextStreamId() external view returns (uint256);
}

interface IDeepstateV1DGP001View is IDeepstateV1 {
    function feeConfig() external view returns (address recipient, uint16 bps);
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

interface IDeepstateLegacyRewarderDGP001View is IDeepstateLegacyRewarder {
    function owner() external view returns (address);
    function sideEmissionCap() external view returns (uint96);
    function emissionDuration() external view returns (uint32);
    function token0StartQuantity() external view returns (uint160);
    function token0MaxQuantity() external view returns (uint160);
    function token1StartQuantity() external view returns (uint160);
    function token1MaxQuantity() external view returns (uint160);
}

interface IDeepstateRoleAdminDGP001 {
    function grantRoles(address account, uint256 roles) external;
}

interface IUpgradeableBeaconDGP001View {
    function implementation() external view returns (address);
}

interface ISablierComptrollerDGP001View {
    function VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function oracle() external view returns (address);
    function MAX_FEE_USD() external view returns (uint256);
    function getMinFeeUSD(uint8 protocol) external view returns (uint256);
    function calculateMinFeeWei(uint8 protocol) external view returns (uint256);
}

interface ISafeDGP001View {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Exact DGP-001 payload, submission entrypoint, and live post-execution verifier.
contract DeployDGP001 is DeepstateProposalScript {
    address internal constant PROPOSER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    uint256 internal constant EXPECTED_PROPOSAL_ID =
        104_314_577_693_082_885_786_109_683_732_203_114_255_408_942_832_054_564_539_957_851_903_575_470_305_161;

    uint256 private constant _ACTION_COUNT = 10;
    bytes32 private constant _TOKEN_MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 private constant _FACTORY_MINTER_ROLE = 1;
    uint256 private constant _FACTORY_HOOK_MANAGER_ROLE = 1;
    uint256 private constant _MARKET_FUNDING = 100_000_000e18;
    uint256 private constant _MARKET_VESTING = _MARKET_FUNDING * 30 / 70;
    uint160 private constant _NVDA_START_QUANTITY = 1e18;
    uint160 private constant _NVDA_MAX_QUANTITY = 5_000e18;
    uint8 private constant _SABLIER_PROTOCOL_LOCKUP = 2;
    address private constant _SAFE_MODULES_SENTINEL = address(1);
    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    error PreconditionFailed(uint256 condition);
    error PostconditionFailed(uint256 condition);

    function proposer() public pure override returns (address) {
        return PROPOSER;
    }

    function expectedProposalId() public pure override returns (uint256) {
        return EXPECTED_PROPOSAL_ID;
    }

    /// @notice Reopens every live activation gate without submitting or executing the proposal.
    function validateActivationPreconditions() external view {
        _validateActivationPreconditions(true);
    }

    /// @notice Reopens the submission gates without requiring the market to remain idle throughout voting.
    function validateSubmissionPreconditions() external view {
        _validateActivationPreconditions(false);
    }

    function _beforeSubmission() internal view override {
        _validateActivationPreconditions(false);
    }

    function _beforeExecution() internal view override {
        _validateActivationPreconditions(true);
    }

    /// @notice Runs the same postconditions as `verifyExecution` without requiring a registered proposal.
    /// @dev Used by the proposal-specific authorized-call test; release verification should use `verifyExecution`.
    function verifyPostconditions() external view {
        _afterExecution();
    }

    function _buildProposal()
        internal
        view
        override
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description)
    {
        targets = new address[](_ACTION_COUNT);
        values = new uint256[](_ACTION_COUNT);
        calldatas = new bytes[](_ACTION_COUNT);

        targets[0] = DeepstateAddresses.DEEP;
        calldatas[0] =
            abi.encodeCall(IAccessControl.grantRole, (_TOKEN_MINTER_ROLE, DeepstateAddresses.DGP001_BOOTSTRAP));

        targets[1] = DeepstateAddresses.DGP001_BOOTSTRAP;
        calldatas[1] = abi.encodeCall(DGP001Bootstrap.execute, ());

        targets[2] = DeepstateAddresses.DEEP;
        calldatas[2] = abi.encodeCall(IAccessControl.grantRole, (bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));

        targets[3] = DeepstateAddresses.DEEP;
        calldatas[3] = abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), DeepstateAddresses.GOVERNOR));

        targets[4] = DeepstateAddresses.MINTER_CONTROLLER;
        calldatas[4] = abi.encodeCall(DeepstateMinterController.activateTokenAdministration, ());

        targets[5] = DeepstateAddresses.MINTER_CONTROLLER;
        calldatas[5] = abi.encodeCall(
            IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, _FACTORY_MINTER_ROLE)
        );

        targets[6] = DeepstateAddresses.ROUTER;
        calldatas[6] = abi.encodeCall(IDeepstateV1.transferOwnership, (DeepstateAddresses.V1_CONTROLLER));

        targets[7] = DeepstateAddresses.V1_CONTROLLER;
        calldatas[7] = abi.encodeCall(
            IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, _FACTORY_HOOK_MANAGER_ROLE)
        );

        targets[8] = DeepstateAddresses.REWARDER_FACTORY;
        DeepstateRewarderFactory.MarketConfig memory market = DeepstateRewarderFactory.MarketConfig({
            stockToken: DeepstateAddresses.NVDA,
            stockStartQuantity: _NVDA_START_QUANTITY,
            stockMaxQuantity: _NVDA_MAX_QUANTITY,
            stockBuySideActive: true,
            usdGBuySideActive: true
        });
        calldatas[8] = abi.encodeCall(DeepstateRewarderFactory.migrateMarket, (market, DeepstateAddresses.REWARDER));

        targets[9] = DeepstateAddresses.REWARDER_FACTORY;
        calldatas[9] = abi.encodeCall(DeepstateRewarderFactory.setOperator, (DeepstateAddresses.DEEPSTATE_INC_SAFE));

        description = vm.readFile("proposals/DGP-001.md");
    }

    function _afterExecution() internal view override {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1DGP001View router = IDeepstateV1DGP001View(DeepstateAddresses.ROUTER);
        IDeepstateLegacyRewarder legacy = IDeepstateLegacyRewarder(DeepstateAddresses.REWARDER);

        _check(DeepstateAddresses.MINTER_CONTROLLER.codehash == DeepstateAddresses.MINTER_CONTROLLER_CODEHASH, 1);
        _check(DeepstateAddresses.DGP001_BOOTSTRAP.codehash == DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH, 2);
        _check(DeepstateAddresses.V1_CONTROLLER.codehash == DeepstateAddresses.V1_CONTROLLER_CODEHASH, 3);
        _check(DeepstateAddresses.REWARDER_FACTORY.codehash == DeepstateAddresses.REWARDER_FACTORY_CODEHASH, 4);
        _check(minter.owner() == DeepstateAddresses.GOVERNOR, 5);
        _check(bootstrap.governor() == DeepstateAddresses.GOVERNOR, 6);
        _check(v1Controller.owner() == DeepstateAddresses.GOVERNOR, 7);
        _check(factory.owner() == DeepstateAddresses.GOVERNOR, 8);

        bytes32 defaultAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        _check(deep.defaultAdminCount() == 1, 9);
        _check(deep.hasRole(defaultAdminRole, DeepstateAddresses.MINTER_CONTROLLER), 10);
        _check(!deep.hasRole(defaultAdminRole, DeepstateAddresses.GOVERNOR), 11);
        _check(!deep.hasRole(defaultAdminRole, DeepstateAddresses.DGP001_BOOTSTRAP), 12);
        _check(!deep.hasRole(defaultAdminRole, DeepstateAddresses.REWARDER_FACTORY), 13);
        _check(deep.hasRole(tokenMinterRole, DeepstateAddresses.MINTER_CONTROLLER), 14);
        _check(!deep.hasRole(tokenMinterRole, DeepstateAddresses.GOVERNOR), 15);
        _check(!deep.hasRole(tokenMinterRole, DeepstateAddresses.DGP001_BOOTSTRAP), 16);
        _check(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER_FACTORY), 17);
        _check(!deep.hasRole(tokenMinterRole, DeepstateAddresses.DEEPSTATE_INC_SAFE), 18);
        _check(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER), 19);

        _check(address(bootstrap.deepstateToken()) == DeepstateAddresses.DEEP, 20);
        _check(address(bootstrap.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 21);
        _check(address(bootstrap.legacyRewarder()) == DeepstateAddresses.REWARDER, 22);
        _check(address(bootstrap.minterController()) == DeepstateAddresses.MINTER_CONTROLLER, 23);
        _check(bootstrap.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 24);
        _check(bootstrap.ENDOWMENT_PERCENT() == 30, 25);
        _check(bootstrap.VESTING_DURATION() == 365 days, 26);
        _check(bootstrap.STREAM_GRANULARITY() == 1 seconds, 27);
        _check(bootstrap.executed(), 28);
        _check(bootstrap.snapshotBlock() != 0 && bootstrap.snapshotBlock() <= block.number, 29);
        uint40 snapshotAt = bootstrap.snapshotAt();
        _check(snapshotAt != 0 && snapshotAt <= block.timestamp, 30);
        _check(bootstrap.snapshotToken0() == DeepstateAddresses.USDG, 31);
        _check(bootstrap.snapshotToken1() == DeepstateAddresses.NVDA, 32);
        _check(bootstrap.token0Accrued() == legacy.totalAccrued(DeepstateAddresses.USDG), 33);
        _check(bootstrap.token1Accrued() == legacy.totalAccrued(DeepstateAddresses.NVDA), 34);
        uint256 expectedTotalAccrued = uint256(bootstrap.token0Accrued()) + uint256(bootstrap.token1Accrued());
        uint256 expectedEndowment = expectedTotalAccrued * bootstrap.ENDOWMENT_PERCENT() / 100;
        _check(bootstrap.totalAccrued() == expectedTotalAccrued, 35);
        _check(bootstrap.endowmentAmount() == expectedEndowment && expectedEndowment != 0, 36);
        _check(deep.totalSupply() == bootstrap.postEndowmentSupply() + _MARKET_FUNDING + _MARKET_VESTING, 37);

        _check(address(minter.deepstateToken()) == DeepstateAddresses.DEEP, 38);
        _check(address(minter.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 39);
        _check(minter.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 40);
        _check(minter.mintCap() == DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP, 41);
        _check(minter.grossIssuanceCap() == DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP, 42);
        _check(minter.tokenAdministrationEndsAt() == snapshotAt + minter.TOKEN_ADMINISTRATION_DURATION(), 43);
        _check(minter.grossIssued() == deep.totalSupply(), 44);
        _check(deep.totalSupply() <= minter.mintCap(), 45);
        _check(minter.grossIssued() <= minter.grossIssuanceCap(), 46);
        _check(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_MINTER_ROLE, 47);
        _check(minter.rolesOf(DeepstateAddresses.DEEPSTATE_INC_SAFE) == 0, 48);

        _check(address(v1Controller.deepstate()) == DeepstateAddresses.ROUTER, 49);
        _check(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_HOOK_MANAGER_ROLE, 50);
        _check(v1Controller.rolesOf(DeepstateAddresses.DEEPSTATE_INC_SAFE) == 0, 51);
        _check(router.owner() == DeepstateAddresses.V1_CONTROLLER, 52);
        (address feeRecipient, uint16 feeBps) = router.feeConfig();
        _check(feeRecipient == DeepstateAddresses.STATE, 53);
        _check(feeBps == DeepstateAddresses.ROUTER_FEE_BPS, 54);

        _check(factory.operator() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 55);
        _check(address(factory.deepstateV1Controller()) == DeepstateAddresses.V1_CONTROLLER, 56);
        _check(address(factory.minterController()) == DeepstateAddresses.MINTER_CONTROLLER, 57);
        _check(address(factory.deepstate()) == DeepstateAddresses.ROUTER, 58);
        _check(address(factory.rewardToken()) == DeepstateAddresses.DEEP, 59);
        _check(factory.usdG() == DeepstateAddresses.USDG, 60);
        _check(factory.fundingBudget() == DeepstateAddresses.FACTORY_LIFETIME_FUNDING_BUDGET, 61);
        _check(factory.fundingCommitted() == _MARKET_FUNDING, 62);
        _check(factory.nextDeploymentAt() == uint256(snapshotAt) + factory.DEPLOYMENT_COOLDOWN(), 63);
        _check(factory.marketDeployed(DeepstateAddresses.NVDA_USDG_POOL_ID), 64);

        address rewarderAddress = factory.activeRewarder(DeepstateAddresses.NVDA_USDG_POOL_ID);
        _check(rewarderAddress != address(0), 65);
        _check(factory.rewarderPool(rewarderAddress) == DeepstateAddresses.NVDA_USDG_POOL_ID, 66);
        _check(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID) == rewarderAddress, 67);

        DeepstateRewarderV2 rewarder = DeepstateRewarderV2(rewarderAddress);
        _check(rewarder.owner() == DeepstateAddresses.REWARDER_FACTORY, 68);
        _check(!rewarder.retired(), 69);
        _check(rewarder.deepstate() == DeepstateAddresses.ROUTER, 70);
        _check(rewarder.rewardToken() == DeepstateAddresses.DEEP, 71);
        _check(rewarder.poolId() == DeepstateAddresses.NVDA_USDG_POOL_ID, 72);
        _check(rewarder.token0() == DeepstateAddresses.USDG, 73);
        _check(rewarder.token1() == DeepstateAddresses.NVDA, 74);
        _check(rewarder.sideEmissionCap() == factory.SIDE_EMISSION_CAP(), 75);
        _check(rewarder.emissionDuration() == 365 days, 76);
        _check(rewarder.token0StartQuantity() == factory.USDG_START_QUANTITY(), 77);
        _check(rewarder.token0MaxQuantity() == factory.USDG_MAX_QUANTITY(), 78);
        _check(rewarder.token1StartQuantity() == _NVDA_START_QUANTITY, 79);
        _check(rewarder.token1MaxQuantity() == _NVDA_MAX_QUANTITY, 80);
        // The CREATE child address is predictable and may hold unsolicited DEEP before deployment. Factory accounting
        // and the Controller's issuance receipt prove the exact 100 million mint; extra balance cannot increase caps.
        _check(deep.balanceOf(rewarderAddress) >= _MARKET_FUNDING, 81);

        _check(legacy.poolId() == DeepstateAddresses.NVDA_USDG_POOL_ID, 82);
        _check(legacy.deepstate() == DeepstateAddresses.ROUTER, 83);
        _check(legacy.rewardToken() == DeepstateAddresses.DEEP, 84);

        uint256 endowmentStreamId = bootstrap.streamId();
        _check(endowmentStreamId != 0, 85);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);
        _checkStream(
            lockup, endowmentStreamId, expectedEndowment, snapshotAt, DeepstateAddresses.DGP001_BOOTSTRAP, 1, 86
        );
        _checkStream(
            lockup, endowmentStreamId + 1, _MARKET_VESTING, snapshotAt, DeepstateAddresses.MINTER_CONTROLLER, 1, 97
        );
        _check(lockup.nextStreamId() > endowmentStreamId + 1, 108);
        _check(deep.allowance(DeepstateAddresses.DGP001_BOOTSTRAP, DeepstateAddresses.SABLIER_LOCKUP) == 0, 110);
        _check(deep.allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP) == 0, 112);

        _check(DeepstateAddresses.DEEP.codehash == DeepstateAddresses.DEEP_CODEHASH, 113);
        _check(DeepstateAddresses.ROUTER.codehash == DeepstateAddresses.ROUTER_CODEHASH, 114);
        _check(DeepstateAddresses.REWARDER.codehash == DeepstateAddresses.REWARDER_CODEHASH, 115);
        _check(DeepstateAddresses.USDG.codehash == DeepstateAddresses.USDG_CODEHASH, 116);
        _check(DeepstateAddresses.NVDA.codehash == DeepstateAddresses.NVDA_CODEHASH, 117);
        _check(DeepstateAddresses.SABLIER_LOCKUP.codehash == DeepstateAddresses.SABLIER_LOCKUP_CODEHASH, 118);
        _check(DeepstateAddresses.SABLIER_COMPTROLLER.codehash == DeepstateAddresses.SABLIER_COMPTROLLER_CODEHASH, 119);
        _check(DeepstateAddresses.DEEPSTATE_INC_SAFE.codehash == DeepstateAddresses.DEEPSTATE_INC_SAFE_CODEHASH, 120);
        _check(lockup.comptroller() == DeepstateAddresses.SABLIER_COMPTROLLER, 121);
        _check(lockup.nativeToken() != DeepstateAddresses.DEEP, 122);
        _check(DeepstateAddresses.USDG_IMPLEMENTATION.codehash == DeepstateAddresses.USDG_IMPLEMENTATION_CODEHASH, 123);
        _check(DeepstateAddresses.NVDA_BEACON.codehash == DeepstateAddresses.NVDA_BEACON_CODEHASH, 124);
        _check(DeepstateAddresses.NVDA_IMPLEMENTATION.codehash == DeepstateAddresses.NVDA_IMPLEMENTATION_CODEHASH, 125);
        _check(
            DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION.codehash
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH,
            126
        );
        _check(
            DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON.codehash
                == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON_CODEHASH,
            127
        );
        _check(_implementationOf(DeepstateAddresses.USDG) == DeepstateAddresses.USDG_IMPLEMENTATION, 128);
        _check(
            IUpgradeableBeaconDGP001View(DeepstateAddresses.NVDA_BEACON).implementation()
                == DeepstateAddresses.NVDA_IMPLEMENTATION,
            129
        );
        _check(
            _implementationOf(DeepstateAddresses.SABLIER_COMPTROLLER)
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION,
            130
        );
        _check(_safeSingleton() == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON, 131);
        _checkSablierComptroller(132, false);
        _checkSafe(138, false);
        _check(_beaconOf(DeepstateAddresses.NVDA) == DeepstateAddresses.NVDA_BEACON, 144);
    }

    function _validateActivationPreconditions(bool requireIdleMarket) private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1DGP001View router = IDeepstateV1DGP001View(DeepstateAddresses.ROUTER);
        IDeepstateLegacyRewarderDGP001View legacy = IDeepstateLegacyRewarderDGP001View(DeepstateAddresses.REWARDER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);

        _pre(DeepstateAddresses.MINTER_CONTROLLER.codehash == DeepstateAddresses.MINTER_CONTROLLER_CODEHASH, 1);
        _pre(DeepstateAddresses.DGP001_BOOTSTRAP.codehash == DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH, 2);
        _pre(DeepstateAddresses.V1_CONTROLLER.codehash == DeepstateAddresses.V1_CONTROLLER_CODEHASH, 3);
        _pre(DeepstateAddresses.REWARDER_FACTORY.codehash == DeepstateAddresses.REWARDER_FACTORY_CODEHASH, 110);
        _pre(DeepstateAddresses.DEEP.codehash == DeepstateAddresses.DEEP_CODEHASH, 4);
        _pre(DeepstateAddresses.ROUTER.codehash == DeepstateAddresses.ROUTER_CODEHASH, 5);
        _pre(DeepstateAddresses.REWARDER.codehash == DeepstateAddresses.REWARDER_CODEHASH, 6);
        _pre(DeepstateAddresses.USDG.codehash == DeepstateAddresses.USDG_CODEHASH, 7);
        _pre(DeepstateAddresses.NVDA.codehash == DeepstateAddresses.NVDA_CODEHASH, 8);
        _pre(DeepstateAddresses.SABLIER_LOCKUP.codehash == DeepstateAddresses.SABLIER_LOCKUP_CODEHASH, 9);
        _pre(DeepstateAddresses.SABLIER_COMPTROLLER.codehash == DeepstateAddresses.SABLIER_COMPTROLLER_CODEHASH, 10);
        _pre(DeepstateAddresses.DEEPSTATE_INC_SAFE.codehash == DeepstateAddresses.DEEPSTATE_INC_SAFE_CODEHASH, 11);

        _pre(minter.owner() == DeepstateAddresses.GOVERNOR, 12);
        _pre(v1Controller.owner() == DeepstateAddresses.GOVERNOR, 13);
        _pre(factory.owner() == DeepstateAddresses.GOVERNOR, 14);

        bytes32 defaultAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        _pre(deep.defaultAdminCount() == 1, 15);
        _pre(deep.hasRole(defaultAdminRole, DeepstateAddresses.GOVERNOR), 16);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.MINTER_CONTROLLER), 17);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.REWARDER_FACTORY), 18);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.GOVERNOR), 19);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.MINTER_CONTROLLER), 20);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER_FACTORY), 21);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.DEEPSTATE_INC_SAFE), 22);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER), 23);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.DGP001_BOOTSTRAP), 111);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.DGP001_BOOTSTRAP), 112);

        _pre(address(minter.deepstateToken()) == DeepstateAddresses.DEEP, 24);
        _pre(address(minter.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 25);
        _pre(minter.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 26);
        _pre(minter.mintCap() == DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP, 27);
        _pre(minter.grossIssuanceCap() == DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP, 28);
        _pre(minter.grossIssued() == 0, 29);
        _pre(minter.tokenAdministrationEndsAt() == 0, 30);
        _pre(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == 0, 31);
        _pre(minter.rolesOf(DeepstateAddresses.DEEPSTATE_INC_SAFE) == 0, 32);

        _pre(bootstrap.governor() == DeepstateAddresses.GOVERNOR, 113);
        _pre(address(bootstrap.deepstateToken()) == DeepstateAddresses.DEEP, 114);
        _pre(address(bootstrap.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 115);
        _pre(address(bootstrap.legacyRewarder()) == DeepstateAddresses.REWARDER, 116);
        _pre(address(bootstrap.minterController()) == DeepstateAddresses.MINTER_CONTROLLER, 117);
        _pre(bootstrap.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 118);
        _pre(bootstrap.ENDOWMENT_PERCENT() == 30, 119);
        _pre(bootstrap.VESTING_DURATION() == 365 days, 120);
        _pre(bootstrap.STREAM_GRANULARITY() == 1 seconds, 121);
        _pre(!bootstrap.executed(), 122);
        _pre(bootstrap.snapshotBlock() == 0, 123);
        _pre(bootstrap.snapshotAt() == 0, 124);
        _pre(bootstrap.snapshotToken0() == address(0) && bootstrap.snapshotToken1() == address(0), 125);
        _pre(bootstrap.token0Accrued() == 0 && bootstrap.token1Accrued() == 0, 126);
        _pre(bootstrap.totalAccrued() == 0, 127);
        _pre(bootstrap.endowmentAmount() == 0, 128);
        _pre(bootstrap.preexistingBalanceBurned() == 0, 134);
        _pre(bootstrap.postEndowmentSupply() == 0, 129);
        _pre(bootstrap.streamId() == 0, 130);
        _pre(deep.allowance(DeepstateAddresses.DGP001_BOOTSTRAP, DeepstateAddresses.SABLIER_LOCKUP) == 0, 132);

        _pre(address(v1Controller.deepstate()) == DeepstateAddresses.ROUTER, 41);
        _pre(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == 0, 42);
        _pre(v1Controller.rolesOf(DeepstateAddresses.DEEPSTATE_INC_SAFE) == 0, 43);
        _pre(router.owner() == DeepstateAddresses.GOVERNOR, 44);
        (address feeRecipient, uint16 feeBps) = router.feeConfig();
        _pre(feeRecipient == DeepstateAddresses.STATE, 45);
        _pre(feeBps == DeepstateAddresses.ROUTER_FEE_BPS, 46);
        _pre(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID) == DeepstateAddresses.REWARDER, 47);

        _pre(factory.operator() == address(0), 48);
        _pre(address(factory.deepstateV1Controller()) == DeepstateAddresses.V1_CONTROLLER, 49);
        _pre(address(factory.minterController()) == DeepstateAddresses.MINTER_CONTROLLER, 50);
        _pre(address(factory.deepstate()) == DeepstateAddresses.ROUTER, 51);
        _pre(address(factory.rewardToken()) == DeepstateAddresses.DEEP, 52);
        _pre(factory.usdG() == DeepstateAddresses.USDG, 53);
        _pre(factory.fundingBudget() == DeepstateAddresses.FACTORY_LIFETIME_FUNDING_BUDGET, 54);
        _pre(factory.MARKET_FUNDING() == _MARKET_FUNDING, 55);
        _pre(factory.SIDE_EMISSION_CAP() == _MARKET_FUNDING / 2, 56);
        _pre(factory.EMISSION_DURATION() == 365 days, 57);
        _pre(factory.DEPLOYMENT_COOLDOWN() == 3 days, 58);
        _pre(factory.USDG_START_QUANTITY() == 1e6, 59);
        _pre(factory.USDG_MAX_QUANTITY() == 1_000_000e6, 60);
        _pre(factory.MAX_QUANTITY_GROWTH() == 1_000_000, 61);
        _pre(factory.fundingCommitted() == 0, 62);
        _pre(factory.nextDeploymentAt() == 0, 63);
        _pre(!factory.marketDeployed(DeepstateAddresses.NVDA_USDG_POOL_ID), 64);
        _pre(factory.activeRewarder(DeepstateAddresses.NVDA_USDG_POOL_ID) == address(0), 65);

        _pre(legacy.owner() == DeepstateAddresses.GOVERNOR, 66);
        _pre(legacy.deepstate() == DeepstateAddresses.ROUTER, 67);
        _pre(legacy.rewardToken() == DeepstateAddresses.DEEP, 68);
        _pre(legacy.poolId() == DeepstateAddresses.NVDA_USDG_POOL_ID, 69);
        _pre(legacy.token0() == DeepstateAddresses.USDG, 70);
        _pre(legacy.token1() == DeepstateAddresses.NVDA, 71);
        _pre(legacy.sideEmissionCap() == DeepstateAddresses.LEGACY_REWARDER_SIDE_EMISSION_CAP, 72);
        _pre(legacy.emissionDuration() == DeepstateAddresses.LEGACY_REWARDER_EMISSION_DURATION, 73);
        _pre(legacy.token0StartQuantity() == DeepstateAddresses.LEGACY_USDG_START_QUANTITY, 74);
        _pre(legacy.token0MaxQuantity() == DeepstateAddresses.LEGACY_USDG_MAX_QUANTITY, 75);
        _pre(legacy.token1StartQuantity() == DeepstateAddresses.LEGACY_NVDA_START_QUANTITY, 76);
        _pre(legacy.token1MaxQuantity() == DeepstateAddresses.LEGACY_NVDA_MAX_QUANTITY, 77);

        if (requireIdleMarket) {
            bytes32 bookId = router.activeBookId(DeepstateAddresses.USDG, DeepstateAddresses.NVDA);
            (uint32 bidNonce, uint160 bidAmount) = router.topOrder(bookId, true);
            (uint32 askNonce, uint160 askAmount) = router.topOrder(bookId, false);
            _pre(bidNonce == 0 && bidAmount == 0, 78);
            _pre(askNonce == 0 && askAmount == 0, 79);
            (uint32 usdGNonce, uint64 usdGStartedAt) = legacy.rewardees(DeepstateAddresses.USDG);
            (uint32 nvdaNonce, uint64 nvdaStartedAt) = legacy.rewardees(DeepstateAddresses.NVDA);
            _pre(usdGNonce == 0 && usdGStartedAt == 0, 80);
            _pre(nvdaNonce == 0 && nvdaStartedAt == 0, 81);
        }

        uint256 totalAccrued = uint256(legacy.totalAccrued(DeepstateAddresses.USDG))
            + uint256(legacy.totalAccrued(DeepstateAddresses.NVDA));
        uint256 endowment = totalAccrued * 30 / 100;
        uint256 activationIssuance = endowment + _MARKET_FUNDING + _MARKET_VESTING;
        _pre(endowment != 0, 82);
        _pre(minter.mintCap() >= activationIssuance, 83);
        _pre(deep.totalSupply() <= minter.mintCap() - activationIssuance, 84);
        _pre(minter.grossIssuanceCap() >= activationIssuance, 85);
        _pre(deep.totalSupply() <= minter.grossIssuanceCap() - activationIssuance, 133);

        _pre(lockup.comptroller() == DeepstateAddresses.SABLIER_COMPTROLLER, 86);
        _pre(lockup.nativeToken() != DeepstateAddresses.DEEP, 87);
        _pre(DeepstateAddresses.USDG_IMPLEMENTATION.codehash == DeepstateAddresses.USDG_IMPLEMENTATION_CODEHASH, 88);
        _pre(DeepstateAddresses.NVDA_BEACON.codehash == DeepstateAddresses.NVDA_BEACON_CODEHASH, 89);
        _pre(DeepstateAddresses.NVDA_IMPLEMENTATION.codehash == DeepstateAddresses.NVDA_IMPLEMENTATION_CODEHASH, 90);
        _pre(
            DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION.codehash
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH,
            91
        );
        _pre(
            DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON.codehash
                == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON_CODEHASH,
            92
        );
        _pre(_implementationOf(DeepstateAddresses.USDG) == DeepstateAddresses.USDG_IMPLEMENTATION, 93);
        _pre(
            IUpgradeableBeaconDGP001View(DeepstateAddresses.NVDA_BEACON).implementation()
                == DeepstateAddresses.NVDA_IMPLEMENTATION,
            94
        );
        _pre(
            _implementationOf(DeepstateAddresses.SABLIER_COMPTROLLER)
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION,
            95
        );
        _pre(_safeSingleton() == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON, 96);
        _checkSablierComptroller(97, true);
        _checkSafe(103, true);
        _pre(_beaconOf(DeepstateAddresses.NVDA) == DeepstateAddresses.NVDA_BEACON, 109);
    }

    function _checkSablierComptroller(uint256 conditionOffset, bool precondition) private view {
        ISablierComptrollerDGP001View comptroller =
            ISablierComptrollerDGP001View(DeepstateAddresses.SABLIER_COMPTROLLER);
        _routeCheck(
            keccak256(bytes(comptroller.VERSION())) == keccak256(bytes(DeepstateAddresses.SABLIER_COMPTROLLER_VERSION)),
            conditionOffset,
            precondition
        );
        _routeCheck(
            comptroller.admin() == DeepstateAddresses.SABLIER_COMPTROLLER_ADMIN, conditionOffset + 1, precondition
        );
        _routeCheck(
            comptroller.oracle() == DeepstateAddresses.SABLIER_COMPTROLLER_ORACLE, conditionOffset + 2, precondition
        );
        _routeCheck(
            comptroller.MAX_FEE_USD() == DeepstateAddresses.SABLIER_MAX_FEE_USD, conditionOffset + 3, precondition
        );
        _routeCheck(
            comptroller.getMinFeeUSD(_SABLIER_PROTOCOL_LOCKUP) == DeepstateAddresses.SABLIER_LOCKUP_MIN_FEE_USD,
            conditionOffset + 4,
            precondition
        );
        _routeCheck(comptroller.calculateMinFeeWei(_SABLIER_PROTOCOL_LOCKUP) == 0, conditionOffset + 5, precondition);
    }

    function _checkSafe(uint256 conditionOffset, bool precondition) private view {
        ISafeDGP001View safe = ISafeDGP001View(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        address[] memory owners = safe.getOwners();
        _routeCheck(owners.length == 1, conditionOffset, precondition);
        if (owners.length == 1) {
            _routeCheck(owners[0] == DeepstateAddresses.DEEPSTATE_INC_SAFE_OWNER, conditionOffset + 1, precondition);
        }
        _routeCheck(
            safe.getThreshold() == DeepstateAddresses.DEEPSTATE_INC_SAFE_THRESHOLD, conditionOffset + 2, precondition
        );
        (address[] memory modules, address next) = safe.getModulesPaginated(_SAFE_MODULES_SENTINEL, 100);
        _routeCheck(modules.length == 0, conditionOffset + 3, precondition);
        _routeCheck(next == _SAFE_MODULES_SENTINEL, conditionOffset + 4, precondition);
        _routeCheck(DeepstateAddresses.DEEPSTATE_INC_SAFE_OWNER.code.length == 0, conditionOffset + 5, precondition);
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _beaconOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ERC1967_BEACON_SLOT))));
    }

    function _safeSingleton() private view returns (address) {
        return address(uint160(uint256(vm.load(DeepstateAddresses.DEEPSTATE_INC_SAFE, bytes32(0)))));
    }

    function _routeCheck(bool condition, uint256 conditionNumber, bool precondition) private pure {
        if (precondition) {
            _pre(condition, conditionNumber);
        } else {
            _check(condition, conditionNumber);
        }
    }

    function _checkStream(
        ISablierDGP001View lockup,
        uint256 streamId,
        uint256 amount,
        uint40 expectedStart,
        address expectedSender,
        uint40 expectedGranularity,
        uint256 conditionOffset
    ) private view {
        _check(lockup.ownerOf(streamId) == DeepstateAddresses.DEEPSTATE_INC_SAFE, conditionOffset);
        _check(lockup.getRecipient(streamId) == DeepstateAddresses.DEEPSTATE_INC_SAFE, conditionOffset + 1);
        _check(lockup.getSender(streamId) == expectedSender, conditionOffset + 2);
        _check(address(lockup.getUnderlyingToken(streamId)) == DeepstateAddresses.DEEP, conditionOffset + 3);
        _check(lockup.getDepositedAmount(streamId) == amount, conditionOffset + 4);
        _check(lockup.getStartTime(streamId) == expectedStart, conditionOffset + 5);
        _check(lockup.getEndTime(streamId) == expectedStart + 365 days, conditionOffset + 6);
        _check(lockup.getCliffTime(streamId) == 0, conditionOffset + 7);
        _check(!lockup.isCancelable(streamId), conditionOffset + 8);
        _check(!lockup.isTransferable(streamId), conditionOffset + 9);
        _check(lockup.getGranularity(streamId) == expectedGranularity, conditionOffset + 10);
    }

    function _check(bool condition, uint256 conditionNumber) private pure {
        if (!condition) revert PostconditionFailed(conditionNumber);
    }

    function _pre(bool condition, uint256 conditionNumber) private pure {
        if (!condition) revert PreconditionFailed(conditionNumber);
    }
}
