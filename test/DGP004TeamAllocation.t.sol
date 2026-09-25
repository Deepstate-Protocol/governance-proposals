// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DGP004TeamAllocation} from "../src/DGP004TeamAllocation.sol";

contract MockDGP004Token is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("Deepstate 2", "2DEEP") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mint(address to, uint256 amount) external virtual onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}

contract ShortMintDGP004Token is MockDGP004Token {
    constructor(address admin) MockDGP004Token(admin) {}

    function mint(address to, uint256 amount) external override onlyRole(MINTER_ROLE) {
        _mint(to, amount - 1);
    }
}

contract DGP004TeamAllocationTest is Test {
    address internal governor = makeAddr("legacyGovernor");
    address internal outsider = makeAddr("outsider");

    DGP004TeamAllocation internal allocation;
    MockDGP004Token internal token;

    function setUp() public {
        token = new MockDGP004Token(address(this));
        allocation = new DGP004TeamAllocation(governor, address(token));
    }

    function testExactAllocationConstantsSumToTenMillion() public view {
        assertEq(allocation.RECIPIENT_A_AMOUNT(), 3_333_333_333333333333333334);
        assertEq(allocation.RECIPIENT_B_AMOUNT(), 3_333_333_333333333333333333);
        assertEq(allocation.RECIPIENT_C_AMOUNT(), 3_333_333_333333333333333333);
        assertEq(
            allocation.RECIPIENT_A_AMOUNT() + allocation.RECIPIENT_B_AMOUNT() + allocation.RECIPIENT_C_AMOUNT(),
            allocation.TOTAL_ALLOCATION()
        );
        assertEq(allocation.TOTAL_ALLOCATION(), 10_000_000e18);
    }

    function testTokenTargetIsImmutable() public view {
        assertEq(allocation.token(), address(token));
    }

    function testOnlyGovernorCanExecute() public {
        vm.prank(outsider);
        vm.expectRevert(DGP004TeamAllocation.OnlyGovernor.selector);
        allocation.execute();
    }

    function testMissingMinterRoleRevertsAtomically() public {
        vm.prank(governor);
        vm.expectRevert();
        allocation.execute();

        assertFalse(allocation.executed());
        assertEq(token.totalSupply(), 0);
    }

    function testMintsDistributesAndRenouncesMinterRoleExactlyOnce() public {
        uint256 existingBalance = 17e18;
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(address(allocation), existingBalance);
        token.grantRole(token.MINTER_ROLE(), address(allocation));

        vm.prank(governor);
        allocation.execute();

        assertTrue(allocation.executed());
        assertEq(token.balanceOf(allocation.RECIPIENT_A()), allocation.RECIPIENT_A_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_B()), allocation.RECIPIENT_B_AMOUNT());
        assertEq(token.balanceOf(allocation.RECIPIENT_C()), allocation.RECIPIENT_C_AMOUNT());
        assertEq(token.balanceOf(address(allocation)), existingBalance);
        assertEq(token.totalSupply(), existingBalance + allocation.TOTAL_ALLOCATION());
        assertFalse(token.hasRole(token.MINTER_ROLE(), address(allocation)));

        vm.prank(governor);
        vm.expectRevert(DGP004TeamAllocation.AlreadyExecuted.selector);
        allocation.execute();
    }

    function testInsufficientMintRevertsEveryStateChange() public {
        ShortMintDGP004Token shortMintToken = new ShortMintDGP004Token(address(this));
        DGP004TeamAllocation shortMintAllocation = new DGP004TeamAllocation(governor, address(shortMintToken));
        shortMintToken.grantRole(shortMintToken.MINTER_ROLE(), address(shortMintAllocation));

        vm.prank(governor);
        vm.expectRevert();
        shortMintAllocation.execute();

        assertFalse(shortMintAllocation.executed());
        assertEq(shortMintToken.totalSupply(), 0);
        assertTrue(shortMintToken.hasRole(shortMintToken.MINTER_ROLE(), address(shortMintAllocation)));
    }
}
