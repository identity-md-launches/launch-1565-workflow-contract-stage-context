// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Fully on-chain, deterministic artwork. Rarity is disclosed, not random.
library SwarmlerArt {
    using Strings for uint256;

    function rarity(uint256 id) internal pure returns (string memory) {
        uint256 roll = (id * 7919) % 2500;
        if (roll < 1500) return "Common";
        if (roll < 2125) return "Uncommon";
        if (roll < 2375) return "Rare";
        if (roll < 2475) return "Epic";
        return "Legendary";
    }

    // Twelve binary markings encode the ID, giving each of the 2,500 spiders a distinct body pattern.
    function _sigil(uint256 id, string memory color) private pure returns (string memory pattern) {
        for (uint256 bit; bit < 12; ++bit) {
            pattern = string.concat(
                pattern,
                '<circle cx="',
                (185 + (bit % 3) * 15).toString(),
                '" cy="',
                (193 + (bit / 3) * 11).toString(),
                '" r="3" fill="',
                color,
                '" opacity="',
                ((id >> bit) & 1) == 1 ? "1" : "0.15",
                '"/>'
            );
        }
    }

    function uri(uint256 id, bool active, uint256 lastActive, uint256 score, uint256 identityId, bool paired)
        internal
        pure
        returns (string memory)
    {
        string memory color = string.concat("hsl(", ((id * 137) % 360).toString(), ",80%,65%)");
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#090d19"/><g stroke="',
            color,
            '" stroke-width="5" fill="none"><path d="M180 185L100 130L60 75M175 200L85 185L35 135',
            "M175 220L85 240L40 285M180 240L115 295L100 345M220 185L300 130L340 75",
            'M225 200L315 185L365 135M225 220L315 240L360 285M220 240L285 295L300 345"/>',
            '<ellipse cx="200" cy="220" rx="',
            (32 + id % 17).toString(),
            '" ry="55" fill="#151d32"/>',
            '<circle cx="200" cy="167" r="30" fill="#151d32"/></g><g fill="',
            color,
            '"><circle cx="190" cy="160" r="',
            active ? "7" : "3",
            '"/><circle cx="210" cy="160" r="',
            active ? "7" : "3",
            '"/></g>',
            _sigil(id, color),
            '<text x="200" y="250" text-anchor="middle" fill="white" font-family="monospace" font-size="18">',
            id.toString(),
            '</text><text x="200" y="35" text-anchor="middle" fill="',
            color,
            '" font-family="monospace" font-size="18">SWARMLER #',
            id.toString(),
            '</text><text x="200" y="380" text-anchor="middle" fill="white" font-family="monospace">',
            rarity(id),
            active ? " / ACTIVE" : " / DORMANT",
            "</text></svg>"
        );
        bytes memory json = abi.encodePacked(
            '{"name":"Swarmler #',
            id.toString(),
            '","description":"Unique spider-crawler agent. Activity is attested; lifetime rewards follow the NFT.",',
            '"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"Rarity","value":"',
            rarity(id),
            '"},{"trait_type":"Agent status","value":"',
            active ? "Active" : "Dormant",
            '"},{"trait_type":"Activity score","value":',
            score.toString(),
            '},{"trait_type":"Last active","display_type":"date","value":',
            lastActive.toString(),
            '},{"trait_type":"Paired","value":"',
            paired ? "Yes" : "No",
            '"},{"trait_type":"Identity ID","value":',
            identityId.toString(),
            "}]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }
}
