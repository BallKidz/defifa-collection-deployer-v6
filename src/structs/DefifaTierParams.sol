// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

/// @custom:member name The name of the tier.
/// @custom:member reservedRate The number of minted tokens needed in the tier to allow for minting another reserved
/// token.
/// @custom:member reservedRateBeneficiary The beneficiary of the reserved tokens for this tier.
/// @custom:member encodedIPFSUri The URI to use for each token within the tier.
/// @custom:member shouldUseReservedRateBeneficiaryAsDefault A flag indicating if the `reservedTokenBeneficiary` should
/// be stored as the default beneficiary for all tiers, saving storage.
/// @custom:member splits The splits to route tier split funds to when an NFT from this tier is minted.
struct DefifaTierParams {
    string name;
    uint16 reservedRate;
    address reservedTokenBeneficiary;
    bytes32 encodedIPFSUri;
    bool shouldUseReservedTokenBeneficiaryAsDefault;
    JBSplit[] splits;
}
