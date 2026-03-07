// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DefifaGamePhase} from "./../enums/DefifaGamePhase.sol";

interface IDefifaGamePhaseReporter {
    function currentGamePhaseOf(uint256 gameId) external view returns (DefifaGamePhase);
}
