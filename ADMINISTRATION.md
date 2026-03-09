# Administration

Admin privileges and their scope in defifa-collection-deployer-v6.

## Roles

| Role | Who | How Assigned |
|------|-----|-------------|
| **Game Creator** | Any EOA or contract that calls `DefifaDeployer.launchGameWith()` | Self-selected; permissionless |
| **DefifaDeployer** (contract) | Singleton deployed at protocol setup | Immutable; owns all game JB projects and the governor |
| **DefifaGovernor** (contract) | Singleton; `Ownable` by the DefifaDeployer | Ownership transferred from deployer at construction |
| **DefifaHook** (per-game clone) | One clone per game; `Ownable` by the DefifaGovernor | Ownership transferred from deployer during `launchGameWith()` (line 567) |
| **DefifaProjectOwner** | Optional proxy contract that holds the Defifa fee project NFT | Receives project NFT; grants `SET_SPLIT_GROUPS` to deployer |
| **Scorecard Submitter** | Any address during SCORING phase | Permissionless (`submitScorecardFor`, DefifaGovernor line 413) |
| **Attestor** | Any NFT holder with attestation weight | Must hold game NFTs; weight proportional to holdings per tier |
| **Default Attestation Delegate** | Address set at game launch | Set via `DefifaLaunchProjectData.defaultAttestationDelegate` |
| **Tier Delegate** | Any address delegated attestation units by an NFT holder | Set via `setTierDelegateTo` / `setTierDelegatesTo` during MINT phase only |

## Privileged Functions

### DefifaDeployer

| Function | Required Role | Permission Check | What It Does |
|----------|--------------|-----------------|-------------|
| `launchGameWith()` | Anyone | None (permissionless) | Creates a new JB project, clones DefifaHook, initializes governor, configures rulesets with MINT/REFUND/SCORING phases. Game parameters are immutable after this call. |
| `fulfillCommitmentsOf()` | Anyone | Guarded by `fulfilledCommitmentsOf[gameId] != 0` reentrancy check; requires `cashOutWeightIsSet` on the hook | Sends fee payouts (Defifa 5% + NANA 2.5% + user splits) via `sendPayoutsOf`, then queues the final COMPLETE ruleset. Can only execute once per game. |
| `triggerNoContestFor()` | Anyone | Requires `currentGamePhaseOf(gameId) == NO_CONTEST` and `!noContestTriggeredFor[gameId]` | Queues a new ruleset without payout limits so surplus equals balance, enabling full refunds. Can only execute once per game. |

### DefifaGovernor

| Function | Required Role | Permission Check | What It Does |
|----------|--------------|-----------------|-------------|
| `initializeGame()` | DefifaDeployer (owner) | `onlyOwner` (line 294) | Sets attestation start time and grace period for a game. Enforces minimum 1-day grace period. Called automatically during `launchGameWith()`. |
| `submitScorecardFor()` | Anyone | Must be in SCORING phase; no ratified scorecard yet; no duplicate scorecard hash; weighted tiers must have nonzero supply | Submits a scorecard for attestation. Sets `attestationsBegin` and `gracePeriodEnds` timestamps. |
| `attestToScorecardFrom()` | Any NFT holder | Must be in SCORING phase; scorecard must be ACTIVE or SUCCEEDED; caller cannot have already attested | Records attestation weight based on tier holdings at the scorecard's `attestationsBegin` timestamp. |
| `ratifyScorecardFrom()` | Anyone | Scorecard must be in SUCCEEDED state (quorum met + grace period elapsed); no scorecard already ratified | Executes the scorecard via low-level call to `setTierCashOutWeightsTo` on the hook, then tries `fulfillCommitmentsOf`. |

### DefifaHook

| Function | Required Role | Permission Check | What It Does |
|----------|--------------|-----------------|-------------|
| `initialize()` | DefifaDeployer | Reverts if `address(this) == codeOrigin` (line 484) or already initialized (`store != address(0)`, line 487) | One-time initialization of the cloned hook with game configuration, tiers, and tier names. Transfers ownership to caller. |
| `setTierCashOutWeightsTo()` | DefifaGovernor (owner) | `onlyOwner` (line 703); must be in SCORING phase; weights not already set | Sets the cash-out weight distribution across tiers. Validates weights sum to `TOTAL_CASHOUT_WEIGHT` (1e18). Irreversible -- once set, `cashOutWeightIsSet` is permanently true. |
| `setTierDelegateTo()` | Any NFT holder | Must be in MINT phase (line 730-732) | Delegates attestation units for a specific tier to another address. |
| `setTierDelegatesTo()` | Any NFT holder | Must be in MINT phase (line 740-742); delegatee cannot be address(0) | Batch delegation of attestation units across multiple tiers. |
| `mintReservesFor()` | Anyone | Reverts if `pauseMintPendingReserves` is set in ruleset metadata (line 537-539) | Mints reserved tokens to the tier's reserve beneficiary. Increments `_totalMintCost` so reserved recipients can claim fee tokens. |
| `afterPayRecordedWith()` | JB Terminal | Caller must be a terminal of the project (line 436-439); `msg.value` must be 0 | Processes payment: validates currency, mints NFTs, sets up attestation delegation. |
| `afterCashOutRecordedWith()` | JB Terminal | Caller must be a terminal of the project (line 610-613); `msg.value` must be 0 | Burns NFTs on cash-out, tracks redeemed amounts, distributes fee tokens during COMPLETE phase. |
| `transferOwnership()` | Current owner | `onlyOwner` (inherited from Ownable) | Transfers hook ownership. Used once during deployment to transfer from deployer to governor. |

