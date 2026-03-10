# Per-Tier Splits Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Forward a percentage of each NFT mint price to per-tier split groups immediately on mint, reducing the available refund.

**Architecture:** One global `splitPercent` applies to all tiers. Each tier has its own JBSplit group defining where that percentage goes. On mint, the terminal forwards split funds to the hook, which distributes them via `JB721TiersHookLib.distributeAll()`. Refunds return only the treasury-retained portion (`tierPrice - splitAmount`). `_totalMintCost` tracks only the retained portion for accurate fee token distribution.

**Tech Stack:** Solidity 0.8.26, Foundry, JB721Hook v6, JBSplits, JB721TiersHookLib

---

### Task 1: Add split fields to DefifaTierParams

**Files:**
- Modify: `src/structs/DefifaTierParams.sol`

**Step 1: Add `splits` field**

```solidity
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
```

**Step 2: Run compilation**

Run: `forge build`
Expected: Compilation errors in files that construct `DefifaTierParams` without the new field. That's expected — we'll fix them in subsequent tasks.

**Step 3: Commit**

```bash
git add src/structs/DefifaTierParams.sol
git commit -m "feat: add splits field to DefifaTierParams"
```

---

### Task 2: Add `splitPercent` to DefifaLaunchProjectData and wire through DefifaDeployer

**Files:**
- Modify: `src/structs/DefifaLaunchProjectData.sol`
- Modify: `src/DefifaDeployer.sol`

**Step 1: Add `tierSplitPercent` to DefifaLaunchProjectData**

In `src/structs/DefifaLaunchProjectData.sol`, add a new field after `tierPrice`:

```solidity
    uint104 tierPrice;
    uint32 tierSplitPercent;
```

Add NatSpec: `/// @custom:member tierSplitPercent The percentage of each tier's price forwarded to the tier's split group on mint. Out of JBConstants.SPLITS_TOTAL_PERCENT (1e9).`

**Step 2: Wire split config through DefifaDeployer**

In `src/DefifaDeployer.sol`, in the tier config loop (around line 399), change:

```solidity
                splitPercent: 0,
                splits: new JBSplit[](0)
```

to:

```solidity
                splitPercent: launchProjectData.tierSplitPercent,
                splits: _defifaTier.splits
```

**Step 3: Run compilation**

Run: `forge build`
Expected: Compilation errors in tests that construct `DefifaLaunchProjectData` or `DefifaTierParams` without the new fields. That's expected.

**Step 4: Commit**

```bash
git add src/structs/DefifaLaunchProjectData.sol src/DefifaDeployer.sol
git commit -m "feat: wire tierSplitPercent and per-tier splits through deployer"
```

---

### Task 3: Override `beforePayRecordedWith` in DefifaHook

**Files:**
- Modify: `src/DefifaHook.sol`
- Modify: `src/libraries/DefifaHookLib.sol`

**Step 1: Add `computeSplitAmounts` to DefifaHookLib**

Defifa metadata uses `(address, uint16[])` format (not `(bool, uint16[])` like JB721TiersHook). So we need a Defifa-specific split amount calculator. Add to `src/libraries/DefifaHookLib.sol`:

```solidity
    /// @notice Compute the total split amount and per-tier breakdown for a Defifa payment.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @param metadataTarget The target address for metadata ID resolution.
    /// @param metadata The raw payment metadata.
    /// @return totalSplitAmount The total amount to forward to splits.
    /// @return splitMetadata Encoded (uint16[] tierIds, uint256[] amounts) for distribution.
    function computeSplitAmounts(
        IJB721TiersHookStore _store,
        address hook,
        address metadataTarget,
        bytes calldata metadata
    )
        external
        view
        returns (uint256 totalSplitAmount, bytes memory splitMetadata)
    {
        // Resolve the pay metadata.
        (bool found, bytes memory data) =
            JBMetadataResolver.getDataFor(JBMetadataResolver.getId("pay", metadataTarget), metadata);
        if (!found) return (0, bytes(""));

        // Decode Defifa-format metadata: (attestationDelegate, tierIdsToMint).
        (, uint16[] memory tierIdsToMint) = abi.decode(data, (address, uint16[]));
        if (tierIdsToMint.length == 0) return (0, bytes(""));

        uint16[] memory splitTierIds = new uint16[](tierIdsToMint.length);
        uint256[] memory splitAmounts = new uint256[](tierIdsToMint.length);
        uint256 splitTierCount;

        for (uint256 i; i < tierIdsToMint.length; i++) {
            JB721Tier memory tier = _store.tierOf(hook, tierIdsToMint[i], false);
            if (tier.splitPercent != 0) {
                splitTierIds[splitTierCount] = tierIdsToMint[i];
                splitAmounts[splitTierCount] = mulDiv(tier.price, tier.splitPercent, JBConstants.SPLITS_TOTAL_PERCENT);
                totalSplitAmount += splitAmounts[splitTierCount];
                splitTierCount++;
            }
        }

        if (splitTierCount != 0) {
            assembly {
                mstore(splitTierIds, splitTierCount)
                mstore(splitAmounts, splitTierCount)
            }
            splitMetadata = abi.encode(splitTierIds, splitAmounts);
        }
    }
```

