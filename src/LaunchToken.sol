// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Launch-policy ERC-20, distinct from the 2,500 Swarmler NFTs.
contract LaunchToken is ERC20 {
    constructor() ERC20("Swarmlers", "SWARMLER") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
