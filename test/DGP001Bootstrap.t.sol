// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DGP001Bootstrap} from "../src/DGP001Bootstrap.sol";
import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {IDeepstateLegacyRewarder} from "../src/interfaces/IDeepstateLegacyRewarder.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";

contract MockDGP001Asset {}

contract MockDGP001Router {
    mapping(bytes32 poolId => address hook) public poolHook;

    bytes32 public activeBook;
    uint32 public bidNonce;
    uint160 public bidAmount;
    uint32 public askNonce;
    uint160 public askAmount;

    function setPoolHook(bytes32 poolId, address hook) external {
        poolHook[poolId] = hook;
    }

    function setActiveBook(bytes32 bookId) external {
        activeBook = bookId;
    }

    function setTopOrder(bool isBid, uint32 nonce, uint160 soldAmount) external {
        if (isBid) {
            bidNonce = nonce;
            bidAmount = soldAmount;
        } else {
            askNonce = nonce;
            askAmount = soldAmount;
        }
    }

    function activeBookId(address, address) external view returns (bytes32) {
        return activeBook;
    }

    function topOrder(bytes32, bool isBid) external view returns (uint32 nonce, uint160 soldAmount) {
        return isBid ? (bidNonce, bidAmount) : (askNonce, askAmount);
    }
}

