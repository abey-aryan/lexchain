// test/LexChain.test.js — LexChain Full Test Suite
// Run with: npx hardhat test
// Each test is commented to explain what it tests and why it matters in the real world.

const { expect }      = require("chai");
const { ethers }      = require("hardhat");
const { time }        = require("@nomicfoundation/hardhat-network-helpers"); // for time manipulation

// ═════════════════════════════════════════════════════════════════════════════
describe("AuditTrail", function () {
// ═════════════════════════════════════════════════════════════════════════════
  let auditTrail;
  let owner, authorizedCaller, unauthorizedCaller, user;

  beforeEach(async function () {
    [owner, authorizedCaller, unauthorizedCaller, user] = await ethers.getSigners();
    const AuditTrail = await ethers.getContractFactory("AuditTrail");
    auditTrail = await AuditTrail.deploy();
  });

  // Real-world significance: The AuditTrail is the cornerstone of legal credibility.
  // If it deploys with the wrong owner, the entire authorization system is compromised.
  it("deploys and sets owner correctly", async function () {
    expect(await auditTrail.owner()).to.equal(owner.address);
  });

  // Real-world significance: If any random wallet could authorize contracts,
  // an attacker could authorize their own contract to inject fake audit entries,
  // poisoning the audit trail with fraudulent legal records.
  it("only allows owner to authorize contracts", async function () {
    await expect(
      auditTrail.connect(unauthorizedCaller).authorizeContract(authorizedCaller.address)
    ).to.be.reverted;
  });

  // Real-world significance: An unauthorized contract trying to write to the audit log
  // simulates a malicious actor trying to insert fake legal events (e.g., fake will triggers).
  // The authorization gate must block this completely.
  it("rejects logAction from unauthorized contract", async function () {
    const fakeHash = ethers.keccak256(ethers.toUtf8Bytes("test"));
    await expect(
      auditTrail.connect(unauthorizedCaller).logAction(
        user.address, "FAKE_ACTION", "Fake details", fakeHash
      )
    ).to.be.revertedWith("AuditTrail: caller not authorized");
  });

  // Real-world significance: Once a legal action is logged, it must be retrievable
  // with all original data intact. Courts and auditors rely on this.
  it("stores audit entries correctly after authorization", async function () {
    await auditTrail.connect(owner).authorizeContract(authorizedCaller.address);

    const fakeHash = ethers.keccak256(ethers.toUtf8Bytes("data"));
    await auditTrail.connect(authorizedCaller).logAction(
      user.address,
      "TEST_ACTION",
      "Test details",
      fakeHash
    );

    expect(await auditTrail.getEntryCount()).to.equal(1);
    const entry = await auditTrail.auditLog(0);
    expect(entry.userAddress).to.equal(user.address);
    expect(entry.actionType).to.equal("TEST_ACTION");
    expect(entry.details).to.equal("Test details");
    expect(entry.dataHash).to.equal(fakeHash);
  });

  // Real-world significance: Users have a right to see their own activity history.
  // This function is also used by legal authorities investigating a specific wallet.
  it("retrieves user history correctly", async function () {
    await auditTrail.connect(owner).authorizeContract(authorizedCaller.address);
    const hash1 = ethers.keccak256(ethers.toUtf8Bytes("action1"));
    const hash2 = ethers.keccak256(ethers.toUtf8Bytes("action2"));

    await auditTrail.connect(authorizedCaller).logAction(user.address, "ACTION_1", "First", hash1);
    await auditTrail.connect(authorizedCaller).logAction(user.address, "ACTION_2", "Second", hash2);

    const history = await auditTrail.getUserHistory(user.address);
    expect(history.length).to.equal(2);
    expect(history[0].actionType).to.equal("ACTION_1");
    expect(history[1].actionType).to.equal("ACTION_2");
  });

  // Real-world significance: In a court case, the opposing party might claim an audit
  // entry was tampered with. verifyEntryIntegrity() provides mathematical proof it wasn't.
  it("verifies entry integrity correctly", async function () {
    await auditTrail.connect(owner).authorizeContract(authorizedCaller.address);
    const dataHash = ethers.keccak256(ethers.toUtf8Bytes("important data"));
    await auditTrail.connect(authorizedCaller).logAction(user.address, "ACTION", "Details", dataHash);

    expect(await auditTrail.verifyEntryIntegrity(0, dataHash)).to.equal(true);

    const wrongHash = ethers.keccak256(ethers.toUtf8Bytes("tampered data"));
    expect(await auditTrail.verifyEntryIntegrity(0, wrongHash)).to.equal(false);
  });

  // Real-world significance: A government auditor calls getFullAuditLog() to get
  // every action on the platform. This must return the complete, unfiltered record.
  it("returns full audit log for authorities", async function () {
    await auditTrail.connect(owner).authorizeContract(authorizedCaller.address);
    const h = ethers.keccak256(ethers.toUtf8Bytes("x"));
    await auditTrail.connect(authorizedCaller).logAction(user.address, "A1", "D1", h);
    await auditTrail.connect(authorizedCaller).logAction(user.address, "A2", "D2", h);
    await auditTrail.connect(authorizedCaller).logAction(user.address, "A3", "D3", h);

    const fullLog = await auditTrail.getFullAuditLog();
    expect(fullLog.length).to.equal(3);
  });
});


