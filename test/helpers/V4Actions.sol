// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev TEST ONLY: minimal unlock/settlement adapter. Has deliberately no production LP custody rules.
contract V4Actions is IUnlockCallback {
    IPoolManager private immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function modify(PoolKey memory key, int256 liquidity)
        external
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(liquidity))),
            (BalanceDelta, BalanceDelta)
        );
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return
            abi.decode(
                manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(params))), (BalanceDelta)
            );
    }

    function donate(PoolKey memory key, uint256 a, uint256 b) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, abi.encode(a, b)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory params) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            BalanceDelta fees;
            (delta, fees) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams(-600, 600, abi.decode(params, (int256)), bytes32(0)),
                ""
            );
            result = abi.encode(delta, fees);
        } else if (action == 1) {
            delta = manager.swap(key, abi.decode(params, (IPoolManager.SwapParams)), "");
            result = abi.encode(delta);
        } else {
            (uint256 a, uint256 b) = abi.decode(params, (uint256, uint256));
            delta = manager.donate(key, a, b, "");
        }
        _settle(key.currency0, payer, delta.amount0());
        _settle(key.currency1, payer, delta.amount1());
    }

    function _settle(Currency currency, address payer, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(
                IERC20(Currency.unwrap(currency))
                    .transferFrom(payer, address(manager), uint256(-int256(delta)))
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint128(delta));
        }
    }
}
