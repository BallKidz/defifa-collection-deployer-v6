// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefifaLaunchProjectData} from "../structs/DefifaLaunchProjectData.sol";
import {DefifaOpsData} from "../structs/DefifaOpsData.sol";
import {IDefifaHook} from "./IDefifaHook.sol";
import {IDefifaGovernor} from "./IDefifaGovernor.sol";

import {IJB721TokenUriResolver} from '@bananapus/721-hook-v5/src/interfaces/IJB721TokenUriResolver.sol';
import {JBSplit} from '@bananapus/core-v5/src/structs/JBSplit.sol';
import {IJBController} from '@bananapus/core-v5/src/interfaces/IJBController.sol';
import {IJBAddressRegistry} from '@bananapus/address-registry-v5/src/interfaces/IJBAddressRegistry.sol';

interface IDefifaDeployer {
    event LaunchGame(
        uint256 indexed gameId,
        IDefifaHook indexed hook,
        IDefifaGovernor indexed governor,
        IJB721TokenUriResolver tokenUriResolver,
        address caller
    );

    event QueuedRefundPhase(uint256 indexed gameId, address caller);

    event QueuedScoringPhase(uint256 indexed gameId, address caller);

    event QueuedNoContest(uint256 indexed gameId, address caller);

    event FulfilledCommitments(
        uint256 indexed gameId,
        uint256 pot,
        address caller
    );

    event DistributeToSplit(JBSplit split, uint256 amount, address caller);

    function splitGroup() external view returns (uint256);

    function defifaProjectId() external view returns (uint256);

    function baseProtocolProjectId() external view returns (uint256);

    function hookCodeOrigin() external view returns (address);

    function tokenUriResolver() external view returns (IJB721TokenUriResolver);

    function governor() external view returns (IDefifaGovernor);

    function controller() external view returns (IJBController);

    function registry() external view returns (IJBAddressRegistry);

    function DEFIFA_FEE_DIVISOR() external view returns (uint256);

    function BASE_PROTOCOL_FEE_DIVISOR() external view returns (uint256);

    function timesFor(uint256 _gameId) external view returns (uint48, uint24, uint24);

    function tokenOf(uint256 _gameId) external view returns (address);

    function nextPhaseNeedsQueueing(uint256 _gameId) external view returns (bool);

    function launchGameWith(DefifaLaunchProjectData calldata _launchProjectData) external returns (uint256 gameId);

    // function queueNextPhaseOf(uint256 _projectId) external returns (uint256 configuration);

    function fulfillCommitmentsOf(uint256 _gameId) external;
}
