// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {DefifaDeployer} from "./DefifaDeployer.sol";
import {IJBPermissions, JBPermissionsData} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v5/src/JBPermissionIds.sol";

/// @notice A contract that can be sent a project to be burned, while still allowing defifa permissions.
/// @dev Once the project NFT is transferred here, it cannot be recovered. This contract permanently
/// holds the project NFT and grants SET_SPLIT_GROUPS permission to the Defifa deployer.
contract DefifaProjectOwner is IERC721Receiver {
    /// @notice The contract where operator permissions are stored.
    IJBPermissions public permissions;

    /// @notice The contract from which project are minted.
    IJBProjects public projects;

    /// @notice The Defifa deployer.
    DefifaDeployer public deployer;

    /// @param _permissions The contract where operator permissions are stored.
    /// @param _projects The contract from which project are minted.
    /// @param _deployer The Defifa deployer which will receive permissions to set splits.
    constructor(IJBPermissions _permissions, IJBProjects _projects, DefifaDeployer _deployer) {
        permissions = _permissions;
        projects = _projects;
        deployer = _deployer;
    }

    /// @notice Give the defifa deployer permission to set splits on this contract's behalf.
    function onERC721Received(address _operator, address _from, uint256 _tokenId, bytes calldata _data)
        external
        returns (bytes4)
    {
        _data;
        _from;
        _operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(projects)) revert();

        // Set the correct permission.
        uint8[] memory _permissionIds = new uint8[](1);
        _permissionIds[0] = JBPermissionIds.SET_SPLIT_GROUPS;

        // Give the defifa deployer contract permission to set splits on this contract's behalf.
        permissions.setPermissionsFor(
            address(this),
            JBPermissionsData({operator: address(deployer), projectId: uint64(_tokenId), permissionIds: _permissionIds})
        );

        return IERC721Receiver.onERC721Received.selector;
    }
}
