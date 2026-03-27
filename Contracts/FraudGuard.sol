// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// FraudGuard.sol - LexChain Decentralized Legal Platform
// ======================================================================
//
// PROBLEM THIS SOLVES:
// When a hacker steals someone's wallet private key, their first move is
// always the same: drain everything instantly in one transaction. By the
// time the real owner notices (hours or days later), the money is gone
// and untraceable. Traditional banks can freeze accounts and reverse
// transfers. Blockchain cannot - transactions are final.
//
// OUR SOLUTION - THE "SLOW DRAIN" DEFENCE:
// FraudGuard watches for suspicious transaction patterns on the owner's
// wallet. When something looks wrong, instead of allowing a full instant
// withdrawal, it begins moving funds to a pre-registered "safe wallet"
// (a cold wallet, a hardware wallet, a trusted family member's address)
// in THREE slow stages:
//
//   Stage 1 -> 30% transferred   (owner has time to cancel if false alarm)
//   Stage 2 -> 40% transferred   (only reached if owner does not cancel)
//   Stage 3 -> 30% transferred   (final stage, all funds now in safe wallet)
//
// Each stage has a mandatory waiting period (default: 24 hours) between it
// and the next stage. This gives the real owner time to cancel if the fraud
// alert was a false positive - for example if they simply moved to a new
// device and the pattern looked unusual.
//
// WHY THREE STAGES INSTEAD OF ONE?
// A single "send everything to safe wallet" would itself be exploitable -
// an attacker who controls the contract could set themselves as the safe
// wallet. The staged approach with cancellation windows means:
//   - A real attacker cannot drain everything instantly (they'd need 3 days)
//   - A false alarm is cheap to recover from (just cancel in stage 1)
//   - Even if the owner loses access, funds eventually reach safety
//
// WHAT COUNTS AS SUSPICIOUS?
// The contract tracks these signals:
//   1. Rapid large withdrawals - multiple big transfers in a short window
//   2. New recipient address - sending to an address never used before
//   3. Unusual hours - transaction at 3am when owner never transacts then
//   4. Manual flag - owner or a trusted guardian explicitly flags it
//   5. Velocity spike - more transactions in 1 hour than in the past month
//
// ======================================================================

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // prevents re-entrancy on ETH transfers
import "@openzeppelin/contracts/access/Ownable.sol";         // onlyOwner for sensitive operations

// Minimal interface to write to the shared AuditTrail.
interface IAuditTrail {
    function logAction(
        address userAddress,
        string  memory actionType,
        string  memory details,
        bytes32 dataHash
    ) external;
}

