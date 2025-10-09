// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import "@bananapus/721-hook-v5/src/JB721TiersHook.sol";
import "@bananapus/721-hook-v5/src/abstract/JB721Hook.sol";
import "@bananapus/721-hook-v5/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import "@bananapus/core-v5/src/libraries/JBRulesetMetadataResolver.sol";
import {DefifaDelegation} from "./structs/DefifaDelegation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDefifaDelegate} from "./interfaces/IDefifaDelegate.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {DefifaTierRedemptionWeight} from "./structs/DefifaTierRedemptionWeight.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";

/// @title DefifaDelegate
/// @notice A delegate that transforms Juicebox treasury interactions into a Defifa game.
contract DefifaDelegate is JB721Hook, Ownable, IDefifaDelegate {
    using Checkpoints for Checkpoints.Trace224;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error BAD_TIER_ORDER();
    error DELEGATE_ADDRESS_ZERO();
    error DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE();
    error GAME_ISNT_SCORING_YET();
    error INVALID_TIER_ID();
    error INVALID_REDEMPTION_WEIGHTS();
    error NOTHING_TO_CLAIM();
    error NOTHING_TO_MINT();
    error WRONG_CURRENCY();
    error NO_CONTEST();
    error OVERSPENDING();
    error REDEMPTION_WEIGHTS_ALREADY_SET();
    error RESERVED_TOKEN_MINTING_PAUSED();
    error TRANSFERS_PAUSED();
    error UNAUTHORIZED(uint256 tokenId, address owner, address caller);

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice
    /// The total redemption weight that can be divided among tiers.
    uint256 public constant override TOTAL_REDEMPTION_WEIGHT = 1_000_000_000_000_000_000;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The redemption weight for each tier.
    /// @dev Tiers are limited to ID 128
    uint256[128] internal _tierRedemptionWeights;

    /// @notice The delegation status for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being delegated.
    mapping(address => mapping(uint256 => address)) internal _tierDelegation;

    /// @notice The delegation checkpoints for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being checked.
    mapping(address => mapping(uint256 => Checkpoints.Trace224)) internal _delegateTierCheckpoints;

    /// @notice The total delegation status for each tier.
    /// _tierId The ID of the tier being checked.
    mapping(uint256 => Checkpoints.Trace224) internal _totalTierCheckpoints;

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens this game was allocated from paying the network fee, packed into a uint256.
    uint256 internal _packedTokenAllocation;

    /// @notice The first owner of each token ID, stored on first transfer out.
    /// _tokenId The ID of the token to get the stored first owner of.
    mapping(uint256 => address) internal _firstOwnerOf;

    /// @notice The names of each tier.
    /// @dev _tierId The ID of the tier to get a name for.
    mapping(uint256 => string) internal _tierNameOf;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The $DEFIFA token that is expected to be issued from paying fees.
    IERC20 public immutable override defifaToken;

    /// @notice The $BASE_PROTOCOL token that is expected to be issued from paying fees.
    IERC20 public immutable override baseProtocolToken;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The address of the origin 'DefifaDelegate', used to check in the init if the contract is the original or not
    address public immutable override codeOrigin;

    /// @notice The contract that stores and manages the NFT's data.
    IJB721TiersHookStore public override store;

    /// @notice The contract storing all funding cycle configurations.
    IJBRulesets public override fundingCycleStore;

    /// @notice The contract reporting game phases.
    IDefifaGamePhaseReporter public override gamePhaseReporter;

    /// @notice The contract reporting the game pot.
    IDefifaGamePotReporter public override gamePotReporter;

    /// @notice The currency that is accepted when minting tier NFTs.
    uint256 public override pricingCurrency;

    /// @notice A flag indicating if the redemption weight has been set.
    bool public override redemptionWeightIsSet;

    /// @notice The common base for the tokenUri's
    string public override baseURI;

    /// @notice Contract metadata uri.
    string public override contractURI;

    /// @notice The address that'll be set as the attestation delegate by default.
    address public override defaultAttestationDelegate;

    /// @notice The amount that has been redeemed from ths game, refunds are not counted.
    uint256 public override amountRedeemed;

    /// @notice The amount of tokens that have been redeemed from a tier, refunds are not counted.
    /// @custom:param The tier from which tokens have been redeemed.
    mapping(uint256 => uint256) public override tokensRedeemedFrom;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The redemption weight for each tier.
    /// @return The array of weights, indexed by tier.
    function tierRedemptionWeights() external view override returns (uint256[128] memory) {
        return _tierRedemptionWeights;
    }

    /// @notice Returns the delegate of an account for specific tier.
    /// @param _account The account to check for a delegate of.
    /// @param _tier the tier to check within.
    function getTierDelegateOf(address _account, uint256 _tier) external view override returns (address) {
        return _tierDelegation[_account][_tier];
    }

    /// @notice Returns the current attestation power of an address for a specific tier.
    /// @param _account The address to check.
    /// @param _tier The tier to check within.
    function getTierAttestationUnitsOf(address _account, uint256 _tier) external view override returns (uint256) {
        return _delegateTierCheckpoints[_account][_tier].latest();
    }

    /// @notice Returns the past attestation units of a specific address for a specific tier.
    /// @param _account The address to check.
    /// @param _tier The tier to check within.
    /// @param _blockNumber the blocknumber to check the attestation power at.
    function getPastTierAttestationUnitsOf(address _account, uint256 _tier, uint256 _blockNumber)
        external
        view
        override
        returns (uint256)
    {
        return _delegateTierCheckpoints[_account][_tier].upperLookup(uint32(_blockNumber));
    }

    /// @notice Returns the total amount of attestation units that exists for a tier.
    /// @param _tier The tier to check.
    function getTierTotalAttestationUnitsOf(uint256 _tier) external view override returns (uint256) {
        return _totalTierCheckpoints[_tier].latest();
    }

    /// @notice Returns the total amount of attestation units that has existed for a tier.
    /// @param _tier The tier to check.
    /// @param _blockNumber The blocknumber to check the total attestation units at.
    function getPastTierTotalAttestationUnitsOf(uint256 _tier, uint256 _blockNumber)
        external
        view
        override
        returns (uint256)
    {
        return _totalTierCheckpoints[_tier].upperLookup(uint32(_blockNumber));
    }

    /// @notice The first owner of each token ID, which corresponds to the address that originally contributed to the project to receive the NFT.
    /// @param _tokenId The ID of the token to get the first owner of.
    /// @return The first owner of the token.
    function firstOwnerOf(uint256 _tokenId) external view override returns (address) {
        // Get a reference to the first owner.
        address _storedFirstOwner = _firstOwnerOf[_tokenId];

        // If the stored first owner is set, return it.
        if (_storedFirstOwner != address(0)) return _storedFirstOwner;

        // Otherwise, the first owner must be the current owner.
        return _owners[_tokenId];
    }

    /// @notice The name of the tier with the specified ID.
    function tierNameOf(uint256 _tierId) external view override returns (string memory) {
        return _tierNameOf[_tierId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the tokenUriResolver if set, otherwise, use the tokenUri set with the token's tier.
    /// @param _tokenId The ID of the token to get the tier URI for.
    /// @return The token URI corresponding with the tier or the tokenUriResolver URI.
    function tokenURI(uint256 _tokenId) public view virtual override returns (string memory) {
        // Use the resolver.
        return store.tokenUriResolverOf(address(this)).tokenUriOf(address(this), _tokenId);
    }

    /// @notice The cumulative weight the given token IDs have in redemptions compared to the `_totalRedemptionWeight`.
    /// @param tokenIds The IDs of the tokens to get the cumulative redemption weight of.
    /// @return cumulativeWeight The weight.
    function cashOutWeightOf(
        uint256[] memory tokenIds,
        JBBeforeCashOutRecordedContext calldata
    )
        public
        view
        virtual
        override
        returns (uint256 cumulativeWeight)
    {
        // Keep a reference to the number of tokens being redeemed.
        uint256 _tokenCount = tokenIds.length;

        for (uint256 _i; _i < _tokenCount;) {
            // Calculate what percentage of the tier redemption amount a single token counts for.
            cumulativeWeight += cashOutWeightOf(tokenIds[_i]);

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice The weight the given token ID has in redemptions.
    /// @param _tokenId The ID of the token to get the redemption weight of.
    /// @return The weight.
    function cashOutWeightOf(uint256 _tokenId) public view override returns (uint256) {
        // Keep a reference to the token's tier ID.
        uint256 _tierId = store.tierIdOfToken(_tokenId);

        // Keep a reference to the tier.
        JB721Tier memory _tier = store.tierOf(address(this), _tierId, false);

        // Get the tier's weight.
        uint256 _weight = _tierRedemptionWeights[_tierId - 1];

        // If there's no weight there's nothing to redeem.
        if (_weight == 0) return 0;

        // If no tiers were minted, nothing to redeem.
        if (_tier.initialSupply- _tier.remainingSupply == 0) return 0;

        uint256 _totalTokensForCashoutInTier = _tier.initialSupply - _tier.remainingSupply
            - (store.numberOfBurnedFor(address(this), _tierId ) - tokensRedeemedFrom[_tierId]);

        // Calculate the percentage of the tier redemption amount a single token counts for.
        return _weight / _totalTokensForCashoutInTier;
    }

    /// @notice The combined cash out weight of all outstanding NFTs.
    /// @dev An NFT's cash out weight is its price.
    /// @return weight The total cash out weight.
    function totalCashOutWeight(JBBeforeCashOutRecordedContext calldata)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return TOTAL_REDEMPTION_WEIGHT;
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens this game was allocated from paying the network fee.
    /// @return defifaTokenAllocation The $DEFIFA token allocation.
    /// @return baseProtocolTokenAllocation The $BASE_PROTOCOL token allocation.
    function tokenAllocations()
        public
        view
        returns (uint256 defifaTokenAllocation, uint256 baseProtocolTokenAllocation)
    {
        // Get a reference to the pakced token allocation.
        uint256 _packed = _packedTokenAllocation;

        // defifa token allocation in bits 0-127 (128 bits).
        uint256 _defifaTokenAllocation = uint256(uint128(_packed));

        // base protocol token allocation in bits 128-255 (128 bits).
        uint256 _baseProtocolTokenAllocation = uint256(uint128(_packed >> 128));

        // Return the values.
        defifaTokenAllocation =
            (_defifaTokenAllocation != 0) ? _defifaTokenAllocation : defifaToken.balanceOf(address(this));
        baseProtocolTokenAllocation = (_baseProtocolTokenAllocation != 0)
            ? _baseProtocolTokenAllocation
            : baseProtocolToken.balanceOf(address(this));
    }

    /// @notice The data calculated before a cash out is recorded in the terminal store. This data is provided to the
    /// terminal's `cashOutTokensOf(...)` transaction.
    /// @dev Sets this contract as the cash out hook. Part of `IJBRulesetDataHook`.
    /// @dev This function is used for NFT cash outs, and will only be called if the project's ruleset has
    /// `useDataHookForCashOut` set to `true`.
    /// @param context The cash out context passed to this contract by the `cashOutTokensOf(...)` function.
    /// @return cashOutTaxRate The cash out tax rate influencing the reclaim amount.
    /// @return cashOutCount The amount of tokens that should be considered cashed out.
    /// @return totalSupply The total amount of tokens that are considered to be existing.
    /// @return hookSpecifications The amount and data to send to cash out hooks (this contract) instead of returning to
    /// the beneficiary.
    function beforeCashOutRecordedWith(JBBeforeCashOutRecordedContext calldata context)
        public
        view
        virtual
        override(IJBRulesetDataHook, JB721Hook)
        returns (
            uint256 cashOutTaxRate,
            uint256 cashOutCount,
            uint256 totalSupply,
            JBCashOutHookSpecification[] memory hookSpecifications
        )
    {
        // Make sure fungible project tokens aren't being redeemed too.
        // TODO: Proper error.
        if (context.cashOutCount > 0) revert();

        // Check the 4 bytes interfaceId and handle the case where the metadata was not intended for this contract
        // Skip 32 bytes reserved for generic extension parameters.
        if (context.metadata.length < 36 || bytes4(context.metadata[32:36]) != type(IDefifaDelegate).interfaceId) {
            // TODO: Proper error.
            revert();
        }

        // Set the only delegate allocation to be a callback to this contract.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification(this, 0, bytes(''));

        // Decode the metadata
        (,, uint256[] memory _decodedTokenIds) = abi.decode(context.metadata, (bytes32, bytes4, uint256[]));

        // Get the current gae phase.
        DefifaGamePhase _gamePhase = gamePhaseReporter.currentGamePhaseOf(context.projectId);

        // If the game is in its minting, refund, or no contest phase, reclaim amount is the same as it costed to mint.
        if (
            _gamePhase == DefifaGamePhase.MINT || _gamePhase == DefifaGamePhase.REFUND
                || _gamePhase == DefifaGamePhase.NO_CONTEST || _gamePhase == DefifaGamePhase.NO_CONTEST_INEVITABLE
        ) {
            // Keep a reference to the number of tokens.
            uint256 _numberOfTokenIds = _decodedTokenIds.length;

            for (uint256 _i; _i < _numberOfTokenIds;) {
                unchecked {
                    cashOutCount += store.tierOfTokenId(address(this), _decodedTokenIds[_i], false).price;
                    _i++;
                }
            }
            
            // TODO: Check if this is correct.
            return (context.cashOutTaxRate, cashOutCount, context.surplus.value, hookSpecifications);
        }

        // Return the weighted amount.
        return (
            context.cashOutTaxRate,
            // TODO: Check if this is correct after changing from v3 -> v5
            mulDiv(
                context.surplus.value + amountRedeemed, cashOutWeightOf(_decodedTokenIds, context), TOTAL_REDEMPTION_WEIGHT
            ),
            context.surplus.value,
            hookSpecifications 
        );
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens claimable for a set of token IDs.
    /// @param _tokenIds The IDs of the tokens that justify a $DEFIFA claim.
    /// @return defifaTokenAmount The amount of $DEFIFA that can be claimed.
    /// @return baseProtocolTokenAmount The amount of $BASE_PROTOCOL that can be claimed.
    function tokensClaimableFor(uint256[] memory _tokenIds)
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // Set the amount of total $DEFIFA and $BASE_PROTOCOL token allocation if it hasn't been set yet.
        (uint256 _defifaTokenAllocation, uint256 _baseProtocolTokenAllocation) = tokenAllocations();

        // If there's no $DEFIFA in this contract, return 0.
        if (_defifaTokenAllocation == 0 && _baseProtocolTokenAllocation == 0) return (0, 0);

        // Get a reference to the game's current pot, including any fulfilled commitments.
        (uint256 _pot,,) = gamePotReporter.currentGamePotOf(PROJECT_ID, true);

        // If there's no usable pot left, the rest of the $DEFIFA and $BASE_PROTOCOL is available.
        if (_pot - gamePotReporter.fulfilledCommitmentsOf(PROJECT_ID) == 0) {
            defifaTokenAmount = defifaToken.balanceOf(address(this));
            baseProtocolTokenAmount = baseProtocolToken.balanceOf(address(this));
        } else {
            // Keep a reference to the number of tokens being used for claims.
            uint256 _numberOfTokens = _tokenIds.length;

            // Keep a reference to the tier being iterated on.
            JB721Tier memory _tier;

            // Keep a reference to the cumulative price of the tokens.
            uint256 _cumulativePrice;

            // Add up the prices of the tokens.
            for (uint256 _i; _i < _numberOfTokens;) {
                _tier = store.tierOfTokenId(address(this), _tokenIds[_i], false);
                _cumulativePrice += _tier.price;
                unchecked {
                    ++_i;
                }
            }

            // The amount of $DEFIFA and $BASE_PROTOCOL to send is the same proportion as the amount being redeemed to the total pot before any amount redeemed.
            defifaTokenAmount = mulDiv(_defifaTokenAllocation, _cumulativePrice, _pot + amountRedeemed);
            baseProtocolTokenAmount =
                mulDiv(_baseProtocolTokenAllocation, _cumulativePrice, _pot + amountRedeemed);
        }
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param _interfaceId The ID of the interface to check for adherence to.
    function supportsInterface(bytes4 _interfaceId) public view override(IERC165, JB721Hook) returns (bool) {
        return _interfaceId == type(IDefifaDelegate).interfaceId || JB721Hook.supportsInterface(_interfaceId);
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @notice The $DEFIFA token that is expected to be issued from paying fees.
    /// @notice The $BASE_PROTOCOL token that is expected to be issued from paying fees.
    // TODO: Change this initial owner (prob).
    constructor(IJBDirectory _directory, IERC20 _defifaToken, IERC20 _baseProtocolToken) Ownable(msg.sender) JB721Hook(_directory) {
        codeOrigin = address(this);
        defifaToken = _defifaToken;
        baseProtocolToken = _baseProtocolToken;
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initialize a clone of this contract.
    /// @param _gameId The ID of the project this contract's functionality applies to.
    /// @param _name The name of the token.
    /// @param _symbol The symbol that the token should be represented by.
    /// @param _fundingCycleStore A contract storing all funding cycle configurations.
    /// @param _baseUri A URI to use as a base for full token URIs.
    /// @param _tokenUriResolver A contract responsible for resolving the token URI for each token ID.
    /// @param _contractUri A URI where contract metadata can be found.
    /// @param _tiers The tiers to set.
    /// @param _currency The currency that the tier contribution floors are denoted in.
    /// @param _store A contract that stores the NFT's data.
    /// @param _gamePhaseReporter The contract that reports the game phase.
    /// @param _gamePotReporter The contract that reports the game's pot.
    /// @param _defaultAttestationDelegate The address that'll be set as the attestation delegate by default.
    /// @param _tierNames The names of each tier.
    function initialize(
        uint256 _gameId,
        string memory _name,
        string memory _symbol,
        IJBRulesets _fundingCycleStore,
        string memory _baseUri,
        IJB721TokenUriResolver _tokenUriResolver,
        string memory _contractUri,
        JB721TierConfig[] memory _tiers,
        uint48 _currency,
        IJB721TiersHookStore _store,
        IDefifaGamePhaseReporter _gamePhaseReporter,
        IDefifaGamePotReporter _gamePotReporter,
        address _defaultAttestationDelegate,
        string[] memory _tierNames
    ) public override {
        // Make the original un-initializable.
        if (address(this) == codeOrigin) revert();

        // Stop re-initialization.
        if (address(store) != address(0)) revert();

        // Initialize the superclass.
        JB721Hook._initialize({projectId: _gameId, name: _name, symbol: _symbol});

        // Store stuff.
        fundingCycleStore = _fundingCycleStore;
        store = _store;
        pricingCurrency = _currency;
        gamePhaseReporter = _gamePhaseReporter;
        gamePotReporter = _gamePotReporter;
        defaultAttestationDelegate = _defaultAttestationDelegate;

        // Store the base URI if provided.
        if (bytes(_baseUri).length != 0) baseURI = _baseUri;

        // Set the contract URI if provided.
        if (bytes(_contractUri).length != 0) contractURI = _contractUri;

        // Set the token URI resolver if provided.
        if (_tokenUriResolver != IJB721TokenUriResolver(address(0))) {
            _store.recordSetTokenUriResolver(_tokenUriResolver);
        }

        // Record the provided tiers.
        _store.recordAddTiers(_tiers);

        // Keep a reference to the number of tier names.
        uint256 _numberOfTierNames = _tierNames.length;

        // Set the name for each tier.
        for (uint256 _i; _i < _numberOfTierNames;) {
            // Set the tier name.
            _tierNameOf[_i + 1] = _tierNames[_i];

            unchecked {
                ++_i;
            }
        }

        // Transfer ownership to the initializer.
        _transferOwnership(msg.sender);
    }

    /// @notice Mint reserved tokens within the tier for the provided value.
    /// @param _tierId The ID of the tier to mint within.
    /// @param _count The number of reserved tokens to mint.
    function mintReservesFor(uint256 _tierId, uint256 _count) public override {
        // Minting reserves must not be paused.
        if (
            JB721TiersRulesetMetadataResolver.mintPendingReservesPaused(
                (JBRulesetMetadataResolver.metadata(fundingCycleStore.currentOf(PROJECT_ID)))
            )
        ) revert RESERVED_TOKEN_MINTING_PAUSED();

        // Keep a reference to the reserved token beneficiary.
        address _reservedTokenBeneficiary = store.reserveBeneficiaryOf(address(this), _tierId);

        // Get a reference to the old delegate.
        address _oldDelegate = _tierDelegation[_reservedTokenBeneficiary][_tierId];

        // Set the delegate as the beneficiary if the beneficiary hasn't already set a delegate.
        if (_oldDelegate == address(0)) {
            _delegateTier(
                _reservedTokenBeneficiary,
                defaultAttestationDelegate != address(0) ? defaultAttestationDelegate : _reservedTokenBeneficiary,
                _tierId
            );
        }

        // Record the minted reserves for the tier.
        uint256[] memory _tokenIds = store.recordMintReservesFor(_tierId, _count);

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        for (uint256 _i; _i < _count;) {
            // Set the token ID.
            _tokenId = _tokenIds[_i];

            // Mint the token.
            _mint(_reservedTokenBeneficiary, _tokenId);

            emit MintReservedToken(_tokenId, _tierId, _reservedTokenBeneficiary, msg.sender);

            unchecked {
                ++_i;
            }
        }

        // Transfer the attestation units to the delegate.
        _transferTierAttestationUnits(
            address(0),
            _reservedTokenBeneficiary,
            _tierId,
            store.tierOf(address(this), _tierId, false).votingUnits * _tokenIds.length
        );
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Stores the redemption weights that should be used in the end game phase.
    /// @dev Only this contract's owner can set tier redemption weights.
    /// @param _tierWeights The tier weights to set.
    function setTierRedemptionWeightsTo(DefifaTierRedemptionWeight[] memory _tierWeights) external override onlyOwner {
        // Get a reference to the game phase.
        DefifaGamePhase _gamePhase = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID);

        // Make sure the game has ended.
        if (_gamePhase != DefifaGamePhase.SCORING) {
            revert GAME_ISNT_SCORING_YET();
        }

        // Make sure the redemption weights haven't already been set.
        if (redemptionWeightIsSet) revert REDEMPTION_WEIGHTS_ALREADY_SET();

        // Make sure the game is not in no contest.
        if (_gamePhase == DefifaGamePhase.NO_CONTEST || _gamePhase == DefifaGamePhase.NO_CONTEST_INEVITABLE) {
            revert NO_CONTEST();
        }

        // Keep a reference to the max tier ID.
        uint256 _maxTierId = store.maxTierIdOf(address(this));

        // Keep a reference to the cumulative amounts.
        uint256 _cumulativeRedemptionWeight;

        // Keep a reference to the number of tier weights.
        uint256 _numberOfTierWeights = _tierWeights.length;

        // Keep a reference to the tier being iterated on.
        JB721Tier memory _tier;

        for (uint256 _i; _i < _numberOfTierWeights;) {
            // Get the tier.
            _tier = store.tierOf(address(this), _tierWeights[_i].id, false);

            // Can't set a redemption weight for tiers not in category 0.
            if (_tier.category != 0) revert INVALID_TIER_ID();

            // Attempting to set the redemption weight for a tier that does not exist (yet) reverts.
            if (_tier.id > _maxTierId) revert INVALID_TIER_ID();

            // Save the tier weight. Tier's are 1 indexed and should be stored 0 indexed.
            _tierRedemptionWeights[_tier.id - 1] = _tierWeights[_i].redemptionWeight;

            // Increment the cumulative amount.
            _cumulativeRedemptionWeight += _tierWeights[_i].redemptionWeight;

            unchecked {
                ++_i;
            }
        }

        // Make sure the cumulative amount is contained within the total redemption weight.
        if (_cumulativeRedemptionWeight > TOTAL_REDEMPTION_WEIGHT) revert INVALID_REDEMPTION_WEIGHTS();

        // Mark the redemption weight as set.
        redemptionWeightIsSet = true;

        emit TierRedemptionWeightsSet(_tierWeights, msg.sender);
    }

    /// @notice Burns the specified NFTs upon token holder cash out, reclaiming funds from the project's balance for
    /// `context.beneficiary`. Part of `IJBCashOutHook`.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The cash out context passed in by the terminal.
    // slither-disable-next-line locked-ether
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context)
        external
        payable
        virtual
        // TODO:Check if we need to make any changes here as we are overriding the new JB721Hook instead.
        override(IJBCashOutHook, JB721Hook)
    {
        // Make sure the caller is a terminal of the project, and the call is being made on behalf of an interaction with the correct project.
        // TODO: Proper error.
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf(PROJECT_ID, IJBTerminal(msg.sender))
                || context.projectId != PROJECT_ID 
        ) revert();

        // If there's nothing being claimed, revert to prevent burning for nothing.
        if (context.reclaimedAmount.value == 0) revert NOTHING_TO_CLAIM();

        // Check the 4 bytes interfaceId and handle the case where the metadata was not intended for this contract
        // Skip 32 bytes reserved for generic extension parameters.
        if (context.cashOutMetadata.length < 36 || bytes4(context.cashOutMetadata[32:36]) != type(IDefifaDelegate).interfaceId) {
            // TODO: Proper error.
            revert();
        }

        // Decode the metadata.
        (,, uint256[] memory _decodedTokenIds) = abi.decode(context.cashOutMetadata, (bytes32, bytes4, uint256[]));

        // Get a reference to the number of token IDs being checked.
        uint256 _numberOfTokenIds = _decodedTokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        // Keep track of whether the redemption is happening during the complete phase.
        bool _isComplete = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) == DefifaGamePhase.COMPLETE;

        // Iterate through all tokens, burning them if the owner is correct.
        for (uint256 _i; _i < _numberOfTokenIds;) {
            // Set the token's ID.
            _tokenId = _decodedTokenIds[_i];

            // Make sure the token's owner is correct.
            if (_owners[_tokenId] != context.holder) revert UNAUTHORIZED(_tokenId, _owners[_tokenId], context.holder);

            // Burn the token.
            _burn(_tokenId);

            unchecked {
                if (_isComplete) ++tokensRedeemedFrom[store.tierIdOfToken(_tokenId)];
                ++_i;
            }
        }

        // Call the hook.
        _didBurn(_decodedTokenIds);

        // Increment the amount redeemed if this is the complete phase.
        if (_isComplete) {
            amountRedeemed += context.reclaimedAmount.value;

            // Claim any $DEFIFA and $BASE_PROTOCOL tokens available.
            _claimTokensFor(context.holder, _decodedTokenIds);
        }
    }

    /// @notice Mint reserved tokens within the tier for the provided value.
    /// @param _mintReservesForTiersData Contains information about how many reserved tokens to mint for each tier.
    function mintReservesFor(JB721TiersMintReservesConfig[] calldata _mintReservesForTiersData)
        external
        override
    {
        // Keep a reference to the number of tiers there are to mint reserves for.
        uint256 _numberOfTiers = _mintReservesForTiersData.length;

        for (uint256 _i; _i < _numberOfTiers;) {
            // Get a reference to the data being iterated on.
            JB721TiersMintReservesConfig memory _data = _mintReservesForTiersData[_i];

            // Mint for the tier.
            mintReservesFor(_data.tierId, _data.count);

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Delegate attestations.
    /// @param _setTierDelegatesData An array of tiers to set delegates for.
    function setTierDelegatesTo(DefifaDelegation[] memory _setTierDelegatesData)
        external
        virtual
        override
    {
        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE();
        }

        // Keep a reference to the number of tier delegates.
        uint256 _numberOfTierDelegates = _setTierDelegatesData.length;

        // Keep a reference to the data being iterated on.
        DefifaDelegation memory _data;

        for (uint256 _i; _i < _numberOfTierDelegates;) {
            // Reference the data being iterated on.
            _data = _setTierDelegatesData[_i];

            // Make sure a delegate is specified.
            if (_data.delegatee == address(0)) revert DELEGATE_ADDRESS_ZERO();

            _delegateTier(msg.sender, _data.delegatee, _data.tierId);

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Delegate attestations.
    /// @param _delegatee The account to delegate tier attestation units to.
    /// @param _tierId The ID of the tier to delegate attestation units for.
    function setTierDelegateTo(address _delegatee, uint256 _tierId) public virtual override {
        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DELEGATE_CHANGES_UNAVAILABLE_IN_THIS_PHASE();
        }

        _delegateTier(msg.sender, _delegatee, _tierId);
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Process an incoming payment.
    /// @param context The Juicebox standard project payment data.
    function _processPayment(JBAfterPayRecordedContext calldata context) internal override {
        // Make sure the game is being played in the correct currency.
        if (context.amount.currency != pricingCurrency) revert WRONG_CURRENCY();

        // Keep a reference to the address that should be given attestations from this mint.
        address _attestationDelegate;

        // Skip the first 32 bytes which are used by the JB protocol to pass the paying project's ID when paying from a JBSplit.
        // Check the 4 bytes interfaceId to verify the metadata is intended for this contract.
        if (context.payerMetadata.length > 68 && bytes4(context.payerMetadata[64:68]) == type(IDefifaDelegate).interfaceId) {
            // Keep a reference to the the specific tier IDs to mint.
            uint16[] memory _tierIdsToMint;

            // Decode the metadata.
            (,,, _attestationDelegate, _tierIdsToMint) =
                abi.decode(context.payerMetadata, (bytes32, bytes32, bytes4, address, uint16[]));

            // Set the payer as the attestation delegate by default.
            if (_attestationDelegate == address(0)) {
                _attestationDelegate =
                    defaultAttestationDelegate != address(0) ? defaultAttestationDelegate : context.payer;
            }

            // Make sure something is being minted.
            if (_tierIdsToMint.length == 0) revert NOTHING_TO_MINT();

            // Keep a reference to the current tier ID.
            uint256 _currentTierId;

            // Keep a reference to the number of attestations units currently accumulated for the given tier.
            uint256 _attestationUnitsForCurrentTier;

            // The price of the tier being iterated on.
            uint256 _attestationUnits;

            // Keep a reference to the number of tiers.
            uint256 _numberOfTiers = _tierIdsToMint.length;

            // Transfer attestation units for each tier.
            for (uint256 _i; _i < _numberOfTiers;) {
                // Keep track of the current tier being iterated on and its price.
                if (_currentTierId != _tierIdsToMint[_i]) {
                    // Make sure the tier IDs are passed in order.
                    if (_tierIdsToMint[_i] < _currentTierId) revert BAD_TIER_ORDER();
                    _currentTierId = _tierIdsToMint[_i];
                    _attestationUnits = store.tierOf(address(this), _currentTierId, false).votingUnits;
                }

                // Get a reference to the old delegate.
                address _oldDelegate = _tierDelegation[context.payer][_currentTierId];

                // If there's either a new delegate or old delegate, increase the delegate weight.
                if (_attestationDelegate != address(0) || _oldDelegate != address(0)) {
                    // Increment the total attestation units for the tier based on price.
                    if (_i < _numberOfTiers - 1 && _tierIdsToMint[_i + 1] == _currentTierId) {
                        _attestationUnitsForCurrentTier += _attestationUnits;
                        // Set the tier's total attestation units.
                    } else {
                        // Switch delegates if needed.
                        if (_attestationDelegate != address(0) && _attestationDelegate != _oldDelegate) {
                            _delegateTier(context.payer, _attestationDelegate, _currentTierId);
                        }

                        // Transfer the new attestation units.
                        _transferTierAttestationUnits(
                            address(0), context.payer, _currentTierId, _attestationUnitsForCurrentTier + _attestationUnits
                        );

                        // Reset the counter
                        _attestationUnitsForCurrentTier = 0;
                    }
                }

                unchecked {
                    ++_i;
                }
            }

            // Mint tiers if they were specified.
            uint256 _leftoverAmount = _mintAll(context.amount.value, _tierIdsToMint, context.beneficiary);

            // Make sure the buyer isn't overspending.
            if (_leftoverAmount != 0) revert OVERSPENDING();
        }
    }

    /// @notice Gets the amount of attestation units an address has for a particular tier.
    /// @param _account The account to get attestation units for.
    /// @param _tierId The ID of the tier to get attestation units for.
    /// @return The attestation units.
    function _getTierAttestationUnits(address _account, uint256 _tierId) internal view virtual returns (uint256) {
        return store.tierVotingUnitsOf(address(this), _account, _tierId);
    }

    /// @notice Delegate all attestation units for the specified tier.
    /// @param _account The account delegating tier attestation units.
    /// @param _delegatee The account to delegate tier attestation units to.
    /// @param _tierId The ID of the tier for which attestation units are being transferred.
    function _delegateTier(address _account, address _delegatee, uint256 _tierId) internal virtual {
        // Get the current delegatee
        address _oldDelegate = _tierDelegation[_account][_tierId];

        // Store the new delegatee
        _tierDelegation[_account][_tierId] = _delegatee;

        emit DelegateChanged(_account, _oldDelegate, _delegatee);

        // Move the attestations.
        _moveTierDelegateAttestations(_oldDelegate, _delegatee, _tierId, _getTierAttestationUnits(_account, _tierId));
    }

    /// @notice Transfers, mints, or burns tier attestation units. To register a mint, `_from` should be zero. To register a burn, `_to` should be zero. Total supply of attestation units will be adjusted with mints and burns.
    /// @param _from The account to transfer tier attestation units from.
    /// @param _to The account to transfer tier attestation units to.
    /// @param _tierId The ID of the tier for which attestation units are being transferred.
    /// @param _amount The amount of attestation units to delegate.
    function _transferTierAttestationUnits(address _from, address _to, uint256 _tierId, uint256 _amount)
        internal
        virtual
    {
        if (_from == address(0) || _to == address(0)) {
            // Get the current total for the tier.
            uint224 _current = _totalTierCheckpoints[_tierId].latest();

            // If minting, add to the total tier checkpoints.
            if (_from == address(0)) _totalTierCheckpoints[_tierId].push(uint32(block.number), _current + uint224(_amount));

            // If burning, subtract from the total tier checkpoints.
            if (_to == address(0)) _totalTierCheckpoints[_tierId].push(uint32(block.number), _current - uint224(_amount));
        }

        // Move delegated attestations.
        _moveTierDelegateAttestations(_tierDelegation[_from][_tierId], _tierDelegation[_to][_tierId], _tierId, _amount);
    }

    /// @notice Moves delegated tier attestations from one delegate to another.
    /// @param _from The account to transfer tier attestation units from.
    /// @param _to The account to transfer tier attestation units to.
    /// @param _tierId The ID of the tier for which attestation units are being transferred.
    /// @param _amount The amount of attestation units to delegate.
    function _moveTierDelegateAttestations(address _from, address _to, uint256 _tierId, uint256 _amount) internal {
        // Nothing to do if moving to the same account, or no amount is being moved.
        if (_from == _to || _amount == 0) return;


        // If not moving from the zero address, update the checkpoints to subtract the amount.
        if (_from != address(0)) {
            // Get the current amount for the sending delegate.
            uint224 _current = _delegateTierCheckpoints[_from][_tierId].latest();
            // Set the new amount for the sending delegate.
            (uint256 _oldValue, uint256 _newValue) = _delegateTierCheckpoints[_from][_tierId].push(uint32(block.number), _current - uint224(_amount));
            emit TierDelegateAttestationsChanged(_from, _tierId, _oldValue, _newValue, msg.sender);
        }

        // If not moving to the zero address, update the checkpoints to add the amount.
        if (_to != address(0)) {
            // Get the current amount for the receiving delegate.
            uint224 _current = _delegateTierCheckpoints[_to][_tierId].latest();
            // Set the new amount for the receiving delegate.
            (uint256 _oldValue, uint256 _newValue) = _delegateTierCheckpoints[_to][_tierId].push(uint32(block.number), _current + uint224(_amount));
            emit TierDelegateAttestationsChanged(_to, _tierId, _oldValue, _newValue, msg.sender);
        }
    }

    /// @notice A function that will run when tokens are burned via redemption.
    /// @param _tokenIds The IDs of the tokens that were burned.
    function _didBurn(uint256[] memory _tokenIds) internal virtual override {
        // Add to burned counter.
        store.recordBurn(_tokenIds);
    }

    /// @notice Mints a token in all provided tiers.
    /// @param _amount The amount to base the mints on. All mints' price floors must fit in this amount.
    /// @param _mintTierIds An array of tier IDs that are intended to be minted.
    /// @param _beneficiary The address to mint for.
    /// @return leftoverAmount The amount leftover after the mint.
    function _mintAll(uint256 _amount, uint16[] memory _mintTierIds, address _beneficiary)
        internal
        returns (uint256 leftoverAmount)
    {
        // Keep a reference to the token ID.
        uint256[] memory _tokenIds;

        // Record the mint. The returned token IDs correspond to the tiers passed in.
        (_tokenIds, leftoverAmount) = store.recordMint(
            _amount,
            _mintTierIds,
            false // Not a manual mint
        );

        // Get a reference to the number of mints.
        uint256 _mintsLength = _tokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        // Loop through each token ID and mint.
        for (uint256 _i; _i < _mintsLength;) {
            // Get a reference to the tier being iterated on.
            _tokenId = _tokenIds[_i];

            // Mint the tokens.
            _mint(_beneficiary, _tokenId);

            emit Mint(_tokenId, _mintTierIds[_i], _beneficiary, _amount, msg.sender);

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Claim $DEFIFA and $BASE_PROTOCOL tokens to an account for a certain redeemed amount.
    /// @param _beneficiary The beneficiary of the $DEFIFA tokens.
    /// @param _tokenIds The IDs of the tokens being redeemed that are justifying a $DEFIFA claim.
    function _claimTokensFor(address _beneficiary, uint256[] memory _tokenIds) internal {
        // Set the amount of total $DEFIFA token allocation if it hasn't been set yet.
        if (_packedTokenAllocation == 0) {
            uint256 _packed;
            // defifa token allocation in bits 0-127 (128 bits).
            _packed |= defifaToken.balanceOf(address(this));
            // base protocol token allocation in bits 128-255 (48 bits).
            _packed |= uint256(uint128(baseProtocolToken.balanceOf(address(this)))) << 128;
            // Store the packed values.
            _packedTokenAllocation = _packed;
        }

        // Get a reference to the amounts to send.
        (uint256 _defifaTokenAmount, uint256 _baseProtocolTokenAmount) = tokensClaimableFor(_tokenIds);

        // Send the tokens.
        defifaToken.transfer(_beneficiary, _defifaTokenAmount);
        baseProtocolToken.transfer(_beneficiary, _baseProtocolTokenAmount);

        emit ClaimedTokens(_beneficiary, _defifaTokenAmount, _baseProtocolTokenAmount, msg.sender);
    }

    /// @notice Before transferring an NFT, register its first owner (if necessary).
    /// @param to The address the NFT is being transferred to.
    /// @param tokenId The token ID of the NFT being transferred.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        // Get a reference to the tier.
        // slither-disable-next-line calls-loop
        JB721Tier memory tier = store.tierOfTokenId({hook: address(this), tokenId: tokenId, includeResolvedUri: false});

        // Record the transfers and keep a reference to where the token is coming from.
        from = super._update(to, tokenId, auth);

        // Transfers must not be paused (when not minting or burning).
        if (from != address(0)) {
            // If transfers are pausable, check if they're paused.
            if (tier.transfersPausable) {
                // Get a reference to the project's current ruleset.
                JBRuleset memory ruleset = fundingCycleStore.currentOf(PROJECT_ID);

                // If transfers are paused and the NFT isn't being transferred to the zero address, revert.
                if (
                    to != address(0)
                        && JB721TiersRulesetMetadataResolver.transfersPaused((JBRulesetMetadataResolver.metadata(ruleset)))
                ) revert TRANSFERS_PAUSED();
            }

            // If the token isn't already associated with a first owner, store the sender as the first owner.
            // slither-disable-next-line calls-loop
            if (_firstOwnerOf[tokenId] == address(0)) _firstOwnerOf[tokenId] = from;
        }

        // Record the transfer.
        // slither-disable-next-line reentrency-events,calls-loop
        store.recordTransferForTier(tier.id, from, to);

        // Dont transfer on mint since the delegation will be transferred more efficiently in _processPayment.
        if (from == address(0)) return from;

        // Transfer the attestation units.
        _transferTierAttestationUnits(from, to, tier.id, tier.votingUnits);
    }

    // Utils OZ extension that is being reused for tier delegation.
    function _add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function _subtract(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }
}
