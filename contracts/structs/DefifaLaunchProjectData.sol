// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefifaTierParams} from "./DefifaTierParams.sol";
import {DefifaOpsData} from "./DefifaOpsData.sol";

import {JBLaunchProjectConfig} from "@bananapus/721-hook-v5/src/structs/JBLaunchProjectConfig.sol";
import {JBAccountingContext} from "@bananapus/core-v5/src/structs/JBAccountingContext.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v5/src/interfaces/IJB721TokenUriResolver.sol";
import {IJBTerminal} from "@bananapus/core-v5/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v5/src/structs/JBSplit.sol";

/// @custom:member name The name of the game being created.
/// @custom:member projectUri Metadata to associate with the project.
/// @custom:member contractUri The URI to associate with the 721.
/// @custom:member baseUri The URI base to prepend onto any tier token URIs.
/// @custom:member tiers Parameters describing the tiers.
/// @custom:member tierPrice The uniform price for all tiers. All tiers use the same price so that price-based voting
/// power is equal across tiers.
/// @custom:member token The token configuration the game is played with.
/// @custom:member mintPeriodDuration The duration of the game's mint phase, measured in seconds.
/// @custom:member refundPeriodDuration The time between the mint phase and the start time when mint's are no longer open but refunds are still allowed, measured in seconds.
/// @custom:member start The time at which the game should start, measured in seconds.
/// @custom:member splits Splits to distribute funds between during the game's scoring phase.
/// @custom:member attestationStartTime The time the attestations will start for all submitted scorecards, measured in seconds. If in the past, scorecards will start accepting attestations right away.
/// @custom:member attestationGracePeriod The time period the attestations must be active for once it has started even if it has already reached quorum, measured in seconds.
/// @custom:member defaultAttestationDelegate The address that'll be set as the attestation delegate by default.
/// @custom:member defaultTokenUriResolver The contract used to resolve token URIs if not provided by a tier specifically.
/// @custom:member terminal The payment terminal where the project will accept funds through.
/// @custom:member store A contract to store standard JB721 data in.
/// @custom:member minParticipation The minimum treasury balance required for the game to proceed to scoring. If the balance is below this when scoring would begin, the game enters NO_CONTEST. Set to 0 to disable.
/// @custom:member scorecardTimeout The maximum time (in seconds) after the scoring phase begins for a scorecard to be ratified. If exceeded, the game enters NO_CONTEST. Set to 0 to disable.
struct DefifaLaunchProjectData {
  string name;
  string projectUri;
  string contractUri;
  string baseUri;
  DefifaTierParams[] tiers;
  uint104 tierPrice;
  JBAccountingContext token;
  uint24 mintPeriodDuration;
  uint24 refundPeriodDuration;
  uint48 start;
  JBSplit[] splits;
  uint256 attestationStartTime;
  uint256 attestationGracePeriod;
  address defaultAttestationDelegate;
  IJB721TokenUriResolver defaultTokenUriResolver;
  IJBTerminal terminal;
  IJB721TiersHookStore store;
  uint256 minParticipation;
  uint32 scorecardTimeout;
}