Add these imports to DefifaHookLib.sol if not already present:
- `import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";`
- `import {mulDiv} from "@prb/math/src/Common.sol";`
- `import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";`

**Step 2: Override `beforePayRecordedWith` in DefifaHook**

Add to `DefifaHook.sol` (in the external views section, near `beforeCashOutRecordedWith`):

```solidity
    /// @notice The data calculated before a payment is recorded in the terminal store.
    /// @dev Calculates split amounts to forward based on tier split percentages.
    /// @param context The payment context.
    /// @return weight The weight to use for token minting.
    /// @return hookSpecifications The hook specifications, with the split amount to forward.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        public
        view
        virtual
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        weight = context.weight;
        hookSpecifications = new JBPayHookSpecification[](1);

        // Calculate per-tier split amounts.
        (uint256 totalSplitAmount, bytes memory splitMetadata) =
            DefifaHookLib.computeSplitAmounts(store, address(this), codeOrigin, context.metadata);

        hookSpecifications[0] = JBPayHookSpecification({hook: this, amount: totalSplitAmount, metadata: splitMetadata});
    }
```

Add the import:
- `import {JBBeforePayRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforePayRecordedContext.sol";`
- `import {JBPayHookSpecification} from "@bananapus/core-v6/src/structs/JBPayHookSpecification.sol";`

**Step 3: Run compilation**

Run: `forge build`
Expected: Should compile (test errors are separate).

**Step 4: Commit**

```bash
git add src/DefifaHook.sol src/libraries/DefifaHookLib.sol
git commit -m "feat: override beforePayRecordedWith to calculate tier split amounts"
```

---

### Task 4: Fix `afterPayRecordedWith` and `_processPayment` to distribute splits

**Files:**
- Modify: `src/DefifaHook.sol`

**Step 1: Remove `msg.value != 0` rejection in `afterPayRecordedWith`**

In `DefifaHook.sol` around line 438, change:

```solidity
        if (
            msg.value != 0 || !DIRECTORY.isTerminalOf({projectId: projectId, terminal: IJBTerminal(msg.sender)})
                || context.projectId != projectId
        ) revert JB721Hook_InvalidPay();
```

to:

```solidity
        if (
            !DIRECTORY.isTerminalOf({projectId: projectId, terminal: IJBTerminal(msg.sender)})
                || context.projectId != projectId
        ) revert JB721Hook_InvalidPay();
```

This matches the base `JB721Hook.afterPayRecordedWith` which does not reject `msg.value`.

**Step 2: Add split distribution at the end of `_processPayment`**

At the end of `_processPayment` (after the `_leftoverAmount` check, around line 833), add split distribution:

```solidity
        // Make sure the buyer isn't overspending.
        if (_leftoverAmount != 0) revert DefifaHook_Overspending();

        // Distribute any forwarded funds to tier split groups.
        if (context.hookMetadata.length != 0 && context.forwardedAmount.value != 0) {
            JB721TiersHookLib.distributeAll(
                DIRECTORY, PROJECT_ID, address(this), context.forwardedAmount.token, context.hookMetadata
            );
        }
```

Add import:
- `import {JB721TiersHookLib} from "@bananapus/721-hook-v6/src/libraries/JB721TiersHookLib.sol";`

**Step 3: Adjust `_mintAll` to track only retained amount in `_totalMintCost`**

In `_mintAll` (line 974), `_totalMintCost` should only track the amount that stayed in the treasury (for accurate fee token distribution). Change:

```solidity
        // Increment the paid mint cost.
        _totalMintCost += _amount;
```

This is already correct — `_amount` passed to `_mintAll` is `context.amount.value` which is the full payment amount minus the forwarded split amount (the terminal subtracts the hook specification amount before recording the payment). Actually, let's verify: `context.amount.value` in `afterPayRecordedWith` is the amount recorded in the terminal store, which is `payAmount - forwardedAmount`. So `_amount` already excludes splits. No change needed here.

