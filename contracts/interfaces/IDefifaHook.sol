// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBRulesets} from "@bananapus/core-v5/src/interfaces/IJBRulesets.sol";
import {IJB721Hook} from "@bananapus/721-hook-v5/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v5/src/interfaces/IJB721TokenUriResolver.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v5/src/structs/JB721TiersMintReservesConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v5/src/structs/JB721TierConfig.sol";
import {DefifaTierCashOutWeight} from "./../structs/DefifaTierCashOutWeight.sol";
import {DefifaDelegation} from "./../structs/DefifaDelegation.sol";
import {IDefifaGamePhaseReporter} from "./IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./IDefifaGamePotReporter.sol";

interface IDefifaHook is IJB721Hook {
    event Mint(
        uint256 indexed tokenId,
        uint256 indexed tierId,
        address indexed beneficiary,
        uint256 totalAmountContributed,
        address caller
    );

    event MintReservedToken(
        uint256 indexed tokenId, uint256 indexed tierId, address indexed beneficiary, address caller
    );

    event TierDelegateAttestationsChanged(
        address indexed delegate, uint256 indexed tierId, uint256 previousBalance, uint256 newBalance, address caller
    );

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);

    event ClaimedTokens(
        address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller
    );

    event TierCashOutWeightsSet(DefifaTierCashOutWeight[] _tierWeights, address caller);

    function TOTAL_CASHOUT_WEIGHT() external view returns (uint256);

    function defifaToken() external view returns (IERC20);

    function baseProtocolToken() external view returns (IERC20);

    function cashOutWeightOf(uint256 tokenId) external view returns (uint256);

    function tierCashOutWeights() external view returns (uint256[128] memory);

    function codeOrigin() external view returns (address);

    function cashOutWeightIsSet() external view returns (bool);

    function currentSupplyOfTier(uint256 _tierId) external view returns (uint256);

    function store() external view returns (IJB721TiersHookStore);

    function rulesets() external view returns (IJBRulesets);

    function gamePhaseReporter() external view returns (IDefifaGamePhaseReporter);

    function gamePotReporter() external view returns (IDefifaGamePotReporter);

    function amountRedeemed() external view returns (uint256);

    function tokenAllocations() external view returns (uint256, uint256);

    function tierNameOf(uint256 tierId) external view returns (string memory);

    function tokensRedeemedFrom(uint256 tierId) external view returns (uint256);

    function pricingCurrency() external view returns (uint256);

    function firstOwnerOf(uint256 tokenId) external view returns (address);

    function baseURI() external view returns (string memory);

    function contractURI() external view returns (string memory);

    function defaultAttestationDelegate() external view returns (address);

    function getTierDelegateOf(address account, uint256 tier) external view returns (address);

    function getTierAttestationUnitsOf(address account, uint256 tier) external view returns (uint256);

    function getPastTierAttestationUnitsOf(address account, uint256 tier, uint48 timestamp)
        external
        view
        returns (uint256);

    function getTierTotalAttestationUnitsOf(uint256 tier) external view returns (uint256);

    function getPastTierTotalAttestationUnitsOf(uint256 tier, uint48 timestamp) external view returns (uint256);

    function tokensClaimableFor(uint256[] memory _tokenIds) external view returns (uint256, uint256);

    function setTierDelegateTo(address delegatee, uint256 tierId) external;

    function setTierDelegatesTo(DefifaDelegation[] memory delegations) external;

    function setTierCashOutWeightsTo(DefifaTierCashOutWeight[] memory tierWeights) external;

    function mintReservesFor(JB721TiersMintReservesConfig[] memory mintReservesForTiersData) external;

    function mintReservesFor(uint256 tierId, uint256 count) external;

    function initialize(
        uint256 gameId,
        string memory name,
        string memory symbol,
        IJBRulesets rulesets,
        string memory baseUri,
        IJB721TokenUriResolver tokenUriResolver,
        string memory contractUri,
        JB721TierConfig [] memory tiers,
        uint48 currency,
        IJB721TiersHookStore store,
        IDefifaGamePhaseReporter gamePhaseReporter,
        IDefifaGamePotReporter gamePotReporter,
        address defaultAttestationDelegate,
        string[] memory tierNames
    ) external;
}
