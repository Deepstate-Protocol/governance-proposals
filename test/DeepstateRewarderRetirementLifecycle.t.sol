// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeepstateV1} from "deepstate-contracts/DeepstateV1.sol";

import {DeepstateMinterController} from "../src/DeepstateMinterController.sol";
import {DeepstateRewarderFactory} from "../src/DeepstateRewarderFactory.sol";
import {DeepstateRewarderV2} from "../src/DeepstateRewarderV2.sol";
import {DeepstateV1Controller} from "../src/DeepstateV1Controller.sol";
import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {MockSablierLockupLinearV4} from "./mocks/MockSablierLockupLinearV4.sol";
import {RewardDeepstateHarness, RewardTestERC20} from "./DeepstateRewarderLocal.t.sol";

contract LifecycleUSDG is RewardTestERC20 {
    constructor() RewardTestERC20("USDG", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeepstateRewarderRetirementLifecycleTest is Test {
    uint256 internal constant MINT_CAP = 20_000_000_000e18;

    RewardTestERC20 internal token0;
    RewardTestERC20 internal token1;
    RewardTestERC20 internal stock;
    LifecycleUSDG internal usdG;
    RewardDeepstateHarness internal deepstate;
    DeepstateToken internal deep;
    DeepstateV1Controller internal deepstateV1Controller;
    DeepstateMinterController internal minterController;
    DeepstateRewarderFactory internal factory;
    MockSablierLockupLinearV4 internal sablier;

    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal vestingRecipient = makeAddr("vestingRecipient");

    function setUp() public {
        vm.warp(1_000_000);

        stock = new RewardTestERC20("Stock", "STOCK");
        usdG = new LifecycleUSDG();
        (token0, token1) = address(stock) < address(usdG)
            ? (RewardTestERC20(address(stock)), RewardTestERC20(address(usdG)))
            : (RewardTestERC20(address(usdG)), RewardTestERC20(address(stock)));

        deepstate = new RewardDeepstateHarness();
        deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
        sablier = new MockSablierLockupLinearV4();
        deepstateV1Controller = new DeepstateV1Controller(address(this), address(deepstate));
        minterController = new DeepstateMinterController(
            address(this), address(deep), address(sablier), vestingRecipient, MINT_CAP, MINT_CAP
        );
        factory = new DeepstateRewarderFactory(
            address(this), address(deepstateV1Controller), address(minterController), address(usdG), 1_500_000_000e18
        );

        deep.grantRole(deep.MINTER_ROLE(), address(minterController));
        deep.grantRole(deep.DEFAULT_ADMIN_ROLE(), address(minterController));
        deep.renounceRole(deep.DEFAULT_ADMIN_ROLE(), address(this));
        minterController.lockTokenAdministration();
        minterController.grantRoles(address(factory), minterController.MINTER_ROLE());

        deepstate.transferOwnership(address(deepstateV1Controller));
        deepstateV1Controller.grantRoles(address(factory), deepstateV1Controller.HOOK_MANAGER_ROLE());
        factory.setOperator(operator);

        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function test_RetirementPermanentlyForfeitsRealAccruedClaimDespiteDirectRefunding() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market());

        bytes32 bookId = deepstate.bookId(address(token0), address(token1), 0);
        vm.prank(alice);
        bytes32 aliceBid = deepstate.fill(_fill(_order(0, 5e18, 0), true));

        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        deepstate.fill(_fill(_order(1, 7e18, 0), true));

        uint32 aliceNonce = uint32(uint256(aliceBid));
        uint256 pending = rewarder.balances(bookId, address(token1), aliceNonce);
        assertGt(pending, 0);
        assertEq(rewarder.registerClaimant(bookId, aliceBid), alice);

        vm.prank(operator);
        factory.removeMarket(address(stock), address(rewarder));

        assertTrue(rewarder.retired());
        assertEq(deep.balanceOf(address(rewarder)), 0);
        assertEq(rewarder.balances(bookId, address(token1), aliceNonce), pending);

        minterController.mint(address(rewarder), pending);

        vm.expectRevert(DeepstateRewarderV2.RewarderRetired.selector);
        rewarder.distributeRewards(bookId, aliceBid, address(token1));

        assertEq(deep.balanceOf(alice), 0);
        assertEq(deep.balanceOf(address(rewarder)), pending);
        assertEq(rewarder.balances(bookId, address(token1), aliceNonce), pending);

        vm.prank(alice);
        rewarder.burnRetiredBalance();
        assertEq(deep.balanceOf(address(rewarder)), 0);
    }

    function test_FactoryCanRetireMarketAfterGovernanceAlreadyClearedItsHook() public {
        vm.prank(operator);
        DeepstateRewarderV2 rewarder = factory.deployMarket(_market());
        bytes32 poolId = deepstate.poolId(address(token0), address(token1));

        deepstateV1Controller.setPoolHookConfig(address(token0), address(token1), address(0), false, false);
        assertEq(deepstate.poolHook(poolId), address(0));

        vm.prank(operator);
        factory.removeMarket(address(stock), address(rewarder));

        assertTrue(rewarder.retired());
        assertEq(rewarder.owner(), address(0));
        assertEq(factory.activeRewarder(poolId), address(0));
        assertEq(factory.retiredRewarderPool(address(rewarder)), poolId);
        assertEq(deep.balanceOf(address(rewarder)), 0);
    }

    function _market() internal view returns (DeepstateRewarderFactory.MarketConfig memory config) {
        config = DeepstateRewarderFactory.MarketConfig({
            stockToken: address(stock),
            stockStartQuantity: 1e18,
            stockMaxQuantity: 5_000e18,
            stockBuySideActive: true,
            usdGBuySideActive: true
        });
    }

    function _fill(bytes32 order, bool isBid) internal view returns (DeepstateV1.FillParams memory params) {
        params = DeepstateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: 0,
            order: order,
            isBid: isBid,
            noRest: false,
            fillOrKill: false
        });
    }

    function _fundAndApprove(address user) internal {
        token0.mint(user, 1_000_000_000e18);
        token1.mint(user, 1_000_000_000e18);

        vm.startPrank(user);
        token0.approve(address(deepstate), type(uint256).max);
        token1.approve(address(deepstate), type(uint256).max);
        vm.stopPrank();
    }

    function _order(int32 price, uint160 quantity, uint32 nonce) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes32((uint256(uint32(price)) << 224) | (uint256(quantity) << 64) | uint256(nonce));
    }
}
