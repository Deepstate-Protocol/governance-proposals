// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {IOrderBook} from "deepstate-protocol/interfaces/IOrderBook.sol";

contract BurnTestOrderBook is IOrderBook {
    mapping(bytes32 orderId_ => address owner) internal _owners;
    mapping(bytes32 bookId => mapping(bool isBid => uint32 nonce)) internal _nonces;
    mapping(bytes32 bookId => mapping(bool isBid => uint160 amount)) internal _amounts;

    function orderId(bytes32 id, bytes32 order) public pure returns (bytes32) {
        return keccak256(abi.encode(id, order));
    }

    function ownerOfOrder(bytes32 orderId_) external view returns (address) {
        return _owners[orderId_];
    }

    function topOrder(bytes32 bookId, bool isBid) external view returns (uint32 nonce, uint160 soldAmount) {
        return (_nonces[bookId][isBid], _amounts[bookId][isBid]);
    }

    function setOrder(bytes32 bookId, bytes32 order, bool isBid, uint32 nonce, uint160 amount, address owner) external {
        _owners[orderId(bookId, order)] = owner;
        _nonces[bookId][isBid] = nonce;
        _amounts[bookId][isBid] = amount;
    }
}

contract DeepstateRewarderV2Test is Test {
    uint96 internal constant SIDE_CAP = 50_000_000e18;
    address internal constant TOKEN0 = address(0x2000);
    address internal constant TOKEN1 = address(0x3000);

    BurnTestOrderBook internal orderBook;
    DeepstateToken internal rewardToken;
    DeepstateRewarderV2 internal rewarder;
    address internal alice = makeAddr("alice");

    function setUp() public {
        orderBook = new BurnTestOrderBook();
        rewardToken = new DeepstateToken(address(this), "Reward", "RWD");
        rewardToken.grantRole(rewardToken.MINTER_ROLE(), address(this));
        rewarder = new DeepstateRewarderV2(
            address(this),
            address(orderBook),
            address(rewardToken),
            keccak256(abi.encode(TOKEN0, TOKEN1)),
            TOKEN0,
            TOKEN1,
            SIDE_CAP,
            365 days,
            1e18,
            5_000e18,
            1e6,
            1_000_000e6
        );
        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);
    }

    function test_InheritsRewarderConfiguration() public view {
        assertEq(rewarder.owner(), address(this));
        assertEq(rewarder.deepstate(), address(orderBook));
        assertEq(rewarder.rewardToken(), address(rewardToken));
        assertEq(rewarder.token0(), TOKEN0);
        assertEq(rewarder.token1(), TOKEN1);
        assertEq(rewarder.sideEmissionCap(), SIDE_CAP);
        assertEq(rewarder.emissionDuration(), 365 days);
        assertEq(rewardToken.balanceOf(address(rewarder)), 100_000_000e18);
    }

    function test_OwnerCanBurnEntireBalance() public {
        uint256 funding = rewardToken.balanceOf(address(rewarder));
        uint256 supplyBefore = rewardToken.totalSupply();

        rewarder.burnBalance();

        assertEq(rewarder.owner(), address(this));
        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), supplyBefore - funding);
    }

    function test_NonOwnerCannotBurnBalance() public {
        uint256 fundingBefore = rewardToken.balanceOf(address(rewarder));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(alice);
        rewarder.burnBalance();

        assertEq(rewardToken.balanceOf(address(rewarder)), fundingBefore);
        assertEq(rewardToken.totalSupply(), fundingBefore);
    }

    function test_BurnCanBeRepeatedAndAnEmptyBurnIsANoOp() public {
        rewarder.burnBalance();
        rewarder.burnBalance();

        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);

        rewardToken.mint(address(rewarder), 7e18);
        rewarder.burnBalance();

        assertEq(rewardToken.balanceOf(address(rewarder)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }

    function test_BurnDoesNotDisableUnlinkedRewarderAccountingOrClaims() public {
        bytes32 bookId = keccak256("unlinked-book");
        uint32 nonce = 7;
        bytes32 order = bytes32(uint256(nonce));
        uint160 quantity = 1_000_000e6;

        rewarder.burnBalance();
        rewardToken.mint(address(rewarder), uint256(SIDE_CAP) * 2);

        orderBook.setOrder(bookId, order, true, nonce, quantity, alice);
        vm.warp(1_000_000);
        bytes32 configuredPoolId = rewarder.poolId();
        vm.prank(address(orderBook));
        rewarder.execute(configuredPoolId, bookId, TOKEN1, 0, nonce);

        assertEq(rewarder.registerClaimant(bookId, order), alice);
        vm.warp(block.timestamp + 1 days);
        rewarder.distributeRewards(bookId, order, TOKEN1);

        assertGt(rewarder.totalAccrued(TOKEN1), 0);
        assertGt(rewardToken.balanceOf(alice), 0);
    }
}
