# defifa-v5

## Purpose

On-chain prediction game framework where players mint NFT game pieces, a governor-based scorecard determines tier payouts, and winners burn NFTs to claim proportional shares of the pot.

## Contracts

| Contract | Role |
|----------|------|
| `DefifaDeployer` | Factory that creates games as Juicebox projects with phased rulesets, cloned hooks, and governor initialization. Also manages post-game commitment fulfillment. |
| `DefifaHook` | ERC-721 hook (extends `JB721Hook`) that manages cash-out weights per tier, attestation delegation with checkpointed voting power, and proportional pot distribution on burn. |
| `DefifaGovernor` | Governance contract for scorecard submission, attestation, and ratification with 50% quorum requirement. |
| `DefifaTokenUriResolver` | On-chain SVG renderer for game card metadata with phase-aware display. |
| `DefifaProjectOwner` | Receives the Defifa fee project's ownership NFT and grants the deployer split-setting permissions. |

## Key Functions

| Function | Contract | What it does |
|----------|----------|--------------|
| `launchGameWith` | `DefifaDeployer` | Creates a new game: clones the hook, initializes it with tiers, launches a Juicebox project with phased rulesets (Mint -> optional Refund -> Scoring), initializes the governor, and transfers hook ownership to the governor. |
| `fulfillCommitmentsOf` | `DefifaDeployer` | After scorecard ratification, sends the fee portion (Defifa fee + protocol fee + user splits) as payouts, then queues a final ruleset with `pausePay=true` and zero payout limits so the remaining pot is available for cash outs. |
| `currentGamePhaseOf` | `DefifaDeployer` | Returns the current game phase based on ruleset cycle number and cash-out weight state. |
| `currentGamePotOf` | `DefifaDeployer` | Returns the current pot size, token address, and decimals for a game. |
| `submitScorecardFor` | `DefifaGovernor` | Submits a proposed scorecard (array of tier cash-out weights). Hashes the calldata to produce a scorecard ID. Stores attestation timing. |
| `attestToScorecardFrom` | `DefifaGovernor` | Attests to a scorecard. Weight is proportional to the caller's tier-delegated voting power at the attestation begin timestamp. Each address can only attest once per scorecard. |
| `ratifyScorecardFrom` | `DefifaGovernor` | Ratifies a scorecard that has reached `SUCCEEDED` state (50% quorum). Executes `setTierCashOutWeightsTo` on the hook and calls `fulfillCommitmentsOf`. |
| `quorum` | `DefifaGovernor` | Returns 50% of `MAX_ATTESTATION_POWER_TIER * numberOfMintedTiers`. Only tiers with non-zero supply count. |
| `getAttestationWeight` | `DefifaGovernor` | Calculates an account's attestation power across all tiers using checkpointed delegation snapshots and `mulDiv` for proportional weight. |
| `setTierCashOutWeightsTo` | `DefifaHook` | Sets cash-out weights for each tier. Validates total equals `TOTAL_CASHOUT_WEIGHT` (1e18). Only callable by owner (the governor). Only callable during scoring phase. |
| `setTierDelegateTo` | `DefifaHook` | Delegates attestation voting power for a specific tier to another address. Only during Mint or Refund phases. |
| `cashOutWeightOf` | `DefifaHook` | Returns the cash-out weight for a specific token ID (derived from its tier's weight divided by the tier's minted supply). |
| `initialize` | `DefifaHook` | Initializes a cloned hook with game ID, name, symbol, tiers, reporters, and delegation defaults. |

## Integration Points

| Dependency | Import | Used For |
|------------|--------|----------|
| `@bananapus/core-v6` | `IJBController`, `IJBDirectory`, `IJBRulesets`, `IJBTerminal`, `IJBMultiTerminal`, `JBRulesetConfig`, `JBSplit`, `JBConstants` | Project creation, ruleset management, terminal interactions, payout distribution. |
| `@bananapus/721-hook-v6` | `JB721TiersHook`, `JB721Hook`, `IJB721TiersHookStore`, `JB721TierConfig`, `JB721Tier` | NFT tier management, hook base class, tier storage. |
| `@bananapus/address-registry-v6` | `IJBAddressRegistry` | Hook address registration for discoverability. |
| `@bananapus/permission-ids-v6` | `JBPermissionIds` | Permission constants for split management. |
| `@openzeppelin/contracts` | `Ownable`, `Clones`, `IERC721Receiver`, `SafeERC20`, `Checkpoints`, `Strings` | Access control, minimal proxy cloning, safe token handling, checkpointed voting, string formatting. |
| `@prb/math` | `mulDiv` | Precise fixed-point arithmetic for attestation weight and pot distribution calculations. |

## Key Types

