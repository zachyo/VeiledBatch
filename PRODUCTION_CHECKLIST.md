# VeiledBatch - Production Deployment Checklist

## Overview

This document outlines all steps required to deploy VeiledBatch Hook to production. The system combines Uniswap v4 Hooks, Fhenix FHE, and EigenLayer AVS for confidential batch auctions.

---

## 🔧 Prerequisites (Actions YOU Must Take)

### 1. **Network Setup**

| Task                                                | Status   | Notes                               |
| --------------------------------------------------- | -------- | ----------------------------------- |
| [ ] Deploy to Fhenix Helium Testnet first           | Required | FHE precompiles only work on Fhenix |
| [ ] Get Fhenix testnet ETH from faucet              | Required | https://faucet.fhenix.zone          |
| [ ] Verify FHE precompile at address(128) is active | Required | Test with simple encrypt/decrypt    |

**Fhenix Network Details:**

- Helium Testnet RPC: `https://api.helium.fhenix.zone`
- Chain ID: `8008135`
- Block Explorer: `https://explorer.helium.fhenix.zone`

### 2. **EigenLayer AVS Registration**

| Task                                 | Status   | Notes              |
| ------------------------------------ | -------- | ------------------ |
| [ ] Create AVS on EigenLayer testnet | Required | Use eigenlayer-cli |
| [ ] Register your AVS metadata       | Required | Upload to IPFS     |
| [ ] Configure slashing conditions    | Optional | For mainnet        |
| [ ] Set up at least 2 operator nodes | Required | For quorum         |

**Commands:**

```bash
# Install EigenLayer CLI
npm install -g @eigenlayer/cli

# Register AVS
eigenlayer avs register --name "VeiledBatch" --network holesky
```

### 3. **Operator Node Setup**

Each operator needs:
| Component | Purpose |
|-----------|---------|
| [ ] Kubernetes/Docker environment | Run operator node |
| [ ] BLS key pair generated | For signature aggregation |
| [ ] Stake deposited to EigenLayer | Minimum 0.1 ETH for testnet |
| [ ] TEE enclave (optional) | For enhanced FHE security |

**Operator Registration Process:**

```solidity
// 1. Generate BLS keypair offline
// 2. Call registerOperator with pubkey hash
hook.registerOperator{value: 0.1 ether}(pubkeyHash);
```

### 4. **Frontend Requirements**

| Task                                | Status   | Notes                     |
| ----------------------------------- | -------- | ------------------------- |
| [ ] Install Fhenix SDK              | Required | `npm install fhenix-sdk`  |
| [ ] Initialize Fhenix client        | Required | See code below            |
| [ ] Implement intent encryption     | Required | Before submitting to hook |
| [ ] Handle sealed output decryption | Required | For viewing your intents  |

**Frontend Integration Example:**

```typescript
import { FhenixClient, EncryptedUint128 } from "fhenix-sdk";

// Initialize client
const client = new FhenixClient({ provider: window.ethereum });

// Encrypt intent before swap
async function encryptIntent(
  amount: bigint,
  zeroForOne: boolean,
  slippage: number
) {
  const encAmount = await client.encrypt_uint128(amount);
  const encDirection = await client.encrypt_bool(zeroForOne);
  const encSlippage = await client.encrypt_uint32(slippage);
  const encMaxPrice = await client.encrypt_uint64(0n); // Or actual limit

  return ethers.utils.defaultAbiCoder.encode(
    ["bytes", "bytes", "bytes", "bytes"],
    [encAmount, encDirection, encSlippage, encMaxPrice]
  );
}

// Submit via swap
const hookData = await encryptIntent(1000000n, true, 50);
await swapRouter.swap(poolKey, swapParams, hookData);
```

---

## 📋 Smart Contract Deployment

### Step 1: Deploy Hook

```bash
# Set environment variables
export PRIVATE_KEY=<your_key>
export FHENIX_RPC=https://api.helium.fhenix.zone

# Deploy
forge script script/DeployProduction.s.sol --rpc-url $FHENIX_RPC --broadcast
```

### Step 2: Verify Contracts

```bash
forge verify-contract <ADDRESS> VeiledBatchHook \
  --chain-id 8008135 \
  --constructor-args $(cast abi-encode "constructor(address)" <POOL_MANAGER>)
```

