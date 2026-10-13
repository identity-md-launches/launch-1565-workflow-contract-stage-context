// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Swarmlers} from "../../src/Swarmlers.sol";
import {SwarmlerActivity} from "../../src/SwarmlerActivity.sol";
import {SwarmlerConstants} from "../../src/SwarmlerConstants.sol";

contract MockIMD is ERC20 {
    bool public failTransfers;
    bool public taxTransfers;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailure(bool fail) external {
        failTransfers = fail;
    }

    function setTax(bool tax) external {
        taxTransfers = tax;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            require(!failTransfers, "IMD transfer failed");
            if (callback != address(0)) {
                address target = callback;
                callback = address(0);
                (callbackSucceeded,) = target.call(callbackData);
            }
            if (taxTransfers && amount > 0) {
                super._update(from, address(0), 1);
                --amount;
            }
        }
        super._update(from, to, amount);
    }
}

contract MockIdentity is ERC721 {
    constructor() ERC721("Mock Identity", "ID") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

abstract contract Fixture is Test {
    MockIMD internal imd;
    MockIdentity internal identity;
    SwarmlerActivity internal activity;
    Swarmlers internal nft;
    address internal alice;
    address internal bob;
    address internal reporter;
    address internal constant CREATOR = SwarmlerConstants.CREATOR;

    function setUp() public virtual {
        vm.warp(1_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        reporter = makeAddr("trusted activity reporter");
        MockIMD implementation = new MockIMD();
        vm.etch(SwarmlerConstants.IMD, address(implementation).code);
        imd = MockIMD(SwarmlerConstants.IMD);
        MockIdentity identityImplementation = new MockIdentity();
        vm.etch(SwarmlerConstants.IDENTITY, address(identityImplementation).code);
        identity = MockIdentity(SwarmlerConstants.IDENTITY);
        activity = new SwarmlerActivity(address(this));
        nft = new Swarmlers(address(this), address(activity));
        activity.setReporter(reporter);
        nft.setRewardDuration(30 days);
        nft.openPublicMint();
        _fund(alice, 100_000 ether);
        _fund(bob, 100_000 ether);
        _fund(address(this), 100_000 ether);
    }

    function _fund(address account, uint256 amount) internal {
        imd.mint(account, amount);
        vm.prank(account);
        imd.approve(address(nft), amount);
    }

    function _activeIdentity(address holder, uint256 id) internal {
        identity.mint(holder, id);
        vm.prank(reporter);
        activity.recordActivity(id, holder, uint64(vm.getBlockTimestamp()), 1, true);
    }

    function _mint(address holder) internal returns (uint256 id) {
        vm.prank(holder);
        id = nft.mint();
    }

    function _assertSolvent() internal view {
        assertEq(imd.balanceOf(address(nft)), nft.accountedBalance(), "collateral must equal ledger");
        assertEq(
            nft.totalProceeds(), imd.balanceOf(address(nft)) + nft.totalClaimed() + nft.totalCreatorPaid()
        );
        assertLe(nft.totalClaimed(), nft.totalAllocated());
        assertLe(
            nft.totalAllocated() + nft.rewardReserve(),
            nft.MAX_SUPPLY() * nft.LIFETIME_CAP(),
            "reserve must never exceed lifetime capacity"
        );
    }
}