Wait — re-check this. In `_processPayment`, `_amount` is `context.amount.value`. The terminal records `amount = payAmount - hookSpecification.amount` in the store. So `context.amount.value` is already the retained amount. `_totalMintCost += _amount` is correct as-is for the treasury-retained portion.

**Step 4: Run compilation**

Run: `forge build`

**Step 5: Commit**

```bash
git add src/DefifaHook.sol
git commit -m "feat: distribute tier splits on mint in afterPayRecordedWith"
```

---

### Task 5: Fix refund math to account for split amounts

**Files:**
- Modify: `src/libraries/DefifaHookLib.sol`
- Modify: `src/DefifaHook.sol`

**Step 1: Add `computeCumulativeRetainedPrice` to DefifaHookLib**

This is like `computeCumulativeMintPrice` but subtracts the split portion. Add to `DefifaHookLib.sol`:

```solidity
    /// @notice Compute the cumulative retained mint price (mint price minus split amounts) for a set of token IDs.
    /// @dev Used for refund calculations — only the retained portion is refundable.
    /// @param tokenIds The token IDs to compute the retained price for.
    /// @param _store The 721 tiers hook store.
    /// @param hook The hook address.
    /// @return cumulativeRetainedPrice The total retained price across all tokens.
    function computeCumulativeRetainedPrice(
        uint256[] memory tokenIds,
        IJB721TiersHookStore _store,
        address hook
    )
        public
        view
        returns (uint256 cumulativeRetainedPrice)
    {
        uint256 _numberOfTokenIds = tokenIds.length;
        for (uint256 _i; _i < _numberOfTokenIds; _i++) {
            JB721Tier memory tier =
                _store.tierOfTokenId({hook: hook, tokenId: tokenIds[_i], includeResolvedUri: false});
            uint256 splitAmount =
                tier.splitPercent != 0 ? mulDiv(tier.price, tier.splitPercent, JBConstants.SPLITS_TOTAL_PERCENT) : 0;
            cumulativeRetainedPrice += tier.price - splitAmount;
        }
    }
```

**Step 2: Update `beforeCashOutRecordedWith` in DefifaHook to use retained price for refunds**

In `beforeCashOutRecordedWith` (around line 348), change the mint price calculation:

```solidity
        // Calculate the amount paid to mint the tokens that are being burned.
        uint256 _cumulativeMintPrice =
            DefifaHookLib.computeCumulativeMintPrice({tokenIds: decodedTokenIds, _store: store, hook: address(this)});
```

to:

```solidity
        // Calculate the full mint price (for fee token distribution) and the retained price (for refunds).
        uint256 _cumulativeMintPrice =
            DefifaHookLib.computeCumulativeMintPrice({tokenIds: decodedTokenIds, _store: store, hook: address(this)});
        uint256 _cumulativeRetainedPrice =
            DefifaHookLib.computeCumulativeRetainedPrice({tokenIds: decodedTokenIds, _store: store, hook: address(this)});
```

Then update the `computeCashOutCount` call to use `_cumulativeRetainedPrice` for refund phases:

```solidity
        // Compute the cash out count based on the game phase.
        cashOutCount = DefifaHookLib.computeCashOutCount({
            gamePhase: _gamePhase,
            cumulativeRetainedPrice: _cumulativeRetainedPrice,
            surplusValue: context.surplus.value,
            _amountRedeemed: amountRedeemed,
            cumulativeCashOutWeight: cashOutWeightOf(decodedTokenIds)
        });
```

