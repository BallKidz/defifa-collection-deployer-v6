// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IJBCashOutHook} from "@bananapus/core-v6/src/interfaces/IJBCashOutHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPayHook} from "@bananapus/core-v6/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBRulesets} from "@bananapus/core-v6/src/interfaces/IJBRulesets.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core-v6/src/libraries/JBRulesetMetadataResolver.sol";
import {JBAfterCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterCashOutRecordedContext.sol";
import {JBAfterPayRecordedContext} from "@bananapus/core-v6/src/structs/JBAfterPayRecordedContext.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBCashOutHookSpecification} from "@bananapus/core-v6/src/structs/JBCashOutHookSpecification.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JB721Hook} from "@bananapus/721-hook-v6/src/abstract/JB721Hook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721TokenUriResolver} from "@bananapus/721-hook-v6/src/interfaces/IJB721TokenUriResolver.sol";
import {
    JB721TiersRulesetMetadataResolver
} from "@bananapus/721-hook-v6/src/libraries/JB721TiersRulesetMetadataResolver.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TiersMintReservesConfig} from "@bananapus/721-hook-v6/src/structs/JB721TiersMintReservesConfig.sol";

import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {DefifaDelegation} from "./structs/DefifaDelegation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDefifaHook} from "./interfaces/IDefifaHook.sol";
import {IDefifaGamePhaseReporter} from "./interfaces/IDefifaGamePhaseReporter.sol";
import {IDefifaGamePotReporter} from "./interfaces/IDefifaGamePotReporter.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "./enums/DefifaGamePhase.sol";
import {DefifaHookLib} from "./libraries/DefifaHookLib.sol";

