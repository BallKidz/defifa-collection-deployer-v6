// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @custom:member id The tier's ID.
/// @custom:member redemptionWeight the weight that all tokens of this tier can be redeemed for.
struct DefifaTierCashOutWeight {
    uint256 id;
    uint256 cashOutWeight;
}
