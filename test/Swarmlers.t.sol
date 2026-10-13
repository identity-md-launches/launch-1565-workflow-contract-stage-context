// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIMD} from "./helpers/Fixture.sol";
import {Swarmlers} from "../src/Swarmlers.sol";
import {SwarmlerActivity} from "../src/SwarmlerActivity.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ReenterMintReceiver is IERC721Receiver {
    Swarmlers public immutable nft;
    bool public reentered;

    constructor(Swarmlers n, MockIMD imd) {
        nft = n;
        imd.approve(address(n), 1 ether);
    }

    function mint() external {
        nft.mint();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (reentered,) = address(nft).call(abi.encodeCall(Swarmlers.mint, ()));
        return this.onERC721Received.selector;
    }
}

contract RejectNFT is IERC721Receiver {
    Swarmlers private immutable nft;

    constructor(Swarmlers n, MockIMD imd) {
        nft = n;
        imd.approve(address(n), 1 ether);
    }

    function mint() external {
        nft.mint();
    }

    function freeClaim(uint256 id) external {
        nft.freeClaim(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("reject");
    }
}

contract SwarmlersTest is Fixture {
    function test_creatorSupplyBeforeOpeningAndExplicitOwner() public {
        Swarmlers fresh = new Swarmlers(alice, address(activity));
        assertEq(fresh.owner(), alice);
        assertEq(fresh.totalMinted(), 25);
        assertEq(fresh.balanceOf(CREATOR), 25);
        for (uint256 i = 1; i <= 25; ++i) {
            assertEq(fresh.ownerOf(i), CREATOR);
        }
        assertFalse(fresh.publicMintOpen());
        assertEq(fresh.totalProceeds(), 0);
        vm.expectRevert(Swarmlers.MintClosed.selector);
        vm.prank(bob);
        fresh.mint();
        vm.expectRevert(Swarmlers.RewardsNotConfigured.selector);
        vm.prank(alice);
        fresh.openPublicMint();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        fresh.setRewardDuration(30 days);
        vm.prank(alice);
        fresh.setRewardDuration(30 days);
        vm.prank(alice);
        fresh.openPublicMint();
        assertTrue(fresh.publicMintOpen());
    }

    function test_configBoundsAndUnsetReporter() public {
        SwarmlerActivity freshActivity = new SwarmlerActivity(address(this));
        Swarmlers fresh = new Swarmlers(address(this), address(freshActivity));
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(1);
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(3651 days);
        fresh.setRewardDuration(1 days);
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.setRewardDuration(2 days);
        vm.expectRevert(SwarmlerActivity.ReporterNotConfigured.selector);
        fresh.openPublicMint();
        freshActivity.setReporter(reporter);
        fresh.openPublicMint();
        vm.expectRevert(Swarmlers.InvalidConfiguration.selector);
        fresh.openPublicMint();
    }

    function test_paidMintExactCostAndSplit() public {
        uint256 beforeBalance = imd.balanceOf(alice);
        assertEq(_mint(alice), 26);
        assertEq(beforeBalance - imd.balanceOf(alice), 0.25 ether);
        assertEq(nft.ownerOf(26), alice);
        assertEq(nft.rewardReserve(), 0.225 ether);
        assertEq(nft.creatorCredit(), 0.025 ether);
        nft.withdrawCreator();
        assertEq(imd.balanceOf(CREATOR), 0.025 ether);
        _assertSolvent();
    }

    function test_paidMintRequiresAllowanceAndRejectsInexactReceipts() public {
        vm.prank(alice);
        imd.approve(address(nft), 0);
        vm.expectRevert();
        vm.prank(alice);
        nft.mint();
        assertEq(nft.totalMinted(), 25);
        vm.prank(alice);
        imd.approve(address(nft), 1 ether);
        imd.setTax(true);
        vm.expectRevert(Swarmlers.InexactPayment.selector);
        vm.prank(alice);
        nft.mint();
        assertEq(nft.totalMinted(), 25);
        assertEq(nft.totalProceeds(), 0);
        assertEq(imd.balanceOf(address(nft)), 0);
    }

    function test_freeClaimRequiresVerifiedRecentOwnedIdentity() public {
        _activeIdentity(alice, 0); // ID zero is a valid ERC-721 identifier.
        assertTrue(nft.eligible(alice, 0));
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        assertEq(nft.freeClaim(0), 26);
        assertEq(imd.balanceOf(alice), balance);
        assertEq(nft.ownerOf(26), alice);
        assertTrue(nft.isPaired(26));
        assertEq(nft.pairedIdentity(26), 0);
        assertFalse(nft.eligible(alice, 0));
        vm.expectRevert(Swarmlers.AlreadyClaimed.selector);
        vm.prank(alice);
        nft.freeClaim(0);
        _activeIdentity(alice, 1);
        vm.expectRevert(Swarmlers.AlreadyClaimed.selector);
        vm.prank(alice);
        nft.freeClaim(1);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        vm.prank(reporter);
        activity.recordActivity(0, bob, uint64(vm.getBlockTimestamp()), 1, true);
        vm.expectRevert(Swarmlers.AlreadyClaimed.selector);
        vm.prank(bob);
        nft.freeClaim(0);
    }

    function test_invalidStaleAndUnverifiedFreeClaims() public {
        _activeIdentity(alice, 1);
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(bob);
        nft.freeClaim(1);
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(bob);
        nft.freeClaim(999);
        skip(7 days + 1);
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(alice);
        nft.freeClaim(1);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 1, false);
        vm.expectRevert(Swarmlers.NotEligible.selector);
        vm.prank(alice);
        nft.freeClaim(1);
        assertEq(_mint(alice), 26); // Paying remains available to an ineligible identity.
    }

    function test_supplyCapIncludesCreatorsAndRejectsLateMints() public {
        vm.startPrank(alice);
        for (uint256 i = 26; i <= 2500; ++i) {
            assertEq(nft.mint(), i);
        }
        vm.stopPrank();
        assertEq(nft.totalMinted(), 2500);
        assertEq(nft.balanceOf(alice), 2475);
        vm.expectRevert(Swarmlers.SoldOut.selector);
        vm.prank(alice);
        nft.mint();
        _activeIdentity(bob, 1);
        assertFalse(nft.eligible(bob, 1));
        vm.expectRevert(Swarmlers.SoldOut.selector);
        vm.prank(bob);
        nft.freeClaim(1);
        _assertSolvent();
    }

    function test_receiverReentrancyAndRejectedMintRollBack() public {
        ReenterMintReceiver receiver = new ReenterMintReceiver(nft, imd);
        imd.mint(address(receiver), 1 ether);
        receiver.mint();
        assertFalse(receiver.reentered());
        assertEq(nft.balanceOf(address(receiver)), 1);
        assertEq(nft.totalMinted(), 26);
        RejectNFT rejector = new RejectNFT(nft, imd);
        imd.mint(address(rejector), 1 ether);
        uint256 proceeds = nft.totalProceeds();
        vm.expectRevert("reject");
        rejector.mint();
        assertEq(nft.totalProceeds(), proceeds);
        assertEq(imd.balanceOf(address(rejector)), 1 ether);
        _activeIdentity(address(rejector), 5);
        vm.expectRevert("reject");
        rejector.freeClaim(5);
        assertFalse(nft.identityClaimed(5));
        assertFalse(nft.walletClaimed(address(rejector)));
        assertEq(nft.totalMinted(), 26);
    }

    function test_dynamicUniqueMetadataAndPairAuthorization() public {
        uint256 id = _mint(alice);
        uint256 secondId = _mint(alice);
        string memory unpaired = nft.tokenURI(id);
        assertNotEq(unpaired, nft.tokenURI(secondId));
        _activeIdentity(alice, 1);
        vm.expectRevert(Swarmlers.NotHolder.selector);
        vm.prank(bob);
        nft.pair(id, 1);
        vm.prank(alice);
        nft.pair(id, 1);
        string memory first = nft.tokenURI(id);
        assertNotEq(unpaired, first);
        skip(1);
        vm.prank(reporter);
        activity.recordActivity(1, alice, uint64(vm.getBlockTimestamp()), 30, true);
        string memory second = nft.tokenURI(id);
        assertNotEq(first, second);
        skip(7 days + 1);
        assertNotEq(second, nft.tokenURI(id));
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(nft.supportsInterface(0x49064906));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2501));
        nft.tokenURI(2501);
    }

    function test_metadataStaysReadableWhenActivityDependencyFails() public {
        _activeIdentity(alice, 1);
        vm.prank(alice);
        uint256 id = nft.freeClaim(1);
        vm.etch(address(activity), hex"60006000fd");
        assertGt(bytes(nft.tokenURI(id)).length, 0);
        assertFalse(nft.eligible(bob, 2));
    }
}
