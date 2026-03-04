// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @custom:member token The token being used by the game.
/// @custom:member start The time at which the game should start, measured in seconds.
/// @custom:member mintPeriodDuration The duration of the game's mint phase, measured in seconds.
/// @custom:member mintPeriodDuration The time between the mint phase and the start time when mint's are no longer open but refunds are still allowed, measured in seconds.
struct DefifaOpsData {
    address token;
    uint48 start;
    uint24 mintPeriodDuration;
    uint24 refundPeriodDuration;
}
