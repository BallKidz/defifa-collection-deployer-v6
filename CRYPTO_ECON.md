# Cryptoeconomics of Defifa

**The CEL Team.**
*This research was conducted by CryptoEconLab in coordination with Jango from the Defifa Team.*

*March 2026*

---

## Abstract

Defifa is a prediction-game protocol built on Juicebox V5 that transforms NFT minting into a parimutuel wagering mechanism with governance-ratified outcomes. Players purchase ERC-721 game pieces representing competing tiers (teams, candidates, outcomes), forming a shared treasury. After the event concludes, a decentralized attestation process ratifies a scorecard that assigns weights to each tier, redistributing the treasury proportionally. This paper formalizes the cryptoeconomic mechanics of Defifa games: the prize distribution formula, the attestation governance model, the fee extraction pipeline, the protocol-token incentive layer, and the rational actor strategies that emerge. We derive solvency guarantees, characterize equilibrium behavior under various participation profiles, analyze the game-theoretic properties of the scorecard ratification process, and identify the parameter regimes that maximize game integrity and participant welfare.

---

## Contents

1. [Introduction](#1-introduction)
   1. [What is Defifa?](#11-what-is-defifa)
   2. [How a Defifa Game Works (at a glance)](#12-how-a-defifa-game-works-at-a-glance)
   3. [The Design Parameters](#13-the-design-parameters)
2. [Mathematical Model of Defifa Economics](#2-mathematical-model-of-defifa-economics)
   1. [Parameters and State Variables](#21-parameters-and-state-variables)
   2. [Minting — Pot Formation](#22-minting--pot-formation)
   3. [Refund — Optionality Window](#23-refund--optionality-window)
   4. [Prize Distribution — The Scorecard Formula](#24-prize-distribution--the-scorecard-formula)
   5. [Fee Extraction Pipeline](#25-fee-extraction-pipeline)
   6. [Protocol Token Allocation](#26-protocol-token-allocation)
3. [Attestation Governance and Scorecard Ratification](#3-attestation-governance-and-scorecard-ratification)
   1. [Voting Power Model](#31-voting-power-model)
   2. [Quorum and Ratification Conditions](#32-quorum-and-ratification-conditions)
   3. [Scorecard Lifecycle](#33-scorecard-lifecycle)
   4. [Resistance to Strategic Manipulation](#34-resistance-to-strategic-manipulation)
4. [Price Dynamics and Value Flows](#4-price-dynamics-and-value-flows)
   1. [NFT Intrinsic Value During Minting](#41-nft-intrinsic-value-during-minting)
   2. [Post-Scorecard Valuation](#42-post-scorecard-valuation)
   3. [Secondary Market Implications](#43-secondary-market-implications)
5. [Rational Actor Analysis](#5-rational-actor-analysis)
   1. [Mint-Phase Strategy: Entry Timing](#51-mint-phase-strategy-entry-timing)
   2. [Refund-Phase Strategy: Option Exercise](#52-refund-phase-strategy-option-exercise)
   3. [Scoring-Phase Strategy: Attestation Delegation](#53-scoring-phase-strategy-attestation-delegation)
   4. [Complete-Phase Strategy: Claim vs Hold](#54-complete-phase-strategy-claim-vs-hold)
6. [Solvency and Conservation Laws](#6-solvency-and-conservation-laws)
   1. [The Conservation Guarantee](#61-the-conservation-guarantee)
   2. [Solvency Under Sequential Cash-Outs](#62-solvency-under-sequential-cash-outs)
   3. [Fee Impact on Total Claimable Value](#63-fee-impact-on-total-claimable-value)
7. [Game-Theoretic Properties](#7-game-theoretic-properties)
   1. [Defifa as a Parimutuel Mechanism](#71-defifa-as-a-parimutuel-mechanism)
   2. [Information Aggregation](#72-information-aggregation)
   3. [Multi-Game Dynamics and Protocol Flywheel](#73-multi-game-dynamics-and-protocol-flywheel)
8. [Parameter Design Space](#8-parameter-design-space)
   1. [Tier Count and Price Calibration](#81-tier-count-and-price-calibration)
   2. [Timing Parameters](#82-timing-parameters)
   3. [Fee Calibration and Protocol Sustainability](#83-fee-calibration-and-protocol-sustainability)
9. [Conclusions and Practical Implications](#9-conclusions-and-practical-implications)

---

## 1 Introduction

### 1.1 What is Defifa?

Defifa is a prediction-game protocol that transforms the act of purchasing an NFT into a wager on the outcome of a real-world event. It is deployed using the Juicebox V5 protocol and governed by a combination of immutable smart-contract rules and a minimal, time-bounded governance process for outcome resolution.

A Defifa game is a *tokenized parimutuel pool*: money goes in via NFT purchases, forming a shared pot; after the event concludes, a governance process assigns weights to each tier (team, outcome, candidate), and the pot is distributed proportionally. The game pieces are ERC-721 tokens organized into tiers, where each tier represents a distinct prediction. The purchase price of a tier token is fixed at game creation, and the payout is determined by post-event scorecard ratification.

Defifa games are:

- **Deterministic in structure**: all phases, durations, tier prices, and fee schedules are fixed at deployment.
- **Governance-minimal**: the only human input is the scorecard — a mapping from tiers to weights — ratified through an attestation process.
- **Self-custodial**: all funds remain in the Juicebox treasury; no operator can access them outside the protocol rules.
- **Composable**: games are standard Juicebox projects, inheriting the full protocol's accounting, terminal, and hook infrastructure.

### 1.2 How a Defifa Game Works (at a glance)

1. **Mint (pot formation).** During the mint phase, anyone can purchase NFTs representing tiers. Each NFT has a fixed price denominated in the game's base asset (e.g., ETH). All payments flow into a shared treasury — the *pot*. Players may delegate their attestation power to a chosen delegate at mint time.

2. **Refund (optional exit window).** If configured, a refund phase follows minting. During this period, players may burn their NFTs to reclaim the original mint price, allowing a risk-free exit for those who change their minds. No new mints are accepted.

3. **Score (outcome resolution).** Once the real-world event concludes, anyone may propose a *scorecard* — a vector of weights summing to $W_{\text{total}} = 10^{18}$ — assigning each tier its share of the pot. NFT holders attest to the scorecard they believe reflects the correct outcome. Once a scorecard achieves quorum, it can be ratified.

4. **Complete (prize distribution).** After ratification, protocol fees are extracted, and the remaining pot is available for claims. Each NFT holder burns their token to receive their proportional share, plus any accrued protocol tokens ($\text{DEFIFA}$ and $\text{BASE\_PROTOCOL}$).

### 1.3 The Design Parameters

A Defifa game is fully specified at deployment by a parameter tuple:

$$\mathcal{G} = \left( \{T_i\}_{i=1}^{N}, \; t_{\text{mint}}, \; t_{\text{refund}}, \; t_{\text{start}}, \; \phi_{\text{defifa}}, \; \phi_{\text{base}}, \; \mathcal{S}, \; \tau_{\text{attest}}, \; \tau_{\text{grace}} \right) \tag{1}$$

Where:

1. **Tier configuration** $\{T_i\}_{i=1}^{N}$: For each of the $N$ tiers, a fixed price $p_i$, an optional reserved rate $\rho_i$, and a reserved-token beneficiary address. The initial supply per tier is set to $999{,}999{,}999$ (effectively unlimited).

2. **Mint period duration** ($t_{\text{mint}}$): How long the minting window stays open, in seconds.

3. **Refund period duration** ($t_{\text{refund}}$): How long the refund window stays open after minting closes. May be zero (no refund phase).

4. **Game start time** ($t_{\text{start}}$): When the scoring phase begins — typically aligned with the real-world event's conclusion.

5. **Defifa fee divisor** ($\phi_{\text{defifa}}$): The fraction $1/\phi_{\text{defifa}}$ of the pot sent to the Defifa protocol project. Default: $\phi_{\text{defifa}} = 20$ (5%).

6. **Base protocol fee divisor** ($\phi_{\text{base}}$): The fraction $1/\phi_{\text{base}}$ of the pot sent to the base protocol project. Default: $\phi_{\text{base}} = 20$ (5%).

7. **Splits** ($\mathcal{S}$): Additional payout splits configured at deployment (e.g., for game organizers, charities).

8. **Attestation start time** ($\tau_{\text{attest}}$): Delay before attestation voting opens on a submitted scorecard.

9. **Attestation grace period** ($\tau_{\text{grace}}$): Duration of the attestation voting window.

Once set, the tuple $\mathcal{G}$ is immutable. Phase transitions occur automatically by timestamp, with the scoring phase having infinite duration (duration = 0) until the scorecard is ratified.

---

## 2 Mathematical Model of Defifa Economics

### 2.1 Parameters and State Variables

The economic behavior of a Defifa game is determined jointly by:

1. The immutable game parameters $\mathcal{G}$ (cf. Section 1.3), fixed at deployment;
2. The evolving state variables, which track the pot, token supplies, and claim status over time.

**Game parameters.** For reference, the parameter tuple is:

$$\mathcal{G} = \left( \{T_i\}_{i=1}^{N}, \; t_{\text{mint}}, \; t_{\text{refund}}, \; t_{\text{start}}, \; \phi_{\text{defifa}}, \; \phi_{\text{base}}, \; \mathcal{S}, \; \tau_{\text{attest}}, \; \tau_{\text{grace}} \right)$$

**State variables.** The core dynamic variables are listed in Table 1.

| Variable | Description |
|----------|-------------|
| $B(t)$ | Pot (treasury balance) at time $t$ |
| $n_i(t)$ | Number of NFTs minted in tier $i$ at time $t$ |
| $N_{\text{total}}(t)$ | Total NFTs outstanding across all tiers: $\sum_i n_i(t)$ |
| $M(t)$ | Total mint cost accumulated: $\sum_i n_i(t) \cdot p_i$ |
| $w_i$ | Scorecard weight assigned to tier $i$ (set at ratification, $\sum_i w_i = W_{\text{total}}$) |
| $d_i(t)$ | Number of NFTs redeemed (burned for prize) from tier $i$ after ratification |
| $B_{\text{prize}}$ | Net prize pool after fee extraction |

*Table 1: Core state variables of a Defifa game.*

At any time $t$, the state of the game is fully determined by the pair $\left(\mathcal{G}, \; \{B(t), n_i(t), w_i, d_i(t)\}\right)$, where $\mathcal{G}$ is the fixed game configuration and the second component evolves endogenously as players interact with the game. The next subsections formalize how each mechanism updates these variables.

### 2.2 Minting — Pot Formation

During the mint phase $[t_{\text{mint\_start}}, \; t_{\text{mint\_start}} + t_{\text{mint}})$, any participant may purchase NFTs from any tier $i$ at the fixed price $p_i$ per token (denominated in the game's base asset).

**Minted quantity.** For a payment amount $x$ of base asset directed at tier $i$:

$$q_i = \left\lfloor \frac{x}{p_i} \right\rfloor \tag{2}$$

The discrete nature of NFTs means that fractional tokens are not issued; any remainder is refunded.

**Reserved minting.** If tier $i$ has a reserved rate $\rho_i > 0$, then for every $\rho_i$ tokens minted by paying players, one additional token is minted to the reserved-token beneficiary. Reserved tokens are *not* paid for, but their cost is counted toward $M(t)$ for purposes of protocol-token distribution (cf. Section 2.6).

**State updates.** At the instant of a mint event where player $j$ purchases $q$ tokens of tier $i$:

$$B(t^+) = B(t^-) + q \cdot p_i \tag{3}$$

$$n_i(t^+) = n_i(t^-) + q \tag{4}$$

$$M(t^+) = M(t^-) + q \cdot p_i \tag{5}$$

These update rules define a monotonically increasing pot $B(t)$ during the mint phase, with the pot serving as a *fully-backed prize pool* — every unit of base asset entering the treasury corresponds to exactly $1/p_i$ NFTs issued to the payer.

**Pot composition.** At the end of the mint phase, the pot is:

$$B_{\text{mint}} = \sum_{i=1}^{N} n_i \cdot p_i \tag{6}$$

This is the total capital at risk in the game, and represents the complete prize pool before fee extraction.

### 2.3 Refund — Optionality Window

If $t_{\text{refund}} > 0$, a refund phase follows minting. During $[t_{\text{mint\_end}}, \; t_{\text{mint\_end}} + t_{\text{refund}})$:

- No new mints are accepted ($\texttt{pausePay} = \text{true}$).
- Any NFT holder may burn their token to reclaim its mint price.

**Refund mechanics.** A player burning $q$ tokens of tier $i$ receives exactly $q \cdot p_i$ base asset from the treasury:

$$R_{\text{refund}} = q \cdot p_i \tag{7}$$

**State updates.** After a refund:

$$B(t^+) = B(t^-) - q \cdot p_i \tag{8}$$

$$n_i(t^+) = n_i(t^-) - q \tag{9}$$

$$M(t^+) = M(t^-) - q \cdot p_i \tag{10}$$

The refund phase creates a *free option* for participants: they can observe late-breaking information (injury reports, market movements, team changes) and exit at zero cost. This option has value and we analyze its implications in Section 5.2.

**Key property.** The refund is dollar-for-dollar: every token refunded removes exactly its mint price from the pot, preserving the per-NFT backing ratio $B(t) / N_{\text{total}}(t)$ for uniform-priced games.

### 2.4 Prize Distribution — The Scorecard Formula

After the real-world event concludes and a scorecard is ratified, the game enters the COMPLETE phase. Players may burn their NFTs to claim their share of the prize pool.

**The scorecard.** A scorecard is a vector of weights $\mathbf{w} = (w_1, w_2, \ldots, w_N)$ satisfying:

$$\sum_{i=1}^{N} w_i = W_{\text{total}} = 10^{18} \tag{11}$$

Each $w_i \in [0, W_{\text{total}}]$ represents the fraction of the prize pool allocated to tier $i$'s holders.

**Per-token weight.** The weight assigned to a single NFT in tier $i$ is:

$$w_i^{\text{token}} = \frac{w_i}{\hat{n}_i} \tag{12}$$

where $\hat{n}_i$ is the *effective* number of tokens eligible for redemption in tier $i$ at the time the scorecard is ratified:

$$\hat{n}_i = n_i^{\text{minted}} - n_i^{\text{remaining}} - (n_i^{\text{burned}} - d_i) \tag{13}$$

Here $n_i^{\text{minted}}$ is the initial supply, $n_i^{\text{remaining}}$ is the unminted supply, $n_i^{\text{burned}}$ is the total burned count, and $d_i$ is the number of tokens redeemed *in the complete phase specifically*. This formula ensures that as tokens are redeemed in the complete phase, the denominator adjusts to maintain fair distribution for remaining holders.

**Cash-out value.** When a player burns a set of token IDs $\{k_1, k_2, \ldots, k_m\}$, the total claim is computed as:

$$C(\{k_j\}) = \frac{\sum_{j=1}^{m} w_{i(k_j)}^{\text{token}}}{W_{\text{total}}} \cdot (B_{\text{prize}} + A_{\text{redeemed}}) \tag{14}$$

where:
- $i(k_j)$ is the tier of token $k_j$,
- $B_{\text{prize}}$ is the current treasury balance (post-fee),
- $A_{\text{redeemed}}$ is the cumulative amount already redeemed by prior players.

The term $(B_{\text{prize}} + A_{\text{redeemed}})$ reconstructs the *original* post-fee pot, ensuring that the order of redemptions does not affect the payout per token. This is a critical design property: it makes Defifa a *path-independent* mechanism. The actual surplus from which the payout is drawn is the current treasury balance $B_{\text{prize}}$ — the formula normalizes against the full original pot to compute the correct fraction, then pays out from what remains.

**Special cases:**

- **Winner-take-all:** $w_j = W_{\text{total}}$ for a single tier $j$, all others zero.
- **Proportional split:** $w_i = W_{\text{total}} \cdot n_i / N_{\text{total}}$ weights by participation count.
- **No contest:** All $w_i$ set to return mint prices (full refund), or the game enters NO\_CONTEST phase and refunds automatically.

### 2.5 Fee Extraction Pipeline

Before prize distribution begins, the Deployer contract extracts protocol fees by calling `fulfillCommitmentsOf`. This triggers a `sendPayoutsOf` call on the terminal, distributing the pot according to the scoring-phase splits.

**Split structure.** The splits configured at game launch allocate the pot as follows:

1. **Base protocol fee:** $\frac{1}{\phi_{\text{base}}}$ of the pot to the base protocol project (default: 5%)
2. **Defifa fee:** $\frac{1}{\phi_{\text{defifa}}}$ of the pot to the Defifa project (default: 5%)
3. **Custom splits** ($\mathcal{S}$): Any additional game-creator-defined splits
4. **Remainder:** Returned to the game's treasury via `addToBalanceOf`

**Fee formulas.** Let $B_{\text{pot}}$ be the treasury balance at commitment fulfillment. The fee amounts are:

$$F_{\text{base}} = \frac{B_{\text{pot}}}{\phi_{\text{base}}} \tag{15}$$

$$F_{\text{defifa}} = \frac{B_{\text{pot}}}{\phi_{\text{defifa}}} \tag{16}$$

$$F_{\text{custom}} = \sum_{s \in \mathcal{S}} \frac{B_{\text{pot}} \cdot \text{percent}_s}{\text{SPLITS\_TOTAL\_PERCENT}} \tag{17}$$

The prize pool available for player claims is:

$$B_{\text{prize}} = B_{\text{pot}} - F_{\text{base}} - F_{\text{defifa}} - F_{\text{custom}} \tag{18}$$

With default parameters ($\phi_{\text{base}} = \phi_{\text{defifa}} = 20$, no custom splits), the prize pool is:

$$B_{\text{prize}} = B_{\text{pot}} \cdot \left(1 - \frac{1}{20} - \frac{1}{20}\right) = 0.9 \cdot B_{\text{pot}} \tag{19}$$

**Fee recycling.** The fees paid to the Defifa and base protocol projects are processed as standard Juicebox payments, which mint project tokens (e.g., $\text{DEFIFA}$, $\text{BASE\_PROTOCOL}$) to the beneficiary — in this case, the game's hook contract. These tokens are later distributed to players upon claim (Section 2.6).

### 2.6 Protocol Token Allocation

When fees are paid to the Defifa and base protocol projects, those projects mint their respective tokens to the game hook's address. The hook contract accumulates these tokens and distributes them proportionally when players burn their NFTs in the COMPLETE phase.

**Token allocation per player.** For a player burning tokens with cumulative mint cost $c$:

$$X_{\text{defifa}} = \frac{c}{M} \cdot D_{\text{total}} \tag{20}$$

$$X_{\text{base}} = \frac{c}{M} \cdot P_{\text{total}} \tag{21}$$

where:
- $M = $ total mint cost of all tokens ever minted in the game ($\texttt{\_totalMintCost}$),
- $D_{\text{total}} = $ total $\text{DEFIFA}$ tokens held by the hook contract,
- $P_{\text{total}} = $ total $\text{BASE\_PROTOCOL}$ tokens held by the hook contract.

**Key property.** Protocol token distribution is proportional to *original mint cost*, not to scorecard weight. This means that even holders of losing tiers (weight = 0) receive protocol tokens when burning their NFTs, creating a partial consolation mechanism that rewards participation regardless of outcome.

**Incentive alignment.** This design ensures that:
- *Larger bets* (higher mint cost) receive proportionally more protocol tokens,
- *All participants* have an incentive to burn their NFTs even in losing tiers (to claim protocol tokens),
- The protocol *captures value* from every game through its fee-token flywheel.

---

## 3 Attestation Governance and Scorecard Ratification

### 3.1 Voting Power Model

The attestation mechanism uses a *per-tier proportional representation* model rather than a simple one-token-one-vote system. This design prevents any single tier's holders from dominating the governance process.

**Attestation units.** Each tier $i$ carries a maximum attestation power of:

$$V_{\text{max}} = 10^9 \quad \text{(MAX\_ATTESTATION\_POWER\_TIER)} \tag{22}$$

This maximum is shared among all holders of tier $i$. A holder's attestation weight for tier $i$ is:

$$v_i^{\text{holder}} = V_{\text{max}} \cdot \frac{n_i^{\text{holder}}}{n_i^{\text{total}}} \tag{23}$$

where $n_i^{\text{holder}}$ is the number of tier-$i$ tokens delegated to (or held by) the attestor, and $n_i^{\text{total}}$ is the total minted supply of tier $i$ at the attestation snapshot timestamp.

**Total attestation weight.** A holder's total attestation power across all tiers is:

$$v^{\text{holder}} = \sum_{i : n_i^{\text{holder}} > 0} V_{\text{max}} \cdot \frac{n_i^{\text{holder}}}{n_i^{\text{total}}} \tag{24}$$

**Checkpoint-based snapshots.** Attestation power is measured at a fixed timestamp (the scorecard's `attestationsBegin` time), using historical checkpoints. This prevents vote-buying attacks where an actor acquires tokens immediately before voting.

**Delegation.** During the mint phase only, holders may delegate their attestation units to a chosen delegate address per tier. Delegation is:
- Per-tier (a holder can delegate different tiers to different delegates),
- Snapshot-locked (only the delegation state at `attestationsBegin` counts),
- Mint-phase-only (no delegation changes after minting closes).

### 3.2 Quorum and Ratification Conditions

**Quorum calculation.** The quorum required for scorecard ratification is:

$$Q = \frac{N_{\text{minted\_tiers}}}{2} \cdot V_{\text{max}} \tag{25}$$

where $N_{\text{minted\_tiers}}$ is the number of tiers that have at least one minted token. This means a scorecard must achieve attestation weight equivalent to *half of all minted tiers voting unanimously* to pass.

**Example.** For a game with 4 tiers (all minted), the quorum is:

$$Q = \frac{4}{2} \cdot 10^9 = 2 \times 10^9$$

This requires the equivalent of 2 full tiers' worth of unanimous attestation — for instance, all holders of 2 tiers attesting, or 50% of holders across all 4 tiers.

**Ratification conditions.** A scorecard can be ratified when all three conditions are met:
1. The scorecard's grace period has expired ($\texttt{gracePeriodEnds} < \texttt{block.timestamp}$),
2. The attestation count meets or exceeds quorum ($\texttt{attestations.count} \geq Q$),
3. No other scorecard has been ratified for this game.

### 3.3 Scorecard Lifecycle

Each submitted scorecard passes through five states:

| State | Condition |
|-------|-----------|
| **PENDING** | $\texttt{attestationsBegin} > \texttt{block.timestamp}$ |
| **ACTIVE** | $\texttt{attestationsBegin} \leq \texttt{now} \leq \texttt{gracePeriodEnds}$ |
| **SUCCEEDED** | Grace period expired AND attestations $\geq$ quorum |
| **DEFEATED** | A different scorecard was ratified |
| **RATIFIED** | This scorecard was ratified |

Multiple scorecards may coexist in ACTIVE or SUCCEEDED state simultaneously, but only one can ever be ratified. This creates a competitive dynamic where multiple proposed outcomes compete for attestation support.

### 3.4 Resistance to Strategic Manipulation

The attestation model incorporates several defenses against strategic manipulation:

**Defense 1: Per-tier cap.** No single tier's holders can contribute more than $V_{\text{max}}$ attestation units, regardless of how many tokens they hold. A whale who buys the entire supply of one tier has exactly $V_{\text{max}}$ power — the same as if any single holder held the tier.

**Defense 2: Checkpoint snapshots.** Attestation power is computed at a fixed historical timestamp. Acquiring tokens after the snapshot provides zero additional voting power for that scorecard.

**Defense 3: Mint-phase-only delegation.** Delegation is locked after the mint phase, preventing last-minute delegation changes during the scoring phase.

**Defense 4: 50% quorum across tiers.** Requiring half of all minted tiers' worth of attestation power means that no coalition controlling fewer than half the minted tiers can unilaterally ratify a fraudulent scorecard — even with 100% participation within their controlled tiers.

**Remaining attack surface.** A coalition controlling $>50\%$ of minted tiers (by token count within each tier) could ratify an arbitrary scorecard. For a game with $N$ tiers, this requires majority token holdings in at least $\lceil N/2 \rceil$ tiers. The economic cost of this attack is at least:

$$C_{\text{attack}} \geq \sum_{i \in \text{majority set}} \left\lceil \frac{n_i + 1}{2} \right\rceil \cdot p_i \tag{26}$$

For the attack to be profitable, the attacker must redirect more than $C_{\text{attack}}$ in prize value to their controlled tiers, which requires the pot to satisfy:

$$B_{\text{prize}} > C_{\text{attack}} \cdot \frac{W_{\text{total}}}{\sum_{i \in \text{majority set}} w_i^{\text{proposed}}} \tag{27}$$

In practice, for games with many tiers and distributed participation, the cost of controlling majority positions across sufficient tiers exceeds the potential redirect, making the attack unprofitable.

---

## 4 Price Dynamics and Value Flows

### 4.1 NFT Intrinsic Value During Minting

During the mint phase, the intrinsic value of a tier-$i$ NFT depends on the holder's subjective probability assessment of the outcomes.

**Expected value at mint.** Let $\pi_i$ be a player's subjective probability that tier $i$ receives scorecard weight $w_i$. The expected post-fee payout for one tier-$i$ NFT is:

$$\mathbb{E}[V_i] = B_{\text{prize}} \cdot \frac{\mathbb{E}[w_i^{\text{token}}]}{W_{\text{total}}} + X_i^{\text{protocol}} \tag{28}$$

where $X_i^{\text{protocol}}$ is the expected protocol token value from burning.

For a binary game (winner-take-all, $N = 2$), this simplifies to:

$$\mathbb{E}[V_i] = \pi_i \cdot \frac{B_{\text{prize}}}{n_i} + X_i^{\text{protocol}} \tag{29}$$

A rational risk-neutral player mints tier $i$ when:

$$\mathbb{E}[V_i] > p_i \tag{30}$$

Substituting:

$$\pi_i > \frac{p_i - X_i^{\text{protocol}}}{B_{\text{prize}} / n_i} \tag{31}$$

This threshold probability decreases as the pot grows (more participants in other tiers create larger prizes for a given probability) and increases as more tokens of tier $i$ are minted (diluting the per-token payout within the tier).

### 4.2 Post-Scorecard Valuation

After the scorecard is ratified and fees are extracted, each NFT has a deterministic value:

**Tier-$i$ token value.** For a single token in tier $i$:

$$V_i^{\text{token}} = \frac{w_i}{\hat{n}_i \cdot W_{\text{total}}} \cdot (B_{\text{prize}} + A_{\text{redeemed}}) + V_i^{\text{protocol}} \tag{32}$$

where $V_i^{\text{protocol}} = \frac{p_i}{M} \cdot (D_{\text{total}} \cdot P_D + P_{\text{total}} \cdot P_P)$ is the protocol-token value, with $P_D$ and $P_P$ being the market prices of $\text{DEFIFA}$ and $\text{BASE\_PROTOCOL}$ tokens respectively.

**Winning tier (full weight).** In a winner-take-all game with $w_j = W_{\text{total}}$:

$$V_j^{\text{token}} = \frac{B_{\text{prize}} + A_{\text{redeemed}}}{\hat{n}_j} + V_j^{\text{protocol}} \tag{33}$$

The winning-tier payout per token is the entire post-fee pot divided by the number of winning-tier tokens.

**Losing tier (zero weight).** When $w_i = 0$:

$$V_i^{\text{token}} = V_i^{\text{protocol}} \tag{34}$$

Losing-tier tokens have zero prize value but retain protocol-token value, providing a non-zero incentive to burn.

### 4.3 Secondary Market Implications

The deterministic valuation after scorecard ratification creates clear secondary-market dynamics:

**Pre-ratification.** NFT value is driven by subjective outcome probabilities. Prices reflect the market's consensus probability-weighted expected payout, analogous to prediction-market shares.

**Post-ratification.** NFT value is deterministic and publicly computable. Any secondary-market price deviating from the redemption value creates an arbitrage:
- If $P_{\text{market}} < V_i^{\text{token}}$: buy on the market, burn for profit.
- If $P_{\text{market}} > V_i^{\text{token}}$: never occurs rationally (burn dominates holding).

This means post-ratification secondary markets should converge immediately to redemption value, eliminating any residual price discovery.

---

## 5 Rational Actor Analysis

### 5.1 Mint-Phase Strategy: Entry Timing

**Early minting advantage.** In a fixed-price game, there is no direct price advantage to minting early vs. late within the mint phase (prices are fixed). However, early minters benefit from:

1. **Information asymmetry**: later minters may have better information about the likely outcome, concentrating on winning tiers and diluting per-token payouts within those tiers.

2. **Delegation coordination**: early minters can establish delegation networks, securing attestation influence.

**Late minting advantage.** Late minters benefit from:

1. **Pot observability**: the total pot size and tier distribution are observable on-chain, allowing more informed expected-value calculations.

2. **Implied probability extraction**: the distribution of mints across tiers reveals collective sentiment, analogous to odds in a betting market.

**Equilibrium.** In a Nash equilibrium of the minting game with risk-neutral players, each player mints the tier maximizing their expected payoff. Denoting by $\pi_i$ the true probability of tier $i$ winning and by $f_i = n_i \cdot p_i / B$ the fraction of the pot allocated to tier $i$:

$$\mathbb{E}[\text{return}_i] = \frac{\pi_i}{f_i} \cdot (1 - \phi) - 1 \tag{35}$$

where $\phi = 1/\phi_{\text{defifa}} + 1/\phi_{\text{base}} + \phi_{\text{custom}}$ is the total fee rate.

In equilibrium, expected returns equalize across tiers: $\mathbb{E}[\text{return}_i] = \mathbb{E}[\text{return}_j]$ for all $i, j$ with non-zero minting, which implies:

$$\frac{\pi_i}{f_i} = \frac{\pi_j}{f_j} \quad \Rightarrow \quad f_i = \frac{\pi_i}{\sum_k \pi_k} = \pi_i \tag{36}$$

**Result.** In equilibrium, the fraction of the pot in each tier equals the market's consensus probability of that tier winning. This is the classical parimutuel result: the pot allocation *reveals* the collective probability assessment.

### 5.2 Refund-Phase Strategy: Option Exercise

The refund phase creates a *free put option* on each minted NFT, struck at the mint price.

**Option value.** Let $V_i(t_{\text{refund\_end}})$ be the expected value of a tier-$i$ token at the end of the refund phase. The refund option has value:

$$O_i = \max\left(p_i - V_i(t_{\text{refund\_end}}), \; 0\right) \tag{37}$$

A rational player exercises (refunds) when $V_i(t_{\text{refund\_end}}) < p_i$, which occurs when new information shifts the expected outcome against their chosen tier.

**Strategic implications.** The refund phase serves three purposes:

1. **Risk reduction**: allows players to participate speculatively during the mint phase, with a guaranteed exit if conditions change.

2. **Information revelation**: refund activity signals belief updates. Tiers experiencing heavy refunds are perceived as less likely to win, reinforcing the signal.

3. **Adverse selection mitigation**: the refund phase partially solves the "winner's curse" problem, where early minters in popular tiers may overpay relative to their per-token payout.

**Pot contraction.** Refunds shrink the pot proportionally. If a fraction $\alpha$ of tier-$i$ tokens are refunded, the pot decreases by $\alpha \cdot n_i \cdot p_i$ and tier $i$'s outstanding supply decreases by $\alpha \cdot n_i$. The per-token expected value for remaining tier-$i$ holders *increases* (fewer tokens sharing the same weight), partially offsetting the information content of the refund signal.

### 5.3 Scoring-Phase Strategy: Attestation Delegation

During the scoring phase, the key strategic variable is delegation. Rational players delegate their attestation power to the address most likely to submit and attest to the correct scorecard.

**Default delegation.** Games may specify a `defaultAttestationDelegate` — a trusted address (e.g., the game organizer) whose scorecard proposals are flagged. Players delegating to this address at mint time reduce coordination costs.

**Strategic delegation.** A player holding tokens in tier $i$ has an incentive to delegate to addresses that will attest to scorecards assigning high weight to tier $i$. However, the quorum requirement (50% of minted tiers) means that no single tier's strategy can unilaterally determine the outcome. Scorecards that deviate from the true outcome face the collective opposition of all other tiers' holders.

**Equilibrium.** In the unique subgame-perfect equilibrium of the attestation game (assuming common knowledge of the event outcome):

1. All holders attest to the *truthful* scorecard — the one reflecting the actual event outcome.
2. The truthful scorecard achieves quorum, as holders of winning tiers have the strongest incentive to attest (they benefit from high weight) and holders of losing tiers are indifferent between truthful scorecards (their weight is zero regardless).

### 5.4 Complete-Phase Strategy: Claim vs Hold

After ratification, holding an NFT rather than burning it has the following payoff profile:

**Burn immediately.** Receive $V_i^{\text{token}} = w_i^{\text{token}} / W_{\text{total}} \cdot (B_{\text{prize}} + A_{\text{redeemed}}) + V_i^{\text{protocol}}$.

**Hold.** The NFT retains the same deterministic value $V_i^{\text{token}}$ indefinitely (the contract imposes no time decay on claims). The only reason to delay is if the player expects the protocol tokens ($\text{DEFIFA}$, $\text{BASE\_PROTOCOL}$) to appreciate in value before claiming.

**Dominant strategy.** For risk-neutral players with positive time preference, burning immediately weakly dominates holding. The claim value does not depreciate (the path-independent formula ensures later claimants receive the same amount), but the time value of money favors immediate realization. Holding is justified only by expected protocol-token appreciation exceeding the discount rate:

$$\frac{dP_D}{dt} \cdot \frac{p_i}{M} \cdot D_{\text{total}} > r \cdot V_i^{\text{token}} \tag{38}$$

where $r$ is the player's discount rate.

---

## 6 Solvency and Conservation Laws

### 6.1 The Conservation Guarantee

A Defifa game satisfies a fundamental conservation property: the total claims available to all NFT holders exactly equal the prize pool, regardless of the order or timing of redemptions.

**Theorem 6.1 (Prize Pool Conservation).** For any scorecard $\mathbf{w}$ with $\sum_i w_i = W_{\text{total}}$ and any sequence of redemptions, the total amount paid out to all NFT holders equals $B_{\text{prize}}$.

*Proof.* The total claim across all tokens is:

$$\sum_{i=1}^{N} n_i^{\text{eligible}} \cdot \frac{w_i}{\hat{n}_i \cdot W_{\text{total}}} \cdot (B_{\text{prize}} + A_{\text{redeemed}})$$

Since $n_i^{\text{eligible}} = \hat{n}_i$ at the start (before any complete-phase redemptions), and the term $(B_{\text{prize}} + A_{\text{redeemed}})$ is invariant (it reconstructs the original pot), this equals:

$$\sum_{i=1}^{N} \frac{w_i}{W_{\text{total}}} \cdot B_{\text{prize}} = \frac{B_{\text{prize}}}{W_{\text{total}}} \sum_{i=1}^{N} w_i = B_{\text{prize}} \quad \square$$

This guarantees that the treasury is exactly drained after all eligible tokens are redeemed — there is no residual and no shortfall.

### 6.2 Solvency Under Sequential Cash-Outs

**Corollary 6.2 (Order Independence).** The payout to any individual NFT holder is independent of the order in which other holders redeem their tokens.

*Proof.* The per-token claim formula (Eq. 14) uses $(B_{\text{prize}} + A_{\text{redeemed}})$ as the reference pot, which is constant regardless of how many tokens have been redeemed. The denominator $\hat{n}_i$ adjusts via the $d_i$ (tokens redeemed from tier $i$) counter, but the per-token weight formula $w_i / \hat{n}_i$ uses the *original* eligible count (at scorecard ratification), not the current count. The Solidity implementation achieves this by tracking `tokensRedeemedFrom[tierId]` and subtracting from the denominator:

$$\hat{n}_i = n_i^{\text{minted}} - n_i^{\text{remaining}} - (n_i^{\text{burned}} - d_i) \tag{39}$$

As each token is redeemed, both $n_i^{\text{burned}}$ and $d_i$ increment by 1, leaving $\hat{n}_i$ invariant. Therefore, each token receives the same payout regardless of when it is redeemed. $\square$

### 6.3 Fee Impact on Total Claimable Value

The total value available to players (prize + protocol tokens) is:

$$V_{\text{total}} = B_{\text{prize}} + V_{\text{protocol}} = B_{\text{pot}} \cdot (1 - \phi) + V_{\text{protocol}} \tag{40}$$

where $V_{\text{protocol}}$ is the market value of protocol tokens allocated to the game. With default fees ($\phi = 10\%$):

$$V_{\text{total}} = 0.9 \cdot B_{\text{pot}} + V_{\text{protocol}} \tag{41}$$

Whether the net present value exceeds the mint cost depends on whether $V_{\text{protocol}} > 0.1 \cdot B_{\text{pot}}$ — i.e., whether protocol token value compensates for the fee extraction. This creates a circular dependency: protocol token value derives from the aggregate fees across all games, which depends on game volume, which depends on expected player returns, which depends on protocol token value. We analyze this flywheel in Section 7.3.

---

## 7 Game-Theoretic Properties

### 7.1 Defifa as a Parimutuel Mechanism

Defifa implements a *generalized parimutuel mechanism* with several distinctive features compared to traditional parimutuel systems:

| Property | Traditional Parimutuel | Defifa |
|----------|----------------------|--------|
| Outcome resolution | Centralized oracle | Decentralized attestation |
| Payout computation | House-computed odds | On-chain formula |
| Fee structure | Fixed takeout rate | Split-based, configurable |
| Asset type | Fungible bet tickets | Non-fungible ERC-721 tokens |
| Secondary market | Typically none | Full ERC-721 transferability |
| Refund option | Typically none | Configurable refund phase |
| Token rewards | None | Protocol token distribution |

**Parimutuel equivalence.** Under the following conditions, a Defifa game is equivalent to a classical parimutuel pool:
- All tiers have the same price ($p_i = p$ for all $i$),
- The scorecard is binary (one winning tier gets $W_{\text{total}}$, all others get 0),
- No refund phase.

In this case, the odds implied by the pot distribution match classical parimutuel odds:

$$\text{odds}_i = \frac{B_{\text{prize}}}{n_i \cdot p} = \frac{(1 - \phi) \cdot \sum_k n_k}{n_i} \tag{42}$$

### 7.2 Information Aggregation

The minting and refund dynamics of Defifa create a multi-round price-discovery mechanism:

**Round 1 (Mint phase).** Players reveal information through tier selection. Under the equilibrium result from Section 5.1, the pot distribution converges to the collective probability distribution.

**Round 2 (Refund phase).** Players who received new information can exit, and the refund pattern reveals belief updates. The post-refund pot distribution reflects updated probability assessments.

**Round 3 (Secondary market).** If NFTs trade on secondary markets during the scoring phase, prices reflect the most current probability assessments, including information arriving after minting closes.

This three-round structure is informationally richer than single-shot betting mechanisms, as it allows for belief revision without the sunk-cost problem (thanks to the refund option).

### 7.3 Multi-Game Dynamics and Protocol Flywheel

Defifa generates a *protocol-level flywheel* through its fee-token mechanism:

1. **Game fees** → minted to protocol projects as payments,
2. **Protocol tokens** are issued to the game hook,
3. **Players claim protocol tokens** upon burning NFTs,
4. **Protocol token value** reflects aggregate fee revenue across all games,
5. **Higher token value** → higher expected returns for players → more game participation → more fees.

**Flywheel dynamics.** Let $G$ be the number of active games, $\bar{B}$ the average pot size, and $\phi$ the fee rate. The aggregate fee revenue is:

$$R = G \cdot \bar{B} \cdot \phi \tag{43}$$

If protocol token value is a multiple $\mu$ of aggregate revenue: $V_{\text{token}} = \mu \cdot R$, then the protocol token allocation per game is approximately:

$$V_{\text{protocol}}^{\text{game}} \approx \frac{\bar{B} \cdot \phi}{\bar{B}} \cdot V_{\text{token}} = \phi \cdot \mu \cdot G \cdot \bar{B} \cdot \phi \tag{44}$$

The fraction of the pot recovered through protocol tokens is:

$$\frac{V_{\text{protocol}}^{\text{game}}}{\bar{B}} = \phi^2 \cdot \mu \cdot G \tag{45}$$

This shows that the protocol-token recovery rate increases linearly with the number of games $G$ and the revenue multiple $\mu$. For $\phi = 0.1$, $\mu = 10$, and $G = 100$:

$$\frac{V_{\text{protocol}}^{\text{game}}}{\bar{B}} = 0.01 \cdot 10 \cdot 100 = 10$$

In this (illustrative) regime, protocol tokens would be worth 10x the pot — making Defifa games a *net-positive expected value* activity. While this extreme scenario is unlikely at scale, it demonstrates the directional incentive: more games create more protocol token value, which attracts more players.

---

## 8 Parameter Design Space

### 8.1 Tier Count and Price Calibration

**Tier count.** The number of tiers $N$ affects:

- **Quorum difficulty**: $Q = (N_{\text{minted}} / 2) \cdot V_{\text{max}}$. More tiers require more attestation weight, increasing governance robustness but potentially slowing ratification.
- **Per-tier dilution**: In a winner-take-all game, the winning tier's payout is diluted only by the number of tokens in that tier, not by total tiers. However, more tiers spread the pot thinner in proportional-split scorecards.
- **Attack cost**: More tiers increase the cost of majority control (Eq. 26).

**Optimal regime**: $4 \leq N \leq 32$ tiers balances governance tractability with outcome granularity. Beyond 32 tiers, quorum coordination becomes challenging; below 4, the game reduces to a coin flip with limited appeal.

**Price calibration.** Tier prices affect:

- **Accessibility**: Lower prices attract more participants but increase gas costs relative to the bet size.
- **Pot concentration**: Uniform pricing ($p_i = p$) creates a clean parimutuel pool where pot fractions equal minting fractions. Non-uniform pricing allows odds-adjustment at design time (e.g., favorites priced higher).
- **Attack economics**: Higher prices increase the cost of acquiring majority positions for attestation manipulation.

**Recommendation**: Uniform pricing between 0.01 and 1 ETH per NFT provides a balance between accessibility, gas efficiency, and attack resistance for most games.

### 8.2 Timing Parameters

**Mint duration** ($t_{\text{mint}}$): Should be long enough for information dissemination and participation growth, but short enough to maintain urgency. For event-based games:

$$t_{\text{mint}} \approx \min(\text{time until event}, \; 30 \text{ days}) \tag{46}$$

**Refund duration** ($t_{\text{refund}}$): Creates optionality value. Longer refund periods increase the option value for minters but may reduce pot stability (more uncertainty about final pot size). A refund period of 1–7 days provides meaningful optionality without excessive uncertainty.

**Attestation start time** ($\tau_{\text{attest}}$): Delay between scorecard submission and voting activation. Longer delays give more holders time to prepare delegations and review scorecards. Recommended: 1–24 hours.

**Attestation grace period** ($\tau_{\text{grace}}$): Duration of the voting window. Must be long enough for broad participation but short enough to deliver results promptly. Recommended: 1–7 days.

### 8.3 Fee Calibration and Protocol Sustainability

The default fee structure (5% Defifa + 5% base protocol = 10% total) is competitive with:

| Platform | Takeout Rate |
|----------|-------------|
| Horse racing (parimutuel) | 15–25% |
| Sports betting (vig) | 4–10% |
| Prediction markets (fees) | 1–5% |
| **Defifa (default)** | **10%** |

The 10% rate positions Defifa between traditional parimutuel systems and modern prediction markets. The key differentiation is the *protocol token rebate*: while the 10% is extracted as fees, a portion returns to players as protocol tokens, making the effective fee rate lower than the nominal rate.

**Effective fee rate.** If protocol tokens retain $\alpha$ fraction of their fee value:

$$\phi_{\text{eff}} = \phi \cdot (1 - \alpha) \tag{47}$$

For $\alpha = 0.5$ (protocol tokens retain 50% of their minting value): $\phi_{\text{eff}} = 0.10 \cdot 0.5 = 5\%$, competitive with low-fee prediction markets.

---

## 9 Conclusions and Practical Implications

This paper has formalized the cryptoeconomic mechanisms of Defifa: a prediction-game protocol that transforms NFT minting into a parimutuel wagering mechanism with governance-ratified outcomes. Through mathematical analysis of the minting, refund, scorecard, and prize distribution operations, we have derived conservation guarantees, characterized equilibrium behavior, analyzed governance security, and mapped the parameter design space.

### Prize Distribution Mechanics

Defifa implements a *path-independent, weight-proportional* prize distribution through Equation 14. The key insight is the use of $(B_{\text{prize}} + A_{\text{redeemed}})$ as the reference pot: by reconstructing the original post-fee pot rather than using the current balance, the protocol ensures that every token holder receives the same payout regardless of redemption order. Theorem 6.1 proves that the total payout across all holders exactly exhausts the prize pool, with no residual or shortfall.

The scorecard weight system ($\sum w_i = 10^{18}$) provides a flexible framework for expressing arbitrary outcome distributions: winner-take-all, proportional splits, partial credit, or any mixture. The per-token weight formula (Eq. 12) correctly adjusts for tier size, ensuring that a tier's total claim equals its weight fraction of the pot regardless of how many tokens were minted in that tier.

### Governance Security

The attestation model (Section 3) achieves a balance between decentralization and efficiency. The per-tier cap on attestation power ($V_{\text{max}} = 10^9$) prevents any single tier from dominating governance, while the 50% quorum across minted tiers ensures broad participation. The checkpoint-based snapshot prevents vote-buying, and mint-phase-only delegation prevents last-minute manipulation.

The economic cost of a successful attestation attack (Eq. 26) scales with the number of tiers and mint prices, providing a quantifiable security budget. For games with $\geq 8$ tiers and uniform pricing above 0.01 ETH, the attack cost typically exceeds the potential redirect, making governance manipulation economically irrational.

### Market Efficiency

The equilibrium analysis (Section 5.1) demonstrates that Defifa games converge to the classical parimutuel result: pot fractions equal consensus probabilities. The three-round information structure (mint → refund → secondary) provides richer information aggregation than single-shot mechanisms, with the refund phase serving as a particularly elegant solution to the adverse-selection problem in prediction markets.

### Protocol Sustainability

The fee-token flywheel (Section 7.3) creates a positive feedback loop between game volume and protocol token value. While the flywheel dynamics are inherently circular, the directional incentive is clear: more games → more fees → higher protocol token value → lower effective fee rates → more attractive games → more participation. The critical mass required to activate this flywheel depends on aggregate fee revenue relative to protocol token market capitalization.

### Practical Recommendations

For game designers deploying Defifa games:

1. **Tier count**: 4–32 tiers balances governance security with outcome expressiveness.
2. **Pricing**: Uniform pricing between 0.01–1 ETH provides the cleanest parimutuel dynamics.
3. **Refund phase**: 1–7 days gives meaningful optionality without excessive pot instability.
4. **Attestation**: A trusted default delegate reduces coordination costs; 24-hour attestation start delay and 3-day grace period balance speed with security.
5. **Fees**: The default 10% split (5% Defifa + 5% base protocol) is competitive; additional organizer splits should not exceed 5% to keep effective rates under 15%.

### Synthesis

Defifa implements a rigorous approach to prediction gaming through the composition of three well-understood mechanisms: parimutuel pooling for price formation, attestation governance for outcome resolution, and Juicebox V5 for treasury management. The mathematical analysis confirms that the system conserves value, resists governance manipulation for realistic parameter ranges, and converges to informationally efficient equilibria. The protocol token layer adds a novel incentive dimension that aligns participant, organizer, and protocol interests around game volume growth.

The elegance of Defifa resides in its architectural composability: prediction games with arbitrary outcomes, arbitrary tier structures, and arbitrary payout distributions emerge from the same set of seven parameters (Eq. 1), executed deterministically by immutable smart contracts with a single, time-bounded governance input.
