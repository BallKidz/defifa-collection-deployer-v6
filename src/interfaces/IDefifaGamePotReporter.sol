// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IDefifaGamePotReporter {
    function fulfilledCommitmentsOf(uint256 gameId) external view returns (uint256);

    function currentGamePotOf(uint256 gameId, bool includeCommitments) external view returns (uint256, address, uint256);
}
