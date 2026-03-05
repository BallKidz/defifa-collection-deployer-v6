// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefifaScorecardState} from "../enums/DefifaScorecardState.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";
import {IDefifaHook} from "./IDefifaHook.sol";
import {IJBController} from "@bananapus/core-v5/src/interfaces/IJBController.sol";

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

    function MAX_ATTESTATION_POWER_TIER() external view returns (uint256);

    function controller() external view returns (IJBController);

    function defaultAttestationDelegateProposalOf(uint256 gameId) external view returns (uint256);

    function ratifiedScorecardIdOf(uint256 gameId) external view returns (uint256);

    function scorecardIdOf(address _gameHook, DefifaTierCashOutWeight[] calldata _tierWeights)
        external
        returns (uint256);

    function stateOf(uint256 gameId, uint256 scorecardId) external view returns (DefifaScorecardState);

    function getAttestationWeight(uint256 gameId, address account, uint48 timestamp)
        external
        view
        returns (uint256 attestationPower);

    function attestationCountOf(uint256 gameId, uint256 scorecardId) external view returns (uint256);

    function hasAttestedTo(uint256 gameId, uint256 scorecardId, address account) external view returns (bool);

    function attestationStartTimeOf(uint256 gameId) external view returns (uint256);

    function attestationGracePeriodOf(uint256 gameId) external view returns (uint256);

    function quorum(uint256 gameId) external view returns (uint256);

    function initializeGame(uint256 gameId, uint256 attestationStartTime, uint256 attestationGracePeriod) external;

    function submitScorecardFor(uint256 gameId, DefifaTierCashOutWeight[] calldata tierWeights)
        external
        returns (uint256);

    function attestToScorecardFrom(uint256 gameId, uint256 scorecardId) external returns (uint256 weight);

    function ratifyScorecardFrom(uint256 gameId, DefifaTierCashOutWeight[] calldata tierWeights)
        external
        returns (uint256);
}
