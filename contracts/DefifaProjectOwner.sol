// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {DefifaDeployer} from "./DefifaDeployer.sol";

/// @notice A contract that can be sent a project to be burned, while still allowing defifa permissions.
contract DefifaProjectOwner is IERC721Receiver {
    /// @notice The contract where operator permissions are stored.
    IJBOperatorStore public operatorStore;

    /// @notice The contract from which project are minted.
    IJBProjects public projects;

    /// @notice The Defifa deployer.
    DefifaDeployer public deployer;

    /// @param _operatorStore The contract where operator permissions are stored.
    /// @param _projects The contract from which project are minted.
    /// @param _deployer The Defifa deployer which will receive permissions to set splits.
    constructor(IJBOperatorStore _operatorStore, IJBProjects _projects, DefifaDeployer _deployer) {
        operatorStore = _operatorStore;
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
        uint256[] memory _permissionIndexes = new uint256[](1);
        _permissionIndexes[0] = JBOperations.SET_SPLITS;

        // Give the defifa deployer contract permission to set splits on this contract's behalf.
        operatorStore.setOperator(
            JBOperatorData({operator: address(deployer), domain: _tokenId, permissionIndexes: _permissionIndexes})
        );

        return IERC721Receiver.onERC721Received.selector;
    }
}