contract MockDGP001LegacyRewarder is IDeepstateLegacyRewarder {
    address public override deepstate;
    address public override rewardToken;
    bytes32 public override poolId;
    address public override token0;
    address public override token1;

    mapping(address token => uint32 nonce) private _rewardeeNonce;
    mapping(address token => uint64 startedAt) private _rewardeeStartedAt;
    mapping(address token => uint96 accrued) private _totalAccrued;

    constructor(address deepstate_, address rewardToken_, address token0_, address token1_) {
        deepstate = deepstate_;
        rewardToken = rewardToken_;
        token0 = token0_;
        token1 = token1_;
        poolId = keccak256(abi.encode(token0_, token1_));
    }

    function setDeepstate(address value) external {
        deepstate = value;
    }

    function setRewardToken(address value) external {
        rewardToken = value;
    }

    function setPoolId(bytes32 value) external {
        poolId = value;
    }

    function setRewardee(address token, uint32 nonce, uint64 startedAt) external {
        _rewardeeNonce[token] = nonce;
        _rewardeeStartedAt[token] = startedAt;
    }

    function setTotalAccrued(address token, uint96 value) external {
        _totalAccrued[token] = value;
    }

    function rewardees(address token) external view returns (uint32 orderNonce, uint64 startedAt) {
        return (_rewardeeNonce[token], _rewardeeStartedAt[token]);
    }

    function totalAccrued(address token) external view returns (uint96 accrued) {
        return _totalAccrued[token];
    }
}

    contract DGP001BootstrapTest is Test {
        uint256 internal constant INITIAL_SUPPLY = 1_000e18;
        uint96 internal constant TOKEN0_ACCRUED = 700e18;
        uint96 internal constant TOKEN1_ACCRUED = 300e18;
        uint256 internal constant ENDOWMENT = 300e18;
        uint256 internal constant DEFAULT_CAP = 3_000e18;

        address internal constant RECIPIENT = address(0xD33F);
        address internal constant UNAUTHORIZED = address(0xBAD);

        DeepstateToken internal deep;
        MockSablierLockupLinearV4 internal sablier;
        MockDGP001Router internal router;
        MockDGP001LegacyRewarder internal legacyRewarder;
        DeepstateMinterController internal minterController;
        DGP001Bootstrap internal bootstrap;

        address internal token0;
        address internal token1;
        bytes32 internal poolId;

        event EndowmentCreated(
            address indexed legacyRewarder,
            address indexed recipient,
            uint256 indexed streamId,
            address token0,
            address token1,
            uint96 token0Accrued,
            uint96 token1Accrued,
            uint256 totalAccrued,
            uint256 endowmentAmount,
            uint256 preexistingBalanceBurned,
            uint256 postEndowmentSupply,
            uint256 snapshotBlock,
            uint40 snapshotAt
        );

        function setUp() public {
            deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
            sablier = new MockSablierLockupLinearV4();
            router = new MockDGP001Router();

            address assetA = address(new MockDGP001Asset());
            address assetB = address(new MockDGP001Asset());
            (token0, token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);

            legacyRewarder = new MockDGP001LegacyRewarder(address(router), address(deep), token0, token1);
            poolId = legacyRewarder.poolId();
            router.setPoolHook(poolId, address(legacyRewarder));
            router.setActiveBook(keccak256("active-book"));
            legacyRewarder.setTotalAccrued(token0, TOKEN0_ACCRUED);
            legacyRewarder.setTotalAccrued(token1, TOKEN1_ACCRUED);

            deep.grantRole(deep.MINTER_ROLE(), address(this));
            deep.mint(address(this), INITIAL_SUPPLY);

            minterController = _newMinterController(DEFAULT_CAP, DEFAULT_CAP);
            bootstrap = _newBootstrap(minterController);
        }

        function testExecuteCreatesExactOneYearEndowmentAndBecomesInert() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            vm.roll(12_345);
            vm.warp(1_800_000_000);

            vm.expectEmit(true, true, true, true, address(bootstrap));
            emit EndowmentCreated(
                address(legacyRewarder),
                RECIPIENT,
                1,
                token0,
                token1,
                TOKEN0_ACCRUED,
                TOKEN1_ACCRUED,
                uint256(TOKEN0_ACCRUED) + uint256(TOKEN1_ACCRUED),
                ENDOWMENT,
                0,
                INITIAL_SUPPLY + ENDOWMENT,
                block.number,
                uint40(block.timestamp)
            );
            uint256 createdStreamId = bootstrap.execute();

            assertEq(createdStreamId, 1);
            assertTrue(bootstrap.executed());
            assertEq(bootstrap.snapshotBlock(), block.number);
            assertEq(bootstrap.snapshotAt(), block.timestamp);
            assertEq(bootstrap.snapshotToken0(), token0);
            assertEq(bootstrap.snapshotToken1(), token1);
            assertEq(bootstrap.token0Accrued(), TOKEN0_ACCRUED);
            assertEq(bootstrap.token1Accrued(), TOKEN1_ACCRUED);
            assertEq(bootstrap.totalAccrued(), uint256(TOKEN0_ACCRUED) + uint256(TOKEN1_ACCRUED));
            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);
            assertEq(bootstrap.preexistingBalanceBurned(), 0);
            assertEq(bootstrap.postEndowmentSupply(), INITIAL_SUPPLY + ENDOWMENT);
            assertEq(bootstrap.streamId(), 1);

            assertEq(deep.totalSupply(), INITIAL_SUPPLY + ENDOWMENT);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.balanceOf(address(sablier)), ENDOWMENT);
            assertEq(deep.allowance(address(bootstrap), address(sablier)), 0);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
            assertTrue(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(this)));
            assertFalse(deep.hasRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController)));

            MockSablierLockupLinearV4.Stream memory stream = sablier.stream(1);
            assertEq(stream.funder, address(bootstrap));
            assertEq(stream.sender, address(bootstrap));
            assertEq(stream.recipient, RECIPIENT);
            assertEq(stream.token, address(deep));
            assertEq(stream.depositAmount, ENDOWMENT);
            assertFalse(stream.cancelable);
            assertFalse(stream.transferable);
            assertEq(stream.shape, "Deepstate Inc endowment");
            assertEq(stream.startUnlockAmount, 0);
            assertEq(stream.cliffUnlockAmount, 0);
            assertEq(stream.granularity, 1 seconds);
            assertEq(stream.cliffDuration, 0);
            assertEq(stream.totalDuration, 365 days);

            assertEq(minterController.grossIssued(), 0);
            assertEq(minterController.tokenAdministrationEndsAt(), 0);

            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            vm.expectRevert(DGP001Bootstrap.AlreadyExecuted.selector);
            bootstrap.execute();
            assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testExecuteRoundsDownThirtyPercentOfCombinedAccrual() public {
            legacyRewarder.setTotalAccrued(token0, 2);
            legacyRewarder.setTotalAccrued(token1, 3);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            bootstrap.execute();

            assertEq(bootstrap.totalAccrued(), 5);
            assertEq(bootstrap.endowmentAmount(), 1);
            assertEq(deep.totalSupply(), INITIAL_SUPPLY + 1);
        }

        function testExecuteBurnsUnsolicitedDeterministicAddressBalanceWithoutChangingEndowment() public {
            uint256 unsolicitedBalance = 17e18;
            // ERC20 balances do not require code at the recipient, so this models dust sent before CREATE2 deployment.
            deep.transfer(address(bootstrap), unsolicitedBalance);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            bootstrap.execute();

            assertEq(bootstrap.preexistingBalanceBurned(), unsolicitedBalance);
            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);
            assertEq(bootstrap.postEndowmentSupply(), INITIAL_SUPPLY - unsolicitedBalance + ENDOWMENT);
            assertEq(deep.totalSupply(), INITIAL_SUPPLY - unsolicitedBalance + ENDOWMENT);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.balanceOf(address(sablier)), ENDOWMENT);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testControllerActivationRecordsPostEndowmentSupplyAsGrossBaseline() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            bootstrap.execute();

            deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
            deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
            minterController.activateTokenAdministration();

            assertEq(minterController.grossIssued(), INITIAL_SUPPLY + ENDOWMENT);
            assertEq(
                minterController.tokenAdministrationEndsAt(),
                block.timestamp + minterController.TOKEN_ADMINISTRATION_DURATION()
            );
        }

        function testExecuteRejectsAlreadyActivatedMinterController() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
            deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
            minterController.activateTokenAdministration();

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.MinterControllerNotPristine.selector,
                    minterController.tokenAdministrationEndsAt(),
                    INITIAL_SUPPLY
                )
            );
            bootstrap.execute();
        }

        function testExecuteRequiresGovernor() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.prank(UNAUTHORIZED);
            vm.expectRevert(abi.encodeWithSelector(DGP001Bootstrap.Unauthorized.selector, UNAUTHORIZED));
            bootstrap.execute();

            assertFalse(bootstrap.executed());
            assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testExecuteRequiresPreGrantedMinterRole() public {
            vm.expectRevert(DGP001Bootstrap.BootstrapMinterRoleMissing.selector);
            bootstrap.execute();

            assertFalse(bootstrap.executed());
            assertEq(deep.totalSupply(), INITIAL_SUPPLY);
        }

        function testExecuteRejectsWrongInstalledRewarder() public {
            router.setPoolHook(poolId, address(0xBEEF));
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewarderNotInstalled.selector,
                    poolId,
                    address(legacyRewarder),
                    address(0xBEEF)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsBusyBidBook() public {
            bytes32 activeBook = router.activeBook();
            router.setTopOrder(true, 7, 1e18);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewarderBookNotIdle.selector, activeBook, true, uint32(7), uint160(1e18)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsBusyAskBook() public {
            bytes32 activeBook = router.activeBook();
            router.setTopOrder(false, 9, 2e18);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewarderBookNotIdle.selector, activeBook, false, uint32(9), uint160(2e18)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsBusyToken0Cursor() public {
            legacyRewarder.setRewardee(token0, 11, 22);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewarderCursorNotIdle.selector, token0, uint32(11), uint64(22)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsBusyToken1Cursor() public {
            legacyRewarder.setRewardee(token1, 33, 44);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewarderCursorNotIdle.selector, token1, uint32(33), uint64(44)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsRewardTokenDrift() public {
            legacyRewarder.setRewardToken(address(0xDEAD));
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.LegacyRewardTokenMismatch.selector, address(deep), address(0xDEAD)
                )
            );
            bootstrap.execute();
        }

        function testExecuteRejectsPoolIdentityDrift() public {
            bytes32 wrongPoolId = keccak256("wrong-pool");
            legacyRewarder.setPoolId(wrongPoolId);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(DGP001Bootstrap.LegacyRewarderPoolIdentityMismatch.selector, poolId, wrongPoolId)
            );
            bootstrap.execute();
        }

        function testExecuteRejectsZeroEndowment() public {
            legacyRewarder.setTotalAccrued(token0, 1);
            legacyRewarder.setTotalAccrued(token1, 2);
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.expectRevert(DGP001Bootstrap.EndowmentAmountZero.selector);
            bootstrap.execute();
        }

        function testExecuteEnforcesControllerLiveSupplyCap() public {
            DeepstateMinterController cappedController = _newMinterController(
                INITIAL_SUPPLY + ENDOWMENT - 1, DEFAULT_CAP
            );
            DGP001Bootstrap cappedBootstrap = _newBootstrap(cappedController);
            deep.grantRole(deep.MINTER_ROLE(), address(cappedBootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.MintCapExceeded.selector, INITIAL_SUPPLY + ENDOWMENT - 1, INITIAL_SUPPLY + ENDOWMENT
                )
            );
            cappedBootstrap.execute();
        }

        function testExecuteEnforcesControllerGrossIssuanceCapAgainstPostEndowmentSupply() public {
            DeepstateMinterController cappedController = _newMinterController(
                DEFAULT_CAP, INITIAL_SUPPLY + ENDOWMENT - 1
            );
            DGP001Bootstrap cappedBootstrap = _newBootstrap(cappedController);
            deep.grantRole(deep.MINTER_ROLE(), address(cappedBootstrap));

            vm.expectRevert(
                abi.encodeWithSelector(
                    DGP001Bootstrap.GrossIssuanceCapExceeded.selector,
                    INITIAL_SUPPLY + ENDOWMENT - 1,
                    INITIAL_SUPPLY + ENDOWMENT
                )
            );
            cappedBootstrap.execute();
        }

        function testSablierFailureRollsBackMintAuditAndRoleRenunciation() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            sablier.setRevertCreate(true);

            vm.expectRevert(MockSablierLockupLinearV4.CreateReverted.selector);
            bootstrap.execute();

            assertFalse(bootstrap.executed());
            assertEq(bootstrap.snapshotBlock(), 0);
            assertEq(bootstrap.endowmentAmount(), 0);
            assertEq(bootstrap.streamId(), 0);
            assertEq(deep.totalSupply(), INITIAL_SUPPLY);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testConstructorRejectsMinterControllerConfigurationMismatch() public {
            DeepstateMinterController wrongController = new DeepstateMinterController(
                address(0xCAFE), address(deep), address(sablier), RECIPIENT, DEFAULT_CAP, DEFAULT_CAP
            );

            vm.expectRevert(DGP001Bootstrap.MinterControllerConfigurationMismatch.selector);
            new DGP001Bootstrap(address(this), address(wrongController), address(legacyRewarder));
        }

        function _newMinterController(uint256 mintCap, uint256 grossCap)
            private
            returns (DeepstateMinterController controller)
        {
            controller = new DeepstateMinterController(
                address(this), address(deep), address(sablier), RECIPIENT, mintCap, grossCap
            );
        }

        function _newBootstrap(DeepstateMinterController controller) private returns (DGP001Bootstrap result) {
            result = new DGP001Bootstrap(address(this), address(controller), address(legacyRewarder));
        }
    }
