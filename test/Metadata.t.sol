// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {Swarmlers} from "src/Swarmlers.sol";
import {SwarmlerArt} from "src/SwarmlerArt.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MetadataTest is Fixture {
    /// @dev Independent, test-only base64 reader. JSON parsing uses Foundry's parser.
    function _decode(string memory uri, string memory prefix) internal pure returns (string memory) {
        bytes memory input = bytes(uri);
        bytes memory start = bytes(prefix);
        assertGt(input.length, start.length);
        for (uint256 i; i < start.length; ++i) {
            assertEq(input[i], start[i]);
        }
        uint256 encodedLength = input.length - start.length;
        assertEq(encodedLength % 4, 0);
        uint256 length = encodedLength / 4 * 3;
        if (input[input.length - 1] == "=") --length;
        if (input[input.length - 2] == "=") --length;
        bytes memory result = new bytes(length);
        uint256 buffer;
        uint256 bits;
        uint256 cursor;
        for (uint256 i = start.length; i < input.length && input[i] != "="; ++i) {
            uint8 c = uint8(input[i]);
            uint256 digit;
            if (c >= 65 && c <= 90) digit = c - 65;
            else if (c >= 97 && c <= 122) digit = c - 71;
            else if (c >= 48 && c <= 57) digit = c + 4;
            else if (c == 43) digit = 62;
            else if (c == 47) digit = 63;
            else revert("invalid base64 alphabet");
            buffer = (buffer << 6) | digit;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                result[cursor++] = bytes1(uint8(buffer >> bits));
            }
        }
        assertEq(cursor, length);
        return string(result);
    }

    function _json(uint256 id) internal view returns (string memory) {
        return _decode(nft.tokenURI(id), "data:application/json;base64,");
    }

    function _attribute(string memory json, uint256 index) internal pure returns (string memory) {
        return vm.parseJsonString(json, string.concat(".attributes[", vm.toString(index), "].value"));
    }

    function test_metadataReaderHandlesBase64Padding() public pure {
        assertEq(_decode("x:Zg==", "x:"), "f");
        assertEq(_decode("x:Zm8=", "x:"), "fo");
        assertEq(_decode("x:Zm9v", "x:"), "foo");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_artworkAndJSONEncodeDistinctIDsAndExactActivity(
        uint16 rawId,
        uint16 rawDistance,
        uint64 score,
        uint64 lastActive,
        bool active
    ) public pure {
        uint256 id = bound(rawId, 1, 2500);
        uint256 other = (id - 1 + bound(rawDistance, 1, 2499)) % 2500 + 1;
        string memory json =
            _decode(SwarmlerArt.uri(id, active, lastActive, score, 0, true), "data:application/json;base64,");
        string memory otherJson = _decode(
            SwarmlerArt.uri(other, active, lastActive, score, 0, true), "data:application/json;base64,"
        );
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Swarmler #", vm.toString(id)));
        assertEq(_attribute(json, 1), active ? "Active" : "Dormant");
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), score);
        assertEq(vm.parseJsonUint(json, ".attributes[3].value"), lastActive);
        assertEq(_attribute(json, 4), "Yes");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 0);
        string memory svg = _decode(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        string memory otherSvg =
            _decode(vm.parseJsonString(otherJson, ".image"), "data:image/svg+xml;base64,");
        assertNotEq(svg, otherSvg, "two IDs share their actual embedded image");
        bytes memory xml = bytes(svg);
        assertEq(xml[0], "<");
        assertEq(xml[1], "s");
        assertEq(xml[2], "v");
        assertEq(xml[3], "g");
        assertEq(xml[xml.length - 1], ">");
    }

    function test_metadataTracksPairingScoreExpiryAndCurrentOwnership() public {
        uint256 id = _mint(alice);
        string memory json = _json(id);
        assertEq(_attribute(json, 1), "Dormant");
        assertEq(_attribute(json, 4), "No");
        _activeIdentity(alice, 0);
        vm.expectEmit(true, true, false, true, address(nft));
        emit Swarmlers.Paired(id, 0);
        vm.prank(alice);
        nft.pair(id, 0);
        json = _json(id);
        string memory image = vm.parseJsonString(json, ".image");
        assertEq(_attribute(json, 1), "Active");
        assertEq(_attribute(json, 4), "Yes");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), 0);
        skip(1);
        vm.prank(reporter);
        activity.recordActivity(0, alice, uint64(vm.getBlockTimestamp()), type(uint64).max, true);
        json = _json(id);
        assertEq(vm.parseJsonUint(json, ".attributes[2].value"), type(uint64).max);
        assertEq(vm.parseJsonUint(json, ".attributes[3].value"), vm.getBlockTimestamp());
        skip(7 days + 1);
        json = _json(id);
        assertEq(_attribute(json, 1), "Dormant");
        assertNotEq(vm.parseJsonString(json, ".image"), image);
        vm.prank(reporter);
        activity.recordActivity(0, alice, uint64(vm.getBlockTimestamp()), 10, true);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(_attribute(_json(id), 1), "Dormant", "NFT buyer inherited another holder's attestation");
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        assertEq(_attribute(_json(id), 1), "Dormant", "identity transfer inherited the seller's attestation");
        vm.prank(reporter);
        activity.recordActivity(0, bob, uint64(vm.getBlockTimestamp()), 20, true);
        assertEq(_attribute(_json(id), 1), "Active");
    }

    function test_metadataRefreshEventAndNonexistentIDs() public {
        vm.expectEmit(false, false, false, true, address(nft));
        emit Swarmlers.MetadataUpdate(1);
        vm.prank(bob);
        nft.refreshMetadata(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 0));
        nft.refreshMetadata(0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 2501));
        nft.rarity(2501);
        assertFalse(nft.supportsInterface(0xffffffff));
    }
}