// ═════════════════════════════════════════════════════════════════════════════
describe("WillRegistry", function () {
// ═════════════════════════════════════════════════════════════════════════════
  let auditTrail, willRegistry;
  let owner, heir1, heir2, heir3, stranger;

  beforeEach(async function () {
    [owner, heir1, heir2, heir3, stranger] = await ethers.getSigners();

    // Deploy AuditTrail first, then WillRegistry with its address.
    const AuditTrail = await ethers.getContractFactory("AuditTrail");
    auditTrail = await AuditTrail.deploy();

    const WillRegistry = await ethers.getContractFactory("WillRegistry");
    willRegistry = await WillRegistry.deploy(await auditTrail.getAddress());

    // Authorize WillRegistry so it can write to AuditTrail.
    await auditTrail.authorizeContract(await willRegistry.getAddress());
  });

  // Real-world significance: The will starts in a clean draft state.
  // If it were triggered or finalized from day one, it would be unusable.
  it("deploys with correct initial state", async function () {
    expect(await willRegistry.willFinalized()).to.equal(false);
    expect(await willRegistry.willTriggered()).to.equal(false);
    expect(await willRegistry.beneficiaryCount()).to.equal(0);
    expect(await willRegistry.getTotalPercentage()).to.equal(0);
  });

  // Real-world significance: Adding a beneficiary is the core action of will creation.
  // The stored data must exactly match what was submitted for legal accuracy.
  it("adds beneficiary with correct data", async function () {
    await willRegistry.connect(owner).addBeneficiary(
      heir1.address, "Alice Smith", 60, "daughter"
    );
    expect(await willRegistry.beneficiaryCount()).to.equal(1);
    expect(await willRegistry.getTotalPercentage()).to.equal(60);

    const [wallets, names, percentages, relationships] = await willRegistry.getBeneficiaries();
    expect(wallets[0]).to.equal(heir1.address);
    expect(names[0]).to.equal("Alice Smith");
    expect(percentages[0]).to.equal(60);
    expect(relationships[0]).to.equal("daughter");
  });

  // Real-world significance: A will with 6 beneficiaries would be a contract bug.
  // Limiting to 5 keeps gas costs predictable and the logic simple.
  it("rejects more than 5 beneficiaries", async function () {
    const signers = await ethers.getSigners();
    // Add 5 beneficiaries (each gets 20%)
    for (let i = 1; i <= 5; i++) {
      await willRegistry.connect(owner).addBeneficiary(
        signers[i].address, `Person ${i}`, 20, "relative"
      );
    }
    // 6th should be rejected
    await expect(
      willRegistry.connect(owner).addBeneficiary(
        signers[6].address, "Person 6", 0, "relative"
      )
    ).to.be.reverted;
  });

  // Real-world significance: If percentages could exceed 100%, the distribution
  // math would be wrong and some heirs would get nothing. This check is essential.
  it("rejects if percentages would exceed 100", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 70, "daughter");
    await expect(
      willRegistry.connect(owner).addBeneficiary(heir2.address, "Bob", 40, "son")
    ).to.be.revertedWith("WillRegistry: total percentage would exceed 100");
  });

  // Real-world significance: A finalized will is the equivalent of a signed legal document.
  // The 100% requirement ensures every wei of the estate has a designated recipient.
  it("finalizes will when total is exactly 100", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 60, "daughter");
    await willRegistry.connect(owner).addBeneficiary(heir2.address, "Bob",   40, "son");
    await willRegistry.connect(owner).finalizeWill();
    expect(await willRegistry.willFinalized()).to.equal(true);
  });

  // Real-world significance: Finalizing a will with unallocated percentages would
  // strand funds in the contract with no way to retrieve them. This must be blocked.
  it("rejects finalization when total is not 100", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 60, "daughter");
    await expect(
      willRegistry.connect(owner).finalizeWill()
    ).to.be.revertedWith("WillRegistry: total percentage must equal exactly 100");
  });

  // Real-world significance: The owner must be able to reset the death switch
  // timer. Without this, every 180 days would be a new scare for live owners.
  it("records activity and resets timer", async function () {
    const before = await willRegistry.lastActivityTimestamp();
    await time.increase(60 * 60); // advance 1 hour
    await willRegistry.connect(owner).recordActivity();
    const after = await willRegistry.lastActivityTimestamp();
    expect(after).to.be.gt(before); // timestamp must have advanced
  });

  // Real-world significance: A will must NOT trigger prematurely. If it fired after
  // 1 day, it would distribute estate to heirs while the owner is still alive.
  it("does not allow trigger before 180 days", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 100, "daughter");
    await willRegistry.connect(owner).finalizeWill();
    await time.increase(100 * 24 * 60 * 60); // only 100 days — not enough
    await expect(
      willRegistry.connect(stranger).checkAndTrigger()
    ).to.be.revertedWith("WillRegistry: inactivity period has not elapsed yet");
  });

  // Real-world significance: After 180 days of genuine inactivity, the heirs
  // must be able to trigger the will. This is the core death switch functionality.
  it("triggers correctly after 180 days of inactivity", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 100, "daughter");
    await willRegistry.connect(owner).finalizeWill();
    await time.increase(180 * 24 * 60 * 60 + 1); // 180 days + 1 second
    await willRegistry.connect(stranger).checkAndTrigger();
    expect(await willRegistry.willTriggered()).to.equal(true);
  });

  // Real-world significance: The most important test — does each heir receive
  // exactly the right amount? If the math is wrong, families lose money.
  it("distributes correct ETH amounts to each beneficiary", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 60, "daughter");
    await willRegistry.connect(owner).addBeneficiary(heir2.address, "Bob",   40, "son");
    await willRegistry.connect(owner).finalizeWill();

    // Fund the estate with 1 ETH.
    await owner.sendTransaction({ to: await willRegistry.getAddress(), value: ethers.parseEther("1") });

    // Fast-forward past inactivity period.
    await time.increase(180 * 24 * 60 * 60 + 1);
    await willRegistry.connect(stranger).checkAndTrigger();

    // Fast-forward past dispute window.
    await time.increase(7 * 24 * 60 * 60 + 1);

    const heir1Before = await ethers.provider.getBalance(heir1.address);
    const heir2Before = await ethers.provider.getBalance(heir2.address);

    await willRegistry.connect(stranger).distributeEstate();

    const heir1After = await ethers.provider.getBalance(heir1.address);
    const heir2After = await ethers.provider.getBalance(heir2.address);

    // Alice should receive 0.6 ETH (60%), Bob 0.4 ETH (40%).
    expect(heir1After - heir1Before).to.equal(ethers.parseEther("0.6"));
    expect(heir2After - heir2Before).to.equal(ethers.parseEther("0.4"));
  });

  // Real-world significance: If the owner returns from a long trip and sees
  // their will was triggered, they must be able to cancel within 7 days.
  it("allows owner to cancel trigger within 7 day dispute window", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 100, "daughter");
    await willRegistry.connect(owner).finalizeWill();
    await time.increase(180 * 24 * 60 * 60 + 1);
    await willRegistry.connect(stranger).checkAndTrigger();

    // Owner notices and cancels within 7 days.
    await time.increase(3 * 24 * 60 * 60); // 3 days later
    await willRegistry.connect(owner).cancelWillTrigger();
    expect(await willRegistry.willTriggered()).to.equal(false);
  });

  // Real-world significance: After 7 days, the dispute window is closed.
  // No one — including the owner — should be able to cancel after this point.
  it("rejects cancel after dispute window has expired", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 100, "daughter");
    await willRegistry.connect(owner).finalizeWill();
    await time.increase(180 * 24 * 60 * 60 + 1);
    await willRegistry.connect(stranger).checkAndTrigger();
    await time.increase(8 * 24 * 60 * 60); // 8 days — past the 7-day window
    await expect(
      willRegistry.connect(owner).cancelWillTrigger()
    ).to.be.revertedWith("WillRegistry: dispute window has expired, cannot cancel");
  });

  // Real-world significance: Every action must be logged for the audit trail.
  // Without this, authorities cannot verify the chain of events.
  it("logs actions to AuditTrail", async function () {
    await willRegistry.connect(owner).addBeneficiary(heir1.address, "Alice", 100, "daughter");
    const count = await auditTrail.getEntryCount();
    expect(count).to.be.gt(0); // at least one entry should exist after addBeneficiary
  });
});


