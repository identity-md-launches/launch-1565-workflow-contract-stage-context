// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture, MockIMD, MockIdentity} from "./helpers/Fixture.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {SwarmlerActivity} from "src/SwarmlerActivity.sol";

/// @dev Ghosts are updated from successful user actions and observed transfers,
/// not copied from the collection's aggregate counters.
contract MultiActorRewardsHandler is Test {
    Swarmlers public immutable nft;
    MockIMD public immutable imd;
    SwarmlerActivity public immutable activity;
    address public immutable reporter;
    address[4] public actors;
    mapping(address => uint256) public initialBalance;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public received;
    mapping(uint256 => address) public holders;
    mapping(uint256 => uint256) public paidById;
    mapping(address => bool) public usedFreeClaim;
    uint256 public minted = 25;
    uint256 public grossReceived;
    uint256 public recognized;
    uint256 public unrecognized;
    uint256 public creatorEntitlement;
    uint256 public rewardsPaid;
    uint256 public creatorPaid;
    uint256 public successfulClaims;
    uint256 public successfulSyncs;
    uint256 public successfulFreeClaims;
    uint256 public overflowedDeposits;

    constructor(Swarmlers n, MockIMD t, SwarmlerActivity a, address r, address[4] memory accounts) {
        nft = n;
        imd = t;
        activity = a;
        reporter = r;
        actors = accounts;
        for (uint256 i; i < 4; ++i) {
            initialBalance[accounts[i]] = t.balanceOf(accounts[i]);
        }
        for (uint256 id = 1; id <= 25; ++id) {
            holders[id] = accounts[3];
        }
    }

    function mint(uint256 actorSeed) public {
        if (minted == 2500) return;
        address actor = actors[actorSeed % 4];
        vm.prank(actor);
        uint256 id = nft.mint();
        assertEq(id, ++minted);
        holders[id] = actor;
        spent[actor] += 0.25 ether;
        grossReceived += 0.25 ether;
        _recognize(0.25 ether);
    }

    function freeClaim(uint256 actorSeed) public {
        if (minted == 2500) return;
        uint256 identityId = actorSeed % 4;
        address actor = actors[identityId];
        if (usedFreeClaim[actor]) {
            vm.expectRevert(Swarmlers.AlreadyClaimed.selector);
            vm.prank(actor);
            nft.freeClaim(identityId);
            return;
        }
        vm.prank(reporter);
        activity.recordActivity(identityId, actor, uint64(vm.getBlockTimestamp()), 1, true);
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        uint256 id = nft.freeClaim(identityId);
        assertEq(id, ++minted);
        assertEq(imd.balanceOf(actor), beforeBalance);
        assertTrue(nft.isPaired(id));
        assertEq(nft.pairedIdentity(id), identityId);
        holders[id] = actor;
        usedFreeClaim[actor] = true;
        ++successfulFreeClaims;
    }

    function fund(uint256 actorSeed, uint128 raw) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(raw, 1, 500 ether);
        vm.prank(actor);
        nft.depositProceeds(amount);
        spent[actor] += amount;
        grossReceived += amount;
        _recognize(amount);
    }

    function donate(uint256 actorSeed, uint128 raw) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(raw, 1, 500 ether);
        vm.prank(actor);
        imd.transfer(address(nft), amount);
        spent[actor] += amount;
        grossReceived += amount;
        unrecognized += amount;
    }

    function sync() public {
        if (unrecognized == 0) {
            vm.expectRevert(Swarmlers.ZeroAmount.selector);
            nft.syncProceeds();
            return;
        }
        nft.syncProceeds();
        _recognize(unrecognized);
        unrecognized = 0;
        ++successfulSyncs;
    }

    function advance(uint32 raw) public {
        uint256 beforeEarned = nft.earned(1);
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 40 days));
        assertGe(nft.earned(1), beforeEarned);
        // Deliberately leave the checkpoint pending: views and transfers must also be solvent.
    }

    function checkpoint() public {
        (uint256 index, uint256 reserve, uint256 first) = nft.previewRewardState();
        nft.checkpoint();
        assertEq(nft.rewardIndex(), index);
        assertEq(nft.rewardReserve(), reserve);
        assertEq(nft.firstActiveId(), first);
    }

    function move(uint256 rawId, uint256 toSeed, bool viaOperator) public {
        uint256 id = bound(rawId, 1, minted);
        address from = holders[id];
        address to = actors[toSeed % 4];
        uint256 beforeEarned = nft.earned(id);
        uint256 beforePaid = nft.claimed(id);
        if (viaOperator) {
            vm.prank(from);
            nft.approve(address(this), id);
            nft.transferFrom(from, to, id);
        } else {
            vm.prank(from);
            nft.transferFrom(from, to, id);
        }
        holders[id] = to;
        assertEq(nft.earned(id), beforeEarned, "a transfer changed lifetime accrual");
        assertEq(nft.claimed(id), beforePaid, "a transfer reset the lifetime cap");
        assertEq(nft.getApproved(id), address(0));
    }

    function claim(uint256 rawId) public {
        _claim(bound(rawId, 1, minted));
    }

    function claimBatch(uint256 actorSeed) public {
        address actor = actors[actorSeed % 4];
        uint256 count;
        uint256 expected;
        uint256[] memory ids = new uint256[](100);
        uint256[] memory amounts = new uint256[](100);
        for (uint256 id = 1; id <= minted && count < 100; ++id) {
            if (holders[id] != actor) continue;
            uint256 amount = nft.claimable(id);
            if (amount == 0) continue;
            ids[count] = id;
            amounts[count++] = amount;
            expected += amount;
        }
        if (count == 0) return;
        assembly ("memory-safe") { mstore(ids, count) }
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        assertEq(nft.claimRewards(ids), expected);
        assertEq(imd.balanceOf(actor) - beforeBalance, expected);
        for (uint256 i; i < count; ++i) {
            paidById[ids[i]] += amounts[i];
        }
        received[actor] += expected;
        rewardsPaid += expected;
        successfulClaims += count;
    }

    function rejectedClaim(uint256 rawId) public {
        uint256 id = bound(rawId, 1, minted);
        // The handler is never an NFT holder, even if every user transfers away.
        uint256 paid = nft.totalClaimed();
        uint256 index = nft.rewardIndex();
        vm.expectRevert(Swarmlers.NotHolder.selector);
        nft.claimReward(id);
        assertEq(nft.totalClaimed(), paid);
        assertEq(nft.rewardIndex(), index, "unauthorized claim persisted its checkpoint");
    }

    function payCreator() public {
        uint256 expected = creatorEntitlement - creatorPaid;
        if (expected == 0) {
            vm.expectRevert(Swarmlers.ZeroAmount.selector);
            nft.withdrawCreator();
            return;
        }
        uint256 beforeBalance = imd.balanceOf(actors[3]);
        nft.withdrawCreator();
        assertEq(imd.balanceOf(actors[3]) - beforeBalance, expected);
        creatorPaid += expected;
        received[actors[3]] += expected;
    }

    // Only called by afterInvariant, never a random action: exercise final withdrawal liveness.
    function drainClaimable() external {
        if (unrecognized != 0) sync();
        checkpoint();
        for (uint256 id = 1; id <= minted; ++id) {
            if (nft.claimable(id) != 0) _claim(id);
            assertEq(nft.claimable(id), 0);
        }
        if (creatorEntitlement != creatorPaid) payCreator();
    }

    function _claim(uint256 id) internal {
        address actor = holders[id];
        uint256 expected = nft.claimable(id);
        if (expected == 0) {
            vm.expectRevert(Swarmlers.NoRewards.selector);
            vm.prank(actor);
            nft.claimReward(id);
            return;
        }
        uint256 beforeBalance = imd.balanceOf(actor);
        vm.prank(actor);
        assertEq(nft.claimReward(id), expected);
        assertEq(imd.balanceOf(actor) - beforeBalance, expected);
        paidById[id] += expected;
        received[actor] += expected;
        rewardsPaid += expected;
        ++successfulClaims;
    }

    /// @dev Reward credit so far is everything recognized that was not the creator's; the brief's cap of
    ///      1 IMD for each of 2,500 NFTs bounds it, and whatever the 90% share cannot fit is the creator's.
    ///      Computed from ghosts only, never from the collection's own counters.
    function rewardCreditCapacity() public view returns (uint256) {
        return 2500 ether - (recognized - creatorEntitlement);
    }

    function _recognize(uint256 amount) internal {
        uint256 creatorShare = amount / 10;
        uint256 rewardShare = amount - creatorShare;
        uint256 capacity = rewardCreditCapacity();
        if (rewardShare > capacity) {
            ++overflowedDeposits;
            creatorShare += rewardShare - capacity;
        }
        recognized += amount;
        creatorEntitlement += creatorShare;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RewardsStatefulTest is Fixture {
    MultiActorRewardsHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[4] memory actors = [alice, bob, makeAddr("rewards C"), CREATOR];
        for (uint256 i; i < 4; ++i) {
            _fund(actors[i], 1_000_000 ether);
            identity.mint(actors[i], i);
        }
        handler = new MultiActorRewardsHandler(nft, imd, activity, reporter, actors);
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.freeClaim.selector;
        selectors[2] = handler.fund.selector;
        selectors[3] = handler.donate.selector;
        selectors[4] = handler.sync.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.checkpoint.selector;
        selectors[7] = handler.move.selector;
        selectors[8] = handler.claim.selector;
        selectors[9] = handler.claimBatch.selector;
        selectors[10] = handler.rejectedClaim.selector;
        selectors[11] = handler.payCreator.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_externalCashFlowsEqualCustodyAndLiabilities() public view {
        assertEq(nft.totalProceeds(), handler.recognized());
        assertEq(nft.totalClaimed(), handler.rewardsPaid());
        assertEq(nft.totalCreatorPaid(), handler.creatorPaid());
        assertEq(nft.creatorCredit() + handler.creatorPaid(), handler.creatorEntitlement());
        assertEq(imd.balanceOf(address(nft)), nft.accountedBalance() + handler.unrecognized());
        assertEq(
            handler.grossReceived(),
            imd.balanceOf(address(nft)) + handler.rewardsPaid() + handler.creatorPaid()
        );
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(
                imd.balanceOf(actor) + handler.spent(actor),
                handler.initialBalance(actor) + handler.received(actor)
            );
        }
    }

    function invariant_currentAndPendingEntitlementsAreBackedAndCapped() public view {
        uint256 earnedSum;
        uint256 claimedSum;
        uint256 supply = handler.minted();
        (, uint256 pendingReserve, uint256 first) = nft.previewRewardState();
        for (uint256 id = 1; id <= supply; ++id) {
            uint256 earned = nft.earned(id);
            uint256 paid = handler.paidById(id);
            assertLe(earned, 1 ether);
            assertLe(paid, earned);
            assertEq(nft.claimed(id), paid);
            assertEq(nft.claimable(id), earned - paid);
            assertEq(nft.ownerOf(id), handler.holders(id));
            if (id < first) assertEq(earned, 1 ether);
            earnedSum += earned;
            claimedSum += paid;
        }
        assertEq(earnedSum, nft.totalAllocated() + nft.rewardReserve() - pendingReserve);
        assertEq(claimedSum, handler.rewardsPaid());
        assertEq(pendingReserve + earnedSum + handler.creatorEntitlement(), handler.recognized());
        // Reward credit never exceeds what 2,500 NFTs can earn, and the contract's view agrees with ghosts.
        assertLe(handler.recognized() - handler.creatorEntitlement(), 2500 ether);
        assertEq(nft.remainingRewardCapacity(), handler.rewardCreditCapacity());
        assertEq(nft.totalMinted(), supply);
        assertLe(supply, 2500);
        assertLe(first, supply + 1);
        assertTrue(nft.publicMintOpen());
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 owned;
            for (uint256 id = 1; id <= supply; ++id) {
                if (handler.holders(id) == actor) ++owned;
            }
            assertEq(nft.balanceOf(actor), owned);
            assertEq(nft.walletClaimed(actor), handler.usedFreeClaim(actor));
            assertEq(nft.identityClaimed(i), handler.usedFreeClaim(actor));
        }
    }

    function afterInvariant() public {
        handler.drainClaimable();
        invariant_externalCashFlowsEqualCustodyAndLiabilities();
        invariant_currentAndPendingEntitlementsAreBackedAndCapped();
        assertEq(nft.totalAllocated(), nft.totalClaimed());
        assertEq(imd.balanceOf(address(nft)), nft.rewardReserve());
    }

    function test_handlerExercisesDelayedSyncBatchClaimsAndTransfers() public {
        handler.mint(0);
        handler.freeClaim(1);
        handler.freeClaim(1);
        handler.fund(2, 100 ether);
        handler.donate(0, 11);
        handler.advance(5 days);
        handler.move(26, 1, true);
        handler.claimBatch(1);
        handler.sync();
        handler.sync();
        handler.rejectedClaim(1);
        handler.payCreator();
        handler.advance(40 days);
        handler.checkpoint();
        handler.claim(26);
        assertGt(handler.successfulClaims(), 0);
        assertEq(handler.successfulSyncs(), 1);
        assertEq(handler.successfulFreeClaims(), 1);
        afterInvariant();
    }

    /// @dev The random campaign can reach lifetime capacity (64 deposits of up to 500 IMD); pin that path
    ///      so the ghost model of the overflow is exercised whether or not the fuzzer finds it.
    function test_handlerModelsFundingPastLifetimeCapacity() public {
        handler.mint(0);
        for (uint256 i; i < 5; ++i) {
            handler.fund(i, uint128(500 ether));
        }
        assertEq(handler.overflowedDeposits(), 0);
        assertEq(nft.remainingRewardCapacity(), 249.775 ether);
        handler.fund(1, uint128(500 ether)); // 450 fits 249.775: 200.225 overflows to the creator.
        assertEq(handler.overflowedDeposits(), 1);
        assertEq(nft.remainingRewardCapacity(), 0);
        assertEq(nft.creatorCredit(), 0.025 ether + 250 ether + 50 ether + 200.225 ether);
        handler.donate(2, uint128(123 ether));
        handler.advance(40 days);
        handler.sync(); // Recognized after accrual: capacity is unchanged by the checkpoint.
        assertEq(handler.overflowedDeposits(), 2);
        handler.mint(3); // A paid mint at zero capacity is all creator share.
        assertEq(handler.overflowedDeposits(), 3);
        invariant_externalCashFlowsEqualCustodyAndLiabilities();
        invariant_currentAndPendingEntitlementsAreBackedAndCapped();
        handler.payCreator();
        handler.claim(26);
        assertEq(nft.claimed(26), 1 ether);
        afterInvariant();
        assertEq(nft.rewardReserve(), 2500 ether - 26 ether);
        assertEq(nft.claimed(27), 0);
    }
}
