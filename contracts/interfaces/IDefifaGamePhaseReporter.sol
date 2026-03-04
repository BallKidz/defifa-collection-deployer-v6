// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DefifaGamePhase} from "./../enums/DefifaGamePhase.sol";

interface IDefifaGamePhaseReporter {
    function currentGamePhaseOf(uint256 gameId) external view returns (DefifaGamePhase);
}