### DefifaProjectOwner

| Function | Required Role | Permission Check | What It Does |
|----------|--------------|-----------------|-------------|
| `onERC721Received()` | JBProjects contract | `msg.sender` must be the JBProjects contract (line 47) | When the Defifa fee project NFT is transferred here, auto-grants `SET_SPLIT_GROUPS` permission to the DefifaDeployer. The project NFT is permanently locked -- cannot be recovered. |

## Game Lifecycle Administration

The game lifecycle is fully automated through Juicebox rulesets configured at launch. No admin can change phases manually.

```
COUNTDOWN --> MINT --> REFUND (optional) --> SCORING --> COMPLETE or NO_CONTEST
```

**Phase transitions are time-based, encoded in JBRuleset durations:**
- **COUNTDOWN**: Before `start - mintPeriodDuration - refundPeriodDuration`. Cycle number 0.
- **MINT**: Duration = `mintPeriodDuration`. Payments open, refunds at mint price. Cycle number 1.
- **REFUND**: Duration = `refundPeriodDuration` (optional, only if nonzero). Payments paused, refunds still at mint price. Cycle number 2.
- **SCORING**: Duration = 0 (no expiry). Payments paused. Cash-out weights must be set via governance. Cycle number 3+.
- **COMPLETE**: Entered when `cashOutWeightIsSet == true`. Cash-outs use scorecard weights.
- **NO_CONTEST**: Entered when `minParticipation` threshold is not met, or `scorecardTimeout` elapses without ratification. Requires `triggerNoContestFor()` to unlock refunds.

**Who controls scoring:**
1. Anyone submits a scorecard during SCORING (`submitScorecardFor`)
2. NFT holders attest based on their per-tier voting weight (`attestToScorecardFrom`)
3. Once quorum (50% of minted tiers' attestation power) is met and grace period passes, anyone ratifies (`ratifyScorecardFrom`)
4. The governor calls `setTierCashOutWeightsTo` on the hook via low-level call
5. `fulfillCommitmentsOf` sends fee payouts and queues the final ruleset

**No single entity controls scoring.** The process requires collective attestation from NFT holders across tiers.

## Immutable Configuration

The following are set at game creation and cannot be changed:

| Parameter | Set In | Notes |
|-----------|--------|-------|
| Tier prices | `launchGameWith()` | Uniform price across all tiers (`tierPrice`) |
| Tier count and names | `launchGameWith()` | Stored in hook during `initialize()` |
| Game timing (start, mint duration, refund duration) | `launchGameWith()` | Encoded as JBRuleset durations |
| Payment token | `launchGameWith()` | Single token per game |
| Fee structure | Constructor constants | `DEFIFA_FEE_DIVISOR = 20` (5%), `BASE_PROTOCOL_FEE_DIVISOR = 40` (2.5%) |
| Attestation start time | `launchGameWith()` | Stored in governor via `initializeGame()` |
| Attestation grace period | `launchGameWith()` | Minimum 1 day enforced (governor line 300) |
| Default attestation delegate | `launchGameWith()` | Stored in hook |
| `minParticipation` threshold | `launchGameWith()` | 0 = disabled |
| `scorecardTimeout` | `launchGameWith()` | 0 = disabled |
| User splits | `launchGameWith()` | Stored as JB split groups at game creation |
| Hook code origin | Constructor | Template contract for cloning |
| `TOTAL_CASHOUT_WEIGHT` | Constant | 1e18, cannot be changed |
| JB project ownership | `launchGameWith()` | Project owned by DefifaDeployer contract |

## Admin Boundaries

What admins CANNOT do:

1. **No one can change game rules after launch.** Tier prices, timing, token, fees, and split configuration are all immutable.

2. **No one can unilaterally set scorecard weights.** The `setTierCashOutWeightsTo` function requires `onlyOwner` (the governor), and the governor only calls it after a scorecard reaches quorum through collective attestation.

3. **No one can pause or cancel a game.** Once launched, the game proceeds through its phases automatically based on time.

4. **No one can extract funds from the treasury.** The `ownerMustSendPayouts` flag is set on the SCORING ruleset, and payouts are limited to the pre-configured splits. The deployer can only send payouts matching the split configuration.

5. **No one can mint new tiers or change tier supply.** Tiers are set once during `initialize()` with `cannotBeRemoved: true`.

6. **No one can change delegates after MINT phase.** `setTierDelegateTo` and `setTierDelegatesTo` both revert with `DefifaHook_DelegateChangesUnavailableInThisPhase` outside MINT.

7. **No one can re-set cash-out weights.** The `cashOutWeightIsSet` flag is checked before setting (line 713) and the function reverts with `DefifaHook_CashoutWeightsAlreadySet`.

8. **No one can re-ratify a scorecard.** The `ratifiedScorecardIdOf[gameId] != 0` check prevents double ratification (governor line 374).

9. **No one can fulfill commitments twice.** The `fulfilledCommitmentsOf[gameId] != 0` check (deployer line 304) prevents re-entry.

10. **No one can recover the project NFT from DefifaProjectOwner.** Once transferred, the NFT is permanently locked.

11. **The game creator has no ongoing privileges.** After `launchGameWith()` returns, the caller has no special role. All game administration is handled by the protocol contracts and collective governance.
