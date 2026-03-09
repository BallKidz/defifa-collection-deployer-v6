# defifa-collection-deployer-v6 -- Risks

Deep implementation-level risk analysis with line references, severity ratings, and test coverage mapping.

## Trust Assumptions

1. **DefifaGovernor** -- All games share one `DefifaGovernor` instance (singleton `Ownable` by `DefifaDeployer`). A bug in the governor affects every game simultaneously.
2. **DefifaDeployer** -- Owns all game JB projects. Controls ruleset queuing for `fulfillCommitmentsOf` and `triggerNoContestFor`. Cannot be upgraded.
3. **Tier Holders (Attestors)** -- Score outcomes via attestation-weighted governance. 50% quorum of minted tiers' attestation power determines the scorecard.
4. **Core Protocol** -- Relies on `JBMultiTerminal` for payment processing, `JBTerminalStore` for balance tracking, `JB721TiersHookStore` for NFT tier data, and `JBRulesets` for phase management. Bugs in any of these propagate.
5. **Immutable Fee Configuration** -- `DEFIFA_FEE_DIVISOR = 20` (5%) and `BASE_PROTOCOL_FEE_DIVISOR = 40` (2.5%) are compile-time constants. Cannot be updated without redeploying.

---

## Risk Inventory

### RISK-1: Whale Tier Dominance via Multi-Tier Accumulation

**Severity:** MEDIUM
**Status:** KNOWN, ACCEPTED
**Tested:** `DefifaSecurityTest.testQuorum_50pctMintedTiers`

**Description:** An attacker buys the majority of tokens in 50%+ of tiers, gaining enough attestation power to single-handedly reach quorum and ratify a self-serving scorecard.

**Mechanism:** Each tier caps attestation power at `MAX_ATTESTATION_POWER_TIER` (1e9, DefifaGovernor line 64). Quorum is 50% of minted tiers' total power (DefifaGovernor `quorum()`, line 203-223). Holding `>50%` of tokens in `>50%` of minted tiers gives the attacker `>25%` of total power per tier, easily exceeding quorum.

**Attack scenario:**
1. Game has 10 tiers, 6 minted. Quorum = `6 * 1e9 / 2 = 3e9`.
2. Attacker mints majority in 4 tiers. Per tier: `1e9 * (attacker_tokens / tier_total)`.
3. If attacker holds 80% of each of 4 tiers: `4 * 0.8 * 1e9 = 3.2e9 > 3e9` quorum.
4. Attacker submits scorecard giving 100% weight to their tiers, attests alone, and ratifies after grace period.

**Mitigation:** Per-tier cap ensures dominance in a single high-supply tier is insufficient. Capital cost scales with number of tiers to control. Grace period (minimum 1 day, DefifaGovernor line 300) gives other holders time to counter-attest.

---

### RISK-2: Dynamic Quorum Based on Live Supply

**Severity:** MEDIUM
**Status:** KNOWN, ACCEPTED
**Tested:** `DefifaSecurityTest.testQuorum_50pctMintedTiers`

**Description:** Quorum is computed from `currentSupplyOfTier()` (live supply = minted - burned) at call time, not from a snapshot. If tokens are burned between attestation and ratification, quorum can decrease, making it easier to ratify.

**Mechanism:** `quorum()` (DefifaGovernor line 203-223) calls `IDefifaHook.currentSupplyOfTier()` for each tier. This reads the live minted-minus-burned count from `DefifaHookLib.computeCurrentSupply()` (line 260-271). During SCORING phase, cash-outs burn tokens but revert with `NothingToClaim` (DefifaHook line 675) because weights are not set yet. This effectively prevents burns during SCORING before scorecard ratification.

**Residual risk:** If a future code path allows burns during SCORING (e.g., via a different hook), quorum could drift downward.

**Mitigation:** `NothingToClaim` revert during SCORING prevents practical exploitation. After ratification, quorum changes are irrelevant.

---

### RISK-3: Cash-Out Weight Integer Division Truncation

**Severity:** LOW
**Status:** KNOWN, BOUNDED
**Tested:** `DefifaSecurityTest.testRounding_extremeWeights`

