// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIMD} from "./helpers/Fixture.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {SwarmlerActivity} from "src/SwarmlerActivity.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Offline external-token behavior; the production collection is never replaced.
contract ReturnModeIMD is MockIMD {
    uint256 public mode;

    function setMode(uint256 value) external {
        mode = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (mode == 1) return false;
        if (mode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (mode == 1) return false;
        if (mode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

contract RewardsAdversarialTest is Fixture {
    function _ledger() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                nft.rewardIndex(),
                nft.rewardReserve(),
                nft.firstActiveId(),
                nft.lastRewardTime(),
                nft.totalAllocated(),
                nft.totalClaimed(),
                nft.creatorCredit(),
                nft.totalCreatorPaid(),
                nft.totalProceeds(),
                nft.totalMinted(),
                imd.balanceOf(address(nft))
            )
        );
    }

    function test_failedBalancePullRestoresCheckpointAllowanceAndSupply() public {
        nft.depositProceeds(100 ether);
        skip(1 days);
        address emptyHolder = makeAddr("unfunded minter");
        vm.prank(emptyHolder);
        imd.approve(address(nft), 0.25 ether);
        bytes32 beforeState = _ledger();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, emptyHolder, 0, 0.25 ether)
        );
        vm.prank(emptyHolder);
        nft.mint();
        assertEq(_ledger(), beforeState, "failed mint consumed a checkpoint");
        assertEq(imd.allowance(emptyHolder, address(nft)), 0.25 ether);
    }

    function test_taxedDepositRestoresSenderBalanceAllowanceAndPendingRewards() public {
        nft.depositProceeds(100 ether);
        skip(1 days);
        bytes32 beforeState = _ledger();
        uint256 balance = imd.balanceOf(alice);
        uint256 allowance = imd.allowance(alice, address(nft));
        uint256 supply = imd.totalSupply();
        imd.setTax(true);
        vm.expectRevert(Swarmlers.InexactPayment.selector);
        vm.prank(alice);
        nft.depositProceeds(1 ether);
        assertEq(_ledger(), beforeState);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(imd.allowance(alice, address(nft)), allowance);
        assertEq(imd.totalSupply(), supply, "rejected tax must not burn funds");
    }

    function test_falseReturningTokenRollsBackMintClaimAndCreatorPayout() public {
        ReturnModeIMD implementation = new ReturnModeIMD();
        vm.etch(address(imd), address(implementation).code);
        ReturnModeIMD unusual = ReturnModeIMD(address(imd));
        uint256 id = _mint(alice);
        nft.depositProceeds(100 ether);
        skip(1 days);
        unusual.setMode(1);
        bytes32 beforeState = _ledger();
        uint256 balance = imd.balanceOf(alice);
        bytes memory errorData =
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd));
        vm.expectRevert(errorData);
        vm.prank(alice);
        nft.mint();
        assertEq(_ledger(), beforeState);
        vm.expectRevert(errorData);
        vm.prank(alice);
        nft.claimReward(id);
        assertEq(_ledger(), beforeState);
        assertEq(nft.claimed(id), 0);
        assertEq(imd.balanceOf(alice), balance);
        vm.expectRevert(errorData);
        nft.withdrawCreator();
        assertEq(_ledger(), beforeState);
        assertEq(imd.balanceOf(CREATOR), 0);
        unusual.setMode(0);
        vm.prank(alice);
        assertGt(nft.claimReward(id), 0, "a rejected payout must remain retryable");
        nft.withdrawCreator();
        _assertSolvent();
    }

    function test_noReturnTokenSupportsFullRewardLifecycle() public {
        ReturnModeIMD implementation = new ReturnModeIMD();
        vm.etch(address(imd), address(implementation).code);
        ReturnModeIMD(address(imd)).setMode(2);
        uint256 beforeBalance = imd.balanceOf(alice);
        uint256 id = _mint(alice);
        assertEq(beforeBalance - imd.balanceOf(alice), 0.25 ether);
        nft.depositProceeds(100 ether);
        skip(31 days);
        vm.prank(alice);
        assertEq(nft.claimReward(id), 1 ether);
        nft.withdrawCreator();
        assertEq(imd.balanceOf(alice), beforeBalance + 0.75 ether);
        assertEq(imd.balanceOf(CREATOR), 10.025 ether);
        _assertSolvent();
    }

    function test_dustWaitsUntilEveryActiveNFTCanReceiveOneWei() public {
        nft.depositProceeds(26); // 24 reward wei for 25 active NFTs.
        skip(1);
        nft.checkpoint();
        assertEq(nft.earned(1), 0);
        assertEq(nft.rewardReserve(), 24);
        nft.depositProceeds(1);
        assertEq(nft.earned(1), 0, "a refill cannot pay unfunded past time");
        skip(1);
        nft.checkpoint();
        assertEq(nft.rewardReserve(), 0);
        assertEq(nft.totalAllocated(), 25);
        for (uint256 id = 1; id <= 25; ++id) {
            vm.prank(CREATOR);
            assertEq(nft.claimReward(id), 1);
        }
        nft.withdrawCreator();
        assertEq(imd.balanceOf(CREATOR), 27);
        assertEq(imd.balanceOf(address(nft)), 0);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_checkpointPartitionDoesNotChangeEntitlement(
        uint128 rawFunding,
        uint32 rawFirst,
        uint32 rawSecond
    ) public {
        uint256 funding = bound(rawFunding, 1, 1000 ether);
        uint256 first = bound(rawFirst, 0, 60 days);
        uint256 second = bound(rawSecond, 0, 60 days);
        _mint(alice);
        nft.depositProceeds(funding);
        uint256 start = vm.getBlockTimestamp();
        uint256 snapshot = vm.snapshotState();
        vm.warp(start + first + second);
        nft.checkpoint();
        bytes32 single = _ledger();
        uint256 oneClaim = nft.claimable(26);
        assertTrue(vm.revertToState(snapshot));
        vm.warp(start + first);
        nft.checkpoint();
        nft.checkpoint(); // Repeated checkpoints at the same timestamp are idempotent.
        vm.warp(start + first + second);
        nft.checkpoint();
        assertEq(_ledger(), single, "third-party checkpoints changed allocation");
        assertEq(nft.claimable(26), oneClaim);
        _assertSolvent();
    }

    function test_batchOf100PaysExactlyOnceAnd101RollsBack() public {
        uint256[] memory ids = new uint256[](100);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _mint(alice);
        }
        nft.depositProceeds(200 ether);
        skip(31 days);
        bytes32 beforeState = _ledger();
        vm.expectRevert(Swarmlers.InvalidBatch.selector);
        vm.prank(alice);
        nft.claimRewards(new uint256[](101));
        assertEq(_ledger(), beforeState);
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        assertEq(nft.claimRewards(ids), 100 ether);
        assertEq(imd.balanceOf(alice) - balance, 100 ether);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(nft.claimed(ids[i]), 1 ether);
        }
        vm.expectRevert(Swarmlers.NoRewards.selector);
        vm.prank(alice);
        nft.claimRewards(ids);
        _assertSolvent();
    }

    function test_nonexistentLastBatchEntryRevertsAllEarlierClaimsAndCheckpoint() public {
        uint256 id = _mint(alice);
        nft.depositProceeds(100 ether);
        skip(1 days);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = 2501;
        bytes32 beforeState = _ledger();
        uint256 balance = imd.balanceOf(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2501));
        vm.prank(alice);
        nft.claimRewards(ids);
        assertEq(_ledger(), beforeState);
        assertEq(nft.claimed(id), 0);
        assertEq(imd.balanceOf(alice), balance);
    }

    function test_directTransferBeforeConfigurationIsRecognizedOnceAfterConfiguration() public {
        Swarmlers fresh = new Swarmlers(address(this), address(activity));
        imd.transfer(address(fresh), 11);
        vm.expectRevert(Swarmlers.RewardsNotConfigured.selector);
        fresh.syncProceeds();
        vm.expectRevert(Swarmlers.RewardsNotConfigured.selector);
        fresh.depositProceeds(1);
        fresh.setRewardDuration(3650 days);
        fresh.syncProceeds();
        assertEq(fresh.creatorCredit(), 1);
        assertEq(fresh.rewardReserve(), 10);
        assertEq(fresh.totalProceeds(), 11);
        vm.expectRevert(Swarmlers.ZeroAmount.selector);
        fresh.syncProceeds();
    }

    /// @dev Oracle for the deposit split, independent of the contract's capacity view: reward credit so
    ///      far is every proceed that was not credited to the creator, and the brief caps it at 2,500 IMD.
    function _expectedSplit(uint256 amount) internal view returns (uint256 rewards, uint256 creatorShare) {
        uint256 credited = nft.totalProceeds() - nft.creatorCredit() - nft.totalCreatorPaid();
        uint256 capacity = 2500 ether - credited;
        creatorShare = amount / 10;
        rewards = amount - creatorShare;
        if (rewards > capacity) {
            creatorShare += rewards - capacity;
            rewards = capacity;
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_depositSplitIsNinetyPercentUntilLifetimeCapacityThenCreator(
        uint128 rawPrior,
        uint128 rawAmount,
        uint32 rawElapsed,
        bool viaSync
    ) public {
        uint256 prior = bound(rawPrior, 1, 3000 ether);
        uint256 amount = bound(rawAmount, 1, 3000 ether);
        _mint(alice);
        nft.depositProceeds(prior);
        skip(bound(rawElapsed, 0, 60 days));
        nft.checkpoint();
        (uint256 rewards, uint256 creatorShare) = _expectedSplit(amount);
        uint256 reserveBefore = nft.rewardReserve();
        uint256 creditBefore = nft.creatorCredit();
        uint256 allocatedBefore = nft.totalAllocated();
        if (viaSync) imd.transfer(address(nft), amount);
        vm.expectEmit(true, false, false, true);
        emit Swarmlers.ProceedsDeposited(address(this), amount, rewards, creatorShare);
        if (viaSync) nft.syncProceeds();
        else nft.depositProceeds(amount);
        assertEq(rewards + creatorShare, amount, "split lost or created value");
        assertEq(nft.rewardReserve() - reserveBefore, rewards);
        assertEq(nft.creatorCredit() - creditBefore, creatorShare);
        assertEq(nft.totalAllocated(), allocatedBefore, "a deposit changed past allocation");
        assertGe(creatorShare, amount / 10, "the creator never receives less than 10%");
        assertLe(nft.totalAllocated() + nft.rewardReserve(), 2500 ether);
        if (nft.totalAllocated() + nft.rewardReserve() < 2500 ether) {
            assertEq(creatorShare, amount / 10, "overflow was credited while capacity remained");
        }
        assertEq(nft.remainingRewardCapacity(), 2500 ether - nft.totalAllocated() - nft.rewardReserve());
        _assertSolvent();
    }

    function test_depositSplitBoundaryAroundRemainingCapacity() public {
        nft.depositProceeds(2000 ether); // 1800 reserved, 700 capacity left.
        assertEq(nft.remainingRewardCapacity(), 700 ether);
        uint256 exact = uint256(700 ether) * 10 / 9;
        assertEq(exact - exact / 10, 700 ether, "fixture: reward share must equal the capacity");
        // A deposit whose 90% share exactly fills the capacity is an ordinary 90/10 split.
        uint256 snapshot = vm.snapshotState();
        vm.expectEmit(true, false, false, true);
        emit Swarmlers.ProceedsDeposited(address(this), exact, 700 ether, exact / 10);
        nft.depositProceeds(exact);
        assertEq(nft.remainingRewardCapacity(), 0);
        assertEq(nft.creatorCredit(), 200 ether + exact / 10);
        assertTrue(vm.revertToState(snapshot));
        // One more wei of reward share than capacity moves exactly one wei to the creator.
        vm.expectEmit(true, false, false, true);
        emit Swarmlers.ProceedsDeposited(address(this), exact + 1, 700 ether, exact / 10 + 1);
        nft.depositProceeds(exact + 1);
        assertEq(nft.remainingRewardCapacity(), 0);
        assertEq(nft.creatorCredit(), 200 ether + exact / 10 + 1);
        // At zero capacity every path (deposit, direct transfer, paid mint) credits the creator in full,
        // and the holder-facing ledger is untouched.
        uint256 credit = nft.creatorCredit();
        uint256 reserve = nft.rewardReserve();
        vm.expectEmit(true, false, false, true);
        emit Swarmlers.ProceedsDeposited(address(this), 20, 0, 20);
        nft.depositProceeds(20);
        imd.transfer(address(nft), 5 ether);
        nft.syncProceeds();
        uint256 id = _mint(alice);
        assertEq(nft.creatorCredit() - credit, 5.25 ether + 20);
        assertEq(nft.rewardReserve(), reserve);
        assertEq(nft.earned(id), 0);
        skip(31 days);
        assertEq(nft.earned(id), 1 ether, "a reserve at capacity still funds the new NFT");
        nft.withdrawCreator();
        assertEq(imd.balanceOf(CREATOR), nft.totalCreatorPaid());
        _assertSolvent();
    }
}
