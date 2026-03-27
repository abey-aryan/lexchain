// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// AuditTrail.sol — LexChain Decentralized Legal Platform
// This contract is the backbone of LexChain's credibility.
// Every action taken across all 3 other contracts (WillRegistry,
// PropertyEscrow, DocumentNotary) gets permanently recorded here.
// A government auditor, tax authority, or lawyer can call this
// contract at any time and get a complete, tamper-proof history
// of all legal activity. Because it lives on the blockchain,
// no company can edit, delete, or hide these records.

contract AuditTrail {

    // ─── DATA STRUCTURES ─────────────────────────────────────────

    // AuditEntry represents a single recorded action in the system.
    // Every time someone creates a will, funds a deal, notarizes a
    // document, etc., one of these structs is created and stored forever.
    struct AuditEntry {
        address contractAddress; // which LexChain contract logged this action
        address userAddress;     // the wallet address of the person who acted
        string  actionType;      // machine-readable label, e.g. "WILL_FINALIZED"
        string  details;         // human-readable description of what happened
        uint256 timestamp;       // block.timestamp when the action occurred
        bytes32 dataHash;        // keccak256 hash of the action data for integrity checks
    }

    // ─── STATE VARIABLES ─────────────────────────────────────────

    // auditLog is the master list of every recorded action.
    // It only ever grows — entries are never deleted or modified.
    // This is what makes it "immutable" from a practical standpoint.
    AuditEntry[] public auditLog;

    // userAuditEntries maps a wallet address to the indices (positions)
    // in auditLog that belong to that user. This lets us quickly fetch
    // all history for a specific person without scanning the whole log.
    mapping(address => uint256[]) public userAuditEntries;

    // authorizedContracts controls which addresses can write to this log.
    // Only WillRegistry, PropertyEscrow, and DocumentNotary should be
    // authorized. This prevents random wallets from polluting the audit log.
    mapping(address => bool) public authorizedContracts;

    // owner is set in the constructor to the deployer's address.
    // Only the owner can authorize new contracts to write to this log.
    address public owner;

    // ─── EVENTS ──────────────────────────────────────────────────

    // Emitted every time a new entry is written to the log.
    // Indexed fields allow off-chain tools to filter and search efficiently.
    event AuditEntryCreated(
        uint256 indexed entryId,   // position in auditLog array
        address indexed user,      // who performed the action
        string  actionType,        // what type of action
        uint256 timestamp          // when it happened
    );

    // Emitted when the owner grants a contract permission to write logs.
    event ContractAuthorized(address indexed contractAddress);

    // ─── CONSTRUCTOR ─────────────────────────────────────────────

    // The constructor runs once at deployment time.
    // It records whoever deployed this contract as the owner.
    // The owner is responsible for calling authorizeContract() for each
    // of the 3 other LexChain contracts after they are deployed.
    constructor() {
        owner = msg.sender; // msg.sender is the deployer's wallet address
    }

    // ─── FUNCTIONS ───────────────────────────────────────────────

    // authorizeContract() — called by the owner after deploying each
    // of the 3 other contracts. Only authorized contracts can call logAction().
    // This is a basic access control pattern. Without it, anyone could
    // spam fake entries into the audit log.
    function authorizeContract(address contractAddress) external {
        require(msg.sender == owner, "AuditTrail: only owner can authorize"); // only deployer can authorize
        require(contractAddress != address(0), "AuditTrail: zero address not allowed"); // sanity check
        authorizedContracts[contractAddress] = true; // grant write permission
        emit ContractAuthorized(contractAddress);    // notify off-chain listeners
    }

    // logAction() — the core write function.
    // Called by WillRegistry, PropertyEscrow, and DocumentNotary
    // every time a significant action occurs. Only authorized contract
    // addresses can call this (checked via msg.sender).
    function logAction(
        address userAddress,     // the person who performed the action
        string  memory actionType, // e.g. "BENEFICIARY_ADDED"
        string  memory details,    // e.g. "Alice added Bob as beneficiary at 25%"
        bytes32 dataHash           // hash of the relevant data for integrity checking
    ) external {
        // Only contracts that have been authorized by the owner can write here.
        // msg.sender here is the calling contract's address, not a user wallet.
        require(authorizedContracts[msg.sender], "AuditTrail: caller not authorized");

        // Build the AuditEntry struct from the provided data and context.
        AuditEntry memory entry = AuditEntry({
            contractAddress: msg.sender,      // the contract calling us
            userAddress:     userAddress,     // the end user who triggered the action
            actionType:      actionType,      // the event label
            details:         details,         // the human-readable description
            timestamp:       block.timestamp, // the current block's timestamp
            dataHash:        dataHash         // hash for later integrity verification
        });

        auditLog.push(entry); // append to the master log (this is permanent)

        // Record the index of this entry for the user so we can look it up later.
        // auditLog.length - 1 gives us the index of the entry we just pushed.
        uint256 entryId = auditLog.length - 1;
        userAuditEntries[userAddress].push(entryId); // track for this user

        emit AuditEntryCreated(entryId, userAddress, actionType, block.timestamp);
    }

    // getUserHistory() — returns every audit entry for a specific user.
    // This is useful when a user wants to see all their own activity,
    // or when an auditor is investigating a particular wallet address.
    function getUserHistory(address user) external view returns (AuditEntry[] memory) {
        uint256[] memory indices = userAuditEntries[user]; // get the index list for this user
        AuditEntry[] memory result = new AuditEntry[](indices.length); // create result array of same size

        // Loop through the indices and copy the corresponding entries.
        for (uint256 i = 0; i < indices.length; i++) {
            result[i] = auditLog[indices[i]]; // copy entry from master log into result
        }

        return result; // return all entries for this user
    }

    // getFullAuditLog() — returns the entire audit log.
    // This is what a government official or court-appointed auditor
    // would call to get a complete record of all legal activity on this platform.
    // Because it's on-chain, they can independently verify it without
    // trusting LexChain the company — there is no company to trust.
    function getFullAuditLog() external view returns (AuditEntry[] memory) {
        return auditLog; // return the full array of every recorded action
    }

    // getEntryCount() — simple helper to get how many entries exist.
    // Useful for pagination on the frontend or quick stats.
    function getEntryCount() external view returns (uint256) {
        return auditLog.length; // length of the master log array
    }

    // verifyEntryIntegrity() — lets anyone check that a specific audit entry
    // has never been tampered with. They provide the entry ID and the hash
    // they expect. If the stored hash matches, the entry is intact.
    // This works because hashes are deterministic — the same data always
    // produces the same hash, and changing any data changes the hash.
    function verifyEntryIntegrity(
        uint256 entryId,
        bytes32 expectedHash
    ) external view returns (bool) {
        require(entryId < auditLog.length, "AuditTrail: entry does not exist"); // bounds check
        return auditLog[entryId].dataHash == expectedHash; // compare stored hash to expected
    }
}
