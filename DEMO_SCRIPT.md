# VeiledBatch Hook - 3 Minute Demo Script

## 🎬 Intro (0:00 - 0:30)

**[Screen: Slide with Project Title & Tagline]**

"Hi everyone, I'm [Your Name] and this is **VeiledBatch**. We're building the 'CoW Swap you can't front-run' — fully encrypted, restaked batch auctions on Uniswap v4."

"The problem is simple: **Toxic MEV**. When you submit a trade, sandwich bots see it and extract value. Existing solutions like dark pools are often centralized or lack liquidity."

"Our solution? **VeiledBatch**. We use **Fhenix FHE** to keep orders encrypted from wallet to settlement, and **EigenLayer AVS** to run fair batch auctions off-chain but trustlessly."

---

## 🏗️ Architecture & Code (0:30 - 1:30)

**[Screen: VS Code - `src/VeiledBatchHook.sol`]**

"Let's look at the code. This is a Uniswap v4 Hook. The magic happens in `beforeSwap`."

- **Highlight `beforeSwap`**: "Instead of a normal swap, users submit an **Encrypted Intent**. Notice the types here: `euint128`, `ebool`. These are **Fhenix FHE types**. The amount, direction, and slippage are fully encrypted on-chain. No one can see them."

**[Screen: VS Code - `src/avs/VeiledBatchAVS.sol`]**

"These encrypted intents are collected into a batch. Once the batch is full (or every 30 seconds), it's sent to our **EigenLayer AVS**."

- **Highlight AVS Logic**: "Operators on EigenLayer pick up the batch. They perform a **Uniform Price Auction** on the encrypted data. They find the clearing price that maximizes volume, all without ever decrypting the individual user orders."

---

## 🚀 Live Demo (1:30 - 2:30)

**[Screen: Terminal]**

"Since we're dealing with advanced cryptography and AVSs, the best way to show the full flow is through our integration tests which simulate the entire lifecycle."

**[Action: Run `forge test --mt testFallbackMechanism -vv`]**

"I'm running the `testFallbackMechanism` test. Let's watch the logs:"

1.  **Submission**: "First, we see 3 users submitting encrypted intents. To the blockchain, these look like random bytes."
2.  **Batching**: "Time passes... The hook detects the batch is ready and emits `BatchFinalized`."
3.  **AVS Execution**: "Our Mock AVS (simulating the EigenLayer operators) calculates the match. In this scenario, it matches User 1 and User 2, but User 3's price limit wasn't met."
4.  **Settlement**: "The AVS submits the result. The Hook verifies the signature and executes the swaps for User 1 and 2."
5.  **Fallback**: "Crucially, look here: `FallbackExecuted`. User 3 wasn't left behind. The hook automatically routed their unmatched order to a standard Uniswap v4 swap. This ensures 100% execution reliability."

---

## 🏁 Conclusion (2:30 - 3:00)

**[Screen: GitHub Repo / README]**

"To summarize, VeiledBatch combines the privacy of **Fhenix**, the decentralized power of **EigenLayer**, and the liquidity of **Uniswap v4**."

"We've built a system where:

1.  **Privacy is default**: No more sandwich attacks.
2.  **Execution is guaranteed**: Batch auction or fallback.
3.  **Security is shared**: Restaked via EigenLayer."

"This is the future of MEV-resistant trading. Thank you!"
