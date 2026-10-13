// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(LaunchToken t, address[4] memory accounts) {
        token = t;
        actors = accounts;
        balances[accounts[0]] = 1e27;
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(raw, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balances[from] -= amount;
        balances[to] += amount;
    }

    function approve(uint256 fromSeed, uint256 spenderSeed, uint256 raw, bool unlimited) external {
        address from = actors[fromSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 amount = unlimited ? type(uint256).max : bound(raw, 0, 1e27);
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        allowances[from][spender] = amount;
    }

    function delegatedMove(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 raw) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 allowed = allowances[from][spender];
        uint256 maximum = balances[from] < allowed ? balances[from] : allowed;
        uint256 amount = bound(raw, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        balances[from] -= amount;
        balances[to] += amount;
        if (allowed != type(uint256).max) allowances[from][spender] -= amount;
    }

    function rejectedOverspend(uint256 fromSeed, uint256 toSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 balance = balances[from];
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + 1)
        );
        vm.prank(from);
        token.transfer(to, balance + 1);
    }

    function rejectedAllowance(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 allowed = allowances[from][spender];
        if (allowed == type(uint256).max) return;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1
            )
        );
        vm.prank(spender);
        token.transferFrom(from, to, allowed + 1);
    }
}

/// @dev The independent balance/allowance model includes zero and self transfers,
/// full-supply movement, revocation, finite allowances, and unlimited allowances.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenStatefulTest is Test {
    LaunchToken internal token;
    LaunchTokenHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        address[4] memory actors =
            [makeAddr("token A"), makeAddr("token B"), makeAddr("token C"), makeAddr("token D")];
        handler = new LaunchTokenHandler(token, actors);
        token.transfer(actors[0], 1e27);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.move.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.delegatedMove.selector;
        selectors[3] = handler.rejectedOverspend.selector;
        selectors[4] = handler.rejectedAllowance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyBalancesAndAllowancesMatchIndependentModel() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.balances(actor));
            sum += token.balanceOf(actor);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.allowances(actor, spender));
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_fullSupplyAndUnlimitedAllowanceRemainConserved() public {
        handler.move(0, 0, 1e27);
        handler.move(0, 1, 1e27);
        handler.approve(1, 2, 0, true);
        handler.delegatedMove(1, 3, 2, 1e27);
        handler.approve(1, 2, 0, false);
        handler.rejectedAllowance(1, 0, 2);
        handler.rejectedOverspend(3, 0);
        handler.move(3, 0, 0);
        invariant_supplyBalancesAndAllowancesMatchIndependentModel();
    }
}
