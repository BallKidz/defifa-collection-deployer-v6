# defifa-v5

On-chain prediction game built on Juicebox -- players mint NFT game pieces representing teams/outcomes, a governor-based scorecard system determines payouts, and winners burn their NFTs to claim rewards from the pot.

## Architecture

| Contract | Description |
|----------|-------------|
| `DefifaDeployer` | Game factory. Launches a Juicebox project with phased rulesets (Mint, optional Refund, Scoring, Complete), deploys a cloned `DefifaHook`, initializes the governor, and manages commitment fulfillment (fee payouts) after scoring. |
| `DefifaHook` | ERC-721 game piece hook (extends `JB721Hook`). Manages tier-based cash-out weights, per-tier attestation delegation with checkpointed voting power, and custom cash-out logic that distributes the pot proportionally based on the ratified scorecard. |
| `DefifaGovernor` | Scorecard governance. Accepts scorecard submissions (tier weight proposals), collects attestations from NFT holders weighted by tier ownership, and ratifies scorecards that reach 50% quorum. Executes the winning scorecard on the hook. |
| `DefifaTokenUriResolver` | On-chain SVG token URI resolver. Renders game cards with game phase, pot size, rarity, and value information using embedded Capsules typeface. |
| `DefifaProjectOwner` | Receives the Defifa fee project's ownership NFT and grants the deployer `SET_SPLIT_GROUPS` permission. |

### Game Lifecycle

| Phase | Cycle | Description |
|-------|-------|-------------|
| `COUNTDOWN` | 0 | Before minting opens. |
| `MINT` | 1 | Players pay to mint NFT game pieces. Cash outs available at face value. |
| `REFUND` | 2 (optional) | Minting closed, refunds still allowed. |
| `SCORING` | 3+ | Game started. Scorecard proposals submitted, attested to, and ratified via governor. |
| `COMPLETE` | -- | Scorecard ratified. Commitments fulfilled. Players burn NFTs to claim pot share. |

### Structs

| Struct | Purpose |
|--------|---------|
| `DefifaLaunchProjectData` | Full game configuration: name, tiers, token, durations, splits, attestation params, terminal, store. |
| `DefifaTierParams` | Per-tier config: name, price, reserved rate, beneficiary, encoded IPFS URI. |
| `DefifaTierCashOutWeight` | Scorecard entry: tier ID and its cash-out weight. |
| `DefifaOpsData` | Packed game timing: token address, start time, mint duration, refund duration. |
| `DefifaScorecard` | Scorecard timing: attestation begin timestamp and grace period end timestamp. |
| `DefifaAttestations` | Attestation tracking: count and per-address attestation flag. |
| `DefifaDelegation` | Delegation assignment: delegatee address and tier ID. |

### Enums

| Enum | Values |
|------|--------|
| `DefifaGamePhase` | `COUNTDOWN`, `MINT`, `REFUND`, `SCORING`, `COMPLETE`, `NO_CONTEST_INEVITABLE`, `NO_CONTEST` |
| `DefifaScorecardState` | `PENDING`, `ACTIVE`, `DEFEATED`, `SUCCEEDED`, `RATIFIED` |

## Install

```bash
npm install @ballkidz/defifa-collection-deployer
```

## Develop

`defifa-v5` uses [npm](https://www.npmjs.com/) for package management and [Foundry](https://github.com/foundry-rs/foundry) for builds, tests, and deployments. Requires `via-ir = true` in foundry.toml. Source directory is `contracts/`, not `src/`.

```bash
curl -L https://foundry.paradigm.xyz | sh
npm install && forge install
```

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts and write artifacts to `out`. |
| `forge test` | Run the test suite. |
| `forge fmt` | Lint Solidity files. |
| `forge build --sizes` | Get contract sizes. |
| `forge clean` | Remove build artifacts and cache. |