Also update the hook metadata to pass the retained price (since that's what was actually contributed to the treasury):

```solidity
        hookSpecifications[0] = JBCashOutHookSpecification(this, 0, abi.encode(_cumulativeRetainedPrice));
```

**Step 3: Update `computeCashOutCount` signature**

In `DefifaHookLib.sol`, rename the parameter in `computeCashOutCount`:

```solidity
    function computeCashOutCount(
        DefifaGamePhase gamePhase,
        uint256 cumulativeRetainedPrice,
        uint256 surplusValue,
        uint256 _amountRedeemed,
        uint256 cumulativeCashOutWeight
    )
        public
        pure
        returns (uint256 cashOutCount)
    {
        // If the game is in its minting, refund, or no-contest phase, reclaim amount is the retained portion.
        if (
            gamePhase == DefifaGamePhase.MINT || gamePhase == DefifaGamePhase.REFUND
                || gamePhase == DefifaGamePhase.NO_CONTEST
        ) {
            cashOutCount = cumulativeRetainedPrice;
        } else {
            // If the game is in its scoring or complete phase, reclaim amount is based on the tier weights.
            cashOutCount = mulDiv(surplusValue + _amountRedeemed, cumulativeCashOutWeight, TOTAL_CASHOUT_WEIGHT);
        }
    }
```

**Step 4: Update `afterCashOutRecordedWith` in DefifaHook**

The hook metadata now contains `_cumulativeRetainedPrice` instead of `_cumulativeMintPrice`. In `afterCashOutRecordedWith` where the metadata is decoded (it's used for fee token claims), this value now represents the retained amount — which is correct for `_totalMintCost` tracking since `_totalMintCost` already tracks retained amounts (per Task 4, Step 3).

No code change needed here — the variable name `_cumulativeMintPrice` in `afterCashOutRecordedWith` will now receive the retained price, and `_totalMintCost -= _cumulativeMintPrice` correctly reduces by the retained portion.

**Step 5: Run compilation**

Run: `forge build`

**Step 6: Commit**

```bash
git add src/DefifaHook.sol src/libraries/DefifaHookLib.sol
git commit -m "feat: refund returns only treasury-retained portion (excludes split amounts)"
```

---

### Task 6: Fix test compilation

**Files:**
- Modify: all test files that construct `DefifaTierParams` or `DefifaLaunchProjectData`

**Step 1: Find all test files that need updating**

Run: `forge build 2>&1 | grep "Error\|error"` to identify compilation errors.

**Step 2: Update `DefifaTierParams` construction**

Everywhere `DefifaTierParams` is constructed in tests, add `splits: new JBSplit[](0)` as the last field:

```solidity
DefifaTierParams({
    name: "...",
    reservedRate: ...,
    reservedTokenBeneficiary: ...,
    encodedIPFSUri: ...,
    shouldUseReservedTokenBeneficiaryAsDefault: ...,
    splits: new JBSplit[](0)
})
```

**Step 3: Update `DefifaLaunchProjectData` construction**

Add `tierSplitPercent: 0` after `tierPrice` in all test constructions:

```solidity
DefifaLaunchProjectData({
    ...
    tierPrice: ...,
    tierSplitPercent: 0,
    ...
})
```

**Step 4: Run tests**

Run: `forge test`
Expected: All 53 existing tests pass (no behavioral change when splitPercent is 0).

**Step 5: Commit**

```bash
git add test/
git commit -m "test: fix compilation for new split fields (splitPercent=0 for existing tests)"
```

---

### Task 7: Write integration test for per-tier splits

**Files:**
- Create: `test/DefifaTierSplits.t.sol`

**Step 1: Write the failing test**

Create `test/DefifaTierSplits.t.sol` with a test that:
1. Creates a game with `tierSplitPercent = 200_000_000` (20%) and per-tier split beneficiaries
2. Mints NFTs — verifies split beneficiaries receive 20% of tier price
3. Refunds during refund phase — verifies refund is 80% of tier price (not 100%)
4. Verifies treasury balance reflects only the retained 80%

The test should extend the existing `TestBaseWorkflow` used by other Defifa tests. Use the patterns from `test/DefifaGovernor.t.sol` for game setup.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// Import same base as other Defifa tests.
// Test structure:
//
// testSplitForwardedOnMint():
//   - Deploy game with 2 tiers, tierSplitPercent=20%, each tier has 1 split beneficiary
//   - Mint 1 NFT from tier 1
//   - Assert split beneficiary received 20% of tierPrice
//   - Assert treasury balance is 80% of tierPrice
//
// testRefundExcludesSplitAmount():
//   - Deploy game with tierSplitPercent=20%
//   - Mint 1 NFT, advance to refund phase
//   - Cash out (refund) the NFT
//   - Assert refund amount is 80% of tierPrice (not 100%)
//
// testZeroSplitPercentUnchanged():
//   - Deploy game with tierSplitPercent=0%
//   - Mint and refund
//   - Assert full price refunded (backward compatibility)
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract DefifaTierSplitsTest -v`
Expected: FAIL (tests reference new functionality)

**Step 3: Verify tests pass after implementation**

After all previous tasks are implemented, run:
Run: `forge test --match-contract DefifaTierSplitsTest -v`
Expected: PASS

**Step 4: Run full test suite**

Run: `forge test`
Expected: All tests pass (53 existing + new split tests).

**Step 5: Commit**

```bash
git add test/DefifaTierSplits.t.sol
git commit -m "test: add per-tier split integration tests"
```

---

### Task 8: Format and final verification

**Step 1: Format**

Run: `forge fmt`

**Step 2: Verify formatting**

Run: `forge fmt --check`
Expected: No diffs.

**Step 3: Run full test suite**

Run: `forge test`
Expected: All tests pass.

**Step 4: Commit any formatting changes**

```bash
git add -A
git commit -m "style: forge fmt"
```
