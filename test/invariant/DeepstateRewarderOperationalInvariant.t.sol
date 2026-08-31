// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";
import {IHook} from "deepstate-contracts/interfaces/IHook.sol";
import {DeepstateRewarder} from "deepstate-protocol/DeepstateRewarder.sol";
import {IOrderBook} from "deepstate-protocol/interfaces/IOrderBook.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DeepstateRewarderV2} from "../../src/DeepstateRewarderV2.sol";

/// @dev Minimal controllable order-book surface. Rewarder calls still cross the same external
/// interface boundaries as production; only order ownership and top-of-book state are modeled.
contract OperationalOrderBook is IOrderBook {
    struct Top {
        uint32 nonce;
        uint160 amount;
    }

    mapping(bytes32 orderId_ => address owner) internal _owners;
    mapping(bytes32 bookId => mapping(bool isBid => Top top)) internal _tops;

    function orderId(bytes32 id, bytes32 order) public pure returns (bytes32) {
        return keccak256(abi.encode(id, order));
    }

    function ownerOfOrder(bytes32 orderId_) external view returns (address) {
        return _owners[orderId_];
    }

    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount) {
        Top memory top = _tops[bookId][isBid];
        return (top.nonce, top.amount);
    }

    function setOwner(bytes32 bookId, bytes32 order, address owner) external {
        _owners[orderId(bookId, order)] = owner;
    }

    function setTop(bytes32 bookId, bool isBid, uint32 nonce, uint160 amount) external {
        _tops[bookId][isBid] = Top({nonce: nonce, amount: amount});
    }

    function tryExecute(
        DeepstateRewarderV2 rewarder,
        bytes32 poolId,
        bytes32 bookId,
        address token,
        uint160 outgoingAmount,
        uint32 incomingNonce
    ) external returns (bool success, bytes memory result, uint256 gasUsed) {
        uint256 beforeGas = gasleft();
        (success, result) = address(rewarder)
            .call(abi.encodeCall(DeepstateRewarder.execute, (poolId, bookId, token, outgoingAmount, incomingNonce)));
        gasUsed = beforeGas - gasleft();
    }

    function tryExecuteWithGas(
        DeepstateRewarderV2 rewarder,
        bytes32 poolId,
        bytes32 bookId,
        address token,
        uint160 outgoingAmount,
        uint32 incomingNonce,
        uint256 gasStipend
    ) external returns (bool success, bytes memory result) {
        (success, result) = address(rewarder).call{gas: gasStipend}(
            abi.encodeCall(DeepstateRewarder.execute, (poolId, bookId, token, outgoingAmount, incomingNonce))
        );
    }
}

