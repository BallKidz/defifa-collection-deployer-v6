// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBFundingCycleStore} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleStore.sol";
import {IJBDirectory} from "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import {IJB721Delegate} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJB721Delegate.sol";
import {IJBTiered721DelegateStore} from
    "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJBTiered721DelegateStore.sol";
import {IJB721TokenUriResolver} from "@jbx-protocol/juice-721-delegate/contracts/interfaces/IJB721TokenUriResolver.sol";
import {JB721TierParams} from "@jbx-protocol/juice-721-delegate/contracts/structs/JB721TierParams.sol";
import {JBTiered721SetTierDelegatesData} from
    "@jbx-protocol/juice-721-delegate/contracts/structs/JBTiered721SetTierDelegatesData.sol";
import {JBTiered721MintReservesForTiersData} from
    "@jbx-protocol/juice-721-delegate/contracts/structs/JBTiered721MintReservesForTiersData.sol";
import {JBTiered721MintForTiersData} from
    "@jbx-protocol/juice-721-delegate/contracts/structs/JBTiered721MintForTiersData.sol";
import {JB721PricingParams} from "@jbx-protocol/juice-721-delegate/contracts/structs/JB721PricingParams.sol";
import {DefifaTierRedemptionWeight} from "./../structs/DefifaTierRedemptionWeight.sol";
import {IDefifaGamePhaseReporter} from "./IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./IDefifaGamePotReporter.sol";

interface IDefifaDelegate is IJB721Delegate {
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

    event TierRedemptionWeightsSet(DefifaTierRedemptionWeight[] _tierWeights, address caller);

    function TOTAL_REDEMPTION_WEIGHT() external view returns (uint256);

    function PROJECT_ID() external view returns (uint256);

    function defifaToken() external view returns (IERC20);

    function baseProtocolToken() external view returns (IERC20);

    function name() external view returns (string memory);

    function redemptionWeightOf(uint256 tokenId) external view returns (uint256);

    function tierRedemptionWeights() external view returns (uint256[128] memory);

    function codeOrigin() external view returns (address);

    function redemptionWeightIsSet() external view returns (bool);

    function store() external view returns (IJBTiered721DelegateStore);

    function fundingCycleStore() external view returns (IJBFundingCycleStore);

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

    function getPastTierAttestationUnitsOf(address account, uint256 tier, uint256 blockNumber)
        external
        view
        returns (uint256);

    function getTierTotalAttestationUnitsOf(uint256 tier) external view returns (uint256);

    function getPastTierTotalAttestationUnitsOf(uint256 tier, uint256 blockNumber) external view returns (uint256);

    function tokensClaimableFor(uint256[] memory _tokenIds) external view returns (uint256, uint256);

    function setTierDelegateTo(address delegatee, uint256 tierId) external;

    function setTierDelegatesTo(JBTiered721SetTierDelegatesData[] memory setTierDelegatesData) external;

    function setTierRedemptionWeightsTo(DefifaTierRedemptionWeight[] memory tierWeights) external;

    function mintReservesFor(JBTiered721MintReservesForTiersData[] memory mintReservesForTiersData) external;

    function mintReservesFor(uint256 tierId, uint256 count) external;

    function initialize(
        uint256 gameId,
        IJBDirectory directory,
        string memory name,
        string memory symbol,
        IJBFundingCycleStore fundingCycleStore,
        string memory baseUri,
        IJB721TokenUriResolver tokenUriResolver,
        string memory contractUri,
        JB721TierParams[] memory tiers,
        uint48 currency,
        IJBTiered721DelegateStore store,
        IDefifaGamePhaseReporter gamePhaseReporter,
        IDefifaGamePotReporter gamePotReporter,
        address defaultAttestationDelegate,
        string[] memory tierNames
    ) external;
}
