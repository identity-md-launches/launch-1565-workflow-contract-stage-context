// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {SwarmlerActivity} from "src/SwarmlerActivity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ActivityBoundariesTest is Fixture {
    function _recordHash(uint256 id) internal view returns (bytes32) {
        (address holder, uint64 lastActive, uint64 score, bool verified) = activity.records(id);
        return keccak256(abi.encode(holder, lastActive, score, verified));
    }

    function test_zeroHolderZeroTimeAndFutureReportsPreserveExistingRecord() public {
        _activeIdentity(alice, 0);
        bytes32 prior = _recordHash(0);
        vm.startPrank(reporter);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        activity.recordActivity(0, address(0), uint64(vm.getBlockTimestamp()), 7, true);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        activity.recordActivity(0, alice, 0, 7, true);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        activity.recordActivity(0, alice, uint64(vm.getBlockTimestamp() + 1), 7, true);
        vm.stopPrank();
        assertEq(_recordHash(0), prior);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        activity.setReporter(address(0));
        assertEq(activity.reporter(), reporter);
    }

    function test_nonexistentIdentityCannotBeAttested() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 77));
        vm.prank(reporter);
        activity.recordActivity(77, alice, uint64(vm.getBlockTimestamp()), 1, true);
        (address holder,,, bool verified) = activity.records(77);
        assertEq(holder, address(0));
        assertFalse(verified);
        assertFalse(nft.eligible(alice, 77));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_freeClaimFreshnessIsInclusiveAndFailedClaimsConsumeNothing(uint32 rawAge, uint64 score)
        public
    {
        uint256 age = bound(rawAge, 0, 14 days);
        identity.mint(alice, 0);
        uint64 reportedAt = uint64(vm.getBlockTimestamp());
        vm.prank(reporter);
        activity.recordActivity(0, alice, reportedAt, score, true);
        skip(age);
        bool expected = age <= 7 days;
        (bool active, uint64 lastActive, uint64 readScore) = activity.status(0, alice);
        assertEq(active, expected);
        assertEq(lastActive, reportedAt);
        assertEq(readScore, score);
        assertEq(nft.eligible(alice, 0), expected);
        uint256 balance = imd.balanceOf(alice);
        if (expected) {
            vm.prank(alice);
            assertEq(nft.freeClaim(0), 26);
            assertTrue(nft.walletClaimed(alice));
            assertTrue(nft.identityClaimed(0));
        } else {
            vm.expectRevert(Swarmlers.NotEligible.selector);
            vm.prank(alice);
            nft.freeClaim(0);
            assertFalse(nft.walletClaimed(alice));
            assertFalse(nft.identityClaimed(0));
            assertEq(nft.totalMinted(), 25);
        }
        assertEq(imd.balanceOf(alice), balance);
        assertEq(nft.totalProceeds(), 0);
    }

    function test_claimExactlyAtWindowEndThenRejectOneSecondLater() public {
        _activeIdentity(alice, 0);
        _activeIdentity(bob, 1);
        skip(7 days);
        vm.prank(alice);
        nft.freeClaim(0);
        skip(1);
        assertFalse(nft.eligible(bob, 1));
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(bob);
        nft.freeClaim(1);
        assertFalse(nft.identityClaimed(1));
        assertFalse(nft.walletClaimed(bob));
    }

    function test_sameTimestampRevocationAndMaximumScoreAreSupported() public {
        _activeIdentity(alice, 0);
        uint64 nowTime = uint64(vm.getBlockTimestamp());
        vm.prank(reporter);
        activity.recordActivity(0, alice, nowTime, type(uint64).max, true);
        (bool active,, uint64 score) = activity.status(0, alice);
        assertTrue(active);
        assertEq(score, type(uint64).max);
        vm.prank(reporter);
        activity.recordActivity(0, alice, nowTime, 0, false);
        assertFalse(nft.eligible(alice, 0));
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(alice);
        nft.freeClaim(0);
        vm.prank(reporter);
        activity.recordActivity(0, alice, nowTime, 0, true);
        assertTrue(nft.eligible(alice, 0));
    }

    function test_identityDependencyOutageFailsClosedAndRecoveryAllowsClaim() public {
        _activeIdentity(alice, 0);
        bytes memory runtime = address(identity).code;
        vm.etch(address(identity), hex"60006000fd");
        (bool active,,) = activity.status(0, alice);
        assertFalse(active);
        assertFalse(nft.eligible(alice, 0));
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(alice);
        nft.freeClaim(0);
        assertFalse(nft.identityClaimed(0));
        vm.etch(address(identity), runtime);
        assertTrue(nft.eligible(alice, 0));
        vm.prank(alice);
        nft.freeClaim(0);
    }

    function test_pairRequiresHolderEvenForApprovedOperatorAndNeverConsumesFreeClaim() public {
        uint256 tokenId = _mint(alice);
        _activeIdentity(alice, 0);
        _activeIdentity(bob, 1);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(bob);
        nft.pair(tokenId, 1);
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(alice);
        nft.pair(tokenId, 1);
        assertFalse(nft.isPaired(tokenId));
        vm.prank(alice);
        nft.pair(tokenId, 0);
        assertFalse(nft.walletClaimed(alice));
        assertFalse(nft.identityClaimed(0));
        vm.prank(bob);
        nft.transferFrom(alice, bob, tokenId);
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(alice);
        nft.pair(tokenId, 0);
        vm.prank(bob);
        nft.pair(tokenId, 1);
        assertEq(nft.pairedIdentity(tokenId), 1);
        assertTrue(nft.eligible(bob, 1));
    }

    function test_collectionOwnershipHandoffDoesNotGrantPendingOwnerPrivileges() public {
        Swarmlers fresh = new Swarmlers(address(this), address(activity));
        fresh.transferOwnership(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.setRewardDuration(1 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        fresh.acceptOwnership();
        vm.prank(alice);
        fresh.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.setRewardDuration(1 days);
        vm.startPrank(alice);
        fresh.setRewardDuration(1 days);
        fresh.openPublicMint();
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.renounceOwnership();
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(3650 days);
        vm.stopPrank();
        assertEq(fresh.owner(), alice);
        assertEq(fresh.rewardDuration(), 1 days);
        assertEq(fresh.balanceOf(CREATOR), 25);
    }

    // Keep constructor reverts in separate tests. Foundry's dynamic linking can
    // propagate deployCode failures out of the test even when expectRevert matches.
    function test_activityRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SwarmlerActivity(address(0));
    }

    function test_collectionRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Swarmlers(address(0), address(activity));
    }

    function test_collectionRejectsZeroRegistry() public {
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        new Swarmlers(alice, address(0));
    }

    function test_rewardDurationEndpoints() public {
        Swarmlers fresh = new Swarmlers(address(this), address(activity));
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(1 days - 1);
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(3650 days + 1);
        fresh.setRewardDuration(3650 days);
        assertGt(fresh.rewardRate(), 0);
        assertEq(fresh.rewardDuration(), 3650 days);
    }
}