**Description:** `computeCashOutWeight()` (DefifaHookLib line 129) divides `_weight / _totalTokensForCashoutInTier` using integer division, permanently locking dust in the contract.

**Bound:** Maximum loss = 1 wei per tier per game. With 128 maximum tiers, at most 128 wei locked per game.

**Proof from test:** `testRounding_extremeWeights` allocates weight 1 to tier 1, `TOTAL_CASHOUT_WEIGHT - 2` to tier 2, and weight 1 to tier 3. Verifies fund conservation within 3 wei tolerance.

---

### RISK-4: Fee Token Dilution from Reserved Mints

**Severity:** LOW
**Status:** BY DESIGN
**Tested:** `DefifaSecurityTest.testC_D3_reservedMintersGetFeeTokens`

**Description:** Reserved mints increment `_totalMintCost` by `tier.price * count` (DefifaHook line 568), even though no ETH was actually paid. This dilutes paid minters' share of fee tokens (`$DEFIFA` / `$NANA`).

**Mechanism:** `_claimTokensFor()` distributes fee tokens proportional to `shareToBeneficiary / outOfTotal` where `outOfTotal = _totalMintCost` (DefifaHook line 670-671). Reserved mints inflate `_totalMintCost` without adding to the hook's fee token balance, reducing each paid minter's proportional claim.

**Example:** 2 paid mints at 1 ETH + 2 reserved mints at 1 ETH tier price. `_totalMintCost = 4 ETH`. Each token gets 25% of fee tokens. Paid minters effectively subsidize reserved recipients.

**Mitigation:** By design. The test `testC_D3_reservedMintersGetFeeTokens` verifies this exact behavior: reserved minters receive fee tokens proportional to tier price, paid minters receive proportional to their contribution, and all fee tokens are distributed with nothing left in the hook.

---

### RISK-5: Scorecard Timeout Can Block Legitimate Ratification

**Severity:** MEDIUM
**Status:** KNOWN, MITIGATED
**Tested:** `DefifaNoContestTest.testScorecardTimeout_elapsed_noContest`, `testNoContest_scorecardBlocked`

**Description:** If `scorecardTimeout` is set and elapses before a scorecard is ratified, the game permanently enters `NO_CONTEST`. Even a scorecard that has reached quorum cannot be ratified because `setTierCashOutWeightsTo` checks for SCORING phase (DefifaHook line 708).

**Mechanism:** `currentGamePhaseOf()` (DefifaDeployer line 258) returns `NO_CONTEST` when `block.timestamp > _currentRuleset.start + _ops.scorecardTimeout`. Once this condition is true, `setTierCashOutWeightsTo` reverts with `DefifaHook_GameIsntScoringYet` because the hook checks `gamePhaseReporter.currentGamePhaseOf(PROJECT_ID) != DefifaGamePhase.SCORING`.

**Mitigation:**
- Ratified scorecards take priority: `cashOutWeightIsSet` is checked before the timeout (DefifaDeployer line 239), so ratifying before timeout is definitive.
- `scorecardTimeout = 0` disables the mechanism entirely.
- The `triggerNoContestFor()` function allows anyone to queue a refund ruleset, ensuring players can recover funds.

---

### RISK-6: Delegation Locked After MINT Phase

**Severity:** MEDIUM
**Status:** BY DESIGN
**Tested:** `DefifaSecurityTest.testM_D6_delegationBlocked`, `DefifaHook_AuditFindings.test_M5_attestationUnitsPreservedOnTransferToUndelegatedRecipient`

**Description:** `setTierDelegateTo` and `setTierDelegatesTo` only work during MINT phase (DefifaHook lines 730, 740). After MINT, NFT transfers auto-delegate to the recipient (if no delegate set), but holders cannot explicitly re-delegate.

**Implication:** If a holder transfers an NFT to a new owner during REFUND or SCORING, the new owner auto-delegates to themselves (DefifaHook `_transferTierAttestationUnits`, line 1002-1005). But if the new owner wants to delegate to a third party, they cannot.

