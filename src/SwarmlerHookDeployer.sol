// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SwarmlerFeeHook} from "./SwarmlerFeeHook.sol";

/// @notice Launchable helper; the permission-addressed hook is created after launch with a mined salt.
/// @dev Runtime receives the exact approved creation code, avoiding an oversized embedded child runtime.
///      The PoolManager is a constructor argument stored without a code probe, because launch constructors
///      run on an empty chain; its code is required on first use.
contract SwarmlerHookDeployer is Ownable2Step {
    bytes32 public immutable hookCreationCodeHash;
    address public immutable collection;
    address public immutable launchToken;
    address public immutable poolManager;
    address public hook;

    error InvalidConfiguration();
    error PoolManagerNotDeployed();
    error AlreadyDeployed();
    error WrongCreationCode();
    error DeploymentFailed();

    event HookDeployed(address indexed hook, bytes32 indexed salt, address indexed hookOwner);

    constructor(address initialOwner, address nftCollection, address token, address manager)
        Ownable(initialOwner)
    {
        if (nftCollection == address(0) || token == address(0) || manager == address(0)) {
            revert InvalidConfiguration();
        }
        collection = nftCollection;
        launchToken = token;
        poolManager = manager;
        hookCreationCodeHash = keccak256(type(SwarmlerFeeHook).creationCode);
    }

    function initCodeHash(bytes calldata creationCode) public view returns (bytes32) {
        return keccak256(_initCode(creationCode));
    }

    function predict(bytes calldata creationCode, bytes32 salt) external view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash(creationCode)))
                )
            )
        );
    }

    function deploy(bytes calldata creationCode, bytes32 salt) external onlyOwner returns (address deployed) {
        if (hook != address(0)) revert AlreadyDeployed();
        bytes memory code = _initCode(creationCode);
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        if (deployed == address(0)) revert DeploymentFailed();
        hook = deployed;
        emit HookDeployed(deployed, salt, owner());
    }

    function renounceOwnership() public view override onlyOwner {
        revert InvalidConfiguration();
    }

    function _initCode(bytes calldata creationCode) private view returns (bytes memory) {
        if (poolManager.code.length == 0) revert PoolManagerNotDeployed();
        if (keccak256(creationCode) != hookCreationCodeHash) revert WrongCreationCode();
        return abi.encodePacked(creationCode, abi.encode(owner(), poolManager, collection, launchToken));
    }
}
