// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// DocumentNotary.sol — LexChain Decentralized Legal Platform
// This contract lets anyone "notarize" a document by storing its SHA-256 hash on-chain.
// How it works: The file is hashed in the user's browser (it never leaves their device).
// That hash — a unique 32-byte fingerprint of the file — is stored permanently on Ethereum.
// Later, anyone can hash the same file and compare against the on-chain record.
// If the hashes match, the document is authentic and has NEVER been modified.
// If they don't match, the document has been tampered with.
// This is exactly what a traditional notary does, but it's free, instant, and permanent.
// A notary's stamp can be faked; a blockchain hash cannot.

import "@openzeppelin/contracts/access/Ownable.sol"; // for owner-only admin functions

// Minimal interface to call AuditTrail without importing the full contract.
interface IAuditTrail {
    function logAction(
        address userAddress,
        string  memory actionType,
        string  memory details,
        bytes32 dataHash
    ) external;
}

contract DocumentNotary is Ownable {

    // ─── DATA STRUCTURES ─────────────────────────────────────────

    // NotarizedDocument stores the on-chain record for a notarized file.
    // We store the hash, not the file itself. This is crucial for two reasons:
    // 1. Privacy: sensitive documents never touch the blockchain.
    // 2. Cost: storing a full document on-chain would cost thousands of dollars.
    struct NotarizedDocument {
        bytes32 documentHash;   // SHA-256 hash of the original file (32 bytes)
        string  documentTitle;  // human-readable name for the document
        string  documentType;   // category e.g. "will", "property deed", "contract"
        address notarizedBy;    // wallet that submitted the notarization
        uint256 timestamp;      // block.timestamp when the hash was recorded
        string  description;    // optional details about the document
        bool    isRevoked;      // if true, the document has been invalidated by its creator
    }

    // ─── STATE VARIABLES ─────────────────────────────────────────

    // documents maps a file hash to its NotarizedDocument record.
    // If documents[hash].timestamp == 0, the hash has never been notarized.
    // This is the core lookup used by verifyDocument().
    mapping(bytes32 => NotarizedDocument) public documents;

    // userDocuments maps a wallet address to all hashes they have notarized.
    // This lets the frontend show a user their complete document history.
    mapping(address => bytes32[]) public userDocuments;

    // totalDocuments is a simple counter for the dashboard stats card.
    uint256 public totalDocuments;

    // The address of the deployed AuditTrail contract.
    address public auditTrailContract;

    // ─── EVENTS ──────────────────────────────────────────────────

    // Emitted when a new document hash is recorded on-chain.
    // Indexed fields allow efficient filtering by hash or submitter.
    event DocumentNotarized(
        bytes32 indexed documentHash,
        string  title,
        address indexed notarizedBy,
        uint256 timestamp
    );

    // Emitted when the creator invalidates a previously notarized document.
    event DocumentRevoked(
        bytes32 indexed documentHash,
        address indexed revokedBy,
        uint256 timestamp
    );

    // Emitted every time someone runs a verification check.
    // The `authentic` flag tells them whether the document passed or failed.
    event DocumentVerified(
        bytes32 indexed documentHash,
        bool    authentic,
        uint256 timestamp
    );

    // ─── CONSTRUCTOR ─────────────────────────────────────────────

    // Sets the owner (deployer) and stores the AuditTrail address.
    // Ownable(msg.sender) is required by OpenZeppelin Ownable in v5+.
    constructor(address _auditTrail) Ownable(msg.sender) {
        require(_auditTrail != address(0), "DocumentNotary: invalid audit trail address");
        auditTrailContract = _auditTrail; // store for use in _log() calls
        totalDocuments     = 0;           // no documents at deployment
    }

    // ─── INTERNAL HELPER ─────────────────────────────────────────

    // _log() reduces repetition when writing entries to AuditTrail.
    function _log(
        address user,
        string memory actionType,
        string memory details,
        bytes32 dataHash
    ) private {
        IAuditTrail(auditTrailContract).logAction(user, actionType, details, dataHash);
    }

    // ─── PUBLIC FUNCTIONS ─────────────────────────────────────────

    // notarizeDocument() — records the hash of a document permanently on-chain.
    // The caller provides the hash (computed in their browser using SubtleCrypto API).
    // We NEVER accept the actual file — only its hash. This is by design:
    // the hash alone is enough to prove authenticity, and keeping files off-chain
    // protects user privacy and keeps gas costs minimal.
    function notarizeDocument(
        bytes32 documentHash,
        string  memory title,
        string  memory docType,
        string  memory description
    ) external {
        // The hash must be non-zero — a zero hash would be meaningless.
        require(documentHash != bytes32(0), "DocumentNotary: document hash cannot be zero");

        // The title must not be empty — we need something to identify the document.
        require(bytes(title).length > 0, "DocumentNotary: document title cannot be empty");

        // Each hash can only be notarized once. If someone tries to notarize the same
        // file twice, the second call reverts. We check this by looking at the timestamp:
        // a timestamp of 0 means the slot has never been written to.
        require(
            documents[documentHash].timestamp == 0,
            "DocumentNotary: this document hash has already been notarized"
        );

        // Create the record and store it.
        documents[documentHash] = NotarizedDocument({
            documentHash:  documentHash,
            documentTitle: title,
            documentType:  docType,
            notarizedBy:   msg.sender,       // whoever called this function
            timestamp:     block.timestamp,  // the block's timestamp — permanently recorded
            description:   description,
            isRevoked:     false             // not revoked by default
        });

        // Track this hash under the caller's address for their document history page.
        userDocuments[msg.sender].push(documentHash);

        totalDocuments++; // increment the global counter for dashboard stats

        _log(
            msg.sender,
            "DOCUMENT_NOTARIZED",
            string(abi.encodePacked("Document notarized: ", title, " (", docType, ")")),
            documentHash // the document hash itself serves as the data hash here
        );

        emit DocumentNotarized(documentHash, title, msg.sender, block.timestamp);
    }

    // verifyDocument() — checks whether a hash is in the on-chain record.
    // The flow is:
    // 1. User uploads a file in their browser.
    // 2. Browser computes SHA-256 hash (SubtleCrypto API).
    // 3. Frontend calls this function with the computed hash.
    // 4. We look it up in the mapping and return authentic/not-found/revoked.
    // This function is marked non-view because it emits an event (DocumentVerified).
    // The event creates a permanent log of every verification attempt, which adds
    // to the audit trail even for read operations.
    function verifyDocument(bytes32 documentHash) external returns (bool) {
        NotarizedDocument storage doc = documents[documentHash]; // load the record

        // If timestamp is 0, this hash was never stored — document is unknown.
        if (doc.timestamp == 0) {
            emit DocumentVerified(documentHash, false, block.timestamp);
            return false;
        }

        // If the creator revoked this document, it no longer counts as authentic.
        if (doc.isRevoked) {
            emit DocumentVerified(documentHash, false, block.timestamp);
            return false;
        }

        // Hash exists and is not revoked — the document is authentic.
        // The file that produced this hash has never been modified since notarization.
        emit DocumentVerified(documentHash, true, block.timestamp);
        return true;
    }

    // revokeDocument() — the original notarizer can invalidate their document.
    // Use cases: the document was superseded by a newer version, it was notarized
    // in error, or the creator wants to formally retire it.
    // Only the person who notarized it can revoke it — no one else has that right.
    function revokeDocument(bytes32 documentHash) external {
        NotarizedDocument storage doc = documents[documentHash]; // load the record

        // Ensure the caller is the original notarizer.
        // We check address(0) as a secondary guard — timestamp == 0 means never notarized.
        require(doc.timestamp != 0,             "DocumentNotary: document does not exist");
        require(doc.notarizedBy == msg.sender,  "DocumentNotary: only the original notarizer can revoke");
        require(!doc.isRevoked,                 "DocumentNotary: document is already revoked");

        doc.isRevoked = true; // mark as revoked — subsequent verifications will return false

        _log(
            msg.sender,
            "DOCUMENT_REVOKED",
            string(abi.encodePacked("Document revoked: ", doc.documentTitle)),
            keccak256(abi.encodePacked(documentHash, msg.sender, block.timestamp))
        );

        emit DocumentRevoked(documentHash, msg.sender, block.timestamp);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────

    // getDocument() — returns the full NotarizedDocument struct for a given hash.
    // The frontend uses this to display document details after a successful verification.
    function getDocument(bytes32 documentHash) external view returns (NotarizedDocument memory) {
        return documents[documentHash]; // return the full struct (or an empty one if not found)
    }

    // getUserDocuments() — returns all hashes that a user has notarized.
    // The frontend iterates over these and calls getDocument() on each to populate
    // the "My Documents" table.
    function getUserDocuments(address user) external view returns (bytes32[] memory) {
        return userDocuments[user]; // return the array of hashes for this user
    }

    // getDocumentCount() — returns how many documents a user has notarized.
    // Used in the dashboard stat cards.
    function getDocumentCount(address user) external view returns (uint256) {
        return userDocuments[user].length; // length of their personal hash array
    }
}
