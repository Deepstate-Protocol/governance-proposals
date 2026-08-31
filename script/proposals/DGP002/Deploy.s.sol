// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepstateProposalScript} from "../../DeepstateProposalScript.s.sol";
import {DeepstateAddresses} from "../../config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../../src/DeepstateV1Controller.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {IDeepstateV1} from "../../../src/interfaces/IDeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ISablierDGP002View {
    function balanceOf(address owner) external view returns (uint256 balance);
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

interface ISablierComptrollerDGP002View {
    function VERSION() external view returns (string memory);
    function admin() external view returns (address);
    function oracle() external view returns (address);
    function MAX_FEE_USD() external view returns (uint256);
    function getMinFeeUSD(uint8 protocol) external view returns (uint256);
    function calculateMinFeeWei(uint8 protocol) external view returns (uint256);
}

interface ISafeDGP002View {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

/// @notice Exact DGP-002 volunteer-allocation payload, entrypoint, and immediate execution verifier.
contract DeployDGP002 is DeepstateProposalScript {
    address internal constant PROPOSER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    uint256 internal constant EXPECTED_PROPOSAL_ID =
        36_177_977_559_725_829_812_483_834_109_258_240_837_107_645_780_872_391_533_836_115_516_881_196_235_226;

    address public constant VOLUNTEER_A = 0x1fb3A8192d00aDe0ddC0EEcB4D872149Eb9C4157;
    address public constant VOLUNTEER_B = 0x5715d61f99487abD65D1091b5d3a46c1b2879355;
    address public constant VOLUNTEER_C = 0x4019921387856f3c5932b0f94Ac5E73337689721;
    uint256 public constant TOTAL_PRIMARY_MINT = 10_000_000e18;
    uint256 public constant VOLUNTEER_A_AMOUNT = 3_333_333_333333333333333334;
    uint256 public constant VOLUNTEER_B_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VOLUNTEER_C_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VESTING_PER_MINT = 1_428_571_428571428571428571;
    uint256 public constant TOTAL_VESTING_AMOUNT = 4_285_714_285714285714285713;

    uint256 private constant _ACTION_COUNT = 3;
    uint256 private constant _DGP001_PROPOSAL_ID =
        104_314_577_693_082_885_786_109_683_732_203_114_255_408_942_832_054_564_539_957_851_903_575_470_305_161;
    uint256 private constant _FACTORY_MINTER_ROLE = 1;
    uint256 private constant _FACTORY_HOOK_MANAGER_ROLE = 1;
    uint256 private constant _DGP001_MARKET_FUNDING = 100_000_000e18;
    uint8 private constant _SABLIER_PROTOCOL_LOCKUP = 2;
    address private constant _SAFE_MODULES_SENTINEL = address(1);
    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    error PreconditionFailed(uint256 condition);
    error PostconditionFailed(uint256 condition);

    function proposer() public pure override returns (address) {
        return PROPOSER;
    }

    function expectedProposalId() public pure override returns (uint256) {
        return EXPECTED_PROPOSAL_ID;
    }

    /// @notice Reopens the post-DGP-001 submission gates without changing state.
    function validateSubmissionPreconditions() external view {
        _validatePreconditions(true);
    }

    /// @notice Reopens the post-DGP-001 execution gates without changing state.
    function validateExecutionPreconditions() external view {
        _validatePreconditions(false);
    }

    function _beforeSubmission() internal view override {
        _validatePreconditions(true);
    }

    function _beforeExecution() internal view override {
        _validatePreconditions(false);
    }

    /// @notice Runs the immediate DGP-002 postconditions without requiring a registered proposal.
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

        for (uint256 i; i < _ACTION_COUNT; ++i) {
            targets[i] = DeepstateAddresses.MINTER_CONTROLLER;
        }
        calldatas[0] = abi.encodeCall(DeepstateMinterController.mint, (VOLUNTEER_A, VOLUNTEER_A_AMOUNT));
        calldatas[1] = abi.encodeCall(DeepstateMinterController.mint, (VOLUNTEER_B, VOLUNTEER_B_AMOUNT));
        calldatas[2] = abi.encodeCall(DeepstateMinterController.mint, (VOLUNTEER_C, VOLUNTEER_C_AMOUNT));

        description = vm.readFile("proposals/DGP-002.md");
    }

    function _validatePreconditions(bool requireFullGovernanceWindow) private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);

        _pre(DeepstateAddresses.DEEP.codehash == DeepstateAddresses.DEEP_CODEHASH, 1);
        _pre(DeepstateAddresses.SABLIER_LOCKUP.codehash == DeepstateAddresses.SABLIER_LOCKUP_CODEHASH, 2);
        _pre(DeepstateAddresses.MINTER_CONTROLLER.codehash == DeepstateAddresses.MINTER_CONTROLLER_CODEHASH, 3);
        _pre(DeepstateAddresses.V1_CONTROLLER.codehash == DeepstateAddresses.V1_CONTROLLER_CODEHASH, 4);
        _pre(DeepstateAddresses.REWARDER_FACTORY.codehash == DeepstateAddresses.REWARDER_FACTORY_CODEHASH, 5);
        _pre(DeepstateAddresses.DGP001_BOOTSTRAP.codehash == DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH, 71);
        _validateExternalDependencies();

        _pre(governor.state(_DGP001_PROPOSAL_ID) == 7, 6);
        _pre(governor.proposalProposer(_DGP001_PROPOSAL_ID) == PROPOSER, 7);
        _pre(minter.owner() == DeepstateAddresses.GOVERNOR, 8);
        _pre(v1Controller.owner() == DeepstateAddresses.GOVERNOR, 9);
        _pre(factory.owner() == DeepstateAddresses.GOVERNOR, 10);
        _pre(address(minter.deepstateToken()) == DeepstateAddresses.DEEP, 11);
        _pre(address(minter.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 12);
        _pre(minter.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 13);
        _pre(minter.mintCap() == DeepstateAddresses.MINTER_LIVE_SUPPLY_CAP, 14);
        _pre(minter.grossIssuanceCap() == DeepstateAddresses.MINTER_GROSS_ISSUANCE_CAP, 15);
        _pre(bootstrap.executed(), 16);
        _pre(bootstrap.snapshotAt() != 0, 17);

        uint40 administrationEndsAt = minter.tokenAdministrationEndsAt();
        _pre(administrationEndsAt == bootstrap.snapshotAt() + minter.TOKEN_ADMINISTRATION_DURATION(), 18);
        _pre(block.timestamp < administrationEndsAt, 19);

        bytes32 defaultAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        _pre(deep.defaultAdminCount() == 1, 20);
        _pre(deep.hasRole(defaultAdminRole, DeepstateAddresses.MINTER_CONTROLLER), 21);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.GOVERNOR), 22);
        _pre(deep.hasRole(tokenMinterRole, DeepstateAddresses.MINTER_CONTROLLER), 23);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.GOVERNOR), 24);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER_FACTORY), 25);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.DGP001_BOOTSTRAP), 72);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.DGP001_BOOTSTRAP), 73);
        _pre(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_MINTER_ROLE, 26);
        _pre(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_HOOK_MANAGER_ROLE, 27);

        _pre(router.owner() == DeepstateAddresses.V1_CONTROLLER, 28);
        _pre(factory.operator() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 29);
        uint256 fundingCommitted = factory.fundingCommitted();
        _pre(fundingCommitted >= _DGP001_MARKET_FUNDING, 30);
        _pre(fundingCommitted <= factory.fundingBudget(), 31);
        _pre(fundingCommitted % _DGP001_MARKET_FUNDING == 0, 32);
        _pre(factory.marketDeployed(DeepstateAddresses.NVDA_USDG_POOL_ID), 33);
        address rewarderAddress = factory.activeRewarder(DeepstateAddresses.NVDA_USDG_POOL_ID);
        _pre(rewarderAddress != address(0), 34);
        _pre(factory.rewarderPool(rewarderAddress) == DeepstateAddresses.NVDA_USDG_POOL_ID, 35);
        _pre(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID) == rewarderAddress, 36);

        DeepstateRewarderV2 rewarder = DeepstateRewarderV2(rewarderAddress);
        _pre(rewarder.owner() == DeepstateAddresses.REWARDER_FACTORY, 37);
        _pre(!rewarder.retired(), 38);
        _pre(rewarder.rewardToken() == DeepstateAddresses.DEEP, 39);
        _pre(rewarder.poolId() == DeepstateAddresses.NVDA_USDG_POOL_ID, 40);
        _pre(rewarder.sideEmissionCap() == _DGP001_MARKET_FUNDING / 2, 41);
        _pre(rewarder.emissionDuration() == 365 days, 42);

        uint256 combinedIssuance = TOTAL_PRIMARY_MINT + TOTAL_VESTING_AMOUNT;
        _pre(minter.grossIssued() <= minter.grossIssuanceCap() - combinedIssuance, 43);
        _pre(deep.totalSupply() <= minter.mintCap() - combinedIssuance, 44);
        _pre(deep.allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP) == 0, 46);
        _pre(VOLUNTEER_A_AMOUNT + VOLUNTEER_B_AMOUNT + VOLUNTEER_C_AMOUNT == TOTAL_PRIMARY_MINT, 47);
        uint256 calculatedVesting = VOLUNTEER_A_AMOUNT * minter.RECIPIENT_ALLOCATION_BPS()
            / minter.PRIMARY_ALLOCATION_BPS() + VOLUNTEER_B_AMOUNT * minter.RECIPIENT_ALLOCATION_BPS()
            / minter.PRIMARY_ALLOCATION_BPS() + VOLUNTEER_C_AMOUNT * minter.RECIPIENT_ALLOCATION_BPS()
            / minter.PRIMARY_ALLOCATION_BPS();
        _pre(calculatedVesting == TOTAL_VESTING_AMOUNT, 48);
        _pre(
            VOLUNTEER_A_AMOUNT * minter.RECIPIENT_ALLOCATION_BPS() / minter.PRIMARY_ALLOCATION_BPS()
                == VESTING_PER_MINT,
            49
        );
        _pre(bootstrap.governor() == DeepstateAddresses.GOVERNOR, 74);
        _pre(address(bootstrap.minterController()) == DeepstateAddresses.MINTER_CONTROLLER, 75);
        _pre(address(bootstrap.deepstateToken()) == DeepstateAddresses.DEEP, 76);
        _pre(address(bootstrap.sablierLockup()) == DeepstateAddresses.SABLIER_LOCKUP, 77);
        _pre(address(bootstrap.legacyRewarder()) == DeepstateAddresses.REWARDER, 78);
        _pre(bootstrap.recipient() == DeepstateAddresses.DEEPSTATE_INC_SAFE, 79);
        _pre(bootstrap.endowmentAmount() != 0 && bootstrap.streamId() != 0, 80);
        _pre(deep.allowance(DeepstateAddresses.DGP001_BOOTSTRAP, DeepstateAddresses.SABLIER_LOCKUP) == 0, 82);

        if (requireFullGovernanceWindow) {
            uint256 governanceWindow =
                governor.votingDelay() + governor.votingPeriod() + governor.lateQuorumVoteExtension() + 2;
            _pre(block.timestamp + governanceWindow < administrationEndsAt, 50);
        }
    }

    function _afterExecution() internal view override {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        ISablierDGP002View lockup = ISablierDGP002View(DeepstateAddresses.SABLIER_LOCKUP);

        _post(deep.balanceOf(VOLUNTEER_A) >= VOLUNTEER_A_AMOUNT, 1);
        _post(deep.balanceOf(VOLUNTEER_B) >= VOLUNTEER_B_AMOUNT, 2);
        _post(deep.balanceOf(VOLUNTEER_C) >= VOLUNTEER_C_AMOUNT, 3);
        _post(deep.totalSupply() <= minter.mintCap(), 4);
        _post(minter.grossIssued() <= minter.grossIssuanceCap(), 5);
        _post(deep.allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP) == 0, 7);

        uint256 nextStreamId = lockup.nextStreamId();
        _post(nextStreamId >= _ACTION_COUNT, 8);
        for (uint256 i; i < _ACTION_COUNT; ++i) {
            _checkStream(lockup, nextStreamId - _ACTION_COUNT + i, minter, 9 + i * 11);
        }

        _post(deep.defaultAdminCount() == 1, 42);
        _post(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), DeepstateAddresses.MINTER_CONTROLLER), 43);
        _post(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER), 44);
        _post(!deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP), 49);
        _post(block.timestamp < minter.tokenAdministrationEndsAt(), 45);
        _post(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_MINTER_ROLE, 46);
        _post(
            DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY).operator()
                == DeepstateAddresses.DEEPSTATE_INC_SAFE,
            47
        );
        _post(IDeepstateV1(DeepstateAddresses.ROUTER).owner() == DeepstateAddresses.V1_CONTROLLER, 48);
    }

    function _validateExternalDependencies() private view {
        ISablierDGP002View lockup = ISablierDGP002View(DeepstateAddresses.SABLIER_LOCKUP);
        ISablierComptrollerDGP002View comptroller =
            ISablierComptrollerDGP002View(DeepstateAddresses.SABLIER_COMPTROLLER);

        _pre(DeepstateAddresses.SABLIER_COMPTROLLER.codehash == DeepstateAddresses.SABLIER_COMPTROLLER_CODEHASH, 51);
        _pre(
            DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION.codehash
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH,
            52
        );
        _pre(lockup.comptroller() == DeepstateAddresses.SABLIER_COMPTROLLER, 53);
        _pre(lockup.nativeToken() != DeepstateAddresses.DEEP, 54);
        _pre(
            _implementationOf(DeepstateAddresses.SABLIER_COMPTROLLER)
                == DeepstateAddresses.SABLIER_COMPTROLLER_IMPLEMENTATION,
            55
        );
        _pre(
            keccak256(bytes(comptroller.VERSION())) == keccak256(bytes(DeepstateAddresses.SABLIER_COMPTROLLER_VERSION)),
            56
        );
        _pre(comptroller.admin() == DeepstateAddresses.SABLIER_COMPTROLLER_ADMIN, 57);
        _pre(comptroller.oracle() == DeepstateAddresses.SABLIER_COMPTROLLER_ORACLE, 58);
        _pre(comptroller.MAX_FEE_USD() == DeepstateAddresses.SABLIER_MAX_FEE_USD, 59);
        _pre(comptroller.getMinFeeUSD(_SABLIER_PROTOCOL_LOCKUP) == DeepstateAddresses.SABLIER_LOCKUP_MIN_FEE_USD, 60);
        _pre(comptroller.calculateMinFeeWei(_SABLIER_PROTOCOL_LOCKUP) == 0, 61);

        _pre(DeepstateAddresses.DEEPSTATE_INC_SAFE.codehash == DeepstateAddresses.DEEPSTATE_INC_SAFE_CODEHASH, 62);
        _pre(
            DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON.codehash
                == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON_CODEHASH,
            63
        );
        _pre(_safeSingleton() == DeepstateAddresses.DEEPSTATE_INC_SAFE_SINGLETON, 64);
        ISafeDGP002View safe = ISafeDGP002View(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        address[] memory owners = safe.getOwners();
        _pre(owners.length == 1, 65);
        if (owners.length == 1) _pre(owners[0] == DeepstateAddresses.DEEPSTATE_INC_SAFE_OWNER, 66);
        _pre(safe.getThreshold() == DeepstateAddresses.DEEPSTATE_INC_SAFE_THRESHOLD, 67);
        (address[] memory modules, address next) = safe.getModulesPaginated(_SAFE_MODULES_SENTINEL, 100);
        _pre(modules.length == 0, 68);
        _pre(next == _SAFE_MODULES_SENTINEL, 69);
        _pre(DeepstateAddresses.DEEPSTATE_INC_SAFE_OWNER.code.length == 0, 70);
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _safeSingleton() private view returns (address) {
        return address(uint160(uint256(vm.load(DeepstateAddresses.DEEPSTATE_INC_SAFE, bytes32(0)))));
    }

    function _checkStream(
        ISablierDGP002View lockup,
        uint256 streamId,
        DeepstateMinterController minter,
        uint256 conditionOffset
    ) private view {
        _post(lockup.ownerOf(streamId) == DeepstateAddresses.DEEPSTATE_INC_SAFE, conditionOffset);
        _post(lockup.getRecipient(streamId) == DeepstateAddresses.DEEPSTATE_INC_SAFE, conditionOffset + 1);
        _post(lockup.getSender(streamId) == DeepstateAddresses.MINTER_CONTROLLER, conditionOffset + 2);
        _post(address(lockup.getUnderlyingToken(streamId)) == DeepstateAddresses.DEEP, conditionOffset + 3);
        _post(lockup.getDepositedAmount(streamId) == VESTING_PER_MINT, conditionOffset + 4);
        uint40 startTime = lockup.getStartTime(streamId);
        _post(startTime <= block.timestamp, conditionOffset + 5);
        _post(lockup.getEndTime(streamId) == startTime + minter.VESTING_DURATION(), conditionOffset + 6);
        _post(lockup.getCliffTime(streamId) == 0, conditionOffset + 7);
        _post(!lockup.isCancelable(streamId), conditionOffset + 8);
        _post(!lockup.isTransferable(streamId), conditionOffset + 9);
        _post(lockup.getGranularity(streamId) == 1, conditionOffset + 10);
    }

    function _pre(bool condition, uint256 conditionNumber) private pure {
        if (!condition) revert PreconditionFailed(conditionNumber);
    }

    function _post(bool condition, uint256 conditionNumber) private pure {
        if (!condition) revert PostconditionFailed(conditionNumber);
    }
}