// ═════════════════════════════════════════════════════════════════════════════
describe("PropertyEscrow", function () {
// ═════════════════════════════════════════════════════════════════════════════
  let auditTrail, propertyEscrow;
  let buyer, seller, stranger;
  const agreedPrice = ethers.parseEther("1.0"); // 1 ETH

  beforeEach(async function () {
    [buyer, seller, stranger] = await ethers.getSigners();

    const AuditTrail = await ethers.getContractFactory("AuditTrail");
    auditTrail = await AuditTrail.deploy();

    const PropertyEscrow = await ethers.getContractFactory("PropertyEscrow");
    propertyEscrow = await PropertyEscrow.connect(buyer).deploy(
      seller.address,
      agreedPrice,
      "3 bed house",
      "123 Main St",
      "Transfer title deed first",
      await auditTrail.getAddress()
    );

    await auditTrail.authorizeContract(await propertyEscrow.getAddress());
  });

  // Real-world significance: On deployment, the deal must start in a well-defined state.
  // A deal that starts as FUNDED or COMPLETED would be a contract bug.
  it("creates deal with correct initial state", async function () {
    expect(await propertyEscrow.buyer()).to.equal(buyer.address);
    expect(await propertyEscrow.seller()).to.equal(seller.address);
    expect(await propertyEscrow.agreedPrice()).to.equal(agreedPrice);
    expect(await propertyEscrow.getDealState()).to.equal("CREATED");
  });

  // Real-world significance: The buyer must be able to send the exact agreed amount.
  // This is the pivotal moment — real money enters the escrow.
  it("allows buyer to fund at exact agreed price", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    expect(await propertyEscrow.getDealState()).to.equal("FUNDED");
    const balance = await ethers.provider.getBalance(await propertyEscrow.getAddress());
    expect(balance).to.equal(agreedPrice);
  });

  // Real-world significance: Sending the wrong amount would create an underfunded or
  // overfunded escrow. Exact-match enforcement prevents pricing disputes.
  it("rejects funding with wrong amount", async function () {
    await expect(
      propertyEscrow.connect(buyer).fundDeal({ value: ethers.parseEther("0.5") })
    ).to.be.revertedWith("PropertyEscrow: must send exactly the agreed price");
  });

  // Real-world significance: The whole point of escrow — when both parties are happy,
  // the funds automatically move to the seller. No middleman needed.
  it("completes deal when both parties confirm (buyer first)", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    await propertyEscrow.connect(buyer).buyerConfirm();
    
    const sellerBefore = await ethers.provider.getBalance(seller.address);
    await propertyEscrow.connect(seller).sellerConfirm();
    const sellerAfter = await ethers.provider.getBalance(seller.address);

    expect(await propertyEscrow.getDealState()).to.equal("COMPLETED");
    // Seller received approximately 1 ETH (minus gas costs, so we use closeTo logic).
    expect(sellerAfter - sellerBefore).to.be.closeTo(
      agreedPrice,
      ethers.parseEther("0.01") // allow 0.01 ETH for gas
    );
  });

  // Real-world significance: The deal should complete regardless of confirmation order.
  // If it only worked buyer-then-seller, the seller would be blocked from confirming first.
  it("completes deal when seller confirms first, then buyer", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    await propertyEscrow.connect(seller).sellerConfirm();
    await propertyEscrow.connect(buyer).buyerConfirm();
    expect(await propertyEscrow.getDealState()).to.equal("COMPLETED");
  });

  // Real-world significance: If a seller goes dark for 30 days, the buyer
  // should get their money back automatically. No lawyers, no courts.
  it("refunds buyer after 30-day timeout", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    await time.increase(30 * 24 * 60 * 60 + 1); // 30 days + 1 second

    const buyerBefore = await ethers.provider.getBalance(buyer.address);
    const tx = await propertyEscrow.connect(buyer).requestRefund();
    const receipt = await tx.wait();
    const gasUsed = receipt.gasUsed * receipt.gasPrice;
    const buyerAfter = await ethers.provider.getBalance(buyer.address);

    expect(await propertyEscrow.getDealState()).to.equal("REFUNDED");
    // Buyer should get their 1 ETH back minus gas.
    expect(buyerAfter - buyerBefore + gasUsed).to.equal(agreedPrice);
  });

  // Real-world significance: Without a minimum lock period, buyers could fund, then
  // immediately refund — wasting the seller's time and disrupting the deal.
  it("rejects refund before 30-day timeout", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    await time.increase(10 * 24 * 60 * 60); // only 10 days
    await expect(
      propertyEscrow.connect(buyer).requestRefund()
    ).to.be.revertedWith("PropertyEscrow: timeout period has not elapsed yet");
  });

  // Real-world significance: Either party can raise a dispute. Sellers might dispute
  // if they believe the buyer is acting in bad faith, and vice versa.
  it("allows either party to raise a dispute", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    await propertyEscrow.connect(seller).raiseDispute();
    expect(await propertyEscrow.getDealState()).to.equal("DISPUTED");
  });

  // Real-world significance: Every property deal action must be in the audit trail
  // for legal documentation purposes. A court could subpoena this data.
  // Note: the constructor no longer logs (that would revert before authorization),
  // so we trigger the first log by calling fundDeal(), then check the count.
  it("logs deal actions to AuditTrail", async function () {
    await propertyEscrow.connect(buyer).fundDeal({ value: agreedPrice });
    const count = await auditTrail.getEntryCount();
    expect(count).to.be.gt(0); // fundDeal logs an entry to AuditTrail
  });
});


