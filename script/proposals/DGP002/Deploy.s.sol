// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeepstateProposalScript} from "../../DeepstateProposalScript.s.sol";
import {DeepstateAddresses} from "../../config/DeepstateAddresses.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../../src/DeepstateV1Controller.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {IDeepstateV1} from "../../../src/interfaces/IDeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface ISablierDGP002View {
    function balanceOf(address owner) external view returns (uint256 balance);
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

/// @notice Exact DGP-002 volunteer-allocation payload, entrypoint, and immediate execution verifier.
contract DeployDGP002 is DeepstateProposalScript {
    address internal constant PROPOSER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    uint256 internal constant EXPECTED_PROPOSAL_ID =
        6_654_724_899_027_437_755_372_567_698_267_830_192_922_209_775_984_828_280_382_998_791_025_729_780_716;

    address public constant VOLUNTEER_A = 0x1fb3A8192d00aDe0ddC0EEcB4D872149Eb9C4157;
    address public constant VOLUNTEER_B = 0x5715d61f99487abD65D1091b5d3a46c1b2879355;
    address public constant VOLUNTEER_C = 0xEb01dF2A97A966f96B1765c78ccD97f3412765F0;
    uint256 public constant TOTAL_PRIMARY_MINT = 10_000_000e18;
    uint256 public constant VOLUNTEER_A_AMOUNT = 3_333_333_333333333333333334;
    uint256 public constant VOLUNTEER_B_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VOLUNTEER_C_AMOUNT = 3_333_333_333333333333333333;
    uint256 public constant VESTING_PER_MINT = 1_428_571_428571428571428571;
    uint256 public constant TOTAL_VESTING_AMOUNT = 4_285_714_285714285714285713;

    uint256 private constant _ACTION_COUNT = 3;
    uint256 private constant _DGP001_PROPOSAL_ID =
        43_515_582_931_149_866_007_777_378_018_087_004_156_505_872_239_108_242_112_228_969_517_517_916_946_941;
    uint256 private constant _FACTORY_MINTER_ROLE = 1;
    uint256 private constant _FACTORY_HOOK_MANAGER_ROLE = 1;
    uint256 private constant _DGP001_MARKET_FUNDING = 100_000_000e18;

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
        _pre(minter.legacyEndowmentCreated(), 16);
        _pre(minter.legacyEndowmentSnapshotAt() != 0, 17);

        uint40 administrationEndsAt = minter.tokenAdministrationEndsAt();
        _pre(administrationEndsAt == minter.legacyEndowmentSnapshotAt() + minter.TOKEN_ADMINISTRATION_DURATION(), 18);
        _pre(block.timestamp < administrationEndsAt, 19);

        bytes32 defaultAdminRole = deep.DEFAULT_ADMIN_ROLE();
        bytes32 tokenMinterRole = deep.MINTER_ROLE();
        _pre(deep.defaultAdminCount() == 1, 20);
        _pre(deep.hasRole(defaultAdminRole, DeepstateAddresses.MINTER_CONTROLLER), 21);
        _pre(!deep.hasRole(defaultAdminRole, DeepstateAddresses.GOVERNOR), 22);
        _pre(deep.hasRole(tokenMinterRole, DeepstateAddresses.MINTER_CONTROLLER), 23);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.GOVERNOR), 24);
        _pre(!deep.hasRole(tokenMinterRole, DeepstateAddresses.REWARDER_FACTORY), 25);
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
        _pre(deep.balanceOf(DeepstateAddresses.MINTER_CONTROLLER) == 0, 45);
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
        _post(deep.balanceOf(DeepstateAddresses.MINTER_CONTROLLER) == 0, 6);
        _post(deep.allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP) == 0, 7);

        uint256 nextStreamId = lockup.nextStreamId();
        _post(nextStreamId >= _ACTION_COUNT, 8);
        for (uint256 i; i < _ACTION_COUNT; ++i) {
            _checkStream(lockup, nextStreamId - _ACTION_COUNT + i, minter, 9 + i * 11);
        }

        _post(deep.defaultAdminCount() == 1, 42);
        _post(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), DeepstateAddresses.MINTER_CONTROLLER), 43);
        _post(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER), 44);
        _post(block.timestamp < minter.tokenAdministrationEndsAt(), 45);
        _post(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY) == _FACTORY_MINTER_ROLE, 46);
        _post(
            DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY).operator()
                == DeepstateAddresses.DEEPSTATE_INC_SAFE,
            47
        );
        _post(IDeepstateV1(DeepstateAddresses.ROUTER).owner() == DeepstateAddresses.V1_CONTROLLER, 48);
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