**Mitigation:** By design. Prevents post-MINT governance manipulation. Auto-delegation on transfer (audit finding M-5 fix) ensures attestation units are never lost to `address(0)`.

---

### RISK-7: Single Governor Instance Across All Games

**Severity:** MEDIUM
**Status:** KNOWN, ACCEPTED

**Description:** All games share a single `DefifaGovernor` contract. A bug in `ratifyScorecardFrom`, `attestToScorecardFrom`, or `submitScorecardFor` affects every game.

**Specific concern:** The governor executes scorecard calldata via low-level call `_metadata.dataHook.call(_calldata)` (DefifaGovernor line 395). If the calldata construction in `_buildScorecardCalldataFor` (line 490-497) has a vulnerability, it could affect all games.

**Mitigation:** Governor logic is deliberately simple (no upgradability, no complex state transitions). Scorecard calldata is a deterministic ABI encoding of `setTierCashOutWeightsTo.selector` with tier weights.

---

### RISK-8: Front-Running of Clone Initialization

**Severity:** LOW
**Status:** MITIGATED
**Tested:** Implicitly by `launchGameWith` tests

**Description:** `DefifaHook` clones are created via `Clones.cloneDeterministic` with salt `keccak256(abi.encodePacked(msg.sender, _currentNonce))` (DefifaDeployer line 526). This prevents front-running because a different caller produces a different address.

**Residual risk:** The `initialize()` function has a re-initialization guard (`if (address(store) != address(0)) revert()`, DefifaHook line 487), but between clone creation and initialization (within the same transaction), there is no window for front-running.

---

### RISK-9: Fulfillment Failure Does Not Block Ratification

**Severity:** LOW
**Status:** MITIGATED
**Tested:** `M36_FulfillmentBlocksRatification.test_ratificationSucceedsWhenFulfillmentReverts`

**Description:** `ratifyScorecardFrom` wraps `fulfillCommitmentsOf` in a try-catch (DefifaGovernor lines 402-405). If fulfillment fails (e.g., `sendPayoutsOf` reverts), the scorecard is still ratified and `FulfillmentFailed` event is emitted.

**Implication:** Fees may not be distributed, but the game proceeds to COMPLETE. `fulfillCommitmentsOf` can be retried separately.

**Mitigation:** The try-catch is intentional to prevent fulfillment issues from permanently blocking game completion. The `fulfilledCommitmentsOf` guard (DefifaDeployer line 304) allows exactly one successful fulfillment.

---

### RISK-10: Grace Period Bypass on Early Scorecard Submission

**Severity:** LOW
**Status:** FIXED (Regression tested)
**Tested:** `M35_GracePeriodBypass.test_gracePeriodExtendsFromAttestationStart`

**Description:** When a scorecard is submitted before `attestationStartTime`, the grace period could previously expire before attestations even begin. Fixed by anchoring `gracePeriodEnds` to `attestationsBegin` rather than submission time.

**Implementation:** `_scorecard.gracePeriodEnds = uint48(_attestationsBegin + attestationGracePeriodOf(_gameId))` (DefifaGovernor line 468). The `attestationsBegin` is `max(block.timestamp, attestationStartTime)` (lines 460-463).

---

### RISK-11: Overweight Scorecard Rejection

**Severity:** LOW
**Status:** SAFE
**Tested:** `DefifaSecurityTest.testC_D2_rejectsOverweight`

**Description:** `validateAndBuildWeights` (DefifaHookLib line 85) enforces `_cumulativeCashOutWeight == TOTAL_CASHOUT_WEIGHT`. Any scorecard that does not sum to exactly 1e18 reverts with `DefifaHook_InvalidCashoutWeights`.

**Additional validations:**
- Tier IDs must be in strict ascending order (line 61): prevents duplicate tier entries.
- Tier must be in category 0 (line 68): prevents weight assignment to non-game tiers.
- Tier must exist (line 71): prevents weight assignment to nonexistent tiers.

---

### RISK-12: No-Contest Cash-Out Requires Explicit Trigger

