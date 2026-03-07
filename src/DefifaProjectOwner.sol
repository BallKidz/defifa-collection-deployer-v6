// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {DefifaDeployer} from "./DefifaDeployer.sol";
import {IJBPermissions, JBPermissionsData} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

/// @notice A contract that can be sent a project to be burned, while still allowing defifa permissions.
/// @dev Once the project NFT is transferred here, it cannot be recovered. This contract permanently
/// holds the project NFT and grants SET_SPLIT_GROUPS permission to the Defifa deployer.
contract DefifaProjectOwner is IERC721Receiver {
    /// @notice The contract where operator permissions are stored.
    IJBPermissions public immutable PERMISSIONS;

    /// @notice The contract from which projects are minted.
    IJBProjects public immutable PROJECTS;

    /// @notice The Defifa deployer.
    DefifaDeployer public immutable DEPLOYER;

    /// @param permissions The contract where operator permissions are stored.
    /// @param projects The contract from which projects are minted.
    /// @param deployer The Defifa deployer which will receive permissions to set splits.
    constructor(IJBPermissions permissions, IJBProjects projects, DefifaDeployer deployer) {
        PERMISSIONS = permissions;
        PROJECTS = projects;
        DEPLOYER = deployer;
    }

    /// @notice Give the defifa deployer permission to set splits on this contract's behalf.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    )
        external
        returns (bytes4)
    {
        data;
        from;
        operator;

        // Make sure the 721 received is the JBProjects contract.
        if (msg.sender != address(PROJECTS)) revert();

        // Set the correct permission.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.SET_SPLIT_GROUPS;

        // Give the defifa deployer contract permission to set splits on this contract's behalf.
        PERMISSIONS.setPermissionsFor({
            account: address(this),
            permissionsData: JBPermissionsData({
                operator: address(DEPLOYER), projectId: uint64(tokenId), permissionIds: permissionIds
            })
        });

        return IERC721Receiver.onERC721Received.selector;
    }
}
