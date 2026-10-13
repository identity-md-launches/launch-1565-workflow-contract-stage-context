// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {Swarmlers} from "../src/Swarmlers.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract RewardsTest is Fixture {
    function test_unfundedTimeEarnsNothingAndRefillIsNotRetroactive() public {
        skip(100 days);
        assertEq(nft.earned(1), 0);
        nft.depositProceeds(10 ether);
        assertEq(nft.earned(1), 0);
        skip(30 days);
        uint256 earned = uint256(9 ether) / 25;
        assertEq(nft.earned(1), earned);
        nft.checkpoint();
        assertEq(nft.rewardReserve(), 0);
        skip(100 days);
        assertEq(nft.earned(1), earned);
        nft.depositProceeds(10 ether);
        assertEq(nft.earned(1), earned);
        skip(1 days);
        assertEq(nft.earned(1), earned + nft.rewardRate() * 1 days);
        _assertSolvent();
    }

    function testFuzz_holdingTimeProportionalityAndLifetimeCap(uint32 timeBefore, uint32 timeAfter) public {
        timeBefore = uint32(bound(timeBefore, 1, 80 days));
        timeAfter = uint32(bound(timeAfter, 1, 80 days));
        uint256 idA = _mint(alice);
        nft.depositProceeds(3000 ether);
        skip(timeBefore);
        uint256 idB = _mint(bob);
        skip(timeAfter);
        uint256 expectedA = uint256(timeBefore + timeAfter) * nft.rewardRate();
        uint256 expectedB = uint256(timeAfter) * nft.rewardRate();
        expectedA = expectedA > 1 ether ? 1 ether : expectedA;
        expectedB = expectedB > 1 ether ? 1 ether : expectedB;
        assertEq(nft.earned(idA), expectedA);
        assertEq(nft.earned(idB), expectedB);
        vm.prank(alice);
        nft.claimReward(idA);
        vm.prank(bob);
        nft.claimReward(idB);
        assertEq(nft.claimed(idA), expectedA);
        assertEq(nft.claimed(idB), expectedB);
        _assertSolvent();
    }

    function test_rewardsFollowNFTAndOperatorsCannotClaim() public {
        uint256 id = _mint(alice);
        nft.depositProceeds(100 ether);
        skip(5 days);
        uint256 accrued = nft.earned(id);
        vm.prank(alice);
        nft.approve(bob, id);
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(bob);
        nft.claimReward(id);
        vm.prank(bob);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.earned(id), accrued);
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(alice);
        nft.claimReward(id);
        uint256 beforeBalance = imd.balanceOf(bob);
        vm.prank(bob);
        nft.claimReward(id);
        assertEq(imd.balanceOf(bob) - beforeBalance, accrued);
        skip(100 days);
        vm.prank(bob);
        nft.claimReward(id);
        assertEq(nft.claimed(id), 1 ether);
        vm.prank(bob);
        nft.transferFrom(bob, alice, id);
        skip(100 days);
        assertEq(nft.claimable(id), 0);
        vm.expectRevert(Swarmlers.NoRewards.selector);
        vm.prank(alice);
        nft.claimReward(id);
        _assertSolvent();
    }

    function test_cappedNFTsStopConsumingFundingWithoutClaiming() public {
        nft.depositProceeds(100 ether);
        skip(31 days);
        nft.checkpoint();
        assertEq(nft.firstActiveId(), 26);
        assertEq(nft.totalAllocated(), 25 ether);
        uint256 reserve = nft.rewardReserve();
        skip(500 days);
        nft.checkpoint();
        assertEq(nft.rewardReserve(), reserve);
        uint256 id = _mint(alice);
        assertEq(nft.earned(id), 0);
        skip(31 days);
        assertEq(nft.earned(id), 1 ether);
        nft.checkpoint();
        assertEq(nft.totalAllocated(), 26 ether);
        assertEq(nft.firstActiveId(), 27);
        assertEq(nft.earned(1), 1 ether);
        _assertSolvent();
    }

    function test_all2500CapInOneBoundedCheckpoint() public {
        vm.startPrank(alice);
        for (uint256 i = 26; i <= 2500; ++i) {
            nft.mint();
        }
        vm.stopPrank();
        nft.depositProceeds(3000 ether);
        skip(31 days);
        uint256 startGas = gasleft();
        nft.checkpoint();
        assertLt(startGas - gasleft(), 12_000_000);
        assertEq(nft.firstActiveId(), 2501);
        assertEq(nft.totalAllocated(), 2500 ether);
        assertEq(nft.earned(2500), 1 ether);
        _assertSolvent();
    }

    function test_batchClaimsRejectDuplicatesAndForeignNFTAtomically() public {
        uint256 first = _mint(alice);
        uint256 second = _mint(alice);
        nft.depositProceeds(100 ether);
        skip(10 days);
        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = first;
        vm.expectRevert(Swarmlers.NoRewards.selector);
        vm.prank(alice);
        nft.claimRewards(ids);
        assertEq(nft.claimed(first), 0);
        ids[1] = 1;
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(alice);
        nft.claimRewards(ids);
        assertEq(nft.claimed(first), 0);
        ids[1] = second;
        uint256 expected = nft.earned(first) + nft.earned(second);
        vm.prank(alice);
        assertEq(nft.claimRewards(ids), expected);
        assertEq(nft.totalClaimed(), expected);
        vm.expectRevert(Swarmlers.InvalidBatch.selector);
        nft.claimRewards(new uint256[](0));
        vm.expectRevert(Swarmlers.InvalidBatch.selector);
        nft.claimRewards(new uint256[](101));
        _assertSolvent();
    }

    function test_failedPayoutAndReentrancyDoNotConsumeClaim() public {
        uint256 id = _mint(alice);
        nft.depositProceeds(100 ether);
        skip(1 days);
        uint256 amount = nft.claimable(id);
        imd.setFailure(true);
        vm.expectRevert("IMD transfer failed");
        vm.prank(alice);
        nft.claimReward(id);
        assertEq(nft.claimed(id), 0);
        assertEq(nft.totalClaimed(), 0);
        assertEq(nft.claimable(id), amount);
        imd.setFailure(false);
        imd.setCallback(address(nft), abi.encodeCall(Swarmlers.claimReward, (id)));
        vm.prank(alice);
        nft.claimReward(id);
        assertFalse(imd.callbackSucceeded());
        assertEq(nft.claimed(id), amount);
        _assertSolvent();
    }

    function test_depositReentrancyAndCreatorFailureRollback() public {
        imd.setCallback(address(nft), abi.encodeCall(Swarmlers.syncProceeds, ()));
        nft.depositProceeds(100 ether);
        assertFalse(imd.callbackSucceeded());
        assertEq(nft.totalProceeds(), 100 ether);
        assertEq(nft.rewardReserve(), 90 ether);
        imd.setFailure(true);
        vm.expectRevert("IMD transfer failed");
        nft.withdrawCreator();
        assertEq(nft.creatorCredit(), 10 ether);
        assertEq(nft.totalCreatorPaid(), 0);
        imd.setFailure(false);
        vm.prank(bob);
        nft.withdrawCreator();
        assertEq(imd.balanceOf(CREATOR), 10 ether);
        _assertSolvent();
    }

    function test_directTransfersRecognizedOnceAndDustConserved() public {
        imd.transfer(address(nft), 1 ether + 3);
        nft.syncProceeds();
        assertEq(nft.totalProceeds(), 1 ether + 3);
        assertEq(nft.creatorCredit(), 0.1 ether);
        assertEq(nft.rewardReserve(), 0.9 ether + 3);
        vm.expectRevert(Swarmlers.ZeroAmount.selector);
        nft.syncProceeds();
        skip(100 days);
        nft.checkpoint();
        assertEq(nft.rewardReserve(), 3);
        for (uint256 i = 1; i <= 25; ++i) {
            vm.prank(CREATOR);
            nft.claimReward(i);
        }
        assertEq(nft.totalClaimed(), 0.9 ether);
        nft.withdrawCreator();
        assertEq(imd.balanceOf(address(nft)), 3);
        _assertSolvent();
    }

    function test_zeroDepositsAndClaimsWithoutFundingRevert() public {
        vm.expectRevert(Swarmlers.ZeroAmount.selector);
        nft.depositProceeds(0);
        vm.expectRevert(Swarmlers.NoRewards.selector);
        vm.prank(CREATOR);
        nft.claimReward(1);
        vm.expectRevert(Swarmlers.ZeroAmount.selector);
        nft.withdrawCreator();
    }
}
