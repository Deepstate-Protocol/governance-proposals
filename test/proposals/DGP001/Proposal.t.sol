// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Lockup} from "@sablier/lockup/src/types/Lockup.sol";
import {LockupLinear} from "@sablier/lockup/src/types/LockupLinear.sol";
import {Test} from "forge-std/Test.sol";

import {
    DeployDGP001,
    IDeepstateRoleAdminDGP001,
    IDeepstateV1DGP001View,
    ISablierDGP001View
} from "../../../script/proposals/DGP001/Deploy.s.sol";
import {DeepstateAddresses} from "../../../script/config/DeepstateAddresses.sol";
import {DGP001Bootstrap} from "../../../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../../../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../../../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../../../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../../../src/DeepstateV1Controller.sol";
import {IDeepstateGovernor} from "../../../src/interfaces/IDeepstateGovernor.sol";
import {ISablierLockupLinearV4} from "../../../src/interfaces/ISablierLockupLinearV4.sol";
import {IDeepstateV1} from "../../../src/interfaces/IDeepstateV1.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";

interface IDeepstateV1DGP001 is IDeepstateV1 {
    function activeBookId(address token0, address token1) external view returns (bytes32);
    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount);
}

interface ILegacyRewarderDGP001 {
    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt);
    function totalAccrued(address token) external view returns (uint96 accrued);
}

contract DGP001SimulatedStockToken {
    uint8 public constant decimals = 18;
}

