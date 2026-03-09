# defifa-collection-deployer-v6 — Risks

## Trust Assumptions

1. **DefifaGovernor** — All games share one DefifaGovernor instance. A bug in the governor affects all games.
2. **Game Deployer** — Configures game parameters (tiers, timing, fees) at deployment. Parameters are immutable after launch.
3. **Tier Holders (Attestors)** — Score outcomes via governance. Majority of attestation power determines the scorecard.
4. **Core Protocol** — Relies on JBMultiTerminal for treasury management and JB721TiersHook for NFT operations.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Whale tier dominance | Attacker buys majority of 6+ tiers, controls quorum | Per-tier attestation cap (1e9), but capital-intensive attack possible |
| Dynamic quorum | Quorum uses live supply, not snapshot — can change after grace period | `NothingToClaim` revert prevents burns during SCORING |
| Cash-out weight truncation | Integer division `weight/tokens` permanently locks dust | Bounded to ~1 wei per tier per game |
| Single governor | All games share one DefifaGovernor — bug affects all games | Design choice; governor logic is simple |
| Fee token dilution | Reserved mints get fee tokens proportional to tier price (not paid) | By design; reduces real payers' claims |
| Scorecard timeout | A scorecard that reaches quorum but isn't ratified before timeout becomes blocked | Submit scorecards early |
| Delegation timing | Token delegation only possible during MINT phase; later transfers inherit sender's delegate or go to address(0) | Delegate immediately after minting |
| Unfulfilled commitments | If deployer doesn't call `fulfillCommitmentsOf`, fee tokens aren't distributed | Permissionless call; anyone can trigger |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Game deployer | Configure tiers, timing, fee percent | Per-game (at deployment only) |
| Tier holders | Submit and attest to scorecards | Per-game |
| DefifaGovernor | Ratify scorecards, set cash-out weights | All games |
| DefifaProjectOwner | Proxy owner for JB project | Per-game |

## Reentrancy Considerations

| Function | Protection | Risk |
|----------|-----------|------|
| `afterCashOutRecordedWith` | Tokens burned BEFORE state updates; terminal state committed | LOW |
| `fulfillCommitmentsOf` | `fulfilledCommitmentsOf` set BEFORE external calls | LOW |