/// @dev Stateful handler for authority, accounting, gas, schedule, and lifecycle properties.
contract DeepstateRewarderOperationalHandler is Test {
    address public constant TOKEN0 = address(0x1000);
    address public constant TOKEN1 = address(0x2000);
    address public constant UNKNOWN_TOKEN = address(0x3000);
    address public constant CLAIMANT = address(0xA11CE);
    uint96 public constant SIDE_CAP = 50_000_000e18;
    uint32 public constant DURATION = 365 days;
    uint160 public constant TOKEN0_START = 1e18;
    uint160 public constant TOKEN0_MAX = 5_000e18;
    uint160 public constant TOKEN1_START = 1e6;
    uint160 public constant TOKEN1_MAX = 1_000_000e6;
    bytes32 public constant BOOK_A = keccak256("operational-book-a");
    bytes32 public constant BOOK_B = keccak256("operational-book-b");
    bytes32 public constant INVALID_POOL = keccak256("invalid-pool");
    uint256 public constant ROUTER_HOOK_GAS_LIMIT = 200_000;

    OperationalOrderBook public immutable orderBook;
    DeepstateToken public immutable rewardToken;
    DeepstateRewarderV2 public immutable rewarder;
    bytes32 public immutable configuredPoolId;

    uint256 public recordedToken0Credits;
    uint256 public recordedToken1Credits;
    uint64 public firstToken0Activation;
    uint64 public firstToken1Activation;
    uint256 public maxSuccessfulExecuteGas;
    uint256 public successfulExecutions;
    uint256 public invalidAttempts;

    bool public bindingViolation;
    bool public validExecutionFailure;
    bool public retirementViolation;
    bool public retiredActionViolation;
    bool public retired;
    uint96 public token0AccruedAtRetirement;
    uint96 public token1AccruedAtRetirement;
    uint32 public token0NonceAtRetirement;
    uint32 public token1NonceAtRetirement;
    uint64 public token0CursorAtRetirement;
    uint64 public token1CursorAtRetirement;

    constructor() {
        orderBook = new OperationalOrderBook();
        rewardToken = new DeepstateToken(address(this), "Invariant Reward", "iDEEP");
        rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
        configuredPoolId = keccak256(abi.encode(TOKEN0, TOKEN1));
        rewarder = new DeepstateRewarderV2(
            address(this),
            address(orderBook),
            address(rewardToken),
            configuredPoolId,
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            DURATION,
            TOKEN0_START,
            TOKEN0_MAX,
            TOKEN1_START,
            TOKEN1_MAX
        );
        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);

        // Establish a non-vacuous cold installation sample before retirement can be selected as the
        // first randomized action in a run.
        (bool success,, uint256 gasUsed) = orderBook.tryExecute(rewarder, configuredPoolId, BOOK_A, TOKEN0, 0, 1);
        require(success, "baseline execute failed");
        successfulExecutions = 1;
        maxSuccessfulExecuteGas = gasUsed;
        // forge-lint: disable-next-line(unsafe-typecast)
        firstToken0Activation = uint64(block.timestamp);
    }

    function executeValid(
        uint8 sideSeed,
        uint8 bookSeed,
        uint160 outgoingAmount,
        uint32 incomingSeed,
        uint32 elapsedSeed
    ) external {
        if (retired) return;

        address token = sideSeed & 1 == 0 ? TOKEN0 : TOKEN1;
        bytes32 incomingBook = bookSeed & 1 == 0 ? BOOK_A : BOOK_B;
        uint32 incomingNonce = incomingSeed % 5 == 0 ? 0 : incomingSeed | 1;
        vm.warp(block.timestamp + bound(elapsedSeed, 0, 14 days));

        (uint32 outgoingNonce,) = rewarder.rewardees(token);
        bytes32 outgoingBook = rewarder.rewardeeBookId(token);
        uint96 accruedBefore = rewarder.totalAccrued(token);
        uint256 balanceBefore = rewarder.balances(outgoingBook, token, outgoingNonce);

        (bool success,, uint256 gasUsed) =
            orderBook.tryExecute(rewarder, configuredPoolId, incomingBook, token, outgoingAmount, incomingNonce);
        if (!success) {
            validExecutionFailure = true;
            return;
        }

        ++successfulExecutions;
        if (gasUsed > maxSuccessfulExecuteGas) maxSuccessfulExecuteGas = gasUsed;

        uint96 accruedAfter = rewarder.totalAccrued(token);
        uint256 balanceAfter = rewarder.balances(outgoingBook, token, outgoingNonce);
        uint256 credit = uint256(accruedAfter) - uint256(accruedBefore);
        if (balanceAfter - balanceBefore != credit) bindingViolation = true;

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 now64 = uint64(block.timestamp);
        if (token == TOKEN0) {
            recordedToken0Credits += credit;
            if (firstToken0Activation == 0 && incomingNonce != 0) firstToken0Activation = now64;
            if (rewarder.emissionStart(token) != firstToken0Activation) bindingViolation = true;
        } else {
            recordedToken1Credits += credit;
            if (firstToken1Activation == 0 && incomingNonce != 0) firstToken1Activation = now64;
            if (rewarder.emissionStart(token) != firstToken1Activation) bindingViolation = true;
        }
    }

    function attemptUnauthorizedExecute(uint8 sideSeed, uint160 outgoingAmount, uint32 incomingNonce) external {
        address token = sideSeed & 1 == 0 ? TOKEN0 : TOKEN1;
        bytes4 expected =
            retired ? DeepstateRewarderV2.RewarderRetired.selector : DeepstateRewarder.NotDeepstate.selector;
        _attemptInvalid(false, expected, configuredPoolId, BOOK_A, token, outgoingAmount, incomingNonce);
    }

    function attemptWrongPool(uint8 sideSeed, uint160 outgoingAmount, uint32 incomingNonce) external {
        address token = sideSeed & 1 == 0 ? TOKEN0 : TOKEN1;
        bytes4 expected =
            retired ? DeepstateRewarderV2.RewarderRetired.selector : DeepstateRewarder.InvalidPool.selector;
        _attemptInvalid(true, expected, INVALID_POOL, BOOK_A, token, outgoingAmount, incomingNonce);
    }

    function attemptWrongToken(uint160 outgoingAmount, uint32 incomingNonce) external {
        bytes4 expected =
            retired ? DeepstateRewarderV2.RewarderRetired.selector : DeepstateRewarder.InvalidHookToken.selector;
        _attemptInvalid(true, expected, configuredPoolId, BOOK_A, UNKNOWN_TOKEN, outgoingAmount, incomingNonce);
    }

    function retireRewarder() external {
        if (retired) return;

        uint256 funding = rewardToken.balanceOf(address(rewarder));
        uint256 supplyBefore = rewardToken.totalSupply();
        token0AccruedAtRetirement = rewarder.totalAccrued(TOKEN0);
        token1AccruedAtRetirement = rewarder.totalAccrued(TOKEN1);
        (token0NonceAtRetirement, token0CursorAtRetirement) = rewarder.rewardees(TOKEN0);
        (token1NonceAtRetirement, token1CursorAtRetirement) = rewarder.rewardees(TOKEN1);

        (bool success,) = address(rewarder).call(abi.encodeCall(DeepstateRewarderV2.retireAndBurnBalance, ()));
        if (!success) {
            retirementViolation = true;
            return;
        }
        retired = true;

        if (!rewarder.retired()) retirementViolation = true;
        if (rewarder.owner() != address(0)) retirementViolation = true;
        if (rewardToken.balanceOf(address(rewarder)) != 0) retirementViolation = true;
        if (rewardToken.totalSupply() + funding != supplyBefore) retirementViolation = true;
    }

    function attemptRetiredActions(uint32 nonceSeed) external {
        if (!retired) return;
        uint32 nonce = nonceSeed | 1;
        bytes32 order = bytes32(uint256(nonce));

        (bool executeSuccess, bytes memory executeResult,) =
            orderBook.tryExecute(rewarder, configuredPoolId, BOOK_A, TOKEN0, 1e18, nonce);
        if (executeSuccess || _selector(executeResult) != DeepstateRewarderV2.RewarderRetired.selector) {
            retiredActionViolation = true;
        }

        (bool registerSuccess, bytes memory registerResult) =
            address(rewarder).call(abi.encodeCall(DeepstateRewarder.registerClaimant, (BOOK_A, order)));
        if (registerSuccess || _selector(registerResult) != DeepstateRewarderV2.RewarderRetired.selector) {
            retiredActionViolation = true;
        }

        DeepstateRewarder.OrderReference[] memory registrations = new DeepstateRewarder.OrderReference[](1);
        registrations[0] = DeepstateRewarder.OrderReference({bookId: BOOK_A, order: order});
        (bool batchRegisterSuccess, bytes memory batchRegisterResult) =
            address(rewarder).call(abi.encodeCall(DeepstateRewarder.registerClaimants, (registrations)));
        if (batchRegisterSuccess || _selector(batchRegisterResult) != DeepstateRewarderV2.RewarderRetired.selector) {
            retiredActionViolation = true;
        }

        (bool distributeSuccess, bytes memory distributeResult) =
            address(rewarder).call(abi.encodeCall(DeepstateRewarder.distributeRewards, (BOOK_A, order, TOKEN0)));
        if (distributeSuccess || _selector(distributeResult) != DeepstateRewarderV2.RewarderRetired.selector) {
            retiredActionViolation = true;
        }

        DeepstateRewarder.RewardClaim[] memory claims = new DeepstateRewarder.RewardClaim[](1);
        claims[0] = DeepstateRewarder.RewardClaim({bookId: BOOK_A, order: order, token: TOKEN0});
        (bool batchDistributeSuccess, bytes memory batchDistributeResult) =
            address(rewarder).call(abi.encodeCall(DeepstateRewarder.distributeRewardsBatch, (claims)));
        if (batchDistributeSuccess || _selector(batchDistributeResult) != DeepstateRewarderV2.RewarderRetired.selector)
        {
            retiredActionViolation = true;
        }
    }

    function mintAndSweepRetiredBalance(uint128 amountSeed) external {
        if (!retired) return;
        uint256 amount = bound(amountSeed, 1, type(uint128).max);
        uint256 supplyBefore = rewardToken.totalSupply();
        rewardToken.mint(address(rewarder), amount);

        (bool success,) = address(rewarder).call(abi.encodeCall(DeepstateRewarderV2.burnRetiredBalance, ()));
        if (!success || rewardToken.balanceOf(address(rewarder)) != 0 || rewardToken.totalSupply() != supplyBefore) {
            retirementViolation = true;
        }
    }

    function _attemptInvalid(
        bool throughOrderBook,
        bytes4 expected,
        bytes32 poolId_,
        bytes32 bookId_,
        address token_,
        uint160 outgoingAmount_,
        uint32 incomingNonce_
    ) internal {
        ++invalidAttempts;
        uint96 accrued0Before = rewarder.totalAccrued(TOKEN0);
        uint96 accrued1Before = rewarder.totalAccrued(TOKEN1);
        (uint32 nonce0Before, uint64 cursor0Before) = rewarder.rewardees(TOKEN0);
        (uint32 nonce1Before, uint64 cursor1Before) = rewarder.rewardees(TOKEN1);
        bytes32 book0Before = rewarder.rewardeeBookId(TOKEN0);
        bytes32 book1Before = rewarder.rewardeeBookId(TOKEN1);

        bool success;
        bytes memory result;
        if (throughOrderBook) {
            (success, result,) =
                orderBook.tryExecute(rewarder, poolId_, bookId_, token_, outgoingAmount_, incomingNonce_);
        } else {
            (success, result) = address(rewarder)
                .call(
                    abi.encodeCall(
                        DeepstateRewarder.execute, (poolId_, bookId_, token_, outgoingAmount_, incomingNonce_)
                    )
                );
        }

        if (success || _selector(result) != expected) bindingViolation = true;
        if (rewarder.totalAccrued(TOKEN0) != accrued0Before) bindingViolation = true;
        if (rewarder.totalAccrued(TOKEN1) != accrued1Before) bindingViolation = true;
        (uint32 nonce0After, uint64 cursor0After) = rewarder.rewardees(TOKEN0);
        (uint32 nonce1After, uint64 cursor1After) = rewarder.rewardees(TOKEN1);
        if (nonce0After != nonce0Before || cursor0After != cursor0Before) bindingViolation = true;
        if (nonce1After != nonce1Before || cursor1After != cursor1Before) bindingViolation = true;
        if (rewarder.rewardeeBookId(TOKEN0) != book0Before) bindingViolation = true;
        if (rewarder.rewardeeBookId(TOKEN1) != book1Before) bindingViolation = true;
    }

    function _selector(bytes memory revertData) internal pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(revertData, 0x20))
        }
    }
}

