// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {DefifaLaunchProjectData} from "../structs/DefifaLaunchProjectData.sol";
import {DefifaOpsData} from "../structs/DefifaOpsData.sol";
import {IDefifaDelegate} from "./IDefifaDelegate.sol";
import {IDefifaGovernor} from "./IDefifaGovernor.sol";

interface IDefifaDeployer {
    event LaunchGame(
        uint256 indexed gameId,
        IDefifaDelegate indexed delegate,
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
        JBSplit[] splits,
        uint256 leftoverAmount,
        uint256 defifaTokenBalance,
        uint256 baseProtocolBalance,
        address caller
    );

    event DistributeToSplit(JBSplit split, uint256 amount, address caller);

    function splitGroup() external view returns (uint256);

    function defifaProjectId() external view returns (uint256);

    function baseProtocolProjectId() external view returns (uint256);

    function delegateCodeOrigin() external view returns (address);

    function tokenUriResolver() external view returns (IJB721TokenUriResolver);

    function governor() external view returns (IDefifaGovernor);

    function controller() external view returns (IJBController3_1);

    function delegatesRegistry() external view returns (IJBDelegatesRegistry);

    function feeDivisor() external view returns (uint256);

    function timesFor(uint256 _gameId) external view returns (uint48, uint24, uint24);

    function tokenOf(uint256 _gameId) external view returns (address);

    function nextPhaseNeedsQueueing(uint256 _gameId) external view returns (bool);

    function launchGameWith(DefifaLaunchProjectData calldata _launchProjectData) external returns (uint256 gameId);

    function queueNextPhaseOf(uint256 _projectId) external returns (uint256 configuration);

    function fulfillCommitmentsOf(uint256 _gameId) external;
}
