// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_policySupplyAndMetadata() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Swarmlers");
        assertEq(token.symbol(), "SWARMLER");
    }

    function testFuzz_exactTransfer(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndUnauthorizedTransfers() public {
        token.approve(alice, 20 ether);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 8 ether);
        assertEq(token.balanceOf(bob), 8 ether);
        assertEq(token.allowance(address(this), alice), 12 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, alice, 12 ether, 13 ether
            )
        );
        vm.prank(alice);
        token.transferFrom(address(this), bob, 13 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_noAdminMintEvenFromFactory() public {
        string[8] memory selectors = [
            "mint(address,uint256)",
            "issue(uint256)",
            "initialize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }
}
