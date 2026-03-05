// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {DefifaScorecardState} from "../enums/DefifaScorecardState.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";
import {IDefifaHook} from "./IDefifaHook.sol";
import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";

/// @notice Manages the ratification of Defifa scorecards through attestation-based governance.
interface IDefifaGovernor {
    event GameInitialized(
        uint256 indexed gameId, uint256 attestationStartTime, uint256 attestationGracePeriod, address caller
    );

    event ScorecardSubmitted(
        uint256 indexed gameId,
        uint256 indexed scorecardId,
        DefifaTierCashOutWeight[] tierWeights,
        bool isDefaultAttestationDelegate,
        address caller
    );

    event ScorecardAttested(uint256 indexed gameId, uint256 indexed scorecardId, uint256 weight, address caller);

    event ScorecardRatified(uint256 indexed gameId, uint256 indexed scorecardId, address caller);

    /// @notice The maximum tier ID that contributes attestation power.
    /// @return The maximum attestation power tier.
    function MAX_ATTESTATION_POWER_TIER() external view returns (uint256);

    /// @notice The Juicebox controller used to manage projects.
    /// @return The controller contract.
    function controller() external view returns (IJBController);

    /// @notice The scorecard proposal submitted by the default attestation delegate for a game.
    /// @param gameId The ID of the game.
    /// @return The scorecard ID.
    function defaultAttestationDelegateProposalOf(uint256 gameId) external view returns (uint256);

    /// @notice The ID of the ratified scorecard for a game.
    /// @param gameId The ID of the game.
    /// @return The ratified scorecard ID, or 0 if none.
    function ratifiedScorecardIdOf(uint256 gameId) external view returns (uint256);

    /// @notice Compute the scorecard ID for a given hook and tier weights.
    /// @param gameHook The game hook address.
    /// @param tierWeights The tier cash out weights.
    /// @return The scorecard ID.
    function scorecardIdOf(address gameHook, DefifaTierCashOutWeight[] calldata tierWeights) external returns (uint256);

    /// @notice The state of a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The scorecard state.
    function stateOf(uint256 gameId, uint256 scorecardId) external view returns (DefifaScorecardState);

    /// @notice Get the attestation weight for an account at a specific timestamp.
    /// @param gameId The ID of the game.
    /// @param account The account to check.
    /// @param timestamp The timestamp to check.
    /// @return attestationPower The attestation power.
    function getAttestationWeight(
        uint256 gameId,
        address account,
        uint48 timestamp
    )
        external
        view
        returns (uint256 attestationPower);

    /// @notice The number of attestations for a scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @return The attestation count.
    function attestationCountOf(uint256 gameId, uint256 scorecardId) external view returns (uint256);

    /// @notice Whether an account has attested to a specific scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard.
    /// @param account The account to check.
    /// @return True if the account has attested.
    function hasAttestedTo(uint256 gameId, uint256 scorecardId, address account) external view returns (bool);

    /// @notice The timestamp when attestation begins for a game.
    /// @param gameId The ID of the game.
    /// @return The attestation start time.
    function attestationStartTimeOf(uint256 gameId) external view returns (uint256);

    /// @notice The grace period after attestation starts during which attestation is still allowed.
    /// @param gameId The ID of the game.
    /// @return The grace period in seconds.
    function attestationGracePeriodOf(uint256 gameId) external view returns (uint256);

    /// @notice The quorum required to ratify a scorecard.
    /// @param gameId The ID of the game.
    /// @return The quorum threshold.
    function quorum(uint256 gameId) external view returns (uint256);

    /// @notice Initialize a game's governance parameters.
    /// @param gameId The ID of the game.
    /// @param attestationStartTime The timestamp when attestation begins.
    /// @param attestationGracePeriod The grace period duration in seconds.
    function initializeGame(uint256 gameId, uint256 attestationStartTime, uint256 attestationGracePeriod) external;

    /// @notice Submit a scorecard for attestation.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash out weights.
    /// @return The scorecard ID.
    function submitScorecardFor(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256);

    /// @notice Attest to a submitted scorecard.
    /// @param gameId The ID of the game.
    /// @param scorecardId The ID of the scorecard to attest to.
    /// @return weight The attestation weight applied.
    function attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external returns (uint256 weight);

    /// @notice Ratify a scorecard that has reached quorum.
    /// @param gameId The ID of the game.
    /// @param tierWeights The tier cash out weights (must match the scorecard).
    /// @return The scorecard ID that was ratified.
    function ratifyScorecardFrom(
        uint256 gameId,
        DefifaTierCashOutWeight[] calldata tierWeights
    )
        external
        returns (uint256);
}
