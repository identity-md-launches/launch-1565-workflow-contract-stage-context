// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {SwarmlerActivity} from "../src/SwarmlerActivity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ActivityTest is Fixture {
    function test_unsetAndConfiguredReporter() public {
        SwarmlerActivity fresh = new SwarmlerActivity(address(this));
        vm.expectRevert(SwarmlerActivity.ReporterNotConfigured.selector);
        fresh.status(1, alice);
        vm.expectRevert(SwarmlerActivity.ReporterNotConfigured.selector);
        fresh.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 1, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        fresh.setReporter(alice);
        fresh.setReporter(reporter);
        identity.mint(alice, 1);
        vm.prank(reporter);
        fresh.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 5, true);
        (bool active,, uint64 score) = fresh.status(1, alice);
        assertTrue(active);
        assertEq(score, 5);
    }

    function test_onlyReporterAndCurrentIdentityOwner() public {
        _activeIdentity(alice, 1);
        vm.expectRevert(SwarmlerActivity.UnauthorizedReporter.selector);
        vm.prank(alice);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 100, true);
        vm.expectRevert(SwarmlerActivity.NotIdentityHolder.selector);
        vm.prank(reporter);
        activity.recordActivity(1, bob, uint64(vm.getBlockTimestamp()), 100, true);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp() + 1), 100, true);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp() - 1), 100, true);
    }

    function test_expirationBoundaryRevocationAndOwnershipBinding() public {
        _activeIdentity(alice, 1);
        skip(7 days);
        (bool active,,) = activity.status(1, alice);
        assertTrue(active);
        skip(1);
        (active,,) = activity.status(1, alice);
        assertFalse(active);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 2, true);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 1);
        (active,,) = activity.status(1, bob);
        assertFalse(active);
        (active,,) = activity.status(1, alice);
        assertFalse(active);
        vm.prank(reporter);
        activity.recordActivity(1, bob, uint64(vm.getBlockTimestamp()), 3, true);
        (active,,) = activity.status(1, bob);
        assertTrue(active);
        vm.prank(reporter);
        activity.recordActivity(1, bob, uint64(vm.getBlockTimestamp()), 3, false);
        (active,,) = activity.status(1, bob);
        assertFalse(active);
    }

    function test_rotationAndTwoStepOwnership() public {
        activity.setReporter(bob);
        vm.expectRevert(SwarmlerActivity.UnauthorizedReporter.selector);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 1, true);
        activity.transferOwnership(alice);
        assertEq(activity.owner(), address(this));
        vm.prank(alice);
        activity.acceptOwnership();
        assertEq(activity.owner(), alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        activity.setReporter(reporter);
        vm.expectRevert(SwarmlerActivity.InvalidReport.selector);
        vm.prank(alice);
        activity.renounceOwnership();
    }
}
