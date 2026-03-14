// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DefifaLaunchProjectData} from "../structs/DefifaLaunchProjectData.sol";
import {IDefifaHook} from "./IDefifaHook.sol";
import {IDefifaGovernor} from "./IDefifaGovernor.sol";

import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBAddressRegistry} from "@bananapus/address-registry-v6/src/interfaces/IJBAddressRegistry.sol";

/// @notice Deploys and manages Defifa prediction games, including lifecycle phase transitions
/// and commitment fulfillment.
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

    event FulfilledCommitments(uint256 indexed gameId, uint256 pot, address caller);

    event DistributeToSplit(JBSplit split, uint256 amount, address caller);

    /// @notice The split group ID used for distributing game pot funds.
    /// @return The split group.
    function SPLIT_GROUP() external view returns (uint256);

    /// @notice The Juicebox project ID of the Defifa project.
    /// @return The project ID.
    function DEFIFA_PROJECT_ID() external view returns (uint256);

    /// @notice The Juicebox project ID of the base protocol project.
    /// @return The project ID.
    function BASE_PROTOCOL_PROJECT_ID() external view returns (uint256);

    /// @notice The code origin address used as an implementation for hook clones.
    /// @return The code origin address.
    function HOOK_CODE_ORIGIN() external view returns (address);

    /// @notice The token URI resolver used for game NFT metadata.
    /// @return The token URI resolver contract.
    function TOKEN_URI_RESOLVER() external view returns (IJB721TokenUriResolver);

    /// @notice The governor contract used for scorecard governance.
    /// @return The governor contract.
    function GOVERNOR() external view returns (IDefifaGovernor);

    /// @notice The Juicebox controller used to manage projects.
    /// @return The controller contract.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The address registry used for content-addressable deployment lookups.
    /// @return The address registry contract.
    function REGISTRY() external view returns (IJBAddressRegistry);

    /// @notice The fee divisor for Defifa fees (100 / fee percent).
    /// @return The fee divisor.
    function DEFIFA_FEE_DIVISOR() external view returns (uint256);

    /// @notice The fee divisor for base protocol fees (100 / fee percent).
    /// @return The fee divisor.
    function BASE_PROTOCOL_FEE_DIVISOR() external view returns (uint256);

    /// @notice The timing parameters for a game.
    /// @param gameId The ID of the game.
    /// @return The mint duration, start time, and refund period.
    function timesFor(uint256 gameId) external view returns (uint48, uint24, uint24);

    /// @notice The token address for a game.
    /// @param gameId The ID of the game.
    /// @return The token address.
    function tokenOf(uint256 gameId) external view returns (address);

    /// @notice The safety parameters for a game.
    /// @param gameId The ID of the game.
    /// @return minParticipation The minimum participation threshold.
    /// @return scorecardTimeout The scorecard timeout duration.
    function safetyParamsOf(uint256 gameId) external view returns (uint256 minParticipation, uint32 scorecardTimeout);

    /// @notice Whether the next game phase needs to be queued.
    /// @param gameId The ID of the game.
    /// @return True if the next phase needs queueing.
    function nextPhaseNeedsQueueing(uint256 gameId) external view returns (bool);

    /// @notice Launch a new Defifa game.
    /// @param launchProjectData The configuration for launching the game.
    /// @return gameId The ID of the newly launched game.
    function launchGameWith(DefifaLaunchProjectData calldata launchProjectData) external returns (uint256 gameId);

    /// @notice Fulfill the commitments of a game by distributing the pot.
    /// @param gameId The ID of the game.
    function fulfillCommitmentsOf(uint256 gameId) external;

    /// @notice Trigger a no-contest outcome for a game.
    /// @param gameId The ID of the game.
    function triggerNoContestFor(uint256 gameId) external;
}
