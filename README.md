# ⚖️ LexChain — Decentralized Legal Platform

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?logo=solidity)](https://soliditylang.org/)
[![Network](https://img.shields.io/badge/Network-Sepolia%20Testnet-6366f1)](https://sepolia.etherscan.io/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.0-4e5ee4)](https://openzeppelin.com/contracts/)
[![Hardhat](https://img.shields.io/badge/Tests-55%20Passing-10b981)](https://hardhat.org/)
[![Vercel](https://img.shields.io/badge/Deployed-Vercel-000000?logo=vercel)](https://vercel.com/)
[![License](https://img.shields.io/badge/License-MIT-f59e0b)](./LICENSE)

> **Final Year Bachelor's Capstone Project** — A fully decentralized legal and financial platform. Write your will, buy property safely, notarize documents, and protect your wallet from fraud — all on the blockchain. No lawyers, no middlemen, no trust required.

---

## 🌐 Live Links

| | Link |
|---|---|
| **Live Platform** | https://lexchain-nu.vercel.app/|
| **Source Code** | https://github.com/abey-aryan/lexchain |

---

## 🚨 The Problem

Legal services are expensive, slow, and inaccessible for regular people. Digital solutions make it worse — they store your most sensitive documents on private servers that can be hacked, deleted, or pressured by governments.

### Cost comparison

| Service | Traditional Cost | LexChain Cost |
|---|---|---|
| Writing a will | **$500 – $2,000** at a law firm | **~$0.50** in gas fees |
| Property escrow agent | **1–3% of sale price** (~$5,000 on a $200k home) | **~$1.00** in gas fees |
| Document notarization | **$50 – $200** per document | **~$0.20** in gas fees |
| Wallet fraud recovery | **$200/hr lawyer + weeks of time** | **Automatic, instant** |

### The centralization problem

- **2023** — A major online notarization company suffered a data breach exposing 100,000+ legal documents
- Dozens of legal tech startups have shut down, taking users' documents offline permanently
- Governments in authoritarian countries have pressured companies to alter or delete property records
- A will stored in a cloud app can be modified by any rogue employee with database access

**The solution is not a better database. It is removing the database entirely.**

---

## 💡 Why Blockchain Is the Only Real Solution

| Problem | Database Approach | Blockchain Approach |
|---|---|---|
| Tampering | Admin can edit any record | Mathematically impossible to alter |
| Deletion | Company can delete your data | Data exists as long as Ethereum exists |
| Trust | Must trust the company | Rules enforced by code, not humans |
| Payment | Escrow agent could steal funds | Smart contract mathematically cannot |
| Fraud | Bank may (sometimes) reverse | Gradual transfer gives 72 hours to cancel |

---

## ✨ Features

### 📜 On-Chain Will and Inheritance
Write your will as a smart contract. Assign up to 5 beneficiaries with percentage shares of your estate. The **death switch** fires automatically after 180 days of wallet inactivity. A 7-day dispute window gives you time to cancel if it was a false alarm. After 7 days, anyone can call `distributeEstate()` and ETH is sent directly to each heir's wallet.

**Real-world impact:** A family knows with certainty that if their parent passes away, their inheritance distributes within 180 days — no lawyer, no court, no probate waiting period.

### 🏠 Property Escrow
Replace an expensive escrow lawyer with a smart contract. The buyer deposits the full agreed price into the contract. Money only releases to the seller when **both parties** confirm the conditions are met. If the seller disappears, the buyer gets a full automatic refund after 30 days.

**Real-world impact:** A property buyer in a country with unregulated escrow agents can now transact safely with a complete stranger, with zero risk of losing their deposit to fraud.

### 🔏 Document Notarization
Hash any document in your browser using the SubtleCrypto API — the file never leaves your device. Store the 32-byte SHA-256 hash permanently on-chain. To verify authenticity, hash the document again and compare. If hashes match, the document has never been modified. A tampered document produces a completely different hash.

**Real-world impact:** A birth certificate, property deed, or business contract can be proven authentic by anyone in the world, forever, without relying on a notary office or government database.

### 🛡️ FraudGuard — Automatic Theft Protection
The most innovative feature of LexChain. When a hacker steals a private key, their first move is always to drain the wallet instantly. FraudGuard makes this impossible.

**Three layers of automatic detection:**
1. **Contract-level** — WillRegistry and PropertyEscrow automatically call `reportSuspiciousActivity()` when they detect large ETH outflows. Zero user input.
2. **Frontend watcher** — A real-time blockchain event listener starts automatically when you connect MetaMask. It monitors every new block for large outgoing transactions, balance drops over 40%, and velocity spikes. When detected, it calls `reportSuspiciousActivity()` automatically.
3. **Guardian and manual** — A trusted second person (spouse, business partner) can raise an alert from their own wallet. The owner can also flag manually.

**The gradual safe transfer mechanism:**
Instead of allowing an instant drain, funds move to a pre-registered safe wallet in three slow stages:
- **Stage 1:** 30% transferred — 24 hours after alert
- **Stage 2:** 40% transferred — 24 hours after Stage 1
- **Stage 3:** 30% transferred — 24 hours after Stage 2

At any point before a stage executes, the real owner can call `cancelAlert()` to stop everything. If it was a false alarm, zero ETH moves.

**Real-world impact:** An attacker who steals a private key cannot drain the wallet instantly. They need 3 full days to complete all stages. During those 3 days the real owner, their family, or a guardian can cancel and save the funds.

### 📋 Immutable Audit Trail
Every action across all five features — every beneficiary added, every deal funded, every document notarized, every fraud alert raised — is permanently recorded in a shared append-only ledger. Any government authority, court, or auditor can call `getFullAuditLog()` directly on the AuditTrail contract. No company controls this data. No company can delete it.

---

## 🏗️ Contract Architecture

```
                    ┌──────────────────────────────────────────┐
                    │              AuditTrail.sol               │
                    │  Shared immutable log. Every action from  │
                    │  all 4 contracts recorded here.           │
                    │  Government / auditor full read access.   │
                    └────────┬──────────┬──────────┬───────────┘
                             │          │          │
               ┌─────────────┘    ┌─────┘    ┌────┘
               ▼                  ▼           ▼
  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
  │  WillRegistry    │  │ PropertyEscrow   │  │ DocumentNotary   │
  │                  │  │                  │  │                  │
  │ Add heirs        │  │ Fund deal        │  │ Hash file        │
  │ 180-day switch   │  │ Dual confirm     │  │ Verify authentic │
  │ Distribute ETH   │  │ 30-day timeout   │  │ Revoke document  │
  └────────┬─────────┘  └────────┬─────────┘  └──────────────────┘
           │                     │
           │  auto-report        │  auto-report
           │  large outflows     │  large outflows
           ▼                     ▼
  ┌──────────────────────────────────────────────────────────────┐
  │                        FraudGuard.sol                         │
  │                                                               │
  │  DETECTION LAYER:                                             │
  │  > Large transfer (>50% balance in single tx)                 │
  │  > Velocity spike (>5 transactions per hour)                  │
  │  > Unknown recipient (non-whitelisted address)                │
  │  > Manual flag by owner or guardian                           │
  │  > Frontend watcher auto-reports every 8 seconds             │
  │                                                               │
  │  RESPONSE LAYER:                                              │
  │  Stage 1 (30%) -> wait 24h -> Stage 2 (40%) ->               │
  │  wait 24h -> Stage 3 (30%) -> COMPLETE                       │
  │                                                               │
  │  CANCEL WINDOW:                                               │
  │  Owner or guardian can cancel before any stage executes       │
  └──────────────────────────────┬───────────────────────────────┘
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │     Safe Wallet       │
                       │  (cold / hardware /   │
                       │   trusted address)    │
                       └──────────────────────┘
```

---

## 📁 Project Structure

```
lexchain/
├── contracts/
│   ├── AuditTrail.sol          ← Shared immutable audit ledger
│   ├── WillRegistry.sol        ← On-chain will with 180-day death switch
│   ├── PropertyEscrow.sol      ← Trustless property escrow
│   ├── DocumentNotary.sol      ← SHA-256 document hash notarization
│   └── FraudGuard.sol          ← Automatic fraud detection + gradual transfer
├── scripts/
│   └── deploy.js               ← Deploys all 5 contracts + wires them together
├── test/
│   └── LexChain.test.js        ← 55 tests covering all contracts
├── frontend/
│   └── index.html              ← Complete single-file platform (no build needed)
├── hardhat.config.js           ← Compiler + Sepolia + Etherscan configuration
├── package.json                ← Project dependencies
├── .env.example                ← Environment variables template
└── README.md                   ← This file
```

---

## 🛠️ Local Setup and Development

### Prerequisites

| Tool | Version | Download |
|---|---|---|
| Node.js | v18+ or v20+ | [nodejs.org](https://nodejs.org) |
| MetaMask | Latest | [metamask.io](https://metamask.io) |
| Git | Any | [git-scm.com](https://git-scm.com) |

### Step 1 — Clone the repository

```bash
git clone https://github.com/YOURUSERNAME/lexchain.git
cd lexchain
npm install
```

### Step 2 — Create the environment file

```bash
cp .env.example .env
```

Open `.env` and fill in all four values:

```env
# Your MetaMask wallet private key (Account 1 — the deployer)
# MetaMask -> three dots -> Account Details -> Export Private Key
PRIVATE_KEY=your_64_character_hex_private_key

# Free Alchemy RPC URL for Sepolia
# alchemy.com -> Create App -> Ethereum -> Sepolia -> API Key -> HTTPS URL
ALCHEMY_SEPOLIA_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Free Etherscan API key for contract verification
# etherscan.io -> My Profile -> API Keys -> Add
ETHERSCAN_API_KEY=your_34_character_api_key

# FraudGuard safe wallet — MUST be different from your PRIVATE_KEY wallet
# MetaMask -> click account circle -> Add account -> copy the new address
SAFE_WALLET=0xYour_Second_Wallet_Address
```

> **Warning:** Never commit `.env` to GitHub. It contains your private key.
> Confirm `.env` is listed in `.gitignore` before your first push.

### Step 3 — Run all tests

```bash
npx hardhat test
```

All 55 tests must pass before deploying:

```
  AuditTrail           7 passing
  WillRegistry        13 passing
  PropertyEscrow       8 passing
  DocumentNotary       7 passing
  FraudGuard          14 passing

  55 passing (4s)
```

### Step 4 — Deploy to Sepolia

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

The script deploys all 5 contracts and automatically:
- Authorizes each contract to write to AuditTrail
- Authorizes WillRegistry and PropertyEscrow as FraudGuard reporters
- Connects WillRegistry and PropertyEscrow to FraudGuard so outflows auto-report

Output:

```
  AuditTrail deployed at:      0xABC...
  WillRegistry deployed at:    0xDEF...
  PropertyEscrow deployed at:  0xGHI...
  DocumentNotary deployed at:  0xJKL...
  FraudGuard deployed at:      0xMNO...

  WillRegistry -> FraudGuard connected
  PropertyEscrow -> FraudGuard connected

  Addresses saved to deployed-addresses.json
```

### Step 6 — Configure the frontend

Open `frontend/index.html`, find the `ADDRESSES` constant and paste your deployed addresses:

```javascript
const ADDRESSES = {
  AuditTrail:     "0xABC...",
  WillRegistry:   "0xDEF...",
  DocumentNotary: "0xJKL...",
  FraudGuard:     "0xMNO...",
};
```

Open `frontend/index.html` in Chrome, switch MetaMask to Sepolia, click **Connect MetaMask**.


---

## 🚀 Frontend Deployment (Free Live Link via Vercel)

The frontend is one HTML file with no build step — deploy to Vercel in under 2 minutes.

### Step 1 — Push to GitHub

```bash
git add .
git commit -m "LexChain capstone project — all contracts deployed"
git remote add origin https://github.com/YOURUSERNAME/lexchain.git
git push -u origin main
```

### Step 2 — Deploy on Vercel

1. Go to [vercel.com](https://vercel.com) → Sign up with GitHub
2. Click **Add New → Project** → Import your `lexchain` repo
3. Configure the project:

| Setting | Value |
|---|---|
| Framework Preset | Other |
| Root Directory | `frontend` |
| Build Command | *(leave blank)* |
| Output Directory | `.` |

4. Click **Deploy**

You get a permanent URL like `https://lexchain.vercel.app` in under 30 seconds. Every `git push` auto-redeploys.

---

## 🎓 Demo Guide for Professor Presentation

### Demo 1 — Document Notarization (2 minutes)
1. Open **Document Notary** page
2. Upload any PDF file — the SHA-256 hash appears instantly in the browser
3. Say: *"The file never left this device. Only this 32-byte fingerprint is stored on-chain."*
4. Click **Notarize** → confirm in MetaMask → Etherscan link appears
5. Switch to **Verify** tab → upload the same file → ✅ **AUTHENTIC**
6. Open the file in Notepad, add one space, save, upload the modified file
7. Show ❌ **NOT ON RECORD**
8. Say: *"One character change completely changes the hash. Tampering is mathematically detectable."*

### Demo 2 — Will and Inheritance (3 minutes)
1. Open **My Will** page → add Alice (60%) and Bob (40%)
2. Click **Finalize Will** → status locks to FINALIZED
3. Deposit 0.1 ETH as estate
4. Open terminal → `npx hardhat console --network localhost`
5. Fast-forward time 181 days → call `checkAndTrigger()` → will fires
6. Fast-forward 8 more days → call `distributeEstate()` → ETH sent to heirs
7. Open **Audit Trail** → show every action permanently recorded

### Demo 3 — Property Escrow (2 minutes)
1. Open **Property Deals** → create a deal with a second MetaMask account as seller
2. Fund the deal as buyer → state changes to FUNDED
3. Confirm as buyer → BUYER_CONFIRMED
4. Switch to seller account → confirm → COMPLETED → funds auto-released
5. Say: *"Traditional escrow agents charge 1–3% of the sale price. This cost $0.80 in gas."*

### Demo 4 — FraudGuard Automatic Detection (3 minutes)
1. Open **Fraud Guard** page → show the **● LIVE** watcher indicator
2. Say: *"This started automatically when I connected MetaMask. No button pressed."*
3. Deposit 0.05 ETH into the protected pool
4. Click **Run Scenario A** (Large Transfer Attack)
5. Watch the live terminal log:
   - `reportSuspiciousActivity()` called automatically
   - Alert level jumps to **HIGH**
   - Stage 1 queued: 30% ready to move after 24 hours
   - Attacker tries to execute immediately → **BLOCKED** by 24h delay
6. Click **Run Scenario B** (Velocity Spike) → watch 6 transactions trigger the alarm
7. Click **Run Scenario C** (False Alarm) → owner cancels → zero ETH moves → guard resets
8. Say: *"The smart contracts themselves call FraudGuard automatically. There was no manual input in any of that."*

### Demo 5 — Audit Trail for Authorities (1 minute)
1. Open **Audit Trail** → show all entries from every previous demo
2. Click **Export JSON** → show the downloaded file
3. Say: *"Any court, regulator, or tax authority can call getFullAuditLog() directly on the blockchain. There is no company to subpoena. There is no server to hack."*

---

## 🔐 Security Features

| Feature | Contract | Protection |
|---|---|---|
| `ReentrancyGuard` | WillRegistry, PropertyEscrow, FraudGuard | Prevents ETH drain via re-entrant callbacks |
| `Ownable` | All contracts | Only wallet owner can modify their own data |
| Authorized writers only | AuditTrail | Only LexChain contracts can write to the log |
| Append-only log | AuditTrail | Records can never be edited or deleted |
| 7-day dispute window | WillRegistry | Prevents premature will execution |
| 30-day escrow timeout | PropertyEscrow | Protects buyers from disappearing sellers |
| Exact-match funding | PropertyEscrow | No underfunding or overpayment possible |
| Checks-Effects-Interactions | All ETH functions | State updated before transfer — prevents re-entrancy |
| 3-stage gradual transfer | FraudGuard | Attacker needs 72 hours to drain — owner can cancel |
| 24-hour stage delay | FraudGuard | Mandatory window between each stage |
| `authorizedReporters` | FraudGuard | Only trusted contracts and watchers can report |
| Guardian address | FraudGuard | Second trusted person can trigger protection |
| Address whitelist | FraudGuard | Known recipients never trigger false alarms |
| Balance snapshot | FraudGuard | Stage percentages calculated from same base — no rounding exploit |

---

## 📊 Test Coverage

| Contract | Tests | Scenarios |
|---|---|---|
| AuditTrail | 7 | Deployment, authorization, integrity verification, full log retrieval |
| WillRegistry | 13 | Add heirs, finalization, 180-day trigger, distribution math, dispute window, cancel |
| PropertyEscrow | 8 | Fund deal, dual confirmation order, 30-day timeout, refund, dispute |
| DocumentNotary | 7 | Notarize, verify, duplicate rejection, revocation, non-creator rejection |
| FraudGuard | 14 | Large transfer, velocity spike, guardian flag, all 3 stages, cancel, reset, whitelist |
| **Total** | **55** | |

---

## 🧰 Technologies

| Technology | Version | Purpose |
|---|---|---|
| Solidity | 0.8.20 | Smart contract language — built-in overflow protection |
| Hardhat | 2.22+ | Compile, test, and deploy contracts |
| OpenZeppelin | 5.0 | Audited security contracts — ReentrancyGuard, Ownable |
| ethers.js | 6.7 | Frontend blockchain library — CDN, no build step |
| MetaMask | Latest | Wallet connection and transaction signing |
| Ethereum Sepolia | Testnet | Live blockchain — free ETH, real environment |
| Alchemy | Free tier | RPC node provider |
| Vercel | Free tier | Frontend hosting with GitHub auto-deploy |
| SubtleCrypto API | Browser built-in | SHA-256 hashing — files never leave the device |

---

## 🌍 Problem Statement

**The scale:**
- Over 2 billion people globally have no access to formal legal services
- Property fraud costs an estimated $1 trillion annually worldwide
- 30% of legal tech startups shut down within 3 years, taking user data with them
- Writing a will costs $500–$2,000 — most people never do it

**Why existing solutions fail:**
- **DocuSign** — centralized servers, can be hacked, company can be pressured
- **LegalZoom** — documents stored privately, not independently verifiable
- **Traditional notaries** — physical presence required, expensive, inaccessible
- **Online wills** — text documents with no enforcement mechanism

**Why LexChain is different:**
LexChain does not store documents. It stores mathematical proofs. It does not hold your money in a company account. Smart contracts hold and enforce movement. It does not require you to trust a company. The code is the company, and the code is public.

---

## 📄 License

MIT — free to use, modify, and distribute with attribution.

---

*"The code is the contract. The blockchain is the notary. The audit trail is the court record."*