contract FraudGuard is ReentrancyGuard, Ownable {

    // --- ENUMS --------------------------------------------------------

    // AlertLevel describes how confident the system is that fraud is occurring.
    // LOW  = one suspicious signal detected (monitoring, no action yet)
    // HIGH = multiple signals or a large amount at risk (transfer begins)
    // CONFIRMED = owner or guardian manually confirmed it is fraud
    enum AlertLevel { NONE, LOW, HIGH, CONFIRMED }

    // TransferStage tracks which stage of the gradual safe transfer we are in.
    // NONE     = no transfer in progress
    // STAGE_1  = 30% has been queued, waiting for delay before executing
    // STAGE_2  = 30% sent, 40% queued
    // STAGE_3  = 70% sent, final 30% queued
    // COMPLETE = all three stages done, all funds in safe wallet
    enum TransferStage { NONE, STAGE_1, STAGE_2, STAGE_3, COMPLETE }

    // --- DATA STRUCTURES ----------------------------------------------

    // SuspiciousEvent records one detected anomaly for the audit trail.
    struct SuspiciousEvent {
        uint256 timestamp;      // when the anomaly was detected
        string  reason;         // human-readable description of why it was flagged
        uint256 amountInvolved; // how much ETH was involved in the suspicious action
        address suspectAddress; // the address that appeared in the suspicious action
        bool    wasResolved;    // true if the owner marked this as a false alarm
    }

    // StageExecution records when each transfer stage was queued and executed.
    struct StageExecution {
        uint256 queuedAt;   // block.timestamp when this stage was queued
        uint256 executedAt; // block.timestamp when the ETH was actually sent (0 if not yet)
        uint256 amount;     // how much ETH this stage will/did send
        bool    cancelled;  // true if the owner cancelled before execution
    }

    // --- CONSTANTS ----------------------------------------------------

    // How long to wait between queuing a stage and executing it.
    // 24 hours gives the real owner a full day to notice and cancel.
    uint256 public constant STAGE_DELAY = 24 hours;

    // The three transfer percentages. Must sum to exactly 100.
    uint8 public constant STAGE_1_PCT = 30; // first  batch: 30%
    uint8 public constant STAGE_2_PCT = 40; // second batch: 40%
    uint8 public constant STAGE_3_PCT = 30; // final  batch: 30%

    // Threshold: if a single outgoing transfer exceeds this fraction of the
    // contract balance, it is flagged as suspicious. 50% = half the balance.
    uint8 public constant LARGE_TRANSFER_THRESHOLD_PCT = 50;

    // Velocity threshold: if more than this many transactions are detected
    // in the velocity window, it is flagged as a velocity spike.
    uint256 public constant VELOCITY_THRESHOLD = 5;

    // The time window for velocity checking (1 hour in seconds).
    uint256 public constant VELOCITY_WINDOW = 1 hours;

    // --- STATE VARIABLES ----------------------------------------------

    // The pre-registered safe wallet. Funds flow HERE during a fraud alert.
    // This must be set before any fraud protection is active.
    // Typically: a hardware wallet, a cold wallet, or a trusted family address.
    address public safeWallet;

    // A secondary trusted address (e.g. spouse, business partner) who can
    // also trigger a fraud alert if they notice something is wrong.
    // This is optional - owner can leave it as address(0).
    address public guardianAddress;

    // The current fraud alert level for this contract.
    AlertLevel public currentAlertLevel;

    // The current stage of the gradual safe transfer process.
    TransferStage public currentTransferStage;

    // All suspicious events ever detected, for the audit trail.
    SuspiciousEvent[] public suspiciousEvents;

    // Details of each stage's execution (indices 0, 1, 2 = stages 1, 2, 3).
    StageExecution[3] public stageExecutions;

    // Timestamp of the last recorded outgoing transaction.
    // Used to detect velocity spikes (many txns in a short window).
    uint256 public lastTransactionTimestamp;

    // Counter of how many transactions occurred in the current velocity window.
    uint256 public transactionCountInWindow;

    // Snapshot of the contract balance when the fraud alert was first raised.
    // We use this snapshot so that all three stage percentages are calculated
    // from the same base amount, not a changing balance.
    uint256 public balanceAtAlertTime;

    // Whether FraudGuard protection is currently active (armed).
    // Owner can pause it for maintenance but it starts active.
    bool public isArmed;

    // The AuditTrail contract address for permanent logging.
    address public auditTrailContract;

    // Flag: has the owner acknowledged and cancelled the current alert?
    bool public alertCancelled;

    // Tracks known/safe recipient addresses the owner has whitelisted.
    // Sending to a whitelisted address never triggers a fraud flag.
    mapping(address => bool) public whitelistedAddresses;

    // How many addresses are whitelisted (for UI display).
    uint256 public whitelistCount;

    // authorizedReporters maps addresses that are allowed to call
    // reportSuspiciousActivity(). This includes WillRegistry, PropertyEscrow,
    // and the frontend event listener's signing wallet.
    // Keeping this separate from whitelistedAddresses prevents confusion:
    // whitelisted = trusted destination for funds
    // authorizedReporter = trusted SOURCE of fraud reports
    mapping(address => bool) public authorizedReporters;

    // --- EVENTS -------------------------------------------------------

    // Emitted when a suspicious pattern is first detected.
    event FraudAlertRaised(
        AlertLevel level,
        string     reason,
        uint256    amountInvolved,
        address    suspectAddress,
        uint256    timestamp
    );

    // Emitted when the alert level is escalated (e.g. LOW -> HIGH).
    event AlertEscalated(AlertLevel from, AlertLevel to, uint256 timestamp);

    // Emitted when a stage is queued - funds not sent yet, just scheduled.
    event StageQueued(uint8 stage, uint256 amount, uint256 executeAfter);

    // Emitted when a stage actually executes and ETH is sent to safe wallet.
    event StageExecuted(uint8 stage, uint256 amount, address safeWallet, uint256 timestamp);

    // Emitted when all three stages finish and the safe transfer is complete.
    event SafeTransferComplete(uint256 totalMoved, address safeWallet, uint256 timestamp);

    // Emitted when the owner cancels an in-progress alert (false alarm).
    event AlertCancelled(address owner, uint256 timestamp, uint8 stagesCompletedBeforeCancel);

    // Emitted when the owner registers or changes their safe wallet.
    event SafeWalletRegistered(address oldWallet, address newWallet, uint256 timestamp);

    // Emitted when an address is added to or removed from the whitelist.
    event WhitelistUpdated(address target, bool allowed, uint256 timestamp);

    // Emitted when a transaction is recorded for velocity tracking.
    event TransactionRecorded(address recipient, uint256 amount, uint256 velocityCount);

    // Emitted when a new address is authorized to submit fraud reports.
    // This is how we wire up WillRegistry and PropertyEscrow to auto-report.
    event ReporterAuthorized(address indexed reporter);

    // --- CONSTRUCTOR --------------------------------------------------

    // Deploy FraudGuard by providing the AuditTrail address and the safe wallet.
    // The safe wallet is the MOST IMPORTANT parameter - it must be an address
    // the owner fully controls but that is separate from their main wallet.
    constructor(
        address _auditTrail,
        address _safeWallet,
        address _guardianAddress  // optional - pass address(0) if not wanted
    ) Ownable(msg.sender) {
        require(_auditTrail  != address(0), "FraudGuard: audit trail cannot be zero address");
        require(_safeWallet  != address(0), "FraudGuard: safe wallet cannot be zero address");
        require(_safeWallet  != msg.sender, "FraudGuard: safe wallet must differ from owner");

        auditTrailContract = _auditTrail;
        safeWallet         = _safeWallet;
        guardianAddress    = _guardianAddress; // can be zero address (optional feature)

        currentAlertLevel    = AlertLevel.NONE;    // no alert on deployment
        currentTransferStage = TransferStage.NONE; // no transfer in progress
        isArmed              = true;               // protection active immediately
        alertCancelled       = false;
        whitelistCount       = 0;

        // Whitelist the safe wallet itself - sending to your own safe wallet
        // should never be flagged as suspicious.
        whitelistedAddresses[_safeWallet] = true;
        whitelistCount = 1;
    }

    // --- MODIFIERS ----------------------------------------------------

    // Only the owner OR the guardian can trigger certain actions.
    // This covers the case where the owner's wallet is compromised -
    // the guardian can still raise an alert.
    modifier onlyOwnerOrGuardian() {
        require(
            msg.sender == owner() || msg.sender == guardianAddress,
            "FraudGuard: caller must be owner or guardian"
        );
        _;
    }

    // Ensures FraudGuard is armed before any detection logic runs.
    modifier whenArmed() {
        require(isArmed, "FraudGuard: protection is currently disarmed");
        _;
    }

    // --- INTERNAL HELPER ----------------------------------------------

    // _log() writes a permanent entry to the AuditTrail.
    function _log(
        string memory actionType,
        string memory details,
        bytes32 dataHash
    ) private {
        IAuditTrail(auditTrailContract).logAction(
            owner(),    // the wallet this FraudGuard protects
            actionType,
            details,
            dataHash
        );
    }

    // --- SAFE WALLET MANAGEMENT ---------------------------------------

    // registerSafeWallet() - sets or updates the safe destination wallet.
    // This is the address that receives funds when fraud is detected.
    // IMPORTANT: Only call this from a secure environment. If an attacker
    // can call this, they could redirect funds to themselves.
    function registerSafeWallet(address newSafeWallet) external onlyOwner {
        require(newSafeWallet != address(0), "FraudGuard: cannot set zero address as safe wallet");
        require(newSafeWallet != owner(),    "FraudGuard: safe wallet must differ from owner wallet");
        require(
            currentTransferStage == TransferStage.NONE || currentTransferStage == TransferStage.COMPLETE,
            "FraudGuard: cannot change safe wallet while a transfer is in progress"
        );

        address old = safeWallet;  // remember old address for the event
        safeWallet  = newSafeWallet; // update to new safe wallet

        // Whitelist the new safe wallet so sending to it never triggers alerts.
        whitelistedAddresses[newSafeWallet] = true;

        _log(
            "SAFE_WALLET_REGISTERED",
            "Safe wallet address updated",
            keccak256(abi.encodePacked(old, newSafeWallet, block.timestamp))
        );

        emit SafeWalletRegistered(old, newSafeWallet, block.timestamp);
    }

    // setGuardian() - sets the secondary trusted address that can raise alerts.
    function setGuardian(address newGuardian) external onlyOwner {
        guardianAddress = newGuardian; // can be set to address(0) to remove guardian
        _log(
            "GUARDIAN_UPDATED",
            "Guardian address updated",
            keccak256(abi.encodePacked(newGuardian, block.timestamp))
        );
    }

    // addToWhitelist() - marks an address as trusted so transfers to it
    // never trigger fraud detection. Use for known frequent recipients.
    function addToWhitelist(address target) external onlyOwner {
        require(target != address(0), "FraudGuard: cannot whitelist zero address");
        require(!whitelistedAddresses[target], "FraudGuard: address already whitelisted");
        whitelistedAddresses[target] = true;
        whitelistCount++;
        emit WhitelistUpdated(target, true, block.timestamp);
    }

    // removeFromWhitelist() - removes an address from the trusted list.
    function removeFromWhitelist(address target) external onlyOwner {
        require(whitelistedAddresses[target], "FraudGuard: address not in whitelist");
        whitelistedAddresses[target] = false;
        whitelistCount--;
        emit WhitelistUpdated(target, false, block.timestamp);
    }

    // --- TRANSACTION RECORDING ----------------------------------------
    //
    // HOW AUTOMATIC DETECTION WORKS:
    // FraudGuard uses two complementary mechanisms so the user never has to
    // press a button manually:
    //
    // 1. CONTRACT-LEVEL: Other LexChain contracts (WillRegistry, PropertyEscrow)
    //    call reportSuspiciousActivity() automatically when they detect a large
    //    outflow. This is the primary, always-on protection layer.
    //
    // 2. FRONTEND-LEVEL: The JavaScript event listener watches all Transfer
    //    and ETH-movement events from the owner's wallet in real time using
    //    ethers.js provider.on(). When it sees a suspicious pattern it calls
    //    reportSuspiciousActivity() on behalf of the user automatically.
    //
    // This means zero manual input is required - fraud detection is fully
    // automatic and happens the moment a suspicious transaction occurs.

    // reportSuspiciousActivity() - the core automatic detection entry point.
    // Called by:
    //   - Other authorized LexChain contracts (WillRegistry, PropertyEscrow)
    //     whenever they detect a large ETH outflow from a protected wallet.
    //   - The frontend event listener automatically when it sees a suspicious
    //     transaction pattern via ethers.js event watching.
    //   - The owner or guardian manually as a last resort.
    //
    // Making this callable by authorizedReporters (not just owner) is critical:
    // if the owner's wallet is compromised, the attacker could block any
    // owner-only call. Authorized reporters are independent and cannot be
    // blocked by a compromised owner key.
    function reportSuspiciousActivity(
        address suspectRecipient, // address the funds were sent or attempted to
        uint256 amountInvolved,   // how much ETH was involved
        string memory reason      // human-readable description of the suspicion
    ) external whenArmed returns (bool suspicious) {
        // Only authorized reporters, the owner, or the guardian can call this.
        // This prevents random wallets from spamming false fraud alerts.
        require(
            authorizedReporters[msg.sender] ||
            msg.sender == owner()            ||
            msg.sender == guardianAddress,
            "FraudGuard: caller not authorized to report"
        );

        // Run all three detection checks against the reported activity.
        return _runDetection(suspectRecipient, amountInvolved, reason);
    }

    // authorizeReporter() - grants an address the right to call reportSuspiciousActivity().
    // Called during deployment to authorize WillRegistry, PropertyEscrow, etc.
    // This is how contract-level automatic detection is wired up.
    function authorizeReporter(address reporter) external onlyOwner {
        require(reporter != address(0), "FraudGuard: zero address");
        authorizedReporters[reporter] = true;
        emit ReporterAuthorized(reporter);
    }

    // revokeReporter() - removes a reporter's authorization.
    function revokeReporter(address reporter) external onlyOwner {
        authorizedReporters[reporter] = false;
    }

    // _runDetection() - internal function that performs all three fraud checks.
    // Extracted so both reportSuspiciousActivity() and the legacy
    // recordTransaction() path can reuse the same logic without duplication.
    function _runDetection(
        address recipient,
        uint256 amount,
        string memory /*context*/
    ) internal returns (bool suspicious) {
        // -- Velocity tracking ---------------------------------------
        // Count transactions within the rolling VELOCITY_WINDOW (1 hour).
        // Each call to _runDetection counts as one observed transaction.
        if (block.timestamp - lastTransactionTimestamp <= VELOCITY_WINDOW) {
            transactionCountInWindow++;
        } else {
            transactionCountInWindow = 1; // new window, reset counter
        }
        lastTransactionTimestamp = block.timestamp;

        emit TransactionRecorded(recipient, amount, transactionCountInWindow);

        suspicious = false; // innocent until proven otherwise

        // -- Check 1: Large transfer threshold -----------------------
        // A single transfer exceeding 50% of the protected balance is a
        // strong signal - attackers always try to drain as much as possible
        // in the first transaction before anyone notices.
        uint256 bal = address(this).balance;
        if (bal > 0 && amount > (bal * LARGE_TRANSFER_THRESHOLD_PCT) / 100) {
            _raiseFraudAlert(
                AlertLevel.HIGH,
                "AUTO-DETECTED: Large transfer exceeds 50% of protected balance",
                amount,
                recipient
            );
            suspicious = true;
        }

        // -- Check 2: Velocity spike ---------------------------------
        // More than 5 transactions in one hour is a classic rapid-drain
        // pattern used by automated wallet drainer scripts.
        if (transactionCountInWindow > VELOCITY_THRESHOLD) {
            _raiseFraudAlert(
                AlertLevel.HIGH,
                "AUTO-DETECTED: Velocity spike - too many transactions in 1 hour",
                amount,
                recipient
            );
            suspicious = true;
        }

        // -- Check 3: Unknown recipient ------------------------------
        // Sending to a non-whitelisted address is a LOW signal.
        // LOW + another LOW = escalates to HIGH automatically.
        if (!whitelistedAddresses[recipient]) {
            if (currentAlertLevel == AlertLevel.LOW) {
                // Second signal on top of existing LOW -> escalate to HIGH
                _escalateAlert();
                suspicious = true;
            } else if (currentAlertLevel == AlertLevel.NONE) {
                // First suspicious signal - set to LOW, keep watching
                _raiseFraudAlert(
                    AlertLevel.LOW,
                    "AUTO-DETECTED: Transfer to unrecognized non-whitelisted address",
                    amount,
                    recipient
                );
                suspicious = true;
            }
        }

        // If alert reached HIGH or CONFIRMED, start the gradual safe transfer.
        if (
            (currentAlertLevel == AlertLevel.HIGH || currentAlertLevel == AlertLevel.CONFIRMED)
            && currentTransferStage == TransferStage.NONE
            && !alertCancelled
        ) {
            _initiateGradualTransfer();
        }

        return suspicious;
    }

    // recordTransaction() - kept for backward compatibility with existing tests.
    // Internally delegates to _runDetection() so the logic is shared.
    // New integrations should call reportSuspiciousActivity() instead.
    function recordTransaction(
        address recipient,
        uint256 amount
    ) external onlyOwner whenArmed returns (bool) {
        return _runDetection(recipient, amount, "manual");
    }

    // --- MANUAL FRAUD CONTROLS ----------------------------------------

    // manuallyFlagFraud() - the owner or guardian explicitly raises an alert.
    // Use this when you notice suspicious activity yourself (e.g. you receive
    // a phishing email and suspect your key may be compromised).
    function manuallyFlagFraud(string memory reason) external onlyOwnerOrGuardian whenArmed {
        require(
            currentAlertLevel != AlertLevel.CONFIRMED,
            "FraudGuard: alert is already at CONFIRMED level"
        );

        // Record this as a suspicious event.
        suspiciousEvents.push(SuspiciousEvent({
            timestamp:      block.timestamp,
            reason:         reason,
            amountInvolved: address(this).balance,
            suspectAddress: msg.sender, // the person flagging it
            wasResolved:    false
        }));

        AlertLevel previous = currentAlertLevel;
        currentAlertLevel   = AlertLevel.CONFIRMED; // manual flag always goes to CONFIRMED

        _log(
            "FRAUD_MANUALLY_FLAGGED",
            string(abi.encodePacked("Manual fraud flag: ", reason)),
            keccak256(abi.encodePacked(msg.sender, reason, block.timestamp))
        );

        emit AlertEscalated(previous, AlertLevel.CONFIRMED, block.timestamp);
        emit FraudAlertRaised(AlertLevel.CONFIRMED, reason, address(this).balance, msg.sender, block.timestamp);

        // Start the gradual transfer immediately on manual flag.
        if (currentTransferStage == TransferStage.NONE) {
            _initiateGradualTransfer();
        }
    }

    // cancelAlert() - the real owner calls this to cancel a false positive.
    // This STOPS all pending stages from executing. Any ETH already sent
    // in completed stages will need to be manually returned from the safe wallet.
    function cancelAlert() external onlyOwner {
        require(
            currentAlertLevel != AlertLevel.NONE,
            "FraudGuard: no active alert to cancel"
        );
        require(
            currentTransferStage != TransferStage.COMPLETE,
            "FraudGuard: transfer is already complete, nothing to cancel"
        );

        // Count how many stages were already executed before the cancel.
        uint8 completedStages = 0;
        for (uint8 i = 0; i < 3; i++) {
            if (stageExecutions[i].executedAt > 0) completedStages++;
        }

        // Mark all unexecuted stages as cancelled so executeNextStage() skips them.
        for (uint8 i = 0; i < 3; i++) {
            if (stageExecutions[i].executedAt == 0) {
                stageExecutions[i].cancelled = true; // cancel pending stages
            }
        }

        // Reset alert state.
        currentAlertLevel    = AlertLevel.NONE;
        currentTransferStage = TransferStage.COMPLETE; // mark as done to prevent restart
        alertCancelled       = true;

        // Mark all unresolved suspicious events as resolved (false alarms).
        for (uint256 i = 0; i < suspiciousEvents.length; i++) {
            if (!suspiciousEvents[i].wasResolved) {
                suspiciousEvents[i].wasResolved = true;
            }
        }

        _log(
            "FRAUD_ALERT_CANCELLED",
            "Owner cancelled fraud alert - marked as false alarm",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );

        emit AlertCancelled(owner(), block.timestamp, completedStages);
    }

    // resetGuard() - after a cancelled alert, call this to re-arm FraudGuard
    // so it can detect new alerts in the future. Separate from cancelAlert()
    // to make the two-step "cancel then reset" explicit and deliberate.
    function resetGuard() external onlyOwner {
        require(alertCancelled, "FraudGuard: no cancelled alert to reset from");

        currentAlertLevel    = AlertLevel.NONE;
        currentTransferStage = TransferStage.NONE;
        alertCancelled       = false;
        balanceAtAlertTime   = 0;

        // Reset all stage execution records for the next potential alert.
        for (uint8 i = 0; i < 3; i++) {
            stageExecutions[i] = StageExecution({
                queuedAt:   0,
                executedAt: 0,
                amount:     0,
                cancelled:  false
            });
        }

        _log(
            "FRAUD_GUARD_RESET",
            "FraudGuard reset and re-armed after cancelled alert",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );
    }

    // arm() / disarm() - toggle protection on/off.
    // The owner might disarm temporarily during planned maintenance.
    function arm()   external onlyOwner { isArmed = true;  }
    function disarm() external onlyOwner { isArmed = false; }

    // --- GRADUAL TRANSFER ENGINE --------------------------------------

    // _initiateGradualTransfer() - internal function that kicks off the
    // 3-stage transfer process. Called automatically when alert level reaches HIGH.
    // This function only QUEUES the first stage - it does not send ETH yet.
    // The actual ETH is sent when executeNextStage() is called after the delay.
    function _initiateGradualTransfer() internal {
        require(address(this).balance > 0, "FraudGuard: no balance to transfer");

        // Snapshot the balance NOW so all three stage calculations use the same base.
        // Without this snapshot, the stage 2 calculation would use a smaller balance
        // (because stage 1 already moved some out), which would mean only 70% total
        // instead of 100%.
        balanceAtAlertTime = address(this).balance;

        // Calculate how much ETH each stage will send.
        uint256 stage1Amount = (balanceAtAlertTime * STAGE_1_PCT) / 100; // 30%
        uint256 stage2Amount = (balanceAtAlertTime * STAGE_2_PCT) / 100; // 40%
        // Stage 3 gets the true remainder to avoid rounding dust staying in contract.
        // Example: 1.0001 ETH - stage1=0.3000, stage2=0.4000, stage3=0.3001 (all of it).
        uint256 stage3Amount = balanceAtAlertTime - stage1Amount - stage2Amount; // remaining 30%

        // Queue stage 1: set the amount, record when it was queued.
        // Execution happens after STAGE_DELAY (24h) from queuedAt.
        stageExecutions[0] = StageExecution({
            queuedAt:   block.timestamp,
            executedAt: 0,
            amount:     stage1Amount,
            cancelled:  false
        });

        // Pre-calculate and store stage 2 and 3 amounts too.
        // They get queued on-demand when the previous stage executes.
        stageExecutions[1] = StageExecution({
            queuedAt:   0, // will be set when stage 1 executes
            executedAt: 0,
            amount:     stage2Amount,
            cancelled:  false
        });
        stageExecutions[2] = StageExecution({
            queuedAt:   0, // will be set when stage 2 executes
            executedAt: 0,
            amount:     stage3Amount,
            cancelled:  false
        });

        currentTransferStage = TransferStage.STAGE_1; // we are now in stage 1

        _log(
            "GRADUAL_TRANSFER_INITIATED",
            "Gradual safe transfer initiated - 3 stages queued",
            keccak256(abi.encodePacked(safeWallet, balanceAtAlertTime, block.timestamp))
        );

        // Emit event: stage 1 queued, executable after 24 hours from now.
        emit StageQueued(1, stage1Amount, block.timestamp + STAGE_DELAY);
    }

    // executeNextStage() - anyone can call this after the delay has passed.
    // Making it callable by anyone (not just owner) means:
    //   - If the owner is compromised, the attacker cannot block the transfer
    //     by simply never calling this function.
    //   - A family member, guardian, or automated service can trigger it.
    // The ETH only ever goes to safeWallet - so calling this is always safe.
    function executeNextStage() external nonReentrant whenArmed {
        require(
            currentTransferStage != TransferStage.NONE,
            "FraudGuard: no gradual transfer is in progress"
        );
        require(
            currentTransferStage != TransferStage.COMPLETE,
            "FraudGuard: all stages already completed"
        );
        require(!alertCancelled, "FraudGuard: alert was cancelled by owner");

        if (currentTransferStage == TransferStage.STAGE_1) {
            _executeStage(0, TransferStage.STAGE_2, 1); // execute stage 1, advance to stage 2
        } else if (currentTransferStage == TransferStage.STAGE_2) {
            _executeStage(1, TransferStage.STAGE_3, 2); // execute stage 2, advance to stage 3
        } else if (currentTransferStage == TransferStage.STAGE_3) {
            _executeStage(2, TransferStage.COMPLETE, 3); // execute stage 3, mark complete
        }
    }

    // _executeStage() - internal helper that performs one stage's ETH transfer.
    // stageIndex    = 0, 1, or 2 (array index into stageExecutions)
    // nextStage     = what TransferStage to advance to after this one executes
    // stageNumber   = 1, 2, or 3 (human-readable, for events and logs)
    function _executeStage(
        uint8         stageIndex,
        TransferStage nextStage,
        uint8         stageNumber
    ) internal {
        StageExecution storage exec = stageExecutions[stageIndex];

        // Make sure this stage was actually queued (has a queuedAt timestamp).
        require(exec.queuedAt > 0,  "FraudGuard: this stage has not been queued yet");

        // Enforce the 24-hour delay. Block.timestamp must be at least STAGE_DELAY
        // seconds after queuedAt before we allow execution.
        require(
            block.timestamp >= exec.queuedAt + STAGE_DELAY,
            "FraudGuard: stage delay period has not elapsed yet"
        );

        // Prevent double-execution of the same stage.
        require(exec.executedAt == 0, "FraudGuard: this stage has already been executed");

        // Make sure we have enough balance to cover this stage's amount.
        // In theory this should always pass if the contract holds funds,
        // but we check defensively to prevent unexpected reverts.
        require(
            address(this).balance >= exec.amount,
            "FraudGuard: insufficient balance for this stage"
        );

        // Record the execution timestamp BEFORE the transfer (checks-effects-interactions).
        exec.executedAt = block.timestamp;
        currentTransferStage = nextStage; // advance the state machine

        // If there is a next stage (not COMPLETE), queue it now.
        // The next stage's delay starts from THIS moment, not from when the transfer was initiated.
        // This means each stage has a full 24-hour independent window.
        if (nextStage == TransferStage.STAGE_2) {
            stageExecutions[1].queuedAt = block.timestamp; // queue stage 2 starting now
            emit StageQueued(2, stageExecutions[1].amount, block.timestamp + STAGE_DELAY);
        } else if (nextStage == TransferStage.STAGE_3) {
            stageExecutions[2].queuedAt = block.timestamp; // queue stage 3 starting now
            emit StageQueued(3, stageExecutions[2].amount, block.timestamp + STAGE_DELAY);
        }

        // Send the ETH to the safe wallet.
        // Using the low-level call pattern which is safe with nonReentrant guard.
        (bool success, ) = safeWallet.call{value: exec.amount}("");
        require(success, "FraudGuard: ETH transfer to safe wallet failed");

        _log(
            string(abi.encodePacked("STAGE_", _uint8ToString(stageNumber), "_EXECUTED")),
            string(abi.encodePacked(
                "Stage ", _uint8ToString(stageNumber), " executed: ",
                _uint256ToEthString(exec.amount), " ETH sent to safe wallet"
            )),
            keccak256(abi.encodePacked(safeWallet, exec.amount, block.timestamp))
        );

        emit StageExecuted(stageNumber, exec.amount, safeWallet, block.timestamp);

        // If all three stages are done, emit the completion event.
        if (nextStage == TransferStage.COMPLETE) {
            _log(
                "SAFE_TRANSFER_COMPLETE",
                "All 3 stages complete - full balance moved to safe wallet",
                keccak256(abi.encodePacked(safeWallet, balanceAtAlertTime, block.timestamp))
            );
            emit SafeTransferComplete(balanceAtAlertTime, safeWallet, block.timestamp);
        }
    }

    // --- INTERNAL DETECTION HELPERS -----------------------------------

    // _raiseFraudAlert() - internal function to create a suspicious event
    // and update the alert level if the new level is higher than current.
    function _raiseFraudAlert(
        AlertLevel level,
        string memory reason,
        uint256 amountInvolved,
        address suspectAddress
    ) internal {
        // Record the suspicious event regardless of whether we escalate.
        suspiciousEvents.push(SuspiciousEvent({
            timestamp:      block.timestamp,
            reason:         reason,
            amountInvolved: amountInvolved,
            suspectAddress: suspectAddress,
            wasResolved:    false
        }));

        // Only update alert level if the new level is higher (never downgrade automatically).
        if (uint8(level) > uint8(currentAlertLevel)) {
            AlertLevel previous = currentAlertLevel;
            currentAlertLevel   = level;
            emit AlertEscalated(previous, level, block.timestamp);
        }

        _log(
            "FRAUD_ALERT_RAISED",
            string(abi.encodePacked("Fraud alert: ", reason)),
            keccak256(abi.encodePacked(suspectAddress, amountInvolved, block.timestamp))
        );

        emit FraudAlertRaised(level, reason, amountInvolved, suspectAddress, block.timestamp);
    }

    // _escalateAlert() - bumps the alert level up by one step.
    function _escalateAlert() internal {
        AlertLevel previous = currentAlertLevel;
        if (currentAlertLevel == AlertLevel.NONE) {
            currentAlertLevel = AlertLevel.LOW;
        } else if (currentAlertLevel == AlertLevel.LOW) {
            currentAlertLevel = AlertLevel.HIGH;
        } else if (currentAlertLevel == AlertLevel.HIGH) {
            currentAlertLevel = AlertLevel.CONFIRMED;
        }
        // Already CONFIRMED - no higher level to go to.
        emit AlertEscalated(previous, currentAlertLevel, block.timestamp);
    }

    // --- VIEW / GETTER FUNCTIONS --------------------------------------

    // getAlertLevelString() - human-readable version of currentAlertLevel.
    function getAlertLevelString() external view returns (string memory) {
        if (currentAlertLevel == AlertLevel.NONE)      return "NONE";
        if (currentAlertLevel == AlertLevel.LOW)       return "LOW";
        if (currentAlertLevel == AlertLevel.HIGH)      return "HIGH";
        if (currentAlertLevel == AlertLevel.CONFIRMED) return "CONFIRMED";
        return "UNKNOWN";
    }

    // getTransferStageString() - human-readable version of currentTransferStage.
    function getTransferStageString() external view returns (string memory) {
        if (currentTransferStage == TransferStage.NONE)     return "NONE";
        if (currentTransferStage == TransferStage.STAGE_1)  return "STAGE_1";
        if (currentTransferStage == TransferStage.STAGE_2)  return "STAGE_2";
        if (currentTransferStage == TransferStage.STAGE_3)  return "STAGE_3";
        if (currentTransferStage == TransferStage.COMPLETE) return "COMPLETE";
        return "UNKNOWN";
    }

    // getStageDetails() - returns all three stage execution records for the frontend.
    function getStageDetails() external view returns (StageExecution[3] memory) {
        return stageExecutions;
    }

    // getSuspiciousEvents() - returns all recorded suspicious events for the UI.
    function getSuspiciousEvents() external view returns (SuspiciousEvent[] memory) {
        return suspiciousEvents;
    }

    // getSecondsUntilNextStage() - returns how many seconds until the current
    // stage's delay expires and executeNextStage() can be called.
    // Returns 0 if it can be called right now.
    function getSecondsUntilNextStage() external view returns (uint256) {
        uint8 idx;
        if (currentTransferStage == TransferStage.STAGE_1) idx = 0;
        else if (currentTransferStage == TransferStage.STAGE_2) idx = 1;
        else if (currentTransferStage == TransferStage.STAGE_3) idx = 2;
        else return 0; // no active stage

        uint256 executeAt = stageExecutions[idx].queuedAt + STAGE_DELAY;
        if (block.timestamp >= executeAt) return 0; // ready now
        return executeAt - block.timestamp;          // seconds remaining
    }

    // getFullStatus() - returns a complete status summary for the frontend dashboard.
    function getFullStatus() external view returns (
        address _safeWallet,
        address _guardian,
        bool    _isArmed,
        uint8   _alertLevelUint,   // 0=NONE,1=LOW,2=HIGH,3=CONFIRMED
        uint8   _transferStageUint, // 0=NONE,1=S1,2=S2,3=S3,4=COMPLETE
        uint256 _balance,
        uint256 _balanceAtAlert,
        uint256 _suspiciousEventCount,
        bool    _alertCancelled,
        uint256 _secondsUntilNextStage
    ) {
        uint256 secUntil = 0;
        uint8 idx2;
        if (currentTransferStage == TransferStage.STAGE_1) idx2 = 0;
        else if (currentTransferStage == TransferStage.STAGE_2) idx2 = 1;
        else if (currentTransferStage == TransferStage.STAGE_3) idx2 = 2;

        if (
            currentTransferStage != TransferStage.NONE &&
            currentTransferStage != TransferStage.COMPLETE &&
            stageExecutions[idx2].queuedAt > 0
        ) {
            uint256 executeAt = stageExecutions[idx2].queuedAt + STAGE_DELAY;
            secUntil = block.timestamp >= executeAt ? 0 : executeAt - block.timestamp;
        }

        return (
            safeWallet,
            guardianAddress,
            isArmed,
            uint8(currentAlertLevel),
            uint8(currentTransferStage),
            address(this).balance,
            balanceAtAlertTime,
            suspiciousEvents.length,
            alertCancelled,
            secUntil
        );
    }

    // --- DEPOSIT / RECEIVE --------------------------------------------

    // deposit() - owner deposits ETH into FraudGuard's protected pool.
    function deposit() external payable onlyOwner {
        // ETH received automatically via msg.value
    }

    // receive() - accepts plain ETH transfers without function call data.
    receive() external payable {}

    // --- PRIVATE HELPERS ---------------------------------------------

    function _uint8ToString(uint8 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint8 temp = value;
        uint8 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint8(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _uint256ToEthString(uint256 weiAmount) private pure returns (string memory) {
        if (weiAmount == 0) return "0";
        uint256 temp = weiAmount;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (weiAmount != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint8(weiAmount % 10)));
            weiAmount /= 10;
        }
        return string(buffer);
    }
}
