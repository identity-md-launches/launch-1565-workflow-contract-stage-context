// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./Fixture.sol";
import {V4Actions} from "./V4Actions.sol";
import {MineHookSalt} from "../../script/MineHookSalt.s.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {SwarmlerFeeHook} from "src/SwarmlerFeeHook.sol";
import {SwarmlerHookDeployer} from "src/SwarmlerHookDeployer.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @dev Real CREATE2 hook and vendored PoolManager; only IMD/Identity are local doubles.
abstract contract HookFixture is Fixture {
    LaunchToken internal token;
    PoolManager internal manager;
    V4Actions internal actions;
    SwarmlerHookDeployer internal deployer;
    SwarmlerFeeHook internal hook;
    PoolKey internal key;

    function setUp() public virtual override {
        super.setUp();
        token = new LaunchToken();
        manager = new PoolManager(address(this));
        actions = new V4Actions(manager);
        deployer = new SwarmlerHookDeployer(address(this), address(nft), address(token));
        deployer.setPoolManager(address(manager));
        hook = _deployHook(deployer);
        key = hook.poolKey();
        manager.initialize(key, uint160(1 << 96));
    }

    function _deployHook(SwarmlerHookDeployer factory) internal returns (SwarmlerFeeHook) {
        bytes memory code = type(SwarmlerFeeHook).creationCode;
        (bytes32 salt,) = new MineHookSalt().run(address(factory), factory.initCodeHash(code), 0, 1_000_000);
        return SwarmlerFeeHook(factory.deploy(code, salt));
    }
}
