// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmlerArt} from "../src/SwarmlerArt.sol";

contract ArtTest is Test {
    function test_exactRarityDistributionAcrossEntireCollection() public pure {
        uint256[5] memory counts;
        for (uint256 id = 1; id <= 2500; ++id) {
            bytes32 tier = keccak256(bytes(SwarmlerArt.rarity(id)));
            if (tier == keccak256("Common")) ++counts[0];
            else if (tier == keccak256("Uncommon")) ++counts[1];
            else if (tier == keccak256("Rare")) ++counts[2];
            else if (tier == keccak256("Epic")) ++counts[3];
            else if (tier == keccak256("Legendary")) ++counts[4];
            else revert("unknown tier");
        }
        assertEq(counts[0], 1500);
        assertEq(counts[1], 625);
        assertEq(counts[2], 250);
        assertEq(counts[3], 100);
        assertEq(counts[4], 25);
    }
}
