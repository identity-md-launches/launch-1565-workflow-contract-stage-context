// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIMD} from "./helpers/Fixture.sol";
import {Swarmlers} from "../src/Swarmlers.sol";
import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Random interleavings of funding, time, minting, claiming and transferring to the creator.
contract RewardHandler is Test, IERC721Receiver {
    Swarmlers public immutable nft;
    MockIMD public immutable imd;
    uint256 public successfulMints;
    uint256 public successfulClaims;
    uint256 public deposits;
    uint256 public transferred;
    uint256 public highestEarned;

    constructor(Swarmlers n, MockIMD t) {
        nft = n;
        imd = t;
        t.mint(address(this), 1_000_000 ether);
        t.approve(address(n), 1_000_000 ether);
    }

    function mint() external {
        if (nft.totalMinted() < 100) {
            nft.mint();
            ++successfulMints;
        }
    }

    function fund(uint128 raw) external {
        uint256 amount = bound(raw, 1, 500 ether);
        nft.depositProceeds(amount);
        deposits += amount;
    }

    function advance(uint32 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 50 days));
        nft.checkpoint();
        uint256 current = nft.earned(1);
        require(current >= highestEarned, "earned decreased");
        highestEarned = current;
    }

    function claim(uint256 raw) external {
        uint256 id = bound(raw, 1, nft.totalMinted());
        address holder = nft.ownerOf(id);
        if (nft.claimable(id) != 0) {
            vm.prank(holder);
            nft.claimReward(id);
            ++successfulClaims;
        }
    }

    function move(uint256 raw) external {
        uint256 id = bound(raw, 1, nft.totalMinted());
        address holder = nft.ownerOf(id);
        address next = holder == address(this) ? nft.creator() : address(this);
        vm.prank(holder);
        nft.transferFrom(holder, next, id);
        ++transferred;
    }

    function payCreator() external {
        if (nft.creatorCredit() != 0) nft.withdrawCreator();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract RewardInvariantTest is Fixture {
    RewardHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RewardHandler(nft, imd);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = RewardHandler.mint.selector;
        selectors[1] = RewardHandler.fund.selector;
        selectors[2] = RewardHandler.advance.selector;
        selectors[3] = RewardHandler.claim.selector;
        selectors[4] = RewardHandler.move.selector;
        selectors[5] = RewardHandler.payCreator.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fundsConservedAndLiabilitiesFullyBacked() public view {
        _assertSolvent();
    }

    function invariant_globalAccountingEqualsSumOfNFTEntitlements() public view {
        uint256 allocated;
        uint256 paid;
        for (uint256 id = 1; id <= nft.totalMinted(); ++id) {
            uint256 earned = nft.earned(id);
            assertLe(earned, 1 ether);
            assertLe(nft.claimed(id), earned);
            allocated += earned;
            paid += nft.claimed(id);
        }
        assertEq(allocated, nft.totalAllocated());
        assertEq(paid, nft.totalClaimed());
        assertLe(nft.totalAllocated(), nft.totalMinted() * 1 ether);
        assertEq(nft.remainingRewardCapacity(), 2500 ether - nft.totalAllocated() - nft.rewardReserve());
    }

    function invariant_supplyAndLifetimeCapNeverReset() public view {
        assertEq(nft.totalMinted(), 25 + handler.successfulMints());
        assertLe(nft.totalMinted(), 2500);
        assertLe(nft.firstActiveId(), nft.totalMinted() + 1);
        for (uint256 id = 1; id < nft.firstActiveId(); ++id) {
            assertEq(nft.earned(id), 1 ether);
        }
    }
}