contract DGP001Test is Test {
    struct NewMarketSnapshot {
        uint40 deployedAt;
        uint256 supply;
        uint256 streamId;
        uint256 factoryNonce;
        address expectedRewarder;
        address originalNvdaRewarder;
    }

    uint256 internal constant FORK_BLOCK = 52005951;
    bytes32 internal constant FORK_BLOCK_HASH = 0x171944f34f37a0ec4bdc941a27968441c513039f841a5acdc5b404208cec3c90;
    bytes32 internal constant EXPECTED_DESCRIPTION_HASH =
        0x921c011db66ae4d02eb97defdb93d76a84aff44ac0fd406399f3d0f462cfeed0;
    address internal constant QUORUM_VOTER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;

    uint256 private constant _MARKET_FUNDING = 100_000_000e18;
    uint256 private constant _MARKET_VESTING = _MARKET_FUNDING * 30 / 70;
    uint128 private constant _ENDOWMENT_AMOUNT = 48_594_966_854_085_794_406_041_707;
    uint256 private constant _POOL_STATE_MAPPING_SLOT = 2;
    uint256 private constant _BOTH_HOOK_FLAGS = (uint256(1) << 254) | (uint256(1) << 255);
    bytes32 private constant _PINNED_ACTIVE_BOOK_ID =
        0xdf941c235503a5d2e67aee5dea00f2965f99421c0d034bd77f924c05c66bf399;

    DeployDGP001 internal proposal;

    function setUp() public {
        proposal = new DeployDGP001();
        vm.makePersistent(address(proposal));
    }

    function _setUpFork() private {
        if (vm.envOr("DGP001_TEST_LATEST_FORK", false)) {
            // Diagnostic-only escape hatch for non-archive public RPCs. Release CI never sets this variable and must
            // execute the pinned branch below against the configured archive endpoint.
            vm.createSelectFork(vm.rpcUrl("robinhood"));
        } else {
            vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK + 1);
            assertEq(blockhash(FORK_BLOCK), FORK_BLOCK_HASH);
            vm.rollFork(FORK_BLOCK);
            assertEq(block.number, FORK_BLOCK);
        }
        assertEq(block.chainid, DeepstateAddresses.CHAIN_ID);

        _assertPristineDeployment();
    }

    function testProposalPayload() public {
        vm.mockCall(
            DeepstateAddresses.DGP001_BOOTSTRAP,
            abi.encodeWithSignature("endowmentAmount()"),
            abi.encode(_ENDOWMENT_AMOUNT)
        );
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        assertEq(targets.length, 15);
        assertEq(values.length, 15);
        assertEq(calldatas.length, 15);
        for (uint256 i; i < values.length; ++i) {
            assertEq(values[i], 0);
        }

        assertEq(targets[0], DeepstateAddresses.DEEP);
        assertEq(targets[1], DeepstateAddresses.DEEP);
        assertEq(targets[2], DeepstateAddresses.DGP001_BOOTSTRAP);
        assertEq(targets[3], DeepstateAddresses.DEEP);
        assertEq(targets[4], DeepstateAddresses.DEEP);
        assertEq(targets[5], DeepstateAddresses.SABLIER_LOCKUP);
        assertEq(targets[6], DeepstateAddresses.DEEP);
        assertEq(targets[7], DeepstateAddresses.DEEP);
        assertEq(targets[8], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[9], DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(targets[10], DeepstateAddresses.ROUTER);
        assertEq(targets[11], DeepstateAddresses.ROUTER);
        assertEq(targets[12], DeepstateAddresses.V1_CONTROLLER);
        assertEq(targets[13], DeepstateAddresses.REWARDER_FACTORY);
        assertEq(targets[14], DeepstateAddresses.REWARDER_FACTORY);

        assertEq(
            calldatas[0],
            abi.encodeCall(IAccessControl.revokeRole, (keccak256("MINTER_ROLE"), DeepstateAddresses.DEEP_DEPLOYER))
        );
        assertEq(
            calldatas[1],
            abi.encodeCall(IAccessControl.grantRole, (keccak256("MINTER_ROLE"), DeepstateAddresses.DGP001_BOOTSTRAP))
        );
        assertEq(calldatas[2], abi.encodeCall(DGP001Bootstrap.mint, ()));
        assertEq(
            calldatas[3],
            abi.encodeCall(IAccessControl.revokeRole, (keccak256("MINTER_ROLE"), DeepstateAddresses.DGP001_BOOTSTRAP))
        );
        uint128 endowmentAmount = _ENDOWMENT_AMOUNT;
        assertEq(
            calldatas[4], abi.encodeCall(IERC20.approve, (DeepstateAddresses.SABLIER_LOCKUP, uint256(endowmentAmount)))
        );
        assertEq(
            calldatas[5],
            abi.encodeCall(
                ISablierLockupLinearV4.createWithDurationsLL,
                (
                    Lockup.CreateWithDurations({
                        sender: DeepstateAddresses.GOVERNOR,
                        recipient: DeepstateAddresses.DEEPSTATE_INC_SAFE,
                        depositAmount: endowmentAmount,
                        token: IERC20(DeepstateAddresses.DEEP),
                        cancelable: false,
                        transferable: false,
                        shape: "Deepstate Inc endowment"
                    }),
                    LockupLinear.UnlockAmounts({start: 0, cliff: 0}),
                    uint40(1 seconds),
                    LockupLinear.Durations({cliff: 0, total: 365 days})
                )
            )
        );
        assertEq(
            calldatas[6], abi.encodeCall(IAccessControl.grantRole, (bytes32(0), DeepstateAddresses.MINTER_CONTROLLER))
        );
        assertEq(calldatas[7], abi.encodeCall(IAccessControl.renounceRole, (bytes32(0), DeepstateAddresses.GOVERNOR)));
        assertEq(calldatas[8], abi.encodeCall(DeepstateMinterController.activateTokenAdministration, ()));
        assertEq(
            calldatas[9],
            abi.encodeCall(IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, uint256(1)))
        );
        assertEq(
            calldatas[10],
            abi.encodeCall(
                IDeepstateV1.setPoolHookConfig,
                (DeepstateAddresses.USDG, DeepstateAddresses.NVDA, address(0), false, false)
            )
        );
        assertEq(calldatas[11], abi.encodeCall(IDeepstateV1.transferOwnership, (DeepstateAddresses.V1_CONTROLLER)));
        assertEq(
            calldatas[12],
            abi.encodeCall(IDeepstateRoleAdminDGP001.grantRoles, (DeepstateAddresses.REWARDER_FACTORY, uint256(1)))
        );
        DeepstateRewarderFactory.MarketConfig memory market = DeepstateRewarderFactory.MarketConfig({
            token0: DeepstateAddresses.USDG,
            token1: DeepstateAddresses.NVDA,
            token0MaxUnits: 1_000_000,
            token1MaxUnits: 5_000,
            token0Active: true,
            token1Active: true
        });
        assertEq(calldatas[13], abi.encodeCall(DeepstateRewarderFactory.deployMarket, (market)));
        assertEq(
            calldatas[14], abi.encodeCall(DeepstateRewarderFactory.setOperator, (DeepstateAddresses.DEEPSTATE_INC_SAFE))
        );

        assertEq(proposal.proposer(), QUORUM_VOTER);
        assertEq(keccak256(bytes(description)), EXPECTED_DESCRIPTION_HASH);
        assertEq(proposal.proposalId(), proposal.expectedProposalId());
    }

    function testAuthorizedTargetCallsAndPostconditions() public {
        _setUpFork();
        proposal.validateSubmissionPreconditions();
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas,) = proposal.proposal();

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);

        uint256 supplyBefore = deep.totalSupply();
        uint256 governorBalanceBefore = deep.balanceOf(DeepstateAddresses.GOVERNOR);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);
        uint256 nextStreamId = lockup.nextStreamId();
        uint256 expectedEndowment = bootstrap.endowmentAmount();

        _executeAction(targets, values, calldatas, 0);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DEEP_DEPLOYER));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));

        _executeAction(targets, values, calldatas, 1);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));

        _executeAction(targets, values, calldatas, 2);
        assertEq(deep.totalSupply(), supplyBefore + expectedEndowment);
        assertEq(deep.balanceOf(DeepstateAddresses.GOVERNOR), governorBalanceBefore + expectedEndowment);
        assertEq(lockup.nextStreamId(), nextStreamId);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));

        _executeAction(targets, values, calldatas, 3);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));

        _executeAction(targets, values, calldatas, 4);
        assertEq(deep.allowance(DeepstateAddresses.GOVERNOR, DeepstateAddresses.SABLIER_LOCKUP), expectedEndowment);
        assertEq(lockup.nextStreamId(), nextStreamId);

        _executeAction(targets, values, calldatas, 5);
        assertEq(deep.allowance(DeepstateAddresses.GOVERNOR, DeepstateAddresses.SABLIER_LOCKUP), 0);
        assertEq(deep.balanceOf(DeepstateAddresses.GOVERNOR), governorBalanceBefore);
        assertEq(lockup.nextStreamId(), nextStreamId + 1);
        _assertEndowmentStream(lockup, nextStreamId, uint40(block.timestamp), expectedEndowment);

        _executeAction(targets, values, calldatas, 6);
        assertEq(deep.defaultAdminCount(), 2);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));

        _executeAction(targets, values, calldatas, 7);
        assertEq(deep.defaultAdminCount(), 1);
        assertFalse(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));

        _executeAction(targets, values, calldatas, 8);
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
        assertEq(minter.tokenAdministrationEndsAt(), block.timestamp + 730 days);

        _executeAction(targets, values, calldatas, 9);
        assertEq(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.REWARDER_FACTORY));

        _executeAction(targets, values, calldatas, 10);
        assertEq(router.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), address(0));

        _executeAction(targets, values, calldatas, 11);
        assertEq(router.owner(), DeepstateAddresses.V1_CONTROLLER);

        _executeAction(targets, values, calldatas, 12);
        assertEq(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);

        _executeAction(targets, values, calldatas, 13);
        address rewarder = router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID);
        assertNotEq(rewarder, address(0));
        assertEq(deep.balanceOf(rewarder), _MARKET_FUNDING);
        if (!vm.envOr("DGP001_TEST_PRUNED_RPC", false)) {
            assertEq(uint256(vm.load(DeepstateAddresses.ROUTER, _poolStateSlot())) & _BOTH_HOOK_FLAGS, _BOTH_HOOK_FLAGS);
        }

        _executeAction(targets, values, calldatas, 14);
        assertEq(factory.operator(), DeepstateAddresses.DEEPSTATE_INC_SAFE);

        assertEq(deep.totalSupply() - supplyBefore, expectedEndowment + _MARKET_FUNDING + _MARKET_VESTING);
        assertEq(lockup.nextStreamId(), nextStreamId + 2);
        proposal.verifyPostconditions();
    }

    function testFullGovernorLifecycle() public {
        _setUpFork();
        proposal.validateSubmissionPreconditions();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();

        vm.prank(proposal.proposer());
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(proposalId, proposal.expectedProposalId());
        assertEq(governor.proposalProposer(proposalId), proposal.proposer());
        assertFalse(governor.proposalNeedsQueuing(proposalId));
        assertEq(governor.state(proposalId), 0); // Pending

        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        assertEq(governor.state(proposalId), 1); // Active
        assertGe(governor.getVotes(QUORUM_VOTER, snapshot), governor.quorum(snapshot));
        vm.prank(QUORUM_VOTER);
        governor.castVote(proposalId, 1);
        assertEq(governor.state(proposalId), 1); // Active until the deadline

        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4); // Succeeded

        // Operationally prepare the market only after voting succeeds, then reopen every execution-time gate.
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);
        uint256 supplyBefore = deep.totalSupply();
        uint256 streamIdBefore = lockup.nextStreamId();
        uint40 executedAt = uint40(block.timestamp);
        address expectedRewarder = vm.computeCreateAddress(
            DeepstateAddresses.REWARDER_FACTORY, vm.getNonce(DeepstateAddresses.REWARDER_FACTORY)
        );

        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(governor.state(proposalId), 7); // Executed
        assertEq(deep.totalSupply() - supplyBefore, bootstrap.endowmentAmount() + _MARKET_FUNDING + _MARKET_VESTING);
        assertEq(lockup.nextStreamId(), streamIdBefore + 2);
        _assertEndowmentStream(lockup, streamIdBefore, executedAt, bootstrap.endowmentAmount());
        assertEq(router.owner(), DeepstateAddresses.V1_CONTROLLER);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), expectedRewarder);
        assertEq(deep.balanceOf(expectedRewarder), _MARKET_FUNDING);
        assertEq(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);
        assertEq(v1Controller.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 1);
        assertEq(factory.operator(), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(proposal.verifyExecution(), proposalId);

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(governor.state(proposalId), 7);
    }

    function testGovernorAndRewarderFactoryCanMintAfterDGP001() public {
        _setUpFork();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        uint256 proposalId = _passProposalToSucceeded(governor, targets, values, calldatas, description);

        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(proposal.verifyExecution(), proposalId);

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);
        address governorMintRecipient = address(0xA11CE);
        address factoryMintRecipient = address(0xB0B);
        uint256 primaryAmount = 70e18;
        uint256 vestingAmount = 30e18;
        uint256 supplyBefore = deep.totalSupply();
        uint256 streamIdBefore = lockup.nextStreamId();

        vm.prank(DeepstateAddresses.GOVERNOR);
        uint256 governorStreamId = minter.mint(governorMintRecipient, primaryAmount);
        assertEq(governorStreamId, streamIdBefore);
        assertEq(deep.balanceOf(governorMintRecipient), primaryAmount);
        _assertMinterStream(lockup, governorStreamId, uint40(block.timestamp), vestingAmount);

        vm.prank(DeepstateAddresses.REWARDER_FACTORY);
        uint256 factoryStreamId = minter.mint(factoryMintRecipient, primaryAmount);
        assertEq(factoryStreamId, streamIdBefore + 1);
        assertEq(deep.balanceOf(factoryMintRecipient), primaryAmount);
        _assertMinterStream(lockup, factoryStreamId, uint40(block.timestamp), vestingAmount);

        assertEq(deep.totalSupply() - supplyBefore, 2 * (primaryAmount + vestingAmount));
        assertEq(lockup.nextStreamId(), streamIdBefore + 2);
        assertEq(deep.balanceOf(DeepstateAddresses.MINTER_CONTROLLER), 0);
        assertEq(deep.allowance(DeepstateAddresses.MINTER_CONTROLLER, DeepstateAddresses.SABLIER_LOCKUP), 0);
        assertEq(governor.state(proposalId), 7);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        minter.mint(address(0xC0FFEE), primaryAmount);
    }

    function testOperatorDeploysAndConfiguresNewRewarderAfterDGP001() public {
        uint256 proposalId = _executeDgp001ForSimulation();
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);
        DGP001SimulatedStockToken stock = new DGP001SimulatedStockToken();
        DeepstateRewarderFactory.MarketConfig memory market = _simulatedMarket(address(stock));
        bytes32 poolId = keccak256(abi.encode(market.token0, market.token1));

        vm.warp(factory.nextDeploymentAt());
        NewMarketSnapshot memory before_ = NewMarketSnapshot({
            deployedAt: uint40(block.timestamp),
            supply: deep.totalSupply(),
            streamId: lockup.nextStreamId(),
            factoryNonce: vm.getNonce(address(factory)),
            expectedRewarder: vm.computeCreateAddress(address(factory), vm.getNonce(address(factory))),
            originalNvdaRewarder: router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID)
        });

        vm.prank(address(0xBAD));
        vm.expectRevert();
        factory.deployMarket(market);
        assertEq(vm.getNonce(address(factory)), before_.factoryNonce);
        assertEq(deep.totalSupply(), before_.supply);
        assertEq(router.poolHook(poolId), address(0));

        vm.prank(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        DeepstateRewarderV2 rewarder = factory.deployMarket(market);

        _assertNewRewarderConfiguration(rewarder, market, poolId, before_.expectedRewarder);
        _assertNewRewarderSystemStatus(rewarder, poolId, before_, proposalId);

        uint256 nextDeploymentAt = factory.nextDeploymentAt();
        vm.expectRevert(abi.encodeWithSelector(DeepstateRewarderFactory.DeploymentCooldown.selector, nextDeploymentAt));
        vm.prank(DeepstateAddresses.DEEPSTATE_INC_SAFE);
        factory.deployMarket(market);
    }

    function testGovernorExecutionRollsBackEveryEarlierActionWhenMarketFundingFails() public {
        _setUpFork();
        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        uint256 proposalId = _passProposalToSucceeded(governor, targets, values, calldatas, description);

        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);

        uint256 supplyBefore = deep.totalSupply();
        uint256 governorBalanceBefore = deep.balanceOf(DeepstateAddresses.GOVERNOR);
        uint256 governorAllowanceBefore = deep.allowance(DeepstateAddresses.GOVERNOR, DeepstateAddresses.SABLIER_LOCKUP);
        uint256 sablierBalanceBefore = deep.balanceOf(DeepstateAddresses.SABLIER_LOCKUP);
        uint256 bootstrapBalanceBefore = deep.balanceOf(DeepstateAddresses.DGP001_BOOTSTRAP);
        uint256 endowmentBefore = bootstrap.endowmentAmount();
        uint256 streamBefore = lockup.nextStreamId();
        uint64 factoryNonceBefore = vm.getNonce(DeepstateAddresses.REWARDER_FACTORY);
        bool prunedRpc = vm.envOr("DGP001_TEST_PRUNED_RPC", false);
        bytes32 poolStateBefore = prunedRpc ? bytes32(0) : vm.load(DeepstateAddresses.ROUTER, _poolStateSlot());
        vm.mockCallRevert(
            DeepstateAddresses.MINTER_CONTROLLER,
            abi.encodeWithSelector(DeepstateMinterController.mint.selector),
            abi.encodeWithSignature("InjectedMarketFundingFailure()")
        );

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        if (prunedRpc) {
            vm.mockCall(
                DeepstateAddresses.ROUTER,
                abi.encodeCall(IDeepstateV1.poolHook, (DeepstateAddresses.NVDA_USDG_POOL_ID)),
                abi.encode(DeepstateAddresses.REWARDER)
            );
        }

        assertEq(governor.state(proposalId), 4);
        assertEq(deep.totalSupply(), supplyBefore);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(bytes32(0), DeepstateAddresses.MINTER_CONTROLLER));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
        assertEq(bootstrap.endowmentAmount(), endowmentBefore);
        assertEq(deep.balanceOf(DeepstateAddresses.GOVERNOR), governorBalanceBefore);
        assertEq(
            deep.allowance(DeepstateAddresses.GOVERNOR, DeepstateAddresses.SABLIER_LOCKUP), governorAllowanceBefore
        );
        assertEq(deep.balanceOf(DeepstateAddresses.SABLIER_LOCKUP), sablierBalanceBefore);
        assertEq(deep.balanceOf(DeepstateAddresses.DGP001_BOOTSTRAP), bootstrapBalanceBefore);
        assertEq(minter.tokenAdministrationEndsAt(), 0);
        assertEq(minter.rolesOf(DeepstateAddresses.REWARDER_FACTORY), 0);
        assertEq(
            DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER).rolesOf(DeepstateAddresses.REWARDER_FACTORY), 0
        );
        assertEq(router.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), DeepstateAddresses.REWARDER);
        if (!prunedRpc) assertEq(vm.load(DeepstateAddresses.ROUTER, _poolStateSlot()), poolStateBefore);
        assertEq(factory.operator(), address(0));
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(lockup.nextStreamId(), streamBefore);
        assertEq(vm.getNonce(DeepstateAddresses.REWARDER_FACTORY), factoryNonceBefore);
    }

    function _assertPristineDeployment() private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DGP001Bootstrap bootstrap = DGP001Bootstrap(DeepstateAddresses.DGP001_BOOTSTRAP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);

        assertEq(DeepstateAddresses.MINTER_CONTROLLER.codehash, DeepstateAddresses.MINTER_CONTROLLER_CODEHASH);
        assertEq(DeepstateAddresses.DGP001_BOOTSTRAP.codehash, DeepstateAddresses.DGP001_BOOTSTRAP_CODEHASH);
        assertEq(DeepstateAddresses.V1_CONTROLLER.codehash, DeepstateAddresses.V1_CONTROLLER_CODEHASH);
        assertEq(DeepstateAddresses.REWARDER_FACTORY.codehash, DeepstateAddresses.REWARDER_FACTORY_CODEHASH);
        assertEq(minter.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(bootstrap.governor(), DeepstateAddresses.GOVERNOR);
        assertEq(address(bootstrap.deepstateToken()), DeepstateAddresses.DEEP);
        assertEq(bootstrap.endowmentAmount(), _ENDOWMENT_AMOUNT);
        assertGe(_currentLegacyEndowment(), bootstrap.endowmentAmount());
        assertGt(bootstrap.endowmentAmount(), 0);
        assertEq(v1Controller.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(factory.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(minter.tokenAdministrationEndsAt(), 0);
        assertEq(factory.operator(), address(0));
        assertEq(factory.nextDeploymentAt(), 0);
        assertEq(router.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), DeepstateAddresses.REWARDER);
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.GOVERNOR));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.DGP001_BOOTSTRAP));
        assertFalse(deep.hasRole(deep.MINTER_ROLE(), DeepstateAddresses.MINTER_CONTROLLER));
    }

    function _executeDgp001ForSimulation() private returns (uint256 proposalId) {
        _setUpFork();
        IDeepstateGovernor governor = IDeepstateGovernor(DeepstateAddresses.GOVERNOR);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, string memory description) =
            proposal.proposal();
        proposalId = _passProposalToSucceeded(governor, targets, values, calldatas, description);

        _clearLegacyMarket();
        proposal.validateActivationPreconditions();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(proposal.verifyExecution(), proposalId);
    }

    function _simulatedMarket(address stock)
        private
        pure
        returns (DeepstateRewarderFactory.MarketConfig memory market)
    {
        address token0 = DeepstateAddresses.USDG < stock ? DeepstateAddresses.USDG : stock;
        address token1 = token0 == DeepstateAddresses.USDG ? stock : DeepstateAddresses.USDG;
        market = DeepstateRewarderFactory.MarketConfig({
            token0: token0,
            token1: token1,
            token0MaxUnits: token0 == DeepstateAddresses.USDG ? 1_000_000 : 20_000,
            token1MaxUnits: token1 == DeepstateAddresses.USDG ? 1_000_000 : 20_000,
            token0Active: true,
            token1Active: true
        });
    }

    function _assertNewRewarderConfiguration(
        DeepstateRewarderV2 rewarder,
        DeepstateRewarderFactory.MarketConfig memory market,
        bytes32 poolId,
        address expectedRewarder
    ) private view {
        assertEq(address(rewarder), expectedRewarder);
        assertGt(address(rewarder).code.length, 0);
        assertEq(rewarder.owner(), DeepstateAddresses.REWARDER_FACTORY);
        assertEq(rewarder.deepstate(), DeepstateAddresses.ROUTER);
        assertEq(rewarder.rewardToken(), DeepstateAddresses.DEEP);
        assertEq(rewarder.poolId(), poolId);
        assertEq(rewarder.token0(), market.token0);
        assertEq(rewarder.token1(), market.token1);
        assertEq(rewarder.sideEmissionCap(), 50_000_000e18);
        assertEq(rewarder.emissionDuration(), 365 days);
        assertEq(rewarder.token0StartQuantity(), market.token0 == DeepstateAddresses.USDG ? 1e6 : 1e18);
        assertEq(rewarder.token1StartQuantity(), market.token1 == DeepstateAddresses.USDG ? 1e6 : 1e18);
        assertEq(rewarder.token0MaxQuantity(), market.token0 == DeepstateAddresses.USDG ? 1_000_000e6 : 20_000e18);
        assertEq(rewarder.token1MaxQuantity(), market.token1 == DeepstateAddresses.USDG ? 1_000_000e6 : 20_000e18);
        assertEq(rewarder.emissionStart(market.token0), 0);
        assertEq(rewarder.emissionStart(market.token1), 0);
        assertEq(rewarder.totalAccrued(market.token0), 0);
        assertEq(rewarder.totalAccrued(market.token1), 0);
    }

    function _assertNewRewarderSystemStatus(
        DeepstateRewarderV2 rewarder,
        bytes32 poolId,
        NewMarketSnapshot memory before_,
        uint256 proposalId
    ) private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);
        ISablierDGP001View lockup = ISablierDGP001View(DeepstateAddresses.SABLIER_LOCKUP);

        assertEq(router.poolHook(poolId), address(rewarder));
        bytes32 poolStateSlot = keccak256(abi.encode(poolId, _POOL_STATE_MAPPING_SLOT));
        assertEq(uint256(vm.load(DeepstateAddresses.ROUTER, poolStateSlot)) & _BOTH_HOOK_FLAGS, _BOTH_HOOK_FLAGS);
        assertEq(router.poolHook(DeepstateAddresses.NVDA_USDG_POOL_ID), before_.originalNvdaRewarder);
        assertEq(deep.balanceOf(address(rewarder)), _MARKET_FUNDING);
        assertEq(deep.totalSupply() - before_.supply, _MARKET_FUNDING + _MARKET_VESTING);
        assertEq(lockup.nextStreamId(), before_.streamId + 1);
        _assertMinterStream(lockup, before_.streamId, before_.deployedAt, _MARKET_VESTING);
        assertEq(factory.nextDeploymentAt(), uint256(before_.deployedAt) + factory.DEPLOYMENT_COOLDOWN());

        _assertSystemAuthorities(proposalId);
    }

    function _assertSystemAuthorities(uint256 proposalId) private view {
        DeepstateToken deep = DeepstateToken(DeepstateAddresses.DEEP);
        DeepstateMinterController minter = DeepstateMinterController(DeepstateAddresses.MINTER_CONTROLLER);
        DeepstateV1Controller v1Controller = DeepstateV1Controller(DeepstateAddresses.V1_CONTROLLER);
        DeepstateRewarderFactory factory = DeepstateRewarderFactory(DeepstateAddresses.REWARDER_FACTORY);
        IDeepstateV1 router = IDeepstateV1(DeepstateAddresses.ROUTER);

        assertEq(factory.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(factory.operator(), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(minter.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(minter.rolesOf(address(factory)), 1);
        assertEq(v1Controller.owner(), DeepstateAddresses.GOVERNOR);
        assertEq(v1Controller.rolesOf(address(factory)), 1);
        assertEq(router.owner(), address(v1Controller));
        assertEq(deep.defaultAdminCount(), 1);
        assertTrue(deep.hasRole(bytes32(0), address(minter)));
        assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(minter)));
        assertLe(deep.totalSupply(), minter.maxSupply());
        assertLt(block.timestamp, minter.tokenAdministrationEndsAt());
        (address feeRecipient, uint16 feeBps) = IDeepstateV1DGP001View(DeepstateAddresses.ROUTER).feeConfig();
        assertEq(feeRecipient, DeepstateAddresses.STATE);
        assertEq(feeBps, DeepstateAddresses.ROUTER_FEE_BPS);
        assertEq(IDeepstateGovernor(DeepstateAddresses.GOVERNOR).state(proposalId), 7);
    }

    function _assertEndowmentStream(
        ISablierDGP001View lockup,
        uint256 streamId,
        uint40 expectedStart,
        uint256 expectedAmount
    ) private view {
        assertEq(lockup.ownerOf(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getRecipient(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getSender(streamId), DeepstateAddresses.GOVERNOR);
        assertEq(address(lockup.getUnderlyingToken(streamId)), DeepstateAddresses.DEEP);
        assertEq(lockup.getDepositedAmount(streamId), expectedAmount);
        assertEq(lockup.getStartTime(streamId), expectedStart);
        assertEq(lockup.getEndTime(streamId), expectedStart + 365 days);
        assertEq(lockup.getCliffTime(streamId), 0);
        assertEq(lockup.getGranularity(streamId), 1 seconds);
        assertFalse(lockup.isCancelable(streamId));
        assertFalse(lockup.isTransferable(streamId));
    }

    function _assertMinterStream(
        ISablierDGP001View lockup,
        uint256 streamId,
        uint40 expectedStart,
        uint256 expectedAmount
    ) private view {
        assertEq(lockup.ownerOf(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getRecipient(streamId), DeepstateAddresses.DEEPSTATE_INC_SAFE);
        assertEq(lockup.getSender(streamId), DeepstateAddresses.MINTER_CONTROLLER);
        assertEq(address(lockup.getUnderlyingToken(streamId)), DeepstateAddresses.DEEP);
        assertEq(lockup.getDepositedAmount(streamId), expectedAmount);
        assertEq(lockup.getStartTime(streamId), expectedStart);
        assertEq(lockup.getEndTime(streamId), expectedStart + 365 days);
        assertEq(lockup.getCliffTime(streamId), 0);
        assertEq(lockup.getGranularity(streamId), 1 seconds);
        assertFalse(lockup.isCancelable(streamId));
        assertFalse(lockup.isTransferable(streamId));
    }

    function _executeAction(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, uint256 index)
        private
    {
        vm.prank(DeepstateAddresses.GOVERNOR);
        (bool success, bytes memory result) = targets[index].call{value: values[index]}(calldatas[index]);
        assertTrue(success, string(result));
    }

    function _passProposalToSucceeded(
        IDeepstateGovernor governor,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) private returns (uint256 proposalId) {
        vm.prank(proposal.proposer());
        proposalId = governor.propose(targets, values, calldatas, description);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        vm.warp(snapshot + 1);
        vm.prank(QUORUM_VOTER);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        assertEq(governor.state(proposalId), 4);
    }

    function _clearLegacyMarket() private {
        IDeepstateV1DGP001 router = IDeepstateV1DGP001(DeepstateAddresses.ROUTER);
        bytes32 bookId = _PINNED_ACTIVE_BOOK_ID;

        // The reviewed fork contains the production deployment and the live book is not yet operationally prepared.
        // Model the observable result of the user/keeper claimant-registration and cancellation phase while leaving
        // immutable identities and cumulative legacy accrual untouched. A final release fork must observe these four
        // zeroes naturally before the proposal is executed.
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.activeBookId, (DeepstateAddresses.USDG, DeepstateAddresses.NVDA)),
            abi.encode(bookId)
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.topOrder, (bookId, true)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.ROUTER,
            abi.encodeCall(IDeepstateV1DGP001.topOrder, (bookId, false)),
            abi.encode(uint32(0), uint160(0))
        );
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP001.rewardees, (DeepstateAddresses.USDG)),
            abi.encode(uint32(0), uint64(0))
        );

        if (vm.envOr("DGP001_TEST_PRUNED_RPC", false)) {
            // Diagnostic-only fallback for the official pruned RPC. Trusted release CI never sets this variable and
            // therefore executes both real Router hook writes and inspects the packed side flags on an archive fork.
            address expectedRewarder = vm.computeCreateAddress(
                DeepstateAddresses.REWARDER_FACTORY, vm.getNonce(DeepstateAddresses.REWARDER_FACTORY)
            );
            vm.mockCall(DeepstateAddresses.ROUTER, IDeepstateV1.setPoolHookConfig.selector, bytes(""));
            bytes[] memory hookReturns = new bytes[](9);
            hookReturns[0] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[1] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[2] = abi.encode(DeepstateAddresses.REWARDER);
            hookReturns[3] = abi.encode(address(0));
            for (uint256 i = 4; i < hookReturns.length; ++i) {
                hookReturns[i] = abi.encode(expectedRewarder);
            }
            vm.mockCalls(
                DeepstateAddresses.ROUTER,
                abi.encodeCall(IDeepstateV1.poolHook, (DeepstateAddresses.NVDA_USDG_POOL_ID)),
                hookReturns
            );
        }
        vm.mockCall(
            DeepstateAddresses.REWARDER,
            abi.encodeCall(ILegacyRewarderDGP001.rewardees, (DeepstateAddresses.NVDA)),
            abi.encode(uint32(0), uint64(0))
        );

        (uint32 bidNonce, uint160 bidAmount) = router.topOrder(bookId, true);
        (uint32 askNonce, uint160 askAmount) = router.topOrder(bookId, false);
        assertEq(bidNonce, 0);
        assertEq(bidAmount, 0);
        assertEq(askNonce, 0);
        assertEq(askAmount, 0);

        ILegacyRewarderDGP001 legacy = ILegacyRewarderDGP001(DeepstateAddresses.REWARDER);
        (uint32 usdGNonce, uint64 usdGStartedAt) = legacy.rewardees(DeepstateAddresses.USDG);
        (uint32 nvdaNonce, uint64 nvdaStartedAt) = legacy.rewardees(DeepstateAddresses.NVDA);
        assertEq(usdGNonce, 0);
        assertEq(usdGStartedAt, 0);
        assertEq(nvdaNonce, 0);
        assertEq(nvdaStartedAt, 0);
    }

    function _currentLegacyEndowment() private view returns (uint256) {
        ILegacyRewarderDGP001 legacy = ILegacyRewarderDGP001(DeepstateAddresses.REWARDER);
        return (uint256(legacy.totalAccrued(DeepstateAddresses.USDG))
                + uint256(legacy.totalAccrued(DeepstateAddresses.NVDA))) * 30 / 100;
    }

    function _poolStateSlot() private pure returns (bytes32) {
        return keccak256(abi.encode(DeepstateAddresses.NVDA_USDG_POOL_ID, _POOL_STATE_MAPPING_SLOT));
    }
}
