// scripts/deploy.js — LexChain Deployment Script
// Deploys all 5 LexChain contracts in dependency order and wires them together.
// Run with:  npx hardhat run scripts/deploy.js --network sepolia
// Local test: npx hardhat run scripts/deploy.js --network localhost

const { ethers } = require("hardhat");
const fs   = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("\n══════════════════════════════════════════════════");
  console.log("  LexChain — Decentralized Legal Platform");
  console.log("  Deployment Script");
  console.log("══════════════════════════════════════════════════");
  console.log(`  Deployer:  ${deployer.address}`);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`  Balance:   ${ethers.formatEther(balance)} ETH`);
  console.log("══════════════════════════════════════════════════\n");

  // ── STEP 1: AuditTrail ────────────────────────────────────────────
  // Must deploy first — every other contract needs its address.
  console.log("📋 Step 1/6: Deploying AuditTrail...");
  const AuditTrail = await ethers.getContractFactory("AuditTrail");
  const auditTrail = await AuditTrail.deploy();
  await auditTrail.waitForDeployment();
  const auditTrailAddress = await auditTrail.getAddress();
  console.log(`   ✅ AuditTrail deployed at: ${auditTrailAddress}`);

  // ── STEP 2: WillRegistry ──────────────────────────────────────────
  console.log("\n📜 Step 2/6: Deploying WillRegistry...");
  const WillRegistry = await ethers.getContractFactory("WillRegistry");
  const willRegistry = await WillRegistry.deploy(auditTrailAddress);
  await willRegistry.waitForDeployment();
  const willRegistryAddress = await willRegistry.getAddress();
  console.log(`   ✅ WillRegistry deployed at: ${willRegistryAddress}`);

  // ── STEP 3: PropertyEscrow ────────────────────────────────────────
  // Example deal — in production each deal is a fresh deployment per transaction.
  console.log("\n🏠 Step 3/6: Deploying PropertyEscrow (example deal)...");
  const PropertyEscrow = await ethers.getContractFactory("PropertyEscrow");
  const propertyEscrow = await PropertyEscrow.deploy(
    "0x0000000000000000000000000000000000000001", // placeholder seller
    ethers.parseEther("0.1"),
    "Example Property — 3 bedroom house",
    "123 Demo Street, Testville",
    "Title deed must be transferred to buyer before release",
    auditTrailAddress
  );
  await propertyEscrow.waitForDeployment();
  const propertyEscrowAddress = await propertyEscrow.getAddress();
  console.log(`   ✅ PropertyEscrow deployed at: ${propertyEscrowAddress}`);

  // ── STEP 4: DocumentNotary ────────────────────────────────────────
  console.log("\n🔏 Step 4/6: Deploying DocumentNotary...");
  const DocumentNotary = await ethers.getContractFactory("DocumentNotary");
  const documentNotary = await DocumentNotary.deploy(auditTrailAddress);
  await documentNotary.waitForDeployment();
  const documentNotaryAddress = await documentNotary.getAddress();
  console.log(`   ✅ DocumentNotary deployed at: ${documentNotaryAddress}`);

  // ── STEP 5: FraudGuard ────────────────────────────────────────────
  // The safe wallet is where funds go when fraud is detected.
  // It MUST be a different address from the deployer — that is the whole
  // point of the feature (funds escape to a separate wallet on fraud).
  //
  // HOW TO SET YOUR SAFE WALLET:
  // Option A (recommended): Hard-code your cold/hardware wallet address below.
  // Option B: Set SAFE_WALLET in your .env file and read it here.
  //
  // If you do not have a second wallet yet:
  //   1. Create a second MetaMask account (click the account circle -> Add account)
  //   2. Copy that address and paste it as SAFE_WALLET_ADDRESS below
  //   3. Keep that account's private key somewhere safe — it is your escape wallet
  console.log("\n🛡️  Step 5/6: Deploying FraudGuard...");

  // ─────────────────────────────────────────────────────────────────
  // EDIT THIS: paste your cold/hardware/second wallet address here.
  // It must be different from your deployer wallet.
  // ─────────────────────────────────────────────────────────────────
  const SAFE_WALLET_ADDRESS = process.env.SAFE_WALLET || "";

  // Validate the safe wallet address before attempting deployment
  if (
    !SAFE_WALLET_ADDRESS ||
    !ethers.isAddress(SAFE_WALLET_ADDRESS) ||
    SAFE_WALLET_ADDRESS.toLowerCase() === deployer.address.toLowerCase()
  ) {
    console.error("\n❌ FraudGuard deployment requires a valid SAFE_WALLET address.");
    console.error("   The safe wallet must be DIFFERENT from your deployer wallet.");
    console.error("   Add this line to your .env file:");
    console.error("   SAFE_WALLET=0xYourSecondWalletAddressHere\n");
    console.error("   How to get a second wallet address:");
    console.error("   MetaMask -> click account circle -> Add account -> Copy address\n");
    process.exit(1);
  }

  const guardianAddr = ethers.ZeroAddress; // optional: set GUARDIAN= in .env for a trusted guardian

  const FraudGuard = await ethers.getContractFactory("FraudGuard");
  const fraudGuard = await FraudGuard.deploy(
    auditTrailAddress,
    SAFE_WALLET_ADDRESS,
    guardianAddr
  );
  await fraudGuard.waitForDeployment();
  const fraudGuardAddress = await fraudGuard.getAddress();
  console.log(`   ✅ FraudGuard deployed at:    ${fraudGuardAddress}`);
  console.log(`   🔒 Safe wallet set to:        ${SAFE_WALLET_ADDRESS}`);

  // ── STEP 6: Wire all contracts together ──────────────────────────
  // Part A: Authorize contracts to write to AuditTrail
  // Part B: Authorize contracts to report to FraudGuard
  // Part C: Connect WillRegistry and PropertyEscrow to FraudGuard
  //         so large ETH outflows are auto-reported without user input
  console.log("\n🔐 Step 6/6: Wiring all contracts together...");

  // Part A — AuditTrail authorization
  console.log("   Authorizing AuditTrail writers...");
  const toAuthorize = [
    { addr: willRegistryAddress,   name: "WillRegistry"   },
    { addr: propertyEscrowAddress, name: "PropertyEscrow" },
    { addr: documentNotaryAddress, name: "DocumentNotary" },
    { addr: fraudGuardAddress,     name: "FraudGuard"     },
  ];
  for (const c of toAuthorize) {
    const tx = await auditTrail.authorizeContract(c.addr);
    await tx.wait();
    console.log(`   ✅ ${c.name} authorized on AuditTrail`);
  }

  // Part B — FraudGuard reporter authorization
  // WillRegistry and PropertyEscrow need permission to call
  // fraudGuard.reportSuspiciousActivity() automatically.
  console.log("\n   Authorizing automatic FraudGuard reporters...");
  const txR1 = await fraudGuard.authorizeReporter(willRegistryAddress);
  await txR1.wait();
  console.log("   ✅ WillRegistry authorized as FraudGuard reporter");

  const txR2 = await fraudGuard.authorizeReporter(propertyEscrowAddress);
  await txR2.wait();
  console.log("   ✅ PropertyEscrow authorized as FraudGuard reporter");

  // Part C — Connect FraudGuard address into WillRegistry and PropertyEscrow
  // This is what makes the auto-detection work end-to-end:
  // When distributeEstate() or completeDeal() runs, it looks up fraudGuardContract
  // and calls reportSuspiciousActivity() automatically.
  console.log("\n   Connecting FraudGuard to other contracts...");
  const txW = await willRegistry.setFraudGuard(fraudGuardAddress);
  await txW.wait();
  console.log("   ✅ WillRegistry -> FraudGuard connected");

  const txP = await propertyEscrow.setFraudGuard(fraudGuardAddress);
  await txP.wait();
  console.log("   ✅ PropertyEscrow -> FraudGuard connected");

  // ── Print Summary ─────────────────────────────────────────────────
  console.log("\n══════════════════════════════════════════════════");
  console.log("  DEPLOYMENT COMPLETE — CONTRACT ADDRESSES");
  console.log("══════════════════════════════════════════════════");
  console.log(`  AuditTrail:      ${auditTrailAddress}`);
  console.log(`  WillRegistry:    ${willRegistryAddress}`);
  console.log(`  PropertyEscrow:  ${propertyEscrowAddress}`);
  console.log(`  DocumentNotary:  ${documentNotaryAddress}`);
  console.log(`  FraudGuard:      ${fraudGuardAddress}`);
  console.log("══════════════════════════════════════════════════");
  console.log("\n  Next steps:");
  console.log("  1. Paste all 5 addresses into frontend/index.html → ADDRESSES constant");
  console.log("  2. Update FraudGuard safe wallet to your cold wallet:");
  console.log(`     await fraudGuard.registerSafeWallet("0xYourColdWalletHere")`);
  console.log("  3. Optionally verify on Etherscan:");
  console.log(`     npx hardhat verify --network sepolia ${auditTrailAddress}`);
  console.log(`     npx hardhat verify --network sepolia ${willRegistryAddress} "${auditTrailAddress}"`);
  console.log(`     npx hardhat verify --network sepolia ${documentNotaryAddress} "${auditTrailAddress}"`);
  console.log(`     npx hardhat verify --network sepolia ${fraudGuardAddress} "${auditTrailAddress}" "${SAFE_WALLET_ADDRESS}" "${guardianAddr}"`);
  console.log("");

  // ── Save addresses to JSON ────────────────────────────────────────
  const addresses = {
    network:              (await ethers.provider.getNetwork()).name,
    deployedAt:           new Date().toISOString(),
    deployer:             deployer.address,
    AuditTrail:           auditTrailAddress,
    WillRegistry:         willRegistryAddress,
    PropertyEscrow:       propertyEscrowAddress,
    DocumentNotary:       documentNotaryAddress,
    FraudGuard:           fraudGuardAddress,
    FraudGuardSafeWallet: SAFE_WALLET_ADDRESS,
  };

  const outputPath = path.join(__dirname, "..", "deployed-addresses.json");
  fs.writeFileSync(outputPath, JSON.stringify(addresses, null, 2));
  console.log(`  📁 Addresses saved to deployed-addresses.json\n`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Deployment failed:", error);
    process.exit(1);
  });