contract DeepstateRewarderOperationalInvariantTest is StdInvariant, Test {
    DeepstateRewarderOperationalHandler internal handler;
    DeepstateRewarderV2 internal rewarder;
    DeepstateToken internal rewardToken;

    function setUp() public {
        vm.warp(1_000_000);
        handler = new DeepstateRewarderOperationalHandler();
        rewarder = handler.rewarder();
        rewardToken = handler.rewardToken();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.executeValid.selector;
        selectors[1] = handler.attemptUnauthorizedExecute.selector;
        selectors[2] = handler.attemptWrongPool.selector;
        selectors[3] = handler.attemptWrongToken.selector;
        selectors[4] = handler.retireRewarder.selector;
        selectors[5] = handler.attemptRetiredActions.selector;
        selectors[6] = handler.mintAndSweepRetiredBalance.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ExecuteIsHookOnlyAndBoundToItsImmutablePoolAndTokens() public view {
        assertFalse(handler.bindingViolation());
        assertFalse(handler.validExecutionFailure());
        assertEq(rewarder.deepstate(), address(handler.orderBook()));
        assertEq(rewarder.poolId(), handler.configuredPoolId());
        assertEq(rewarder.token0(), handler.TOKEN0());
        assertEq(rewarder.token1(), handler.TOKEN1());
    }

    function invariant_EachSideIndependentlyRespectsItsScheduleAndCap() public view {
        uint256 accrued0 = rewarder.totalAccrued(handler.TOKEN0());
        uint256 accrued1 = rewarder.totalAccrued(handler.TOKEN1());
        assertEq(accrued0, handler.recordedToken0Credits());
        assertEq(accrued1, handler.recordedToken1Credits());
        assertLe(accrued0, handler.SIDE_CAP());
        assertLe(accrued1, handler.SIDE_CAP());
        assertLe(accrued0 + accrued1, uint256(handler.SIDE_CAP()) * 2);
        assertEq(rewarder.emissionStart(handler.TOKEN0()), handler.firstToken0Activation());
        assertEq(rewarder.emissionStart(handler.TOKEN1()), handler.firstToken1Activation());
        assertEq(rewarder.cumulativeEmissionsAtElapsed(handler.DURATION()), handler.SIDE_CAP());
        assertEq(rewarder.cumulativeEmissionsAtElapsed(type(uint256).max), handler.SIDE_CAP());
    }

    function invariant_SuccessfulExecuteFitsTheRoutersFixedHookGasBudget() public view {
        assertGt(handler.successfulExecutions(), 0);
        assertLt(handler.maxSuccessfulExecuteGas(), handler.ROUTER_HOOK_GAS_LIMIT());
    }

    function invariant_RetirementIsTerminalAndAllRewardBalancesRemainBurnable() public view {
        assertFalse(handler.retirementViolation());
        assertFalse(handler.retiredActionViolation());

        if (handler.retired()) {
            assertTrue(rewarder.retired());
            assertEq(rewarder.owner(), address(0));
            assertEq(rewardToken.balanceOf(address(rewarder)), 0);
            assertEq(rewardToken.totalSupply(), 0);
            assertEq(rewarder.totalAccrued(handler.TOKEN0()), handler.token0AccruedAtRetirement());
            assertEq(rewarder.totalAccrued(handler.TOKEN1()), handler.token1AccruedAtRetirement());
            (uint32 nonce0, uint64 cursor0) = rewarder.rewardees(handler.TOKEN0());
            (uint32 nonce1, uint64 cursor1) = rewarder.rewardees(handler.TOKEN1());
            assertEq(nonce0, handler.token0NonceAtRetirement());
            assertEq(nonce1, handler.token1NonceAtRetirement());
            assertEq(cursor0, handler.token0CursorAtRetirement());
            assertEq(cursor1, handler.token1CursorAtRetirement());
        } else {
            assertFalse(rewarder.retired());
            assertEq(rewarder.owner(), address(handler));
            assertEq(rewardToken.balanceOf(address(rewarder)), uint256(handler.SIDE_CAP()) * 2);
            assertEq(rewardToken.totalSupply(), uint256(handler.SIDE_CAP()) * 2);
        }
    }
}

contract OperationalRouterToken is ERC20 {
    string internal _tokenName;
    string internal _tokenSymbol;

    constructor(string memory name_, string memory symbol_) {
        _tokenName = name_;
        _tokenSymbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OperationalRevertingHook is IHook {
    function execute(bytes32, bytes32, address, uint160, uint32) external pure {
        revert("intentional hook failure");
    }
}

contract OperationalGasBurningHook is IHook {
    function execute(bytes32, bytes32, address, uint160, uint32) external pure {
        assembly ("memory-safe") {
            for { let i := 0 } 1 { i := add(i, 1) } { mstore(0, i) }
        }
    }
}

/// @dev Focused operational properties whose preconditions are clearer and stronger than randomly
/// hoping a state machine reaches the exact multi-transaction lifecycle in the right order.
contract DeepstateRewarderOperationalPropertyTest is Test {
    uint96 internal constant SIDE_CAP = 50_000_000e18;
    uint32 internal constant DURATION = 365 days;
    uint160 internal constant START_QUANTITY = 1e18;
    uint160 internal constant MAX_QUANTITY = 5_000e18;
    bytes32 internal constant BOOK_ID = keccak256("claim-book");
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    OperationalOrderBook internal orderBook;
    DeepstateToken internal rewardToken;
    DeepstateRewarderV2 internal rewarder;
    bytes32 internal poolId;

    function setUp() public {
        vm.warp(1_000_000);
        orderBook = new OperationalOrderBook();
        rewardToken = new DeepstateToken(address(this), "Reward", "RWD");
        rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
        poolId = keccak256(abi.encode(TOKEN0, TOKEN1));
        rewarder = _newRewarder();
    }

    function testFuzz_UnderfundedLiveClaimRollsBackAtomicallyAndCanBeRetried(uint32 elapsedSeed, uint160 quantitySeed)
        public
    {
        uint256 elapsed = bound(elapsedSeed, 1, 30 days);
        uint160 quantity = uint160(bound(quantitySeed, START_QUANTITY, MAX_QUANTITY));
        uint32 nonce = 7;
        bytes32 order = bytes32(uint256(nonce));
        _activateCurrentOrder(order, nonce, quantity, ALICE);

        (, uint64 cursorBefore) = rewarder.rewardees(TOKEN1);
        vm.warp(block.timestamp + elapsed);
        uint256 expected = rewarder.previewReward(TOKEN1, cursorBefore, block.timestamp, quantity);
        assertGt(expected, 0);

        (bool success,) =
            address(rewarder).call(abi.encodeCall(DeepstateRewarder.distributeRewards, (BOOK_ID, order, TOKEN1)));
        assertFalse(success);

        bytes32 id = orderBook.orderId(BOOK_ID, order);
        (, uint64 cursorAfterFailure) = rewarder.rewardees(TOKEN1);
        assertEq(cursorAfterFailure, cursorBefore);
        assertEq(rewarder.totalAccrued(TOKEN1), 0);
        assertEq(rewarder.balances(BOOK_ID, TOKEN1, nonce), 0);
        assertEq(rewarder.claimants(id), address(0));
        assertEq(rewardToken.balanceOf(ALICE), 0);

        rewardToken.mint(address(rewarder), expected);
        rewarder.distributeRewards(BOOK_ID, order, TOKEN1);
        assertEq(rewardToken.balanceOf(ALICE), expected);
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewarder.totalAccrued(TOKEN1), expected);
        assertEq(rewarder.claimants(id), ALICE);
    }

    function testFuzz_RegistrationBeforeDeletionPreservesClaimWhileRegistrationAfterDeletionCannotRecoverIt(
        uint32 elapsedSeed,
        uint160 quantitySeed
    ) public {
        uint256 elapsed = bound(elapsedSeed, 1, 30 days);
        uint160 quantity = uint160(bound(quantitySeed, START_QUANTITY, MAX_QUANTITY));

        DeepstateRewarderV2 registeredRewarder = _newRewarder();
        DeepstateRewarderV2 unregisteredRewarder = _newRewarder();
        rewardToken.mint(address(registeredRewarder), uint256(SIDE_CAP) * 2);
        rewardToken.mint(address(unregisteredRewarder), uint256(SIDE_CAP) * 2);

        uint32 registeredNonce = 11;
        uint32 unregisteredNonce = 13;
        bytes32 registeredOrder = bytes32(uint256(registeredNonce));
        bytes32 unregisteredOrder = bytes32(uint256(unregisteredNonce));
        bytes32 registeredBook = keccak256("registered-book");
        bytes32 unregisteredBook = keccak256("unregistered-book");

        orderBook.setOwner(registeredBook, registeredOrder, ALICE);
        orderBook.setTop(registeredBook, true, registeredNonce, quantity);
        _execute(registeredRewarder, registeredBook, TOKEN1, 0, registeredNonce);
        assertEq(registeredRewarder.registerClaimant(registeredBook, registeredOrder), ALICE);

        orderBook.setOwner(unregisteredBook, unregisteredOrder, ALICE);
        orderBook.setTop(unregisteredBook, true, unregisteredNonce, quantity);
        _execute(unregisteredRewarder, unregisteredBook, TOKEN1, 0, unregisteredNonce);

        vm.warp(block.timestamp + elapsed);
        orderBook.setTop(registeredBook, true, 17, quantity);
        _execute(registeredRewarder, registeredBook, TOKEN1, quantity, 17);
        orderBook.setTop(unregisteredBook, true, 19, quantity);
        _execute(unregisteredRewarder, unregisteredBook, TOKEN1, quantity, 19);

        uint256 registeredPending = registeredRewarder.balances(registeredBook, TOKEN1, registeredNonce);
        uint256 unregisteredPending = unregisteredRewarder.balances(unregisteredBook, TOKEN1, unregisteredNonce);
        assertGt(registeredPending, 0);
        assertGt(unregisteredPending, 0);

        orderBook.setOwner(registeredBook, registeredOrder, address(0));
        orderBook.setOwner(unregisteredBook, unregisteredOrder, address(0));

        registeredRewarder.distributeRewards(registeredBook, registeredOrder, TOKEN1);
        assertEq(rewardToken.balanceOf(ALICE), registeredPending);
        assertEq(registeredRewarder.balances(registeredBook, TOKEN1, registeredNonce), 0);

        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        unregisteredRewarder.registerClaimant(unregisteredBook, unregisteredOrder);
        vm.expectRevert(DeepstateRewarder.NoOrderOwner.selector);
        unregisteredRewarder.distributeRewards(unregisteredBook, unregisteredOrder, TOKEN1);
        assertEq(unregisteredRewarder.balances(unregisteredBook, TOKEN1, unregisteredNonce), unregisteredPending);
    }

    function testFuzz_RetirementBurnsFundingAndPermanentlyForfeitsUnpaidClaims(
        uint32 elapsedSeed,
        uint160 quantitySeed,
        uint128 directRefundSeed
    ) public {
        uint256 elapsed = bound(elapsedSeed, 1, 30 days);
        uint160 quantity = uint160(bound(quantitySeed, START_QUANTITY, MAX_QUANTITY));
        uint256 directRefund = bound(directRefundSeed, 1, type(uint128).max);
        uint32 nonce = 23;
        bytes32 order = bytes32(uint256(nonce));

        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);
        _activateCurrentOrder(order, nonce, quantity, ALICE);
        assertEq(rewarder.registerClaimant(BOOK_ID, order), ALICE);

        vm.warp(block.timestamp + elapsed);
        orderBook.setTop(BOOK_ID, true, 29, quantity);
        _execute(rewarder, BOOK_ID, TOKEN1, quantity, 29);
        uint256 pending = rewarder.balances(BOOK_ID, TOKEN1, nonce);
        assertGt(pending, 0);

        uint256 supplyBefore = rewardToken.totalSupply();
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));
        rewarder.retireAndBurnBalance();
        assertTrue(rewarder.retired());
        assertEq(rewarder.owner(), address(0));
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), supplyBefore - fundingBefore);
        assertEq(rewarder.balances(BOOK_ID, TOKEN1, nonce), pending);

        rewardToken.mint(address(rewarder), directRefund);
        vm.expectRevert(DeepstateRewarderV2.RewarderRetired.selector);
        rewarder.distributeRewards(BOOK_ID, order, TOKEN1);
        assertEq(rewardToken.balanceOf(ALICE), 0);
        assertEq(rewarder.balances(BOOK_ID, TOKEN1, nonce), pending);
        assertEq(rewardToken.balanceOf(address(rewarder)), directRefund);

        vm.prank(address(0xB0B));
        rewarder.burnRetiredBalance();
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewarder.balances(BOOK_ID, TOKEN1, nonce), pending);
    }

    function testFuzz_PublicSideSchedulesStayMonotonicBoundedAndQuantityAdjusted(
        uint32 firstSeed,
        uint32 secondSeed,
        uint160 lowerAmountSeed,
        uint160 upperAmountSeed
    ) public view {
        uint256 first = bound(firstSeed, 0, DURATION + 30 days);
        uint256 second = bound(secondSeed, 0, DURATION + 30 days);
        if (first > second) (first, second) = (second, first);
        uint160 lowerAmount = lowerAmountSeed;
        uint160 upperAmount = upperAmountSeed;
        if (lowerAmount > upperAmount) (lowerAmount, upperAmount) = (upperAmount, lowerAmount);

        uint256 cumulativeFirst = rewarder.cumulativeEmissionsAtElapsed(first);
        uint256 cumulativeSecond = rewarder.cumulativeEmissionsAtElapsed(second);
        assertLe(cumulativeFirst, cumulativeSecond);
        assertLe(cumulativeSecond, SIDE_CAP);

        uint256 lowerReward = rewarder.previewRewardAtElapsed(TOKEN0, first, second, lowerAmount);
        uint256 upperReward = rewarder.previewRewardAtElapsed(TOKEN0, first, second, upperAmount);
        assertLe(lowerReward, upperReward);
        assertLe(upperReward, cumulativeSecond - cumulativeFirst);
    }

    function test_ColdHeavyAccrualExecuteSucceedsWithExactlyTheRouterGasStipend() public {
        uint32 outgoingNonce = 31;
        bytes32 outgoingOrder = bytes32(uint256(outgoingNonce));
        orderBook.setOwner(BOOK_ID, outgoingOrder, ALICE);
        orderBook.setTop(BOOK_ID, false, outgoingNonce, START_QUANTITY);
        _execute(rewarder, BOOK_ID, TOKEN0, 0, outgoingNonce);

        vm.warp(block.timestamp + 15 days);
        orderBook.setTop(BOOK_ID, false, 37, START_QUANTITY);
        vm.cool(address(rewarder));
        (bool success, bytes memory result) =
            orderBook.tryExecuteWithGas(rewarder, poolId, BOOK_ID, TOKEN0, START_QUANTITY, 37, 200_000);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }

        assertGt(rewarder.totalAccrued(TOKEN0), 0);
        assertEq(rewarder.balances(BOOK_ID, TOKEN0, outgoingNonce), rewarder.totalAccrued(TOKEN0));
        (uint32 currentNonce, uint64 currentStartedAt) = rewarder.rewardees(TOKEN0);
        assertEq(currentNonce, 37);
        assertEq(currentStartedAt, block.timestamp);
    }

    function testFuzz_RouterSwallowsRevertingHookFailureAndPreservesTheFill(uint128 quantitySeed) public {
        _assertRouterSurvivesHook(address(new OperationalRevertingHook()), quantitySeed);
    }

    function testFuzz_RouterBoundsAndSwallowsOutOfGasHookFailureAndPreservesTheFill(uint128 quantitySeed) public {
        _assertRouterSurvivesHook(address(new OperationalGasBurningHook()), quantitySeed);
    }

    function testFuzz_RouterSwallowsRetiredRewarderFailureAndLeavesItsAccountingUnchanged(uint128 quantitySeed) public {
        DeepstateV1 router = new DeepstateV1();
        OperationalRouterToken a = new OperationalRouterToken("A", "A");
        OperationalRouterToken b = new OperationalRouterToken("B", "B");
        (OperationalRouterToken token0, OperationalRouterToken token1) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 quantity = uint160(bound(quantitySeed, 1, type(uint128).max));
        bytes32 configuredPool = router.poolId(address(token0), address(token1));

        DeepstateRewarderV2 retiredRewarder = new DeepstateRewarderV2(
            address(this),
            address(router),
            address(rewardToken),
            configuredPool,
            address(token0),
            address(token1),
            SIDE_CAP,
            DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );
        retiredRewarder.retireAndBurnBalance();
        router.setPoolHookConfig(address(token0), address(token1), address(retiredRewarder), true, true);

        _executeGenuineMatch(router, token0, token1, quantity);

        assertTrue(retiredRewarder.retired());
        assertEq(retiredRewarder.emissionStart(address(token0)), 0);
        assertEq(retiredRewarder.totalAccrued(address(token0)), 0);
        (uint32 token0Nonce, uint64 token0Since) = retiredRewarder.rewardees(address(token0));
        assertEq(token0Nonce, 0);
        assertEq(token0Since, 0);

        assertEq(retiredRewarder.emissionStart(address(token1)), 0);
        assertEq(retiredRewarder.totalAccrued(address(token1)), 0);
        (uint32 token1Nonce, uint64 token1Since) = retiredRewarder.rewardees(address(token1));
        assertEq(token1Nonce, 0);
        assertEq(token1Since, 0);
    }

    function _assertRouterSurvivesHook(address hook, uint128 quantitySeed) internal {
        DeepstateV1 router = new DeepstateV1();
        OperationalRouterToken a = new OperationalRouterToken("A", "A");
        OperationalRouterToken b = new OperationalRouterToken("B", "B");
        (OperationalRouterToken token0, OperationalRouterToken token1) = address(a) < address(b) ? (a, b) : (b, a);
        uint160 quantity = uint160(bound(quantitySeed, 1, type(uint128).max));

        router.setPoolHookConfig(address(token0), address(token1), hook, true, true);
        _executeGenuineMatch(router, token0, token1, quantity);
    }

    function _executeGenuineMatch(
        DeepstateV1 router,
        OperationalRouterToken token0,
        OperationalRouterToken token1,
        uint160 quantity
    ) internal {
        uint256 initialBalance = uint256(quantity) * 2;
        token0.mint(ALICE, initialBalance);
        token1.mint(ALICE, initialBalance);
        token0.mint(BOB, initialBalance);
        token1.mint(BOB, initialBalance);

        vm.startPrank(ALICE);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        bytes32 makerAsk = router.fill(
            DeepstateV1.FillParams({
                token0: address(token0),
                token1: address(token1),
                epoch: 0,
                order: _order(0, quantity, 0),
                isBid: false,
                noRest: false,
                fillOrKill: false
            })
        );
        vm.stopPrank();

        bytes32 book = router.bookId(address(token0), address(token1), 0);
        assertEq(router.ownerOfOrder(router.orderId(book, makerAsk)), ALICE);
        (uint32 askNonce, uint160 liveAskQuantity) = router.topOrder(book, false);
        assertEq(askNonce, uint32(uint256(makerAsk)));
        assertEq(liveAskQuantity, quantity);

        uint256 bobToken0Before = token0.balanceOf(BOB);
        uint256 bobToken1Before = token1.balanceOf(BOB);
        vm.startPrank(BOB);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        bytes32 takerResting = router.fill(
            DeepstateV1.FillParams({
                token0: address(token0),
                token1: address(token1),
                epoch: 0,
                order: _order(0, quantity, 0),
                isBid: true,
                noRest: true,
                fillOrKill: true
            })
        );
        vm.stopPrank();

        assertEq(takerResting, bytes32(0));
        assertEq(token0.balanceOf(BOB), bobToken0Before + quantity);
        assertEq(token1.balanceOf(BOB), bobToken1Before - quantity);
        (askNonce, liveAskQuantity) = router.topOrder(book, false);
        assertEq(askNonce, 0);
        assertEq(liveAskQuantity, 0);

        uint256 aliceToken1BeforeClaim = token1.balanceOf(ALICE);
        vm.prank(ALICE);
        router.cancel(address(token0), address(token1), 0, makerAsk);
        assertEq(token1.balanceOf(ALICE), aliceToken1BeforeClaim + quantity);
        assertEq(token0.balanceOf(address(router)), 0);
        assertEq(token1.balanceOf(address(router)), 0);
    }

    function _newRewarder() internal returns (DeepstateRewarderV2 deployed) {
        deployed = new DeepstateRewarderV2(
            address(this),
            address(orderBook),
            address(rewardToken),
            poolId,
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            DURATION,
            START_QUANTITY,
            MAX_QUANTITY,
            START_QUANTITY,
            MAX_QUANTITY
        );
    }

    function _activateCurrentOrder(bytes32 order, uint32 nonce, uint160 quantity, address owner) internal {
        orderBook.setOwner(BOOK_ID, order, owner);
        orderBook.setTop(BOOK_ID, true, nonce, quantity);
        _execute(rewarder, BOOK_ID, TOKEN1, 0, nonce);
    }

    function _execute(
        DeepstateRewarderV2 rewarder_,
        bytes32 book,
        address token,
        uint160 outgoingAmount,
        uint32 incomingNonce
    ) internal {
        (bool success, bytes memory result,) =
            orderBook.tryExecute(rewarder_, poolId, book, token, outgoingAmount, incomingNonce);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function _order(int32 price, uint160 quantity, uint32 nonce) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32((uint256(uint32(price)) << 224) | (uint256(quantity) << 64) | uint256(nonce));
    }
}
