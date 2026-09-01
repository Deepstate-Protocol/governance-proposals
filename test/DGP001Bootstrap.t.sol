// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeepstateToken} from "deepstate-protocol/DeepstateToken.sol";
import {DGP001Bootstrap} from "../src/DGP001Bootstrap.sol";
import {IDeepstateLegacyRewarder} from "../src/interfaces/IDeepstateLegacyRewarder.sol";

contract MockDGP001FrozenRewarder is IDeepstateLegacyRewarder {
    address public immutable override token0;
    address public immutable override token1;

    mapping(address token => uint96 accrued) private _totalAccrued;

    constructor(address token0_, address token1_, uint96 token0Accrued_, uint96 token1Accrued_) {
        token0 = token0_;
        token1 = token1_;
        _totalAccrued[token0_] = token0Accrued_;
        _totalAccrued[token1_] = token1Accrued_;
    }

    function deepstate() external pure returns (address) {
        return address(0);
    }

    function rewardToken() external pure returns (address) {
        return address(0);
    }

    function poolId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function rewardees(address) external pure returns (uint32 orderNonce, uint64 startedAt) {
        return (0, 0);
    }

    function totalAccrued(address token) external view returns (uint96 accrued) {
        return _totalAccrued[token];
    }

    function setTotalAccrued(address token, uint96 accrued) external {
        _totalAccrued[token] = accrued;
    }
}

    contract DGP001BootstrapTest is Test {
        uint96 internal constant TOKEN0_ACCRUED = 700_000_000e18;
        uint96 internal constant TOKEN1_ACCRUED = 300_000_000e18;
        uint128 internal constant ENDOWMENT = 300_000_000e18;

        address internal constant TOKEN0 = address(0x1000);
        address internal constant TOKEN1 = address(0x2000);
        address internal constant UNAUTHORIZED = address(0xBAD);

        DeepstateToken internal deep;
        MockDGP001FrozenRewarder internal legacyRewarder;
        DGP001Bootstrap internal bootstrap;

        function setUp() public {
            deep = new DeepstateToken(address(this), "Deepstate", "DEEP");
            legacyRewarder = new MockDGP001FrozenRewarder(TOKEN0, TOKEN1, TOKEN0_ACCRUED, TOKEN1_ACCRUED);
            bootstrap = new DGP001Bootstrap(address(this), address(deep), address(legacyRewarder));
        }

        function testConstructorFreezesThirtyPercentOfCombinedAccrual() public view {
            assertEq(bootstrap.governor(), address(this));
            assertEq(address(bootstrap.deepstateToken()), address(deep));
            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);
        }

        function testFrozenAmountDoesNotChangeRuntimeCodeHash() public {
            MockDGP001FrozenRewarder differentAccrual = new MockDGP001FrozenRewarder(TOKEN0, TOKEN1, 10e18, 20e18);
            DGP001Bootstrap differentBootstrap =
                new DGP001Bootstrap(address(this), address(deep), address(differentAccrual));

            assertNotEq(differentBootstrap.endowmentAmount(), bootstrap.endowmentAmount());
            assertEq(address(differentBootstrap).codehash, address(bootstrap).codehash);
        }

        function testFuzzConstructorRoundsDownThirtyPercent(uint96 token0Accrued, uint96 token1Accrued) public {
            MockDGP001FrozenRewarder rewarder = new MockDGP001FrozenRewarder(
                TOKEN0, TOKEN1, token0Accrued, token1Accrued
            );
            DGP001Bootstrap frozen = new DGP001Bootstrap(address(this), address(deep), address(rewarder));

            uint256 expected = (uint256(token0Accrued) + uint256(token1Accrued)) * 30 / 100;
            assertEq(frozen.endowmentAmount(), expected);
        }

        function testLaterLegacyAccrualChangesCannotChangeFrozenAmount() public {
            legacyRewarder.setTotalAccrued(TOKEN0, type(uint96).max);
            legacyRewarder.setTotalAccrued(TOKEN1, type(uint96).max);

            assertEq(bootstrap.endowmentAmount(), ENDOWMENT);

            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));
            bootstrap.mint();

            assertEq(deep.balanceOf(address(this)), ENDOWMENT);
            assertEq(deep.totalSupply(), ENDOWMENT);
        }

        function testMintMintsExactFrozenAmountDirectlyToGovernor() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            bootstrap.mint();

            assertEq(deep.balanceOf(address(this)), ENDOWMENT);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.totalSupply(), ENDOWMENT);
            assertTrue(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testMintRequiresGovernor() public {
            deep.grantRole(deep.MINTER_ROLE(), address(bootstrap));

            vm.prank(UNAUTHORIZED);
            vm.expectRevert(abi.encodeWithSelector(DGP001Bootstrap.Unauthorized.selector, UNAUTHORIZED));
            bootstrap.mint();

            assertEq(deep.balanceOf(address(this)), 0);
            assertEq(deep.totalSupply(), 0);
        }

        function testMintWithoutTokenRoleFailsNaturallyAndLeavesStateUnchanged() public {
            uint128 frozenAmount = bootstrap.endowmentAmount();

            vm.expectRevert();
            bootstrap.mint();

            assertEq(bootstrap.endowmentAmount(), frozenAmount);
            assertEq(deep.balanceOf(address(this)), 0);
            assertEq(deep.balanceOf(address(bootstrap)), 0);
            assertEq(deep.totalSupply(), 0);
            assertFalse(deep.hasRole(deep.MINTER_ROLE(), address(bootstrap)));
        }

        function testRepeatMintingIsPossibleOnlyWhileTemporaryRoleRemains() public {
            bytes32 minterRole = deep.MINTER_ROLE();
            deep.grantRole(minterRole, address(bootstrap));

            bootstrap.mint();
            bootstrap.mint();
            assertEq(deep.balanceOf(address(this)), uint256(ENDOWMENT) * 2);

            // The production Governor payload performs this immediately after its single mint action.
            deep.revokeRole(minterRole, address(bootstrap));
            uint256 supplyAfterRevocation = deep.totalSupply();

            vm.expectRevert();
            bootstrap.mint();

            assertEq(deep.totalSupply(), supplyAfterRevocation);
            assertEq(deep.balanceOf(address(this)), uint256(ENDOWMENT) * 2);
            assertFalse(deep.hasRole(minterRole, address(bootstrap)));
        }
    }
