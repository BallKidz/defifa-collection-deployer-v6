// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @custom:member token The token being used by the game.
/// @custom:member start The time at which the game should start, measured in seconds.
/// @custom:member mintPeriodDuration The duration of the game's mint phase, measured in seconds.
/// @custom:member refundPeriodDuration The time between the mint phase and the start time when mint's are no longer open but refunds are still allowed, measured in seconds.
/// @custom:member minParticipation The minimum treasury balance required for the game to proceed to scoring. If the balance is below this when scoring would begin, the game enters NO_CONTEST. Set to 0 to disable.
/// @custom:member scorecardTimeout The maximum time (in seconds) after the scoring phase begins for a scorecard to be ratified. If exceeded, the game enters NO_CONTEST. Set to 0 to disable.
struct DefifaOpsData {
    address token;
    uint48 start;
    uint24 mintPeriodDuration;
    uint24 refundPeriodDuration;
    uint256 minParticipation;
    uint32 scorecardTimeout;
}
