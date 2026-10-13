// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture, MockIMD} from "./helpers/Fixture.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract InspectingNFTReceiver is Test, IERC721Receiver {
    Swarmlers internal immutable nft;
    address internal immutable recipient;
    bool internal free;
    uint256 public observedToken;
    uint256 public blockedCalls;

    constructor(Swarmlers n, MockIMD imd, address receiver) {
        nft = n;
        recipient = receiver;
        imd.approve(address(n), type(uint256).max);
    }

    function paidMint() external returns (uint256) {
        return nft.mint();
    }

    function freeMint() external returns (uint256) {
        free = true;
        return nft.freeClaim(0);
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        assertEq(msg.sender, address(nft));
        assertEq(from, address(0));
        assertEq(nft.totalMinted(), id);
        assertEq(nft.ownerOf(id), address(this));
        assertEq(nft.earned(id), 0, "receiver observed pre-mint rewards");
        assertEq(nft.birthIndex(id), nft.rewardIndex());
        if (free) {
            assertTrue(nft.walletClaimed(address(this)));
            assertTrue(nft.identityClaimed(0));
            assertTrue(nft.isPaired(id));
            assertEq(nft.pairedIdentity(id), 0);
            assertFalse(nft.eligible(address(this), 0));
        }
        _blocked(abi.encodeCall(Swarmlers.mint, ()));
        _blocked(abi.encodeCall(Swarmlers.freeClaim, (0)));
        _blocked(abi.encodeCall(Swarmlers.claimReward, (id)));
        _blocked(abi.encodeCall(Swarmlers.depositProceeds, (1)));
        _blocked(abi.encodeCall(Swarmlers.syncProceeds, ()));
        _blocked(abi.encodeCall(Swarmlers.withdrawCreator, ()));
        // ERC-721 holders may transfer inside a receiver callback. It must not
        // undo pairing, consume another mint, or reset rewards after returning.
        nft.checkpoint();
        nft.transferFrom(address(this), recipient, id);
        observedToken = id;
        return IERC721Receiver.onERC721Received.selector;
    }

    function _blocked(bytes memory callData) internal {
        (bool ok, bytes memory reason) = address(nft).call(callData);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        ++blockedCalls;
    }
}

contract ReceiverCallbacksTest is Fixture {
    function test_paidReceiverSeesFinalStateAndCannotReenterAnyValueFunction() public {
        nft.depositProceeds(100 ether);
        skip(5 days);
        InspectingNFTReceiver receiver = new InspectingNFTReceiver(nft, imd, alice);
        imd.mint(address(receiver), 0.25 ether);
        uint256 id = receiver.paidMint();
        assertEq(id, 26);
        assertEq(receiver.observedToken(), id);
        assertEq(receiver.blockedCalls(), 6);
        assertEq(nft.totalMinted(), 26);
        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.balanceOf(address(receiver)), 0);
        assertEq(imd.balanceOf(address(receiver)), 0);
        assertEq(nft.earned(id), 0);
        skip(1 days);
        vm.prank(alice);
        assertGt(nft.claimReward(id), 0);
        _assertSolvent();
    }

    function test_freeReceiverSeesClaimFlagsAndPairingBeforeCallback() public {
        InspectingNFTReceiver receiver = new InspectingNFTReceiver(nft, imd, bob);
        _activeIdentity(address(receiver), 0);
        assertEq(receiver.freeMint(), 26);
        assertEq(receiver.blockedCalls(), 6);
        assertEq(nft.ownerOf(26), bob);
        assertEq(nft.totalProceeds(), 0);
        assertTrue(nft.walletClaimed(address(receiver)));
        assertTrue(nft.identityClaimed(0));
        assertTrue(nft.isPaired(26));
        assertFalse(nft.walletClaimed(bob), "recipient was charged the sender's free claim");
        _assertSolvent();
    }
}
