// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @custom:member name The name of the tier.
/// @custom:member reservedRate The number of minted tokens needed in the tier to allow for minting another reserved token.
/// @custom:member reservedRateBeneficiary The beneificary of the reserved tokens for this tier.
/// @custom:member encodedIPFSUri The URI to use for each token within the tier.
/// @custom:member shouldUseReservedRateBeneficiaryAsDefault A flag indicating if the `reservedTokenBeneficiary` should be stored as the default beneficiary for all tiers, saving storage.
struct DefifaTierParams {
    string name;
    uint16 reservedRate;
    address reservedTokenBeneficiary;
    bytes32 encodedIPFSUri;
    bool shouldUseReservedTokenBeneficiaryAsDefault;
}