| Struct/Enum | Key Fields | Used In |
|-------------|------------|---------|
| `DefifaLaunchProjectData` | `name`, `tiers` (DefifaTierParams[]), `token` (JBAccountingContext), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24), `start` (uint48), `splits` (JBSplit[]), `attestationStartTime`, `attestationGracePeriod`, `defaultAttestationDelegate`, `terminal`, `store` | `DefifaDeployer.launchGameWith` |
| `DefifaTierParams` | `name`, `price` (uint80), `reservedRate` (uint16), `reservedTokenBeneficiary`, `encodedIPFSUri` (bytes32) | `DefifaLaunchProjectData.tiers` |
| `DefifaTierCashOutWeight` | `id` (uint256), `cashOutWeight` (uint256) | Scorecard proposals, `DefifaHook.setTierCashOutWeightsTo` |
| `DefifaOpsData` | `token` (address), `start` (uint48), `mintPeriodDuration` (uint24), `refundPeriodDuration` (uint24) | Internal game state in `DefifaDeployer` |
| `DefifaScorecard` | `attestationsBegin` (uint48), `gracePeriodEnds` (uint48) | `DefifaGovernor` internal scorecard tracking |
| `DefifaAttestations` | `count` (uint256), `hasAttested` (mapping address=>bool) | `DefifaGovernor` attestation tracking |
| `DefifaDelegation` | `delegatee` (address), `tierId` (uint256) | `DefifaHook.setTierDelegatesTo` |
| `DefifaGamePhase` | `COUNTDOWN`, `MINT`, `REFUND`, `SCORING`, `COMPLETE`, `NO_CONTEST_INEVITABLE`, `NO_CONTEST` | Phase reporting throughout |
| `DefifaScorecardState` | `PENDING`, `ACTIVE`, `DEFEATED`, `SUCCEEDED`, `RATIFIED` | `DefifaGovernor.stateOf` |

## Gotchas

- `TOTAL_CASHOUT_WEIGHT` is 1e18. Submitted scorecard tier weights must sum to exactly this value or `setTierCashOutWeightsTo` reverts with `INVALID_CASHOUT_WEIGHTS`.
- Tier IDs are limited to 128 (`uint256[128] _tierCashOutWeights`). Games with more than 128 tiers are not supported.
- `DefifaHook` is deployed as a minimal proxy clone (`Clones.clone`). The `initialize` function can only be called once (the code origin has `_gameId != 0` after its own construction).
- Scorecard attestation weight uses `mulDiv(MAX_ATTESTATION_POWER_TIER, userTierUnits, totalTierUnits)` per tier. If `totalTierUnits` is 0 for a tier (no delegations), that tier contributes no attestation power.
- The governor's `quorum` is dynamic: it only counts tiers that have at least one minted token. Adding minted tiers changes the quorum retroactively for all active proposals.
- `ratifyScorecardFrom` executes the scorecard via a low-level `.call` to the data hook address. This is necessary because the hook's `setTierCashOutWeightsTo` is called via the governor (which is the hook's owner).
- `fulfillCommitmentsOf` uses a reentrancy guard (setting `fulfilledCommitmentsOf[gameId] = 1` before external calls). If called when the pot is 0, it stores 1 as the fulfilled amount.
- The `defifaFeeDivisor` (default 20 = 5%) and `baseProtocolFeeDivisor` (default 40 = 2.5%) are mutable public state on the deployer. Changing them affects future games, not existing ones (splits are locked at launch time).
- `_buildSplits` normalizes all split percentages relative to the total absolute percent. Rounding remainder is absorbed by the protocol fee split (last in the array).
- Delegation changes are only allowed during `MINT` and `REFUND` phases. During `SCORING` and `COMPLETE`, attestation delegation is frozen to prevent manipulation.

## Example Integration

```solidity
import {IDefifaDeployer} from "./interfaces/IDefifaDeployer.sol";
import {DefifaLaunchProjectData} from "./structs/DefifaLaunchProjectData.sol";
import {DefifaTierParams} from "./structs/DefifaTierParams.sol";
import {DefifaTierCashOutWeight} from "./structs/DefifaTierCashOutWeight.sol";

// 1. Launch a game
DefifaTierParams[] memory tiers = new DefifaTierParams[](2);
tiers[0] = DefifaTierParams({
    name: "Team A",
    price: 0.01 ether,
    reservedRate: 0,
    reservedTokenBeneficiary: address(0),
    encodedIPFSUri: bytes32(0),
    shouldUseReservedTokenBeneficiaryAsDefault: false
});
tiers[1] = DefifaTierParams({
    name: "Team B",
    price: 0.01 ether,
    reservedRate: 0,
    reservedTokenBeneficiary: address(0),
    encodedIPFSUri: bytes32(0),
    shouldUseReservedTokenBeneficiaryAsDefault: false
});

// 2. Submit a scorecard (Team A wins 70%, Team B gets 30%)
DefifaTierCashOutWeight[] memory weights = new DefifaTierCashOutWeight[](2);
weights[0] = DefifaTierCashOutWeight({id: 1, cashOutWeight: 7e17});
weights[1] = DefifaTierCashOutWeight({id: 2, cashOutWeight: 3e17});
// Total must equal 1e18

uint256 scorecardId = governor.submitScorecardFor(gameId, weights);

// 3. Attest to the scorecard
governor.attestToScorecardFrom(gameId, scorecardId);

// 4. Ratify once quorum is reached
governor.ratifyScorecardFrom(gameId, weights);

// 5. Players burn NFTs via terminal cash-out to claim their share
```
