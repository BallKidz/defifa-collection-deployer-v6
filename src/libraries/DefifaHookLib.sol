// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {mulDiv} from "@prb/math/src/Common.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {DefifaTierCashOutWeight} from "../structs/DefifaTierCashOutWeight.sol";
import {DefifaGamePhase} from "../enums/DefifaGamePhase.sol";

/// @title DefifaHookLib
/// @notice Pure/view helper functions extracted from DefifaHook to reduce contract bytecode size.
/// @dev Public library functions are deployed separately and called via delegatecall, so their bytecode does not count
/// toward the calling contract's EIP-170 size limit.
library DefifaHookLib {
    using SafeERC20 for IERC20;

    error DefifaHook_BadTierOrder();
    error DefifaHook_InvalidTierId();
    error DefifaHook_InvalidCashoutWeights();

    event ClaimedTokens(
        address indexed beneficiary, uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount, address caller
    );

    /// @notice The total cashOut weight that can be divided among tiers.
    uint256 internal constant TOTAL_CASHOUT_WEIGHT = 1_000_000_000_000_000_000;

    /// @notice Validates tier cash out weights and returns the weight array to store.
    /// @param tierWeights The tier weights to validate and set.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return weights The 128-element array of validated weights.
    function validateAndBuildWeights(
        DefifaTierCashOutWeight[] memory tierWeights,
        IJB721TiersHookStore _store,
        address hook
    )
        public
        view
        returns (uint256[128] memory weights)
    {
        // Keep a reference to the max tier ID.
        uint256 _maxTierId = _store.maxTierIdOf(hook);

        // Keep a reference to the cumulative amounts.
        uint256 _cumulativeCashOutWeight;

        // Keep a reference to the number of tier weights.
        uint256 _numberOfTierWeights = tierWeights.length;

        // Keep a reference to the tier being iterated on.
        JB721Tier memory _tier;

        // Keep a reference to the last tier ID to enforce ascending order (no duplicates).
        uint256 _lastTierId;

        for (uint256 _i; _i < _numberOfTierWeights;) {
            // Enforce strict ascending order to prevent duplicate tier IDs.
            if (tierWeights[_i].id <= _lastTierId && _i != 0) revert DefifaHook_BadTierOrder();
            _lastTierId = tierWeights[_i].id;

            // Get the tier.
            _tier = _store.tierOf({hook: hook, id: tierWeights[_i].id, includeResolvedUri: false});

            // Can't set a cashOut weight for tiers not in category 0.
            if (_tier.category != 0) revert DefifaHook_InvalidTierId();

            // Attempting to set the cashOut weight for a tier that does not exist (yet) reverts.
            if (_tier.id > _maxTierId) revert DefifaHook_InvalidTierId();

            // Save the tier weight. Tiers are 1 indexed and should be stored 0 indexed.
            weights[_tier.id - 1] = tierWeights[_i].cashOutWeight;

            // Increment the cumulative amount.
            _cumulativeCashOutWeight += tierWeights[_i].cashOutWeight;

            unchecked {
                ++_i;
            }
        }

        // Make sure the cumulative amount is exactly the total cashOut weight.
        if (_cumulativeCashOutWeight != TOTAL_CASHOUT_WEIGHT) revert DefifaHook_InvalidCashoutWeights();
    }

    /// @notice Compute the cash out weight for a single token.
    /// @param tokenId The token ID.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash out weights array.
    /// @param tokensRedeemedFrom The mapping of tokens redeemed per tier (passed as a function that returns the value).
    /// @return The cash out weight.
    function computeCashOutWeight(
        uint256 tokenId,
        IJB721TiersHookStore _store,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom
    )
        public
        view
        returns (uint256)
    {
        // Keep a reference to the token's tier ID.
        uint256 _tierId = _store.tierIdOfToken(tokenId);

        // Keep a reference to the tier.
        JB721Tier memory _tier = _store.tierOf({hook: hook, id: _tierId, includeResolvedUri: false});

        // Get the tier's weight.
        uint256 _weight = tierCashOutWeights[_tierId - 1];

        // If there's no weight there's nothing to redeem.
        if (_weight == 0) return 0;

        // Get the amount of tokens that have already been burned.
        uint256 _burnedTokens = _store.numberOfBurnedFor({hook: hook, tierId: _tierId});

        // If no tiers were minted, nothing to redeem.
        if (_tier.initialSupply - (_tier.remainingSupply + _burnedTokens) == 0) return 0;

        // Calculate the amount of tokens that existed at the start of the last phase.
        uint256 _totalTokensForCashoutInTier =
            _tier.initialSupply - _tier.remainingSupply - (_burnedTokens - tokensRedeemedFrom[_tierId]);

        // Calculate the percentage of the tier cashOut amount a single token counts for.
        return _weight / _totalTokensForCashoutInTier;
    }

    /// @notice Compute the cumulative cash out weight for multiple tokens.
    /// @param tokenIds The token IDs.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierCashOutWeights The tier cash out weights array.
    /// @param tokensRedeemedFrom The mapping of tokens redeemed per tier.
    /// @return cumulativeWeight The cumulative weight.
    function computeCashOutWeightBatch(
        uint256[] memory tokenIds,
        IJB721TiersHookStore _store,
        address hook,
        uint256[128] storage tierCashOutWeights,
        mapping(uint256 => uint256) storage tokensRedeemedFrom
    )
        public
        view
        returns (uint256 cumulativeWeight)
    {
        uint256 _tokenCount = tokenIds.length;
        for (uint256 _i; _i < _tokenCount;) {
            cumulativeWeight += computeCashOutWeight({
                tokenId: tokenIds[_i],
                _store: _store,
                hook: hook,
                tierCashOutWeights: tierCashOutWeights,
                tokensRedeemedFrom: tokensRedeemedFrom
            });
            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Compute the claimable token amounts for a set of token IDs.
    /// @param tokenIds The token IDs.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param totalMintCost The cumulative mint cost.
    /// @param defifaBalance The current $DEFIFA balance.
    /// @param baseProtocolBalance The current $BASE_PROTOCOL balance.
    /// @return defifaTokenAmount The claimable $DEFIFA amount.
    /// @return baseProtocolTokenAmount The claimable $BASE_PROTOCOL amount.
    function computeTokensClaim(
        uint256[] memory tokenIds,
        IJB721TiersHookStore _store,
        address hook,
        uint256 totalMintCost,
        uint256 defifaBalance,
        uint256 baseProtocolBalance
    )
        public
        view
        returns (uint256 defifaTokenAmount, uint256 baseProtocolTokenAmount)
    {
        // If nothing was paid to mint, no fee tokens can be claimed.
        if (totalMintCost == 0) return (0, 0);

        // Keep a reference to the number of tokens being used for claims.
        uint256 _numberOfTokens = tokenIds.length;

        // Calculate the amount paid to mint the tokens that are being burned.
        uint256 _cumulativeMintPrice;
        for (uint256 _i; _i < _numberOfTokens; _i++) {
            _cumulativeMintPrice += _store.tierOfTokenId({hook: hook, tokenId: tokenIds[_i], includeResolvedUri: false})
            .price;
        }

        // Calculate the user's claimable amount proportional to what they paid.
        defifaTokenAmount = defifaBalance * _cumulativeMintPrice / totalMintCost;
        baseProtocolTokenAmount = baseProtocolBalance * _cumulativeMintPrice / totalMintCost;
    }

    /// @notice Compute the cumulative mint price for a set of token IDs.
    /// @param tokenIds The token IDs.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return cumulativeMintPrice The total mint price.
    function computeCumulativeMintPrice(
        uint256[] memory tokenIds,
        IJB721TiersHookStore _store,
        address hook
    )
        public
        view
        returns (uint256 cumulativeMintPrice)
    {
        uint256 _numberOfTokenIds = tokenIds.length;
        for (uint256 _i; _i < _numberOfTokenIds; _i++) {
            cumulativeMintPrice += _store.tierOfTokenId({hook: hook, tokenId: tokenIds[_i], includeResolvedUri: false})
            .price;
        }
    }

    /// @notice Compute the cash out count for the beforeCashOutRecorded hook.
    /// @param gamePhase The current game phase.
    /// @param cumulativeMintPrice The cumulative mint price of the tokens being cashed out.
    /// @param surplusValue The surplus value from the context.
    /// @param _amountRedeemed The amount already redeemed.
    /// @param cumulativeCashOutWeight The cumulative cash out weight of the tokens.
    /// @return cashOutCount The computed cash out count.
    function computeCashOutCount(
        DefifaGamePhase gamePhase,
        uint256 cumulativeMintPrice,
        uint256 surplusValue,
        uint256 _amountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
        returns (uint256 cashOutCount)
    {
        // If the game is in its minting, refund, or no-contest phase, reclaim amount is the same as it cost to mint.
        if (
            gamePhase == DefifaGamePhase.MINT || gamePhase == DefifaGamePhase.REFUND
                || gamePhase == DefifaGamePhase.NO_CONTEST
        ) {
            cashOutCount = cumulativeMintPrice;
        } else {
            // If the game is in its scoring or complete phase, reclaim amount is based on the tier weights.
            cashOutCount = mulDiv(surplusValue + _amountRedeemed, cumulativeCashOutWeight, TOTAL_CASHOUT_WEIGHT);
        }
    }

    /// @notice Compute the current supply of a tier (minted - burned).
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param tierId The ID of the tier.
    /// @return The current supply.
    function computeCurrentSupply(
        IJB721TiersHookStore _store,
        address hook,
        uint256 tierId
    )
        public
        view
        returns (uint256)
    {
        JB721Tier memory _tier = _store.tierOf({hook: hook, id: tierId, includeResolvedUri: false});
        return _tier.initialSupply - (_tier.remainingSupply + _store.numberOfBurnedFor({hook: hook, tierId: tierId}));
    }

    /// @notice Computes the attestation units for tiers during payment processing.
    /// @dev Returns parallel arrays: tier IDs, cumulative attestation units per tier, and whether to switch delegate.
    /// @param _tierIdsToMint The tier IDs being minted (must be in ascending order).
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return tierIds The unique tier IDs.
    /// @return attestationAmounts The cumulative attestation units for each unique tier.
    /// @return count The number of unique tiers.
    function computeAttestationUnits(
        uint16[] memory _tierIdsToMint,
        IJB721TiersHookStore _store,
        address hook
    )
        public
        view
        returns (uint256[] memory tierIds, uint256[] memory attestationAmounts, uint256 count)
    {
        uint256 _numberOfTiers = _tierIdsToMint.length;
        tierIds = new uint256[](_numberOfTiers);
        attestationAmounts = new uint256[](_numberOfTiers);

        if (_numberOfTiers == 0) return (tierIds, attestationAmounts, 0);

        uint256 _currentTierId;
        uint256 _attestationUnits;
        uint256 _accumulated;

        for (uint256 _i; _i < _numberOfTiers;) {
            if (_currentTierId != _tierIdsToMint[_i]) {
                // Flush accumulated units for previous tier.
                if (_currentTierId != 0) {
                    tierIds[count] = _currentTierId;
                    attestationAmounts[count] = _accumulated;
                    count++;
                }
                if (_tierIdsToMint[_i] < _currentTierId) revert DefifaHook_BadTierOrder();
                _currentTierId = _tierIdsToMint[_i];
                _attestationUnits =
                _store.tierOf({hook: hook, id: _currentTierId, includeResolvedUri: false}).votingUnits;
                _accumulated = _attestationUnits;
            } else {
                _accumulated += _attestationUnits;
            }
            unchecked {
                ++_i;
            }
        }
        // Flush the last tier.
        if (_currentTierId != 0) {
            tierIds[count] = _currentTierId;
            attestationAmounts[count] = _accumulated;
            count++;
        }
    }

    /// @notice Claims the defifa and base protocol tokens for a beneficiary.
    /// @dev Executes via delegatecall, so `address(this)` is the calling contract. Transfers are from the hook's
    /// balance. @param _beneficiary The address to claim tokens for.
    /// @param shareToBeneficiary The share relative to the `outOfTotal` to send the user.
    /// @param outOfTotal The total share that the `shareToBeneficiary` is relative to.
    /// @param _defifaToken The $DEFIFA token.
    /// @param _baseProtocolToken The $BASE_PROTOCOL token.
    /// @return beneficiaryReceivedTokens A flag indicating if the beneficiary received any tokens.
    function claimTokensFor(
        address _beneficiary,
        uint256 shareToBeneficiary,
        uint256 outOfTotal,
        IERC20 _defifaToken,
        IERC20 _baseProtocolToken
    )
        public
        returns (bool beneficiaryReceivedTokens)
    {
        // Calculate the share of $DEFIFA and $BASE_PROTOCOL tokens to send.
        uint256 baseProtocolAmount = _baseProtocolToken.balanceOf(address(this)) * shareToBeneficiary / outOfTotal;
        uint256 defifaAmount = _defifaToken.balanceOf(address(this)) * shareToBeneficiary / outOfTotal;

        // If there is an amount we should send, send it.
        if (defifaAmount != 0) _defifaToken.safeTransfer(_beneficiary, defifaAmount);
        if (baseProtocolAmount != 0) _baseProtocolToken.safeTransfer(_beneficiary, baseProtocolAmount);

        emit ClaimedTokens(_beneficiary, defifaAmount, baseProtocolAmount, msg.sender);

        return (defifaAmount != 0 || baseProtocolAmount != 0);
    }
}
