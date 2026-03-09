# defifa-collection-deployer-v6 — Architecture

## Purpose

Prediction game platform built on Juicebox V6. Creates games where players buy NFT tiers representing outcomes, a governance process scores the outcomes, and winners claim treasury funds proportional to their tier's score.

## Contract Map

```
src/
├── DefifaDeployer.sol          — Deploys games: project + hook + governor + URI resolver
├── DefifaHook.sol              — Pay/cashout hook with game phase logic and attestation
├── DefifaGovernor.sol          — Scorecard ratification via tier-weighted governance
├── DefifaProjectOwner.sol      — Proxy owner for Defifa projects
├── DefifaTokenUriResolver.sol  — On-chain SVG metadata for game NFTs
├── enums/
│   ├── DefifaGamePhase.sol     — MINT → REFUND → SCORING → COMPLETE
│   └── DefifaScorecardState.sol
├── interfaces/                 — IDefifaDeployer, IDefifaHook, IDefifaGovernor, etc.
├── libraries/
│   └── DefifaHookLib.sol       — Game logic helpers
└── structs/                    — Scorecards, attestations, tier params, delegations
```

## Key Data Flows

### Game Lifecycle
```
MINT Phase:
  Creator → DefifaDeployer.launchGameWith()
    → Create JB project with DefifaHook as data/pay/cashout hook
    → Deploy DefifaGovernor for scorecard governance
    → Players buy NFT tiers (outcomes they predict)
    → Delegation happens during this phase only

REFUND Phase:
  → Players can cash out for full refund (100% redemption rate)

SCORING Phase:
  → Anyone → DefifaGovernor.submitScorecard(weights[])
    → Tier holders attest to scorecards
    → Scorecard reaches quorum → ratified
    → DefifaHook receives final cash-out weights per tier

COMPLETE Phase:
  → Winners → cash out NFTs at scored weights
  → Deployer → fulfillCommitmentsOf() distributes fee tokens
```

### Governance Flow
```
Scorer → DefifaGovernor.submitScorecard(tierWeights[])
  → Validate: correct phase, valid tier order, weights sum correctly
  → Create proposal hash

Attestor → DefifaGovernor.attestToScorecard(proposalId)
  → Must hold NFT tier tokens
  → Attestation weight = voting power from held tiers
  → When quorum reached → scorecard ratified
  → DefifaHook.setScorecard() called
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | Phase-aware pay/cashout behavior |
| Pay hook | `IJBPayHook` | NFT minting during MINT phase |
| Cash out hook | `IJBCashOutHook` | Scored weight redemptions |
| Token URI resolver | `IJB721TokenUriResolver` | On-chain SVG generation |
| Governor | `IDefifaGovernor` | Scorecard governance |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tier system
- `@bananapus/address-registry-v6` — Deterministic deploys
- `@bananapus/permission-ids-v6` — Permission constants
- `@openzeppelin/contracts` — Checkpoints, Ownable, Clones
- `@prb/math` — mulDiv
- `scripty.sol` — On-chain scripting for SVG
