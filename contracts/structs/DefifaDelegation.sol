// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @custom:member delegatee The account to delegate tier voting units to.
/// @custom:member tierId The ID of the tier to delegate voting units for.
struct DefifaDelegation {
    address delegatee;
    uint256 tierId;
}
