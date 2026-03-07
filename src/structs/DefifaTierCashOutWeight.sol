// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @custom:member id The tier's ID.
/// @custom:member cashOutWeight The weight that all tokens of this tier can be cashed out for.
struct DefifaTierCashOutWeight {
    uint256 id;
    uint256 cashOutWeight;
}