**Severity:** MEDIUM
**Status:** BY DESIGN
**Tested:** `DefifaNoContestTest.testNoContest_cashOutBeforeTrigger_reverts`, `testMinParticipation_cashOutReturnsMintPrice`, `testScorecardTimeout_cashOutReturnsMintPrice`, `testNoContest_allUsersCanRefund`

**Description:** When a game enters NO_CONTEST, users cannot immediately cash out. They must first call `triggerNoContestFor()` (DefifaDeployer line 585), which queues a new ruleset without payout limits. Without this trigger, the SCORING ruleset has payout limits consuming the entire balance, leaving surplus at 0.

**Mechanism:** The SCORING ruleset sets `payoutLimits` to `type(uint224).max` (DefifaDeployer line 759), meaning all balance is allocated as payout. Since `ownerMustSendPayouts = true`, no one can send payouts, but the balance is not counted as surplus either. `triggerNoContestFor()` queues a ruleset with no `fundAccessLimitGroups`, making the entire balance available as surplus.

**Mitigation:** `triggerNoContestFor()` is permissionless -- anyone can call it. The function is idempotent (cannot be called twice: line 592).

---

### RISK-13: `_totalMintCost` Accounting Integrity

**Severity:** CRITICAL (if violated)
**Status:** SAFE (proven by invariant tests)
**Tested:** `DefifaMintCostInvariant.invariant_totalMintCostMatchesExpected`, `invariant_totalMintCostEqualsPriceTimesLiveTokens`, `invariant_tokenCountConsistency`

**Description:** `_totalMintCost` tracks the cumulative price of all live (non-burned) NFTs. It is incremented on mint (DefifaHook line 859) and reserved mint (line 568), and decremented on cash-out (line 678). If this value drifts, fee token distribution (`_claimTokensFor`) will over/under-allocate.

**Invariant proof:** Stateful fuzz testing (`MintCostHandler`) performs random mints and refunds, verifying after each operation that `_totalMintCost == tierPrice * liveTokenCount` and `_totalMintCost == expectedMintCost` (shadow accounting).

---

### RISK-14: Fee Accounting After Split Normalization

**Severity:** MEDIUM
**Status:** SAFE (proven by tests)
**Tested:** `DefifaFeeAccountingTest.testFeeAccounting_defaultSplits`, `testCashOutAfterFees`, `testFeeAccounting_noRoundingLoss`, `testFeeAccounting_withUserSplits`, `testCashOutAfterFees_withUserSplits`, `testSplitNormalization_noRoundingLoss`

**Description:** Fee splits are normalized in `_buildSplits()` (DefifaDeployer lines 825-894). The NANA split absorbs the rounding remainder (line 883). `_commitmentPercentOf[_gameId]` stores the absolute total, and `fulfillCommitmentsOf` computes `mulDiv(_pot, _commitmentPercentOf[gameId], SPLITS_TOTAL_PERCENT)` (line 326) to determine the fee amount.

**Proven property:** `fee + surplus == originalPot` (exact equality, tested in `testFeeAccounting_noRoundingLoss`).

---

### RISK-15: Reentrancy in `afterCashOutRecordedWith`

**Severity:** LOW
**Status:** SAFE

**Description:** `afterCashOutRecordedWith` (DefifaHook lines 602-679) burns tokens before making external calls. The burn sequence:
1. Burns tokens in a loop (line 648)
2. Calls `_didBurn` to record burns in the store (line 658)
3. Increments `amountRedeemed` (line 666)
4. Calls `_claimTokensFor` which transfers fee tokens (line 669-671)

**Analysis:** Tokens are burned before state updates and before any external token transfers. The JB terminal has already committed the cash-out amount before calling this hook. A reentrant call would fail because the burned tokens no longer exist (ownership check at line 643 would revert).

---

### RISK-16: Reentrancy in `fulfillCommitmentsOf`

**Severity:** LOW
**Status:** SAFE