/// @title DefifaHook
/// @notice A hook that transforms Juicebox treasury interactions into a Defifa game.
contract DefifaHook is JB721Hook, Ownable, IDefifaHook {
    using Checkpoints for Checkpoints.Trace208;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error DefifaHook_BadTierOrder();
    error DefifaHook_DelegateAddressZero();
    error DefifaHook_DelegateChangesUnavailableInThisPhase();
    error DefifaHook_GameIsntScoringYet();
    error DefifaHook_InvalidTierId();
    error DefifaHook_InvalidCashoutWeights();
    error DefifaHook_NothingToClaim();
    error DefifaHook_NothingToMint();
    error DefifaHook_WrongCurrency();
    error DefifaHook_Overspending();
    error DefifaHook_CashoutWeightsAlreadySet();
    error DefifaHook_ReservedTokenMintingPaused();
    error DefifaHook_TransfersPaused();
    error DefifaHook_Unauthorized(uint256 tokenId, address owner, address caller);

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice The total cashOut weight that can be divided among tiers.
    uint256 public constant override TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The cashOut weight for each tier.
    /// @dev Tiers are limited to ID 128
    uint256[128] internal _tierCashOutWeights;

    /// @notice The delegation status for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being delegated.
    mapping(address => mapping(uint256 => address)) internal _tierDelegation;

    /// @notice The delegation checkpoints for each address and for each tier.
    /// _delegator The delegator.
    /// _tierId The ID of the tier being checked.
    mapping(address => mapping(uint256 => Checkpoints.Trace208)) internal _delegateTierCheckpoints;

    /// @notice The total delegation status for each tier.
    /// _tierId The ID of the tier being checked.
    mapping(uint256 => Checkpoints.Trace208) internal _totalTierCheckpoints;

    /// @notice The first owner of each token ID, stored on first transfer out.
    /// _tokenId The ID of the token to get the stored first owner of.
    mapping(uint256 => address) internal _firstOwnerOf;

    /// @notice The names of each tier.
    /// @dev _tierId The ID of the tier to get a name for.
    mapping(uint256 => string) internal _tierNameOf;

    /// @notice The cumulative mint price of all tokens (paid and reserved). Used as the denominator for fee token
    /// ($DEFIFA/$NANA) distribution.
    uint256 internal _totalMintCost;

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

    /// @notice The address of the origin 'DefifaHook', used to check in the init if the contract is the original or not
    address public immutable override codeOrigin;

    /// @notice The contract that stores and manages the NFT's data.
    IJB721TiersHookStore public override store;

    /// @notice The contract storing all funding cycle configurations.
    IJBRulesets public override rulesets;

    /// @notice The contract reporting game phases.
    IDefifaGamePhaseReporter public override gamePhaseReporter;

    /// @notice The contract reporting the game pot.
    IDefifaGamePotReporter public override gamePotReporter;

    /// @notice The currency that is accepted when minting tier NFTs.
    uint256 public override pricingCurrency;

    /// @notice A flag indicating if the cashout weights has been set.
    bool public override cashOutWeightIsSet;

    /// @notice The common base for the tokenUri's
    string public override baseURI;

    /// @notice Contract metadata uri.
    string public override contractURI;

    /// @notice The address that'll be set as the attestation delegate by default.
    address public override defaultAttestationDelegate;

    /// @notice The amount that has been redeemed from this game, refunds are not counted.
    uint256 public override amountRedeemed;

    /// @notice The amount of tokens that have been redeemed from a tier, refunds are not counted.
    /// @custom:param The tier from which tokens have been redeemed.
    mapping(uint256 => uint256) public override tokensRedeemedFrom;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The first owner of each token ID, which corresponds to the address that originally contributed to the
    /// project to receive the NFT.
    /// @param tokenId The ID of the token to get the first owner of.
    /// @return The first owner of the token.
    function firstOwnerOf(uint256 tokenId) external view override returns (address) {
        // Get a reference to the first owner.
        address _storedFirstOwner = _firstOwnerOf[tokenId];

        // If the stored first owner is set, return it.
        if (_storedFirstOwner != address(0)) return _storedFirstOwner;

        // Otherwise, the first owner must be the current owner.
        return _owners[tokenId];
    }

    /// @notice Returns the past attestation units of a specific address for a specific tier.
    /// @param account The address to check.
    /// @param tier The tier to check within.
    /// @param timestamp The timestamp to check the attestation power at.
    function getPastTierAttestationUnitsOf(
        address account,
        uint256 tier,
        uint48 timestamp
    )
        external
        view
        override
        returns (uint256)
    {
        return _delegateTierCheckpoints[account][tier].upperLookup(timestamp);
    }

    /// @notice Returns the total amount of attestation units that has existed for a tier.
    /// @param tier The tier to check.
    /// @param timestamp The timestamp to check the total attestation units at.
    function getPastTierTotalAttestationUnitsOf(
        uint256 tier,
        uint48 timestamp
    )
        external
        view
        override
        returns (uint256)
    {
        return _totalTierCheckpoints[tier].upperLookup(timestamp);
    }

    /// @notice Returns the current attestation power of an address for a specific tier.
    /// @param account The address to check.
    /// @param tier The tier to check within.
    function getTierAttestationUnitsOf(address account, uint256 tier) external view override returns (uint256) {
        return _delegateTierCheckpoints[account][tier].latest();
    }

    /// @notice Returns the delegate of an account for specific tier.
    /// @param account The account to check for a delegate of.
    /// @param tier The tier to check within.
    function getTierDelegateOf(address account, uint256 tier) external view override returns (address) {
        return _tierDelegation[account][tier];
    }

    /// @notice Returns the total amount of attestation units that exists for a tier.
    /// @param tier The tier to check.
    function getTierTotalAttestationUnitsOf(uint256 tier) external view override returns (uint256) {
        return _totalTierCheckpoints[tier].latest();
    }

    /// @notice The cashOut weight for each tier.
    /// @return The array of weights, indexed by tier.
    function tierCashOutWeights() external view override returns (uint256[128] memory) {
        return _tierCashOutWeights;
    }

    /// @notice The name of the tier with the specified ID.
    /// @param tierId The ID of the tier.
    function tierNameOf(uint256 tierId) external view override returns (string memory) {
        return _tierNameOf[tierId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

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
        // Make sure (fungible) project tokens aren't also being cashed out.
        if (context.cashOutCount > 0) revert JB721Hook_UnexpectedTokenCashedOut();

        // Fetch the cash out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) =
            JBMetadataResolver.getDataFor(JBMetadataResolver.getId("cashOut", codeOrigin), context.metadata);

        uint256[] memory decodedTokenIds;

        // Decode the metadata.
        if (metadataExists) decodedTokenIds = abi.decode(metadata, (uint256[]));

        // Get the current game phase.
        DefifaGamePhase _gamePhase = gamePhaseReporter.currentGamePhaseOf(context.projectId);

        // Calculate the amount paid to mint the tokens that are being burned.
        uint256 _cumulativeMintPrice =
            DefifaHookLib.computeCumulativeMintPrice({tokenIds: decodedTokenIds, _store: store, hook: address(this)});

        // Use this contract as the only cash out hook.
        hookSpecifications = new JBCashOutHookSpecification[](1);
        hookSpecifications[0] = JBCashOutHookSpecification(this, 0, abi.encode(_cumulativeMintPrice));

        // Compute the cash out count based on the game phase.
        cashOutCount = DefifaHookLib.computeCashOutCount({
            gamePhase: _gamePhase,
            cumulativeMintPrice: _cumulativeMintPrice,
            surplusValue: context.surplus.value,
            _amountRedeemed: amountRedeemed,
            cumulativeCashOutWeight: cashOutWeightOf(decodedTokenIds)
        });

        // Use the surplus as the total supply.
        totalSupply = context.surplus.value;

        // Use the cash out tax rate from the context.
        cashOutTaxRate = context.cashOutTaxRate;
    }

    /// @notice The cumulative weight the given token IDs have in cashOuts compared to the `totalCashOutWeight`.
    /// @param tokenIds The IDs of the tokens to get the cumulative cashOut weight of.
    /// @return cumulativeWeight The weight.
    function cashOutWeightOf(uint256[] memory tokenIds)
        public
        view
        virtual
        override
        returns (uint256 cumulativeWeight)
    {
        cumulativeWeight = DefifaHookLib.computeCashOutWeightBatch({
            tokenIds: tokenIds,
            _store: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The weight the given token ID has in cashOuts.
    /// @param tokenId The ID of the token to get the cashOut weight of.
    /// @return The weight.
    function cashOutWeightOf(uint256 tokenId) public view override returns (uint256) {
        return DefifaHookLib.computeCashOutWeight({
            tokenId: tokenId,
            _store: store,
            hook: address(this),
            tierCashOutWeights: _tierCashOutWeights,
            tokensRedeemedFrom: tokensRedeemedFrom
        });
    }

    /// @notice The amount of tokens of a tier that are currently in circulation.
    /// @param tierId The ID of the tier to get the current supply of.
    function currentSupplyOfTier(uint256 tierId) public view returns (uint256) {
        return DefifaHookLib.computeCurrentSupply({_store: store, hook: address(this), tierId: tierId});
    }

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherence to.
    function supportsInterface(bytes4 interfaceId) public view override(JB721Hook, IERC165) returns (bool) {
        return interfaceId == type(IDefifaHook).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens this game was allocated from paying the network fee.
    /// @return defifaTokenAllocation The $DEFIFA token allocation.
    /// @return baseProtocolTokenAllocation The $BASE_PROTOCOL token allocation.
    function tokenAllocations()
        public
        view
        returns (uint256 defifaTokenAllocation, uint256 baseProtocolTokenAllocation)
    {
        defifaTokenAllocation = defifaToken.balanceOf(address(this));
        baseProtocolTokenAllocation = baseProtocolToken.balanceOf(address(this));
    }

    /// @notice The metadata URI of the provided token ID.
    /// @dev Defer to the tokenUriResolver if set, otherwise, use the tokenUri set with the token's tier.
    /// @param tokenId The ID of the token to get the tier URI for.
    /// @return The token URI corresponding with the tier or the tokenUriResolver URI.
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        // Use the resolver.
        return store.tokenUriResolverOf(address(this)).tokenUriOf(address(this), tokenId);
    }

    /// @notice The amount of $DEFIFA and $BASE_PROTOCOL tokens claimable for a set of token IDs.
    /// @param tokenIds The IDs of the tokens that justify a $DEFIFA claim.
    /// @return defifaTokenAmount The amount of $DEFIFA that can be claimed.
    /// @return baseProtocolTokenAmount The amount of $BASE_PROTOCOL that can be claimed.
    function tokensClaimableFor(uint256[] memory tokenIds)
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // If the game isn't complete, we do not have any tokens to claim.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.COMPLETE) return (0, 0);

        // slither-disable-next-line unused-return
        return DefifaHookLib.computeTokensClaim({
            tokenIds: tokenIds,
            _store: store,
            hook: address(this),
            totalMintCost: _totalMintCost,
            defifaBalance: defifaToken.balanceOf(address(this)),
            baseProtocolBalance: baseProtocolToken.balanceOf(address(this))
        });
    }

    /// @notice The combined cash out weight of all outstanding NFTs.
    /// @dev An NFT's cash out weight is its price.
    /// @return The total cash out weight.
    function totalCashOutWeight() public view virtual override returns (uint256) {
        return TOTAL_CASHOUT_WEIGHT;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev The initial owner is msg.sender; ownership is transferred to the governor after initialization.
    constructor(
        IJBDirectory _directory,
        IERC20 _defifaToken,
        IERC20 _baseProtocolToken
    )
        JB721Hook(_directory)
        Ownable(msg.sender)
    {
        codeOrigin = address(this);
        defifaToken = _defifaToken;
        baseProtocolToken = _baseProtocolToken;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Mints one or more NFTs to the `context.beneficiary` upon payment if conditions are met.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The payment context passed in by the terminal.
    // slither-disable-next-line locked-ether
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context)
        external
        payable
        virtual
        override(IJBPayHook, JB721Hook)
    {
        uint256 projectId = PROJECT_ID;

        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf({projectId: projectId, terminal: IJBTerminal(msg.sender)})
                || context.projectId != projectId
        ) revert JB721Hook_InvalidPay();

        // Process the payment.
        _processPayment(context);
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Initialize a clone of this contract.
    /// @param _gameId The ID of the project this contract's functionality applies to.
    /// @param _name The name of the token.
    /// @param _symbol The symbol that the token should be represented by.
    /// @param _rulesets A contract storing all ruleset configurations.
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
        IJBRulesets _rulesets,
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
    )
        public
        override
    {
        // Make the original un-initializable.
        if (address(this) == codeOrigin) revert();

        // Stop re-initialization.
        if (address(store) != address(0)) revert();

        // Initialize the superclass.
        _initialize({projectId: _gameId, name: _name, symbol: _symbol});

        // Store stuff.
        rulesets = _rulesets;
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
        // slither-disable-next-line unused-return
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
    /// @param tierId The ID of the tier to mint within.
    /// @param count The number of reserved tokens to mint.
    function mintReservesFor(uint256 tierId, uint256 count) public override {
        // Minting reserves must not be paused.
        if (JB721TiersRulesetMetadataResolver.mintPendingReservesPaused(
                (JBRulesetMetadataResolver.metadata(rulesets.currentOf(PROJECT_ID)))
            )) revert DefifaHook_ReservedTokenMintingPaused();

        // Keep a reference to the reserved token beneficiary.
        address _reservedTokenBeneficiary = store.reserveBeneficiaryOf({hook: address(this), tierId: tierId});

        // Get a reference to the old delegate.
        address _oldDelegate = _tierDelegation[_reservedTokenBeneficiary][tierId];

        // Set the delegate as the beneficiary if the beneficiary hasn't already set a delegate.
        if (_oldDelegate == address(0)) {
            _delegateTier({
                _account: _reservedTokenBeneficiary,
                _delegatee: defaultAttestationDelegate != address(0)
                    ? defaultAttestationDelegate
                    : _reservedTokenBeneficiary,
                _tierId: tierId
            });
        }

        // Record the minted reserves for the tier.
        uint256[] memory _tokenIds = store.recordMintReservesFor({tierId: tierId, count: count});

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        // Fetch the tier details (needed for votingUnits below).
        JB721Tier memory _tier = store.tierOf({hook: address(this), id: tierId, includeResolvedUri: false});

        // Increment _totalMintCost so reserved recipients can claim their share of fee tokens ($DEFIFA/$NANA).
        _totalMintCost += _tier.price * count;

        for (uint256 _i; _i < count;) {
            // Set the token ID.
            _tokenId = _tokenIds[_i];

            // Mint the token.
            _mint(_reservedTokenBeneficiary, _tokenId);

            emit MintReservedToken(_tokenId, tierId, _reservedTokenBeneficiary, msg.sender);

            unchecked {
                ++_i;
            }
        }

        // Transfer the attestation units to the delegate.
        _transferTierAttestationUnits({
            _from: address(0),
            _to: _reservedTokenBeneficiary,
            _tierId: tierId,
            _amount: _tier.votingUnits * _tokenIds.length
        });
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Burns the specified NFTs upon token holder cash out, reclaiming funds from the project's balance for
    /// `context.beneficiary`. Part of `IJBCashOutHook`.
    /// @dev Reverts if the calling contract is not one of the project's terminals.
    /// @param context The cash out context passed in by the terminal.
    // slither-disable-next-line locked-ether,reentrancy-no-eth
    function afterCashOutRecordedWith(JBAfterCashOutRecordedContext calldata context)
        external
        payable
        virtual
        override(IJBCashOutHook, JB721Hook)
    {
        // Make sure the caller is a terminal of the project, and that the call is being made on behalf of an
        // interaction with the correct project.
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf({projectId: PROJECT_ID, terminal: IJBTerminal(msg.sender)})
                || context.projectId != PROJECT_ID
        ) revert JB721Hook_InvalidCashOut();

        // Fetch the cash out hook metadata using the corresponding metadata ID.
        (bool metadataExists, bytes memory metadata) = JBMetadataResolver.getDataFor(
            JBMetadataResolver.getId("cashOut", METADATA_ID_TARGET), context.cashOutMetadata
        );

        if (!metadataExists) {
            revert();
        }

        // Decode the CashOut metadata.
        (uint256[] memory _decodedTokenIds) = abi.decode(metadata, (uint256[]));

        // Get a reference to the number of token IDs being checked.
        uint256 _numberOfTokenIds = _decodedTokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        // Keep track of whether the cashOut is happening during the complete phase.
        bool _isComplete = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) == DefifaGamePhase.COMPLETE;

        // Iterate through all tokens, burning them if the owner is correct.
        for (uint256 _i; _i < _numberOfTokenIds; _i++) {
            // Set the token's ID.
            _tokenId = _decodedTokenIds[_i];

            // Make sure the token's owner is correct.
            address _tokenOwner = _ownerOf(_tokenId);
            if (_tokenOwner != context.holder) {
                revert DefifaHook_Unauthorized(_tokenId, _tokenOwner, context.holder);
            }

            // Burn the token.
            _burn(_tokenId);

            if (_isComplete) {
                unchecked {
                    ++tokensRedeemedFrom[store.tierIdOfToken(_tokenId)];
                }
            }
        }

        // Call the hook.
        _didBurn(_decodedTokenIds);

        // Decode the metadata passed by the hook.
        (uint256 _cumulativeMintPrice) = abi.decode(context.hookMetadata, (uint256));

        // Increment the amount redeemed if this is the complete phase.
        bool _beneficiaryReceivedTokens;
        if (_isComplete) {
            amountRedeemed += context.reclaimedAmount.value;

            // Claim the $DEFIFA and $NANA tokens for the user.
            _beneficiaryReceivedTokens = _claimTokensFor({
                _beneficiary: context.holder, shareToBeneficiary: _cumulativeMintPrice, outOfTotal: _totalMintCost
            });
        }

        // If there's nothing being claimed and we did not distribute fee tokens, revert to prevent burning for nothing.
        if (context.reclaimedAmount.value == 0 && !_beneficiaryReceivedTokens) revert DefifaHook_NothingToClaim();

        // Decrement the paid mint cost by the cumulative mint price of the tokens being burned.
        _totalMintCost -= _cumulativeMintPrice;
    }

    /// @notice Mint reserved tokens within the tier for the provided value.
    /// @param mintReservesForTiersData Contains information about how many reserved tokens to mint for each tier.
    function mintReservesFor(JB721TiersMintReservesConfig[] calldata mintReservesForTiersData) external override {
        // Keep a reference to the number of tiers there are to mint reserves for.
        uint256 _numberOfTiers = mintReservesForTiersData.length;

        for (uint256 _i; _i < _numberOfTiers;) {
            // Get a reference to the data being iterated on.
            JB721TiersMintReservesConfig memory _data = mintReservesForTiersData[_i];

            // Mint for the tier.
            mintReservesFor(_data.tierId, _data.count);

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Stores the cashOut weights that should be used in the end game phase.
    /// @dev Only this contract's owner can set tier cashOut weights.
    /// @param tierWeights The tier weights to set.
    function setTierCashOutWeightsTo(DefifaTierCashOutWeight[] memory tierWeights) external override onlyOwner {
        // Get a reference to the game phase.
        DefifaGamePhase _gamePhase = gamePhaseReporter.currentGamePhaseOf(PROJECT_ID);

        // Make sure the game has ended.
        if (_gamePhase != DefifaGamePhase.SCORING) {
            revert DefifaHook_GameIsntScoringYet();
        }

        // Make sure the cashOut weights haven't already been set.
        if (cashOutWeightIsSet) revert DefifaHook_CashoutWeightsAlreadySet();

        // Validate weights and build the array. Reverts on invalid input.
        _tierCashOutWeights =
            DefifaHookLib.validateAndBuildWeights({tierWeights: tierWeights, _store: store, hook: address(this)});

        // Mark the cashOut weight as set.
        cashOutWeightIsSet = true;

        emit TierCashOutWeightsSet(tierWeights, msg.sender);
    }

    /// @notice Delegate attestations.
    /// @param delegatee The account to delegate tier attestation units to.
    /// @param tierId The ID of the tier to delegate attestation units for.
    function setTierDelegateTo(address delegatee, uint256 tierId) public virtual override {
        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DefifaHook_DelegateChangesUnavailableInThisPhase();
        }

        _delegateTier({_account: msg.sender, _delegatee: delegatee, _tierId: tierId});
    }

    /// @notice Delegate attestations.
    /// @param delegations An array of tiers to set delegates for.
    function setTierDelegatesTo(DefifaDelegation[] memory delegations) external virtual override {
        // Make sure the current game phase is the minting phase.
        if (gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.MINT) {
            revert DefifaHook_DelegateChangesUnavailableInThisPhase();
        }

        // Keep a reference to the number of tier delegates.
        uint256 _numberOfTierDelegates = delegations.length;

        // Keep a reference to the data being iterated on.
        DefifaDelegation memory _data;

        for (uint256 _i; _i < _numberOfTierDelegates;) {
            // Reference the data being iterated on.
            _data = delegations[_i];

            // Make sure a delegate is specified.
            if (_data.delegatee == address(0)) revert DefifaHook_DelegateAddressZero();

            _delegateTier({_account: msg.sender, _delegatee: _data.delegatee, _tierId: _data.tierId});

            unchecked {
                ++_i;
            }
        }
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Claims the defifa and base protocol tokens for a beneficiary.
    /// @param _beneficiary The address to claim tokens for.
    /// @param shareToBeneficiary The share relative to the `outOfTotal` to send the user.
    /// @param outOfTotal The total share that the `shareToBeneficiary` is relative to.
    /// @return beneficiaryReceivedTokens A flag indicating if the beneficiary received any tokens.
    function _claimTokensFor(
        address _beneficiary,
        uint256 shareToBeneficiary,
        uint256 outOfTotal
    )
        internal
        returns (bool beneficiaryReceivedTokens)
    {
        return DefifaHookLib.claimTokensFor({
            _beneficiary: _beneficiary,
            shareToBeneficiary: shareToBeneficiary,
            outOfTotal: outOfTotal,
            _defifaToken: defifaToken,
            _baseProtocolToken: baseProtocolToken
        });
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
        _moveTierDelegateAttestations({
            _from: _oldDelegate,
            _to: _delegatee,
            _tierId: _tierId,
            _amount: _getTierAttestationUnits({_account: _account, _tierId: _tierId})
        });
    }

    /// @notice A function that will run when tokens are burned via cashOut.
    /// @param _tokenIds The IDs of the tokens that were burned.
    function _didBurn(uint256[] memory _tokenIds) internal virtual override {
        // Add to burned counter.
        store.recordBurn(_tokenIds);
    }

    /// @notice Gets the amount of attestation units an address has for a particular tier.
    /// @param _account The account to get attestation units for.
    /// @param _tierId The ID of the tier to get attestation units for.
    /// @return The attestation units.
    function _getTierAttestationUnits(address _account, uint256 _tierId) internal view virtual returns (uint256) {
        return store.tierVotingUnitsOf({hook: address(this), account: _account, tierId: _tierId});
    }

    /// @notice Mints a token in all provided tiers.
    /// @param _amount The amount to base the mints on. All mints' price floors must fit in this amount.
    /// @param _mintTierIds An array of tier IDs that are intended to be minted.
    /// @param _beneficiary The address to mint for.
    /// @return leftoverAmount The amount leftover after the mint.
    function _mintAll(
        uint256 _amount,
        uint16[] memory _mintTierIds,
        address _beneficiary
    )
        internal
        returns (uint256 leftoverAmount)
    {
        // Keep a reference to the token ID.
        uint256[] memory _tokenIds;

        // Record the mint. The returned token IDs correspond to the tiers passed in.
        (_tokenIds, leftoverAmount) = store.recordMint({
            amount: _amount,
            tierIds: _mintTierIds,
            isOwnerMint: false // Not a manual mint
        });

        // Get a reference to the number of mints.
        uint256 _mintsLength = _tokenIds.length;

        // Keep a reference to the token ID being iterated on.
        uint256 _tokenId;

        // Increment the paid mint cost.
        _totalMintCost += _amount;

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
            uint208 _current = _delegateTierCheckpoints[_from][_tierId].latest();
            // Set the new amount for the sending delegate.
            (uint256 _oldValue, uint256 _newValue) =
                _delegateTierCheckpoints[_from][_tierId].push(uint48(block.timestamp), _current - uint208(_amount));
            emit TierDelegateAttestationsChanged(_from, _tierId, _oldValue, _newValue, msg.sender);
        }

        // If not moving to the zero address, update the checkpoints to add the amount.
        if (_to != address(0)) {
            // Get the current amount for the receiving delegate.
            uint208 _current = _delegateTierCheckpoints[_to][_tierId].latest();
            // Set the new amount for the receiving delegate.
            (uint256 _oldValue, uint256 _newValue) =
                _delegateTierCheckpoints[_to][_tierId].push(uint48(block.timestamp), _current + uint208(_amount));
            emit TierDelegateAttestationsChanged(_to, _tierId, _oldValue, _newValue, msg.sender);
        }
    }

    /// @notice Process an incoming payment.
    /// @param context The Juicebox standard project payment data.
    function _processPayment(JBAfterPayRecordedContext calldata context) internal override {
        // Make sure the game is being played in the correct currency.
        if (context.amount.currency != pricingCurrency) revert DefifaHook_WrongCurrency();

        // Resolve the metadata.
        (bool found, bytes memory metadata) =
            JBMetadataResolver.getDataFor(JBMetadataResolver.getId("pay", codeOrigin), context.payerMetadata);

        if (!found) revert DefifaHook_NothingToMint();

        // Decode the metadata.
        (address _attestationDelegate, uint16[] memory _tierIdsToMint) = abi.decode(metadata, (address, uint16[]));

        // Set the payer as the attestation delegate by default.
        if (_attestationDelegate == address(0)) {
            _attestationDelegate = defaultAttestationDelegate != address(0) ? defaultAttestationDelegate : context.payer;
        }

        // Make sure something is being minted.
        if (_tierIdsToMint.length == 0) revert DefifaHook_NothingToMint();

        // Compute attestation units per unique tier (validates ascending order, reverts on bad order).
        (uint256[] memory _tierIds, uint256[] memory _attestationAmounts, uint256 _uniqueTierCount) =
            DefifaHookLib.computeAttestationUnits({_tierIdsToMint: _tierIdsToMint, _store: store, hook: address(this)});

        // Apply attestation units for each unique tier.
        for (uint256 _i; _i < _uniqueTierCount;) {
            uint256 _tierId = _tierIds[_i];

            // Get a reference to the old delegate.
            address _oldDelegate = _tierDelegation[context.payer][_tierId];

            // If there's either a new delegate or old delegate, set delegation and transfer units.
            if (_attestationDelegate != address(0) || _oldDelegate != address(0)) {
                // Switch delegates if needed.
                if (_attestationDelegate != address(0) && _attestationDelegate != _oldDelegate) {
                    _delegateTier({_account: context.payer, _delegatee: _attestationDelegate, _tierId: _tierId});
                }

                // Transfer the attestation units.
                _transferTierAttestationUnits({
                    _from: address(0), _to: context.payer, _tierId: _tierId, _amount: _attestationAmounts[_i]
                });
            }

            unchecked {
                ++_i;
            }
        }

        // Mint tiers if they were specified.
        uint256 _leftoverAmount =
            _mintAll({_amount: context.amount.value, _mintTierIds: _tierIdsToMint, _beneficiary: context.beneficiary});

        // Make sure the buyer isn't overspending.
        if (_leftoverAmount != 0) revert DefifaHook_Overspending();
    }

    /// @notice Transfers, mints, or burns tier attestation units. To register a mint, `_from` should be zero. To
    /// register a burn, `_to` should be zero. Total supply of attestation units will be adjusted with mints and burns.
    /// @param _from The account to transfer tier attestation units from.
    /// @param _to The account to transfer tier attestation units to.
    /// @param _tierId The ID of the tier for which attestation units are being transferred.
    /// @param _amount The amount of attestation units to delegate.
    function _transferTierAttestationUnits(
        address _from,
        address _to,
        uint256 _tierId,
        uint256 _amount
    )
        internal
        virtual
    {
        if (_from == address(0) || _to == address(0)) {
            // Get the current total for the tier.
            uint208 _current = _totalTierCheckpoints[_tierId].latest();

            // If minting, add to the total tier checkpoints.
            if (_from == address(0)) {
                // slither-disable-next-line unused-return
                _totalTierCheckpoints[_tierId].push(uint48(block.timestamp), _current + uint208(_amount));
            }

            // If burning, subtract from the total tier checkpoints.
            if (_to == address(0)) {
                // slither-disable-next-line unused-return
                _totalTierCheckpoints[_tierId].push(uint48(block.timestamp), _current - uint208(_amount));
            }
        }

        // Move delegated attestations.
        _moveTierDelegateAttestations({
            _from: _tierDelegation[_from][_tierId],
            _to: _tierDelegation[_to][_tierId],
            _tierId: _tierId,
            _amount: _amount
        });
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
                JBRuleset memory ruleset = rulesets.currentOf(PROJECT_ID);

                // If transfers are paused and the NFT isn't being transferred to the zero address, revert.
                if (
                    to != address(0)
                        && JB721TiersRulesetMetadataResolver.transfersPaused(
                            (JBRulesetMetadataResolver.metadata(ruleset))
                        )
                ) revert DefifaHook_TransfersPaused();
            }

            // If the token isn't already associated with a first owner, store the sender as the first owner.
            // slither-disable-next-line calls-loop
            if (_firstOwnerOf[tokenId] == address(0)) _firstOwnerOf[tokenId] = from;
        }

        // Record the transfer.
        // slither-disable-next-line reentrency-events,calls-loop
        store.recordTransferForTier({tierId: tier.id, from: from, to: to});

        // Dont transfer on mint since the delegation will be transferred more efficiently in _processPayment.
        if (from == address(0)) return from;

        // Transfer the attestation units.
        _transferTierAttestationUnits({_from: from, _to: to, _tierId: tier.id, _amount: tier.votingUnits});
    }
}
