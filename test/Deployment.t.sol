// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SwarmlerActivity} from "../src/SwarmlerActivity.sol";
import {Swarmlers} from "../src/Swarmlers.sol";
import {SwarmlerHookDeployer} from "../src/SwarmlerHookDeployer.sol";
import {SwarmlerConstants} from "../src/SwarmlerConstants.sol";

contract DeploymentTest is Test {
    address internal constant LAUNCH_OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;

    function test_factoryConstructorsOnEmptyChainPreserveSupplyAndOwnership() public {
        vm.chainId(1);
        assertEq(SwarmlerConstants.IMD.code.length, 0);
        assertEq(SwarmlerConstants.IDENTITY.code.length, 0);
        LaunchToken token = new LaunchToken();
        SwarmlerActivity activity = new SwarmlerActivity(LAUNCH_OWNER);
        Swarmlers nft = new Swarmlers(LAUNCH_OWNER, address(activity));
        SwarmlerHookDeployer deployer = new SwarmlerHookDeployer(LAUNCH_OWNER, address(nft), address(token));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(address(nft)), 0);
        assertEq(activity.owner(), LAUNCH_OWNER);
        assertEq(nft.owner(), LAUNCH_OWNER);
        assertEq(deployer.owner(), LAUNCH_OWNER);
        assertEq(activity.reporter(), address(0));
        assertEq(deployer.poolManager(), address(0));
        assertEq(deployer.hook(), address(0));
        assertFalse(nft.publicMintOpen());
        assertEq(nft.ownerOf(1), SwarmlerConstants.CREATOR);
        _runtime(address(token));
        _runtime(address(activity));
        _runtime(address(nft));
        _runtime(address(deployer));
    }

    function _runtime(address deployed) internal view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
