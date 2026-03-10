# Per-Tier Splits Design

## Summary

Enable per-tier split groups in Defifa games. One global `splitPercent` applies to all tiers; each tier routes that percentage to its own JBSplit group (configured at game creation). Split funds are forwarded immediately on mint (default 721 hook behavior), reducing the available refund amount.

## Current State

- DefifaHook inherits `JB721Hook` (base), not `JB721TiersHook`
- `JB721Hook.beforePayRecordedWith()` returns `amount: 0` — no split forwarding
- `DefifaHook.afterPayRecordedWith()` rejects `msg.value != 0` — blocks forwarded funds
- `DefifaHook._processPayment()` requires exact payment (reverts on leftover)
- `JB721TiersHook` already has full split infrastructure via `JB721TiersHookLib`
- `JB721TierConfig` already has `splitPercent` (uint32) and `splits` (JBSplit[]) fields

## Changes

### 1. Override `beforePayRecordedWith` in DefifaHook

Copy JB721TiersHook's approach: call `JB721TiersHookLib.calculateSplitAmounts()` to compute per-tier split amounts from tier configs. Return the total split amount as the hook specification's forwarded amount.

### 2. Allow forwarded funds in `afterPayRecordedWith`

Remove the `msg.value != 0` rejection so the terminal can forward split funds to the hook for distribution.

### 3. Distribute splits in `_processPayment`

Before minting, call `JB721TiersHookLib.distributeAll()` to forward split funds to tier beneficiaries. Then mint NFTs with the remaining amount. Adjust the overspend check: minter pays `tierPrice` per NFT, of which `splitPercent` is forwarded — the remaining covers mint cost in the treasury.

### 4. Adjust refund math in `beforeCashOutRecordedWith`

During MINT/REFUND/NO_CONTEST phases, the refund amount is currently `cumulativeMintPrice` (what was paid). With splits, only `mintPrice - splitAmount` stayed in the treasury, so that's the maximum refundable. Update `DefifaHookLib.computeCashOutCount()` accordingly.

### 5. Track split amounts for refund calculation

Store the cumulative split amount per tier (or per token) so refund math knows how much was forwarded vs retained. Options:
- Store `splitPercent` at mint time (immutable per tier, can recompute)
- Or derive from tier config at refund time (simpler, no new storage)

Since `splitPercent` is immutable per tier (set at creation), we can derive the split amount at refund time: `refundAmount = tierPrice - (tierPrice * splitPercent / SPLITS_TOTAL_PERCENT)`.

### 6. DefifaDeployer: pass split config through

`DefifaTierParams` needs to include split configuration so the deployer can populate `JB721TierConfig.splitPercent` and `JB721TierConfig.splits` when creating tiers.

## Flow (After Changes)

**Mint:**
1. Player pays `tierPrice` to terminal
2. `beforePayRecordedWith` calculates `splitAmount = tierPrice * splitPercent / SPLITS_TOTAL_PERCENT`
3. Terminal records payment, forwards `splitAmount` to hook
4. `afterPayRecordedWith` receives forwarded funds
5. `_processPayment` calls `distributeAll()` to send splits to beneficiaries
6. Mints NFT, treasury retains `tierPrice - splitAmount`

**Refund:**
1. Player burns NFT during REFUND phase
2. `beforeCashOutRecordedWith` computes refund = `tierPrice - splitAmount`
3. Player receives reduced refund (split already forwarded, can't be clawed back)

**Cashout (COMPLETE phase):**
1. Unchanged — tier weights determine share of surplus
2. Surplus is smaller because splits already left the treasury

## Files to Modify

- `src/DefifaHook.sol` — override `beforePayRecordedWith`, fix `afterPayRecordedWith`, update `_processPayment`, update refund math
- `src/libraries/DefifaHookLib.sol` — update `computeCashOutCount` for split-aware refunds, add `computeSplitAmount` helper
- `src/structs/DefifaTierParams.sol` — add `splitPercent` and `splits` fields
- `src/DefifaDeployer.sol` — pass split config to `JB721TierConfig`
- `test/` — new test for split forwarding + reduced refund
