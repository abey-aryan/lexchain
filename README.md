# ⚖️ LexChain — Decentralized Legal Platform

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://soliditylang.org/)
[![Network](https://img.shields.io/badge/Network-Sepolia%20Testnet-6366f1)](https://sepolia.etherscan.io/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.0-4e5ee4)](https://openzeppelin.com/contracts/)
[![License](https://img.shields.io/badge/License-MIT-10b981)](./LICENSE)
[![Tests](https://img.shields.io/badge/Tests-Hardhat-f6851b)](https://hardhat.org/)

> **Capstone Project** — A decentralized platform for wills, property escrow, and document notarization. No lawyers. No middlemen. No trust required.

---

## 🚨 The Problem

Legal services are expensive and inaccessible for ordinary people.

| Service | Traditional Cost | LexChain Cost |
|---|---|---|
| Writing a will | **$500 – $2,000** at a law firm | **~$0.50** in gas fees |
| Property escrow agent | **1–3% of sale price** | **~$1.00** in gas fees |
| Document notarization | **$50 – $200** per document | **~$0.20** in gas fees |

Worse, every existing digital solution (DocuSign, LegalZoom, online will services) stores your data on **private company servers**. If the company shuts down, gets hacked, or is pressured by a government, your legal documents can be **altered or deleted**.

Real examples of centralized legal data failures:
- **2023**: A major online notarization company suffered a data breach exposing 100,000+ notarized documents
- Countless users have lost access to legal documents when startups pivoted or shut down
- Governments in authoritarian states have pressured companies to alter property records

---

## 💡 Why Blockchain Is Specifically Needed

A regular database is **not enough** because:

1. **Databases can be edited** — any admin can change a record. A blockchain record is mathematically immutable.
2. **Databases can be deleted** — companies shut down. Ethereum nodes will exist as long as the internet does.
3. **Databases require trust** — you must trust the company running it. Smart contracts enforce rules by code, not by trust.
4. **Smart contracts enforce payment** — a traditional escrow agent *could* steal your money. A smart contract *mathematically cannot*.

---

## ✨ Features

### 📜 On-Chain Will
Create a legally-structured will that automatically distributes your estate after 180 days of wallet inactivity. A real-world family could use this knowing that: if they die without anyone knowing, their estate automatically distributes to their children 180 days later with no court involvement required.

### 🏠 Property Escrow
Replace a $10,000 escrow lawyer with a smart contract. Buyer deposits funds; they release to seller only when **both parties** confirm the deal is complete. If the seller disappears, the buyer gets a full refund after 30 days automatically.

### 🔏 Document Notarization
Any document — a will, a property deed, a signed contract — can be hashed and recorded permanently. To prove a document is genuine, hash it again and compare. A $200/hour notary cannot offer a stronger proof of authenticity.

### 📋 Immutable Audit Trail
Every action across all three features is recorded in a shared, append-only audit ledger. Any government authority can call this contract and get a complete, tamper-proof history.

---

## 🏗️ Contract Architecture

```
┌─────────────────────────────────────────────────────┐
│                    AuditTrail.sol                    │
│  Shared immutable ledger. All 3 contracts write here │
│  Any authority can read the full history             │
└──────────────┬──────────────┬──────────────┬────────┘
               │              │              │
    ┌──────────┴───┐  ┌───────┴──────┐  ┌───┴──────────────┐
    │WillRegistry  │  │PropertyEscrow│  │DocumentNotary     │
    │              │  │              │  │                   │
    │• Add heirs   │  │• Fund deal   │  │• Hash file        │
    │• Death switch│  │• Dual confirm│  │• Verify authentic │
    │• Distribute  │  │• Auto refund │  │• Revoke doc       │
    └──────────────┘  └──────────────┘  └───────────────────┘
```

All three contracts call `AuditTrail.logAction()` on every significant event. The AuditTrail only accepts calls from pre-authorized contract addresses, preventing fake entries.

---

## 🛠️ Complete Setup Guide

### Step 1 — Install Node.js
Download from [nodejs.org](https://nodejs.org) (LTS version). Verify with:
```bash
node --version  # should print v18+ or v20+
npm --version
```

### Step 2 — Install Project Dependencies
```bash
cd lexchain
npm install
```
This installs Hardhat, OpenZeppelin contracts, and all tools. No credit card needed.

### Step 3 — Get Free Sepolia ETH
1. Go to [sepoliafaucet.com](https://sepoliafaucet.com)
2. Connect MetaMask and select Sepolia network
3. Paste your wallet address and click "Send Me ETH"
4. Wait ~1 minute. You'll receive 0.5 ETH free.
5. Repeat if needed — you need ~0.05 ETH for all deployments

### Step 4 — Get Free Alchemy RPC URL
1. Go to [alchemy.com](https://alchemy.com) and create a free account (no credit card)
2. Click **"Create New App"**
3. Select **Ethereum** as chain, **Sepolia** as network
4. Give it any name (e.g. "LexChain")
5. Click the app, then **"API Key"** → copy the **HTTPS URL**

### Step 5 — Get Free Etherscan API Key
1. Go to [etherscan.io](https://etherscan.io) and register
2. Go to **My Profile → API Keys → Add**
3. Give it any name, click **"Create New API Key"**
4. Copy the 34-character key

### Step 6 — Set Up Environment File
```bash
cp .env.example .env
```
Open `.env` and fill in:
```
PRIVATE_KEY=your_metamask_private_key_here
ALCHEMY_SEPOLIA_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=your_free_etherscan_api_key_here
```

**How to get your MetaMask private key:**
MetaMask → click account name → three dots → **Account Details** → **Export Private Key** → enter password → copy key

> ⚠️ **WARNING**: Never share your `.env` file or commit it to GitHub. Add `.env` to your `.gitignore` immediately.

### Step 7 — Run Tests (All Must Pass)
```bash
npx hardhat test
```
Expected output:
```
  AuditTrail
    ✔ deploys and sets owner correctly
    ✔ only allows owner to authorize contracts
    ✔ rejects logAction from unauthorized contract
    ... (all 24 tests passing)

  24 passing (3s)
```

### Step 8 — Deploy to Sepolia
```bash
npx hardhat run scripts/deploy.js --network sepolia
```
Wait 1–2 minutes. You'll see:
```
══════════════════════════════════════════════════
  DEPLOYMENT COMPLETE — CONTRACT ADDRESSES
══════════════════════════════════════════════════
  AuditTrail:      0xABCD...
  WillRegistry:    0x1234...
  PropertyEscrow:  0x5678...
  DocumentNotary:  0x9ABC...
══════════════════════════════════════════════════
```
Copy all 4 addresses.

### Step 9 — Configure Frontend
Open `frontend/index.html` and find this section near the top of the `<script>` tag:
```javascript
const ADDRESSES = {
  AuditTrail:     "0x0000...", // ← paste your AuditTrail address here
  WillRegistry:   "0x0000...", // ← paste your WillRegistry address here
  DocumentNotary: "0x0000...", // ← paste your DocumentNotary address here
};
```
Replace all three zero addresses with your deployed contract addresses.

### Step 10 — Run the Platform
1. Open `frontend/index.html` in any browser (Chrome, Firefox, Edge)
2. Switch MetaMask to **Sepolia Test Network**
3. Click **"Connect MetaMask"**
4. All features are now live and working

### Optional — Verify Contracts on Etherscan
Makes your source code publicly readable at etherscan.io:
```bash
npx hardhat verify --network sepolia AUDIT_TRAIL_ADDRESS
npx hardhat verify --network sepolia WILL_REGISTRY_ADDRESS "AUDIT_TRAIL_ADDRESS"
npx hardhat verify --network sepolia DOCUMENT_NOTARY_ADDRESS "AUDIT_TRAIL_ADDRESS"
```

---

## 🎓 Demo Guide for Professor Presentation

### Demo 1 — Document Notarization (2 minutes)
1. Go to **Document Notary** page
2. Upload any PDF file — show that the SHA-256 hash appears instantly in the browser
3. Emphasize: *"The file never left my device. Only the 32-byte hash goes on-chain."*
4. Click **Notarize Document**, confirm in MetaMask
5. Show the Etherscan transaction link that appears
6. Switch to **Verify** tab, upload the **same file** → shows ✅ **AUTHENTIC**
7. Open the file in any text editor, change one letter, save, upload the modified version
8. Show ❌ **NOT ON RECORD** — *"One character change produces a completely different hash"*

### Demo 2 — Will and Inheritance (3 minutes)
1. Go to **My Will** page
2. Add 3 beneficiaries: Alice 50%, Bob 30%, Carol 20% (totals 100%)
3. Click **Finalize Will** — show the lock icon and status change to FINALIZED
4. Deposit 0.1 ETH using the Deposit button
5. Open a terminal and run:
   ```bash
   npx hardhat console --network sepolia
   # Then advance time (only works on local hardhat, for demo use local network)
   ```
   *Explain:* "On the live Sepolia network we'd wait 180 real days. For testing we use Hardhat's time manipulation."
6. Show the **Audit Trail** — every single action appears with timestamp and hash

### Demo 3 — Property Escrow (2 minutes)
1. Go to **Property Deals**, click **New Deal**
2. Create a deal with a second MetaMask account as seller
3. Describe the property and conditions
4. Click **Fund Deal** as buyer — money enters escrow
5. Click **Confirm Deal** as buyer, then switch MetaMask to seller account and confirm
6. Show the deal status changing to **COMPLETED** and funds auto-releasing
7. *"A traditional escrow lawyer charges 1–3% of the sale price. This entire transaction cost $0.80 in gas."*

### Demo 4 — Audit Trail for Authorities (1 minute)
1. Go to **Audit Trail**
2. Show all actions across all features recorded in one place
3. Click **Export JSON** — show the downloaded file
4. *"Any government authority, tax official, or court could call this smart contract directly and get this exact same data. There is no company that can delete it."*

---

## 🔐 Security Features

| Feature | Implementation | Why It Matters |
|---|---|---|
| Re-entrancy protection | `ReentrancyGuard` on all ETH-sending functions | Prevents attackers from draining funds via callback loops |
| Access control | `Ownable` throughout | Only wallet owner can modify their own will |
| Audit write protection | `authorizedContracts` mapping | Only LexChain contracts can write audit entries |
| Immutable records | Append-only `AuditEntry[]` array | Legal records can never be altered or deleted |
| 7-day dispute window | `DISPUTE_WINDOW` constant | Protects owners from premature will execution |
| 30-day escrow timeout | `DEAL_TIMEOUT` constant | Protects buyers from disappearing sellers |
| Exact-match funding | `msg.value == agreedPrice` | No underfunding or overpayment possible |
| Checks-Effects-Interactions | State updated before ETH transfer | Industry-standard pattern against re-entrancy |

---

## 🧰 Technologies Used

| Technology | Purpose |
|---|---|
| **Solidity 0.8.20** | Smart contract language — chosen for latest security features and overflow protection |
| **Hardhat** | Development framework — free, powerful, includes testing and deployment |
| **OpenZeppelin v5** | Security library — battle-tested, audited contracts for Ownable and ReentrancyGuard |
| **ethers.js v6** | Frontend blockchain library — loaded via CDN, no npm needed for frontend |
| **MetaMask** | Wallet connection — most widely used Ethereum wallet |
| **Sepolia Testnet** | Deployment network — free ETH, real Ethereum environment |
| **Alchemy** | Free RPC node provider — required to interact with Sepolia |
| **Google Fonts (Montserrat)** | Typography — loaded via CDN, free |
| **SubtleCrypto API** | Browser-native SHA-256 hashing — no external library, files never leave device |

---

## 📁 Project Structure

```
lexchain/
├── contracts/
│   ├── AuditTrail.sol         ← Shared immutable audit ledger
│   ├── WillRegistry.sol       ← On-chain will with death switch
│   ├── PropertyEscrow.sol     ← Trustless property deal escrow
│   └── DocumentNotary.sol     ← Document hash notarization
├── scripts/
│   └── deploy.js              ← Deployment script (run on Sepolia)
├── test/
│   └── LexChain.test.js       ← 24 tests covering all contracts
├── frontend/
│   └── index.html             ← Complete single-file frontend
├── hardhat.config.js          ← Hardhat + Sepolia + Etherscan config
├── package.json               ← Dependencies
├── .env.example               ← Environment variables template
└── README.md                  ← This file
```

---

## 📄 License

MIT — free to use, modify, and distribute with attribution.

---

*Built with ❤️ as a final year Bachelor's capstone project. LexChain demonstrates that blockchain technology can make legal services accessible to everyone, not just those who can afford expensive lawyers.*
