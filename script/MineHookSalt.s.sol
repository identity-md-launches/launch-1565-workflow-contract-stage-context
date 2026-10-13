// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Local, pure salt search. No wallet, environment, RPC, FFI or broadcast needed.
contract MineHookSalt {
    error InvalidSearch();
    error SaltNotFound();

    function run(address deployer, bytes32 initCodeHash, uint256 start, uint256 attempts)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        if (deployer == address(0) || initCodeHash == bytes32(0) || attempts == 0 || attempts > 1_000_000) revert InvalidSearch();
        for (uint256 i; i < attempts; ++i) {
            salt = bytes32(start + i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x2503) return (salt, predicted);
        }
        revert SaltNotFound();
    }
}