// ═════════════════════════════════════════════════════════════════════════════
describe("DocumentNotary", function () {
// ═════════════════════════════════════════════════════════════════════════════
  let auditTrail, documentNotary;
  let notarizer, otherUser, stranger;

  // Sample document hash simulating a SHA-256 hash from the browser.
  const sampleHash = ethers.keccak256(ethers.toUtf8Bytes("This is a test document content"));

  beforeEach(async function () {
    [notarizer, otherUser, stranger] = await ethers.getSigners();

    const AuditTrail = await ethers.getContractFactory("AuditTrail");
    auditTrail = await AuditTrail.deploy();

    const DocumentNotary = await ethers.getContractFactory("DocumentNotary");
    documentNotary = await DocumentNotary.deploy(await auditTrail.getAddress());

    await auditTrail.authorizeContract(await documentNotary.getAddress());
  });

  // Real-world significance: A notarized document must store all metadata accurately.
  // The hash, title, type, creator, and timestamp are all legally significant.
  it("notarizes document with correct data", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(
      sampleHash, "My Will 2024", "Will", "Final will document"
    );

    const doc = await documentNotary.getDocument(sampleHash);
    expect(doc.documentHash).to.equal(sampleHash);
    expect(doc.documentTitle).to.equal("My Will 2024");
    expect(doc.documentType).to.equal("Will");
    expect(doc.notarizedBy).to.equal(notarizer.address);
    expect(doc.isRevoked).to.equal(false);
    expect(doc.timestamp).to.be.gt(0);
  });

  // Real-world significance: If the same document could be notarized twice,
  // an attacker could create a fake "original" record earlier than the real one.
  it("rejects duplicate hash notarization", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "Doc", "Will", "Desc");
    await expect(
      documentNotary.connect(otherUser).notarizeDocument(sampleHash, "Fake", "Contract", "Fake")
    ).to.be.revertedWith("DocumentNotary: this document hash has already been notarized");
  });

  // Real-world significance: The verify function is what courts and lawyers use.
  // It must return true for a genuine, unrevoked document.
  it("verifies authentic document correctly", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "My Will", "Will", "Final");
    const isAuthentic = await documentNotary.connect(stranger).verifyDocument.staticCall(sampleHash);
    expect(isAuthentic).to.equal(true);
  });

  // Real-world significance: A forged document will have a different hash.
  // The system must return false — not crash — for unknown hashes.
  it("returns false for unknown document hash", async function () {
    const unknownHash = ethers.keccak256(ethers.toUtf8Bytes("Unknown document"));
    const isAuthentic = await documentNotary.connect(stranger).verifyDocument.staticCall(unknownHash);
    expect(isAuthentic).to.equal(false);
  });

  // Real-world significance: If a will is replaced by a new one, the old version
  // should be revocable so people don't mistakenly verify an outdated document.
  it("allows creator to revoke their document", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "Old Will", "Will", "Old");
    await documentNotary.connect(notarizer).revokeDocument(sampleHash);

    const doc = await documentNotary.getDocument(sampleHash);
    expect(doc.isRevoked).to.equal(true);
  });

  // Real-world significance: Only the original notarizer should be able to revoke.
  // A competitor or adversary must not be able to invalidate someone else's documents.
  it("rejects revocation from non-creator", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "My Doc", "Contract", "Imp");
    await expect(
      documentNotary.connect(stranger).revokeDocument(sampleHash)
    ).to.be.revertedWith("DocumentNotary: only the original notarizer can revoke");
  });

  // Real-world significance: A revoked document must verify as false.
  // Verification of a revoked document should return false with no ambiguity.
  it("returns false for revoked document on verification", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "Doc", "Will", "Desc");
    await documentNotary.connect(notarizer).revokeDocument(sampleHash);
    const isAuthentic = await documentNotary.connect(stranger).verifyDocument.staticCall(sampleHash);
    expect(isAuthentic).to.equal(false);
  });

  // Real-world significance: Document actions must appear in the audit trail
  // so there is a permanent record of when documents were notarized.
  it("logs notarization to AuditTrail", async function () {
    await documentNotary.connect(notarizer).notarizeDocument(sampleHash, "Doc", "Will", "Desc");
    const count = await auditTrail.getEntryCount();
    expect(count).to.be.gt(0); // at least one entry logged during notarization
  });
});


