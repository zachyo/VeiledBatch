# Confidential Batch Auction Hook – Internal Kickoff Pack

## Process Doc + Mini PRD

### 1. Project Name (final)

**VeiledBatch Hook** – Confidential Intent-Based Batch Auctions powered by Fhenix FHE + EigenLayer AVS

Tagline for judges & website  
“The CoW Swap you can’t front-run — fully encrypted, restaked batch auctions on Uniswap v4”

### 2. One-Paragraph Vision (PRD)

VeiledBatch is a Uniswap v4 hook that lets traders submit fully encrypted intents (size, direction, max slippage). Every ~15–30 seconds all intents are batched and sent to a custom EigenLayer AVS that runs a uniform-price (or discriminatory) auction entirely under FHE. Only the final matched trades are selectively decrypted and settled on-chain. Unfilled volume automatically falls back to UniswapX/v4 pools. The result: zero toxic MEV, full order privacy, and the hottest 2025 narrative combo (FHE + restaked AVSs).

### 3. Core User Stories

| As a…            | I want to…                                           | So that…                             | Priority |
| ---------------- | ---------------------------------------------------- | ------------------------------------ | -------- |
| Retail trader    | Submit my swap wish without anyone seeing it         | I don’t get sandwiched or sandwiched | P0       |
| Retail trader    | Still get execution even if batch is small           | I’m never stuck                      | P0       |
| DeFi power user  | Run my own solver / provide extra liquidity in batch | I can earn extra surplus             | P1       |
| Judge / Investor | See a working demo with real encryption & settlement | It feels production-ready and novel  | P0       |

### 4. High-Level Architecture (5 components)

```
1. Frontend / Wallet → encrypts intent (Fhenix JS SDK) → signs → sends to Relayer
2. Relayer → batches & pushes encrypted intents into the Hook (via beforeSwap)
2. Uniswap v4 Hook (on-chain) → stores encrypted intents → triggers AVS when batch full
3. EigenLayer AVS (off-chain operators) → runs homomorphic batch auction → returns encrypted matches + aggregate proof
4. Hook → verifies AVS signature → selective decryption (Fhenix) → settles swaps via PoolManager
5. Unmatched intents → automatically routed to UniswapX filler or normal v4 swap
```

### 5. MVP Scope for Hookathon (4-week timeline)

| Week | Milestone                                   | Owner       | Deliverable                                       |
| ---- | ------------------------------------------- | ----------- | ------------------------------------------------- |
| 0    | Repo & team setup                           | All         | GitHub repo, Notion, Discord, Foundry template    |
| 1    | Encrypted intent submission + Hook storage  | @you        | Working hook that accepts ciphertexts             |
| 1    | Mock AVS oracle (centralised for demo)      | @crypto-guy | Returns fake clearing price & matches             |
| 2    | Settlement logic + UniswapX fallback        | @defi-bro   | Real swaps happen after batch                     |
| 2    | Simple React frontend for intent submission | @frontend   | One-click “Sell 1000 USDC” with encryption        |
| 3    | Replace mock with real EigenLayer AVS stub  | @avs-ninja  | Operators can register, task gets signed response |
| 3    | End-to-end encrypted demo + video           | All         | Record 2-min demo for judges                      |
| 4    | Polish, gas optimisation, README, deck      | All         | Submission ready                                  |

### 6. Out-of-Scope for MVP (we can add later)

- Full decentralised AVS with slashing (use testnet + 2-3 friendly operators)
- Discriminatory pricing (uniform price is enough for demo)
- Cross-chain intents
- ZK-based verification instead of AVS (too heavy)

### 7. Tech Stack (all battle-tested 2025)

| Layer    | Choice                                     | Why                             |
| -------- | ------------------------------------------ | ------------------------------- |
| Chain    | Ethereum Sepolia + Fhenix Frontier testnet | Fhenix has real FHE on testnet  |
| Hooks    | Uniswap v4-core + v4-periphery             | Official template               |
| FHE      | Fhenix TFHE + Fhenix JS SDK                | Best UX & on-chain decryption   |
| AVS      | EigenLayer testnet AVS kit                 | One-click operator registration |
| Frontend | Next.js + wagmi + Fhenix SDK               | Fastest possible demo           |
| Testing  | Foundry + Anvil                            | Instant local v4 fork           |

### 8. Repo Structure (suggested)

```
VeiledBatch-hook/
├── src/
│   ├── BatchAuctionHook.sol
│   ├── IntentBridge.sol
│   └── mocks/MockAVS.sol
├── script/Deploy.s.sol
├── test/BatchAuction.t.sol
├── avs-operator/          ← Rust node (week 3)
├── frontend/              ← Next.js demo
└── docs/                  ← this PRD + deck
```

### 9. Judging Criteria → How We Max Points

| Criteria            | How we nail it                                            |
| ------------------- | --------------------------------------------------------- |
| Innovation          | First ever on-chain FHE batch auction + EigenLayer AVS    |
| Use of Hooks        | Core logic lives in beforeSwap / afterSwap                |
| Real Problem Solved | MEV / sandwich protection for retail                      |
| Polish & UX         | One-click encrypted intent from wallet + clean settlement |
| Narrative Fit       | FHE + Restaking = the two hottest tickets of 2025         |

### 10. One-Line Pitch for the Submission Form

“VeiledBatch hides your orders in fully homomorphic ice until the batch auction finishes — then only the executed trades ever see daylight. Powered by Fhenix FHE + EigenLayer AVS on Uniswap v4.”