**Description:** `fulfillCommitmentsOf` (DefifaDeployer lines 302-388) sets `fulfilledCommitmentsOf[gameId]` (line 330) before calling `sendPayoutsOf` (line 334) and `queueRulesetsOf` (line 383). The guard at line 304 (`if (fulfilledCommitmentsOf[gameId] != 0) return`) prevents re-entry.

**Edge case:** Uses `max(feeAmount, 1)` (line 330) to ensure the guard works even when the pot rounds to 0 fee.

---

### RISK-17: Attestation Unit Conservation on Transfer

**Severity:** HIGH (before fix)
**Status:** FIXED
**Tested:** `DefifaHook_AuditFindings.test_M5_attestationUnitsPreservedOnTransferToUndelegatedRecipient`, `test_M5_multipleTransfersToUndelegatedRecipientsPreserveUnits`

**Description:** Previously, transferring an NFT to a recipient with no delegate set would lose attestation units (sender's delegate lost units but no one gained them). Fixed by auto-delegating undelegated recipients to themselves in `_transferTierAttestationUnits` (DefifaHook lines 1001-1006).

**Invariant verified:** Sum of all delegate attestation units equals total attestation supply across chains of 3+ sequential transfers.

---

### RISK-18: Fund Conservation Across Varying Game Parameters

**Severity:** CRITICAL (if violated)
**Status:** SAFE
**Tested:** `DefifaSecurityTest.testFuzz_fundConservation` (fuzz), `testHighVolume_32tiers`, `testMultiPlayer_winnerTakesAll`, `testRefundIntegrity`

**Description:** Total cash-outs + remaining surplus must equal the pre-fulfillment pot (minus fees). This is the fundamental economic invariant.

**Fuzz test parameters:** 2-12 tiers, 1-3 players per tier, 1 ETH tier price. Tolerance: N wei where N = total user count.

**Proven for edge cases:**
- 32 tiers at 100 ETH each (3,200 ETH pot): dust <= 1e15 wei
- Winner-takes-all (100% to one tier): losers get 0 ETH, winners split evenly within 0.1%
- Extreme weights (1, TOTAL-2, 1): tier 2 gets >99% of pot

---

### RISK-19: `uint208` Overflow in Attestation Checkpoints

**Severity:** LOW
**Status:** SAFE (bounded)

**Description:** Attestation units use OpenZeppelin `Checkpoints.Trace208` which stores values as `uint208`. The `_moveTierDelegateAttestations` function casts amounts to `uint208` (DefifaHook lines 892, 902).

**Bound:** Maximum attestation units per tier = `tier.votingUnits * tier.initialSupply`. With `initialSupply = 999_999_999` and typical `votingUnits` values, overflow of `uint208` (max ~4.1e62) is practically impossible.

---

### RISK-20: Stale `block.timestamp` in Via-IR Compiled Tests

**Severity:** LOW (test-only)
**Status:** MITIGATED

**Description:** Multiple test files use a `TimestampReader` helper contract to read `block.timestamp` via an external call, bypassing the Solidity via-IR optimizer's timestamp caching. This is a test infrastructure concern, not a production risk.

---

## Reentrancy Summary

| Function | Protection | External Calls After State Updates | Risk |
|----------|-----------|-----------------------------------|------|
| `afterCashOutRecordedWith` | Tokens burned before state updates; terminal already committed | `_claimTokensFor` (fee token transfer) | LOW |
| `afterPayRecordedWith` | Payment recorded before minting | None after mint | LOW |
| `fulfillCommitmentsOf` | `fulfilledCommitmentsOf` guard set before `sendPayoutsOf` | `sendPayoutsOf`, `queueRulesetsOf` | LOW |
| `triggerNoContestFor` | `noContestTriggeredFor` set before `queueRulesetsOf` | `queueRulesetsOf` | LOW |
| `ratifyScorecardFrom` | `ratifiedScorecardIdOf` set before low-level call | `dataHook.call`, `fulfillCommitmentsOf` (try-catch) | LOW |

---

## Test Coverage Map

| Risk | Test File(s) | Specific Test(s) |
|------|-------------|-----------------|
| RISK-1 Whale dominance | `DefifaSecurity.t.sol` | `testQuorum_50pctMintedTiers` |
| RISK-2 Dynamic quorum | `DefifaSecurity.t.sol` | `testQuorum_50pctMintedTiers`, `testNoCashOut_beforeScorecard` |
| RISK-3 Weight truncation | `DefifaSecurity.t.sol` | `testRounding_extremeWeights` |
| RISK-4 Fee token dilution | `DefifaSecurity.t.sol` | `testC_D3_reservedMintersGetFeeTokens` |
| RISK-5 Scorecard timeout | `DefifaNoContest.t.sol` | `testScorecardTimeout_elapsed_noContest`, `testScorecardTimeout_exactBoundary_scoring`, `testNoContest_scorecardBlocked` |
| RISK-6 Delegation locked | `DefifaSecurity.t.sol` | `testM_D6_delegationBlocked` |
| RISK-7 Single governor | (No isolation test) | Design review only |
| RISK-8 Clone front-running | (Implicit) | All `launchGameWith` tests |
| RISK-9 Fulfillment failure | `regression/M36_FulfillmentBlocksRatification.t.sol` | `test_ratificationSucceedsWhenFulfillmentReverts` |
| RISK-10 Grace period bypass | `regression/M35_GracePeriodBypass.t.sol` | `test_gracePeriodExtendsFromAttestationStart` |
| RISK-11 Overweight scorecard | `DefifaSecurity.t.sol` | `testC_D2_rejectsOverweight` |
| RISK-12 No-contest trigger | `DefifaNoContest.t.sol` | `testNoContest_cashOutBeforeTrigger_reverts`, `testTriggerNoContest_revertsWhenNotNoContest`, `testTriggerNoContest_revertsWhenAlreadyTriggered` |
| RISK-13 `_totalMintCost` | `DefifaMintCostInvariant.t.sol` | `invariant_totalMintCostMatchesExpected`, `invariant_totalMintCostEqualsPriceTimesLiveTokens`, `invariant_tokenCountConsistency` |
| RISK-14 Fee accounting | `DefifaFeeAccounting.t.sol` | All 6 tests |
| RISK-15 Cash-out reentrancy | (Code review) | State ordering analysis |
| RISK-16 Fulfillment reentrancy | (Code review) | Guard analysis |
| RISK-17 Attestation conservation | `DefifaHook_AuditFindings.t.sol` | `test_M5_attestationUnitsPreservedOnTransferToUndelegatedRecipient`, `test_M5_multipleTransfersToUndelegatedRecipientsPreserveUnits` |
| RISK-18 Fund conservation | `DefifaSecurity.t.sol` | `testFuzz_fundConservation`, `testHighVolume_32tiers`, `testMultiPlayer_winnerTakesAll`, `testRefundIntegrity` |
| RISK-19 uint208 overflow | (Bounded analysis) | Arithmetic review |
| RISK-20 Timestamp caching | (Test infrastructure) | `TimestampReader` pattern |

### Untested Areas

| Area | Reason | Risk |
|------|--------|------|
| ERC-20 token games (non-ETH) | All tests use `NATIVE_TOKEN` | LOW -- same code path, `SafeERC20` used |
| Games with >32 tiers | Fuzz tests cap at 12, security tests at 32 | LOW -- 128-element array bounds |
| Custom `tokenUriResolver` interaction | SVG test exists but no adversarial URI resolver | LOW -- resolver is view-only |
| Concurrent multi-game governor state | Tests use single game per governor | MEDIUM -- storage isolation via `gameId` mapping keys |
| `Clones.cloneDeterministic` collision | Deterministic but no collision test | LOW -- `keccak256(sender, nonce)` salt is unique per caller per call |

---

## Severity Legend

| Rating | Definition |
|--------|-----------|
| CRITICAL | Fund loss or protocol-breaking if violated; proven safe by invariant tests |
| HIGH | Significant impact on game fairness or fund distribution; fixed via audit |
| MEDIUM | Exploitable under specific conditions; mitigated by design choices or economic constraints |
| LOW | Theoretical risk with bounded impact or test-only concern |