### Step 3: Configure Hook

```solidity
// After deployment:
// 1. No additional setup needed - hook is self-contained
// 2. Operators register themselves
// 3. Users start submitting encrypted intents
```

---

## 🔐 Security Considerations

### Before Mainnet

| Check                                     | Status | Priority |
| ----------------------------------------- | ------ | -------- |
| [ ] Formal verification of FHE operations | P0     | Critical |
| [ ] Audit of slashing conditions          | P0     | Critical |
| [ ] BLS signature aggregation audit       | P0     | Critical |
| [ ] Reentrancy analysis                   | P0     | Critical |
| [ ] Gas optimization review               | P1     | High     |
| [ ] Operator collusion prevention         | P1     | High     |
| [ ] Emergency pause mechanism testing     | P1     | High     |

### Known Limitations

1. **Decryption Latency**: FHE decrypt operations are slow (~500ms per value)
2. **Gas Costs**: Encrypted operations are gas-intensive
3. **Network Dependency**: Only works on Fhenix-compatible networks
4. **Operator Trust**: Operators can see decrypted data during processing

---

## 📊 Monitoring Setup

### Recommended Metrics

```javascript
// Monitor these events
VeiledBatchHook.on("EncryptedIntentSubmitted", logIntent);
VeiledBatchHook.on("BatchFinalized", logBatch);
VeiledBatchHook.on("BatchProcessed", logProcess);
VeiledBatchHook.on("OperatorSlashed", alertSlash);
```

### Dashboard Requirements

| Metric                         | Alert Threshold  |
| ------------------------------ | ---------------- |
| Batch size before finalization | > 90 intents     |
| Time to batch finalization     | > 45 seconds     |
| Operator response time         | > 5 minutes      |
| Fallback execution rate        | > 50% of intents |
| Gas per intent                 | > 500k gas       |

---

## 🚀 Deployment Order

### Testnet (Do First)

1. [ ] Deploy to Fhenix Helium
2. [ ] Register 2+ test operators
3. [ ] Submit test encrypted intents
4. [ ] Verify batch processing
5. [ ] Test fallback mechanism
6. [ ] Load test with 100 intents

### Mainnet Checklist

1. [ ] Complete security audit
2. [ ] Deploy with timelock admin
3. [ ] Set up multisig ownership
4. [ ] Gradual operator onboarding
5. [ ] Monitor for 2 weeks minimum
6. [ ] Full launch

---

## 🛠️ Troubleshooting

### Common Issues

**"FHE decrypt failed"**

- Ensure you're on Fhenix network
- Check precompile at address(128) is active
- Verify encrypted handles are valid

**"Invalid signature"**

- Verify operator is registered
- Check BLS key matches registration
- Ensure message hash matches

**"Batch not finalized"**

- Wait for timeout (30 seconds)
- Or wait for MAX_BATCH_SIZE (100 intents)
- Or call forceFinalizeBatch (owner only)

---

## 📞 Support Resources

- Fhenix Discord: https://discord.gg/fhenix
- EigenLayer Docs: https://docs.eigenlayer.xyz
- Uniswap v4 Docs: https://docs.uniswap.org/contracts/v4/overview

---

## File Structure (Production)

```
VeiledBatch/
├── src/
│   ├── VeiledBatchHook.sol          # Main production hook
│   └── avs/
│       └── VeiledBatchAVSOperator.sol # Operator logic
├── script/
│   └── DeployProduction.s.sol        # Production deploy
├── operator/                          # To be created
│   ├── Dockerfile
│   ├── src/
│   │   ├── main.rs                   # Rust operator
│   │   ├── fhe.rs                    # FHE operations
│   │   └── bls.rs                    # BLS signatures
│   └── Cargo.toml
└── frontend/                          # To be created
    ├── src/
    │   ├── hooks/useFhenix.ts
    │   └── components/SwapForm.tsx
    └── package.json
```

---

**Status**: Week 3 Implementation Complete
**Next Steps**:

1. Deploy to Fhenix Helium testnet
2. Set up operator infrastructure
3. Build frontend with Fhenix SDK
4. Run integration tests