// ═════════════════════════════════════════════════════════════════════════════
describe("FraudGuard", function () {
// ═════════════════════════════════════════════════════════════════════════════
  let auditTrail, fraudGuard;
  let owner, safeWallet, guardian, stranger, attacker;

  beforeEach(async function () {
    [owner, safeWallet, guardian, stranger, attacker] = await ethers.getSigners();

    const AuditTrail = await ethers.getContractFactory("AuditTrail");
    auditTrail = await AuditTrail.deploy();

    const FraudGuard = await ethers.getContractFactory("FraudGuard");
    fraudGuard = await FraudGuard.connect(owner).deploy(
      await auditTrail.getAddress(),
      safeWallet.address,  // safe wallet where funds go on fraud
      guardian.address     // secondary trusted guardian
    );

    await auditTrail.authorizeContract(await fraudGuard.getAddress());

    // Fund the contract so transfers have something to move
    await owner.sendTransaction({
      to: await fraudGuard.getAddress(),
      value: ethers.parseEther("1.0")
    });
  });

  // Real-world significance: On deployment the system must be armed and clean.
  // Any pre-armed state would mean users receive a false alert immediately.
  it("deploys with correct initial state", async function () {
    expect(await fraudGuard.isArmed()).to.equal(true);
    expect(await fraudGuard.getAlertLevelString()).to.equal("NONE");
    expect(await fraudGuard.getTransferStageString()).to.equal("NONE");
    expect(await fraudGuard.safeWallet()).to.equal(safeWallet.address);
    expect(await fraudGuard.guardianAddress()).to.equal(guardian.address);
  });

  // Real-world significance: The safe wallet is the most critical configuration.
  // Changing it must be logged and must not be possible mid-transfer.
  it("allows owner to update safe wallet", async function () {
    const [,,, newSafe] = await ethers.getSigners();
    await fraudGuard.connect(owner).registerSafeWallet(newSafe.address);
    expect(await fraudGuard.safeWallet()).to.equal(newSafe.address);
  });

  // Real-world significance: A large single transfer (>50% of balance)
  // is the #1 signal of a compromised wallet — attackers always drain fast.
  it("raises HIGH alert on large transfer detection", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    const bigAmount = (bal * 60n) / 100n; // 60% of balance — over the 50% threshold

    await fraudGuard.connect(owner).recordTransaction(attacker.address, bigAmount);

    expect(await fraudGuard.getAlertLevelString()).to.equal("HIGH");
    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_1");
  });

  // Real-world significance: Rapid repeated small transactions are another
  // classic hacker pattern — they split a large drain into many small txns.
  it("raises HIGH alert on velocity spike (>5 txns in 1 hour)", async function () {
    const smallAmount = ethers.parseEther("0.01"); // small, below large-transfer threshold
    // Send 6 transactions within the velocity window — the 6th triggers the spike
    for (let i = 0; i < 6; i++) {
      await fraudGuard.connect(owner).recordTransaction(attacker.address, smallAmount);
    }
    expect(await fraudGuard.getAlertLevelString()).to.equal("HIGH");
  });

  // Real-world significance: Sending to an unknown address alone is suspicious
  // but not conclusive. It should raise LOW first, not immediately trigger transfer.
  it("raises LOW alert on first unrecognised recipient", async function () {
    const tinyAmount = ethers.parseEther("0.001"); // well below 50% threshold
    await fraudGuard.connect(owner).recordTransaction(stranger.address, tinyAmount);
    // stranger is not whitelisted → LOW alert
    expect(await fraudGuard.getAlertLevelString()).to.equal("LOW");
    // LOW alone does not start the transfer
    expect(await fraudGuard.getTransferStageString()).to.equal("NONE");
  });

  // Real-world significance: When the guardian (spouse/partner) spots suspicious
  // activity, they must be able to trigger the protection immediately.
  it("allows guardian to manually flag fraud", async function () {
    await fraudGuard.connect(guardian).manuallyFlagFraud("Saw suspicious login on owner device");
    expect(await fraudGuard.getAlertLevelString()).to.equal("CONFIRMED");
    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_1");
  });

  // Real-world significance: Strangers must not be able to trigger fraud alerts.
  // If anyone could call manuallyFlagFraud(), it would be a griefing vector.
  it("rejects manual fraud flag from stranger", async function () {
    await expect(
      fraudGuard.connect(stranger).manuallyFlagFraud("I am not guardian")
    ).to.be.revertedWith("FraudGuard: caller must be owner or guardian");
  });

  // Real-world significance: The core protection — the 24-hour delay prevents
  // an attacker from draining everything instantly even after triggering the alarm.
  it("queues stage 1 correctly and enforces 24h delay", async function () {
    // Trigger fraud with a large transfer
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_1");

    // Try to execute immediately — should revert because 24h has not passed
    await expect(
      fraudGuard.connect(stranger).executeNextStage()
    ).to.be.revertedWith("FraudGuard: stage delay period has not elapsed yet");
  });

  // Real-world significance: After 24h the first 30% must move to the safe wallet.
  // This is the first real transfer — partial protection is better than none.
  it("executes stage 1 (30%) after 24h delay", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    // Advance time by 24 hours + 1 second
    await time.increase(24 * 60 * 60 + 1);

    const safeBefore = await ethers.provider.getBalance(safeWallet.address);
    await fraudGuard.connect(stranger).executeNextStage(); // anyone can call this
    const safeAfter = await ethers.provider.getBalance(safeWallet.address);

    // Safe wallet should have received ~30% of 1 ETH = ~0.3 ETH
    const received = safeAfter - safeBefore;
    expect(received).to.equal(ethers.parseEther("0.3")); // exactly 30%

    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_2");
  });

  // Real-world significance: All three stages must complete correctly
  // so 100% of funds eventually reach safety — not just 30%.
  it("executes all 3 stages and moves 100% of funds to safe wallet", async function () {
    const initialBal = await ethers.provider.getBalance(await fraudGuard.getAddress());

    // Trigger fraud
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (initialBal * 60n) / 100n);

    const safeBefore = await ethers.provider.getBalance(safeWallet.address);

    // Execute stage 1 after 24h
    await time.increase(24 * 60 * 60 + 1);
    await fraudGuard.connect(stranger).executeNextStage();
    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_2");

    // Execute stage 2 after another 24h
    await time.increase(24 * 60 * 60 + 1);
    await fraudGuard.connect(stranger).executeNextStage();
    expect(await fraudGuard.getTransferStageString()).to.equal("STAGE_3");

    // Execute stage 3 after another 24h
    await time.increase(24 * 60 * 60 + 1);
    await fraudGuard.connect(stranger).executeNextStage();
    expect(await fraudGuard.getTransferStageString()).to.equal("COMPLETE");

    // Safe wallet should have received the full 1 ETH
    const safeAfter = await ethers.provider.getBalance(safeWallet.address);
    const totalReceived = safeAfter - safeBefore;
    expect(totalReceived).to.equal(initialBal); // all 1 ETH moved
  });

  // Real-world significance: If it was a false alarm (owner was just on holiday
  // with no internet), they must be able to cancel BEFORE funds move.
  // cancelAlert() sets currentTransferStage to COMPLETE to prevent any restart,
  // so executeNextStage() reverts with the "already completed" guard first.
  it("owner can cancel alert before stage 1 executes (false alarm)", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    // Owner sees the alert and cancels within the 24h window
    await fraudGuard.connect(owner).cancelAlert();

    // cancelAlert() marks the stage as COMPLETE to block any further execution.
    // Advancing time past 24h and trying to execute must revert — cancelled deal
    // is treated as complete so no ETH can ever move after a cancel.
    await time.increase(24 * 60 * 60 + 1);
    await expect(
      fraudGuard.connect(stranger).executeNextStage()
    ).to.be.revertedWith("FraudGuard: all stages already completed");

    expect(await fraudGuard.getAlertLevelString()).to.equal("NONE");
  });

  // Real-world significance: After a false alarm is resolved, the system
  // must be re-armable so it can protect against real future attacks.
  it("can be reset and re-armed after a cancelled alert", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);
    await fraudGuard.connect(owner).cancelAlert();
    await fraudGuard.connect(owner).resetGuard();

    // After reset, alert level and stage should be clean
    expect(await fraudGuard.getAlertLevelString()).to.equal("NONE");
    expect(await fraudGuard.getTransferStageString()).to.equal("NONE");
    expect(await fraudGuard.alertCancelled()).to.equal(false);
  });

  // Real-world significance: Between stages the attacker has no way to stop
  // the transfers — they can't cancel (only owner can), and they can't
  // redirect (safe wallet is locked in at deploy/registration time).
  it("stage 2 cannot execute before its own 24h delay after stage 1", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    // Execute stage 1 after 24h
    await time.increase(24 * 60 * 60 + 1);
    await fraudGuard.connect(stranger).executeNextStage();

    // Try stage 2 immediately — should fail because stage 2's 24h clock just started
    await expect(
      fraudGuard.connect(stranger).executeNextStage()
    ).to.be.revertedWith("FraudGuard: stage delay period has not elapsed yet");
  });

  // Real-world significance: Whitelisting known addresses prevents constant
  // false alarms for regular activity (e.g. paying the same vendor every month).
  it("does not raise alert for whitelisted address", async function () {
    // Whitelist the stranger's address
    await fraudGuard.connect(owner).addToWhitelist(stranger.address);

    // Even a large transfer to a whitelisted address should not trigger LOW alert
    // (only the large-amount check can still fire — whitelist only suppresses the
    // "unknown recipient" check)
    const tinyAmount = ethers.parseEther("0.001");
    await fraudGuard.connect(owner).recordTransaction(stranger.address, tinyAmount);

    // Unknown-recipient check should NOT fire since stranger is whitelisted
    expect(await fraudGuard.getAlertLevelString()).to.equal("NONE");
  });

  // Real-world significance: Every fraud event must be logged to the AuditTrail
  // so law enforcement can see exactly when the attack occurred.
  it("logs fraud events to AuditTrail", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    const count = await auditTrail.getEntryCount();
    expect(count).to.be.gt(0); // fraud alert must be logged
  });

  // Real-world significance: getSuspiciousEvents() must return all detected
  // anomalies so the owner can review the history of what was flagged.
  it("records suspicious events for review", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);

    const events = await fraudGuard.getSuspiciousEvents();
    expect(events.length).to.be.gt(0);
    expect(events[0].wasResolved).to.equal(false); // not resolved yet
  });

  // Real-world significance: After the owner cancels an alert (false alarm),
  // all suspicious events should be marked as resolved.
  it("marks suspicious events as resolved after owner cancels", async function () {
    const bal = await ethers.provider.getBalance(await fraudGuard.getAddress());
    await fraudGuard.connect(owner).recordTransaction(attacker.address, (bal * 60n) / 100n);
    await fraudGuard.connect(owner).cancelAlert();

    const events = await fraudGuard.getSuspiciousEvents();
    expect(events[0].wasResolved).to.equal(true); // now marked as false alarm
  });
});
