// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// WillRegistry.sol — LexChain Decentralized Legal Platform
// This contract lets a person write their will on the blockchain.
// They name up to 5 beneficiaries and assign each a percentage of their estate.
// The "death switch" works like this: if the owner's wallet has not sent a
// "proof of life" transaction in 180 days, anyone can trigger the will.
// There is a 7-day dispute window after the trigger fires, giving the owner
// time to cancel if they are simply on holiday and not actually dead.
// After 7 days, anyone can call distributeEstate() to send the funds.
// This replaces a $500–$2000 lawyer-drafted will with a transparent smart contract.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // prevents re-entrancy attacks on ETH transfers
import "@openzeppelin/contracts/access/Ownable.sol";         // gives us onlyOwner modifier cleanly

// We import a minimal interface for the AuditTrail contract so we can call
// its logAction() function without importing the full contract code.
interface IAuditTrail {
    function logAction(
        address userAddress,
        string  memory actionType,
        string  memory details,
        bytes32 dataHash
    ) external;
}

// Minimal interface to call FraudGuard.reportSuspiciousActivity() automatically
// when a large ETH outflow is detected from the estate.
interface IFraudGuard {
    function reportSuspiciousActivity(
        address suspectRecipient,
        uint256 amountInvolved,
        string memory reason
    ) external returns (bool);
}

// WillRegistry inherits ReentrancyGuard (for safe ETH transfers)
// and Ownable (for onlyOwner access control on sensitive functions).
contract WillRegistry is ReentrancyGuard, Ownable {

    // ─── DATA STRUCTURES ─────────────────────────────────────────

    // Beneficiary represents one person who will inherit from this will.
    // We store enough information to identify them and calculate their share.
    struct Beneficiary {
        address wallet;       // the Ethereum address where their inheritance is sent
        string  fullName;     // their legal name for record-keeping
        uint8   percentage;   // their share of the estate (0–100)
        string  relationship; // e.g. "spouse", "son", "daughter" — for human context
        bool    active;       // soft-delete flag: false means this beneficiary was removed
    }

    // ─── STATE VARIABLES ─────────────────────────────────────────

    // We support up to 5 beneficiaries. A fixed-size array is used because
    // Solidity makes it easier to reason about gas costs with bounded loops.
    Beneficiary[5] public beneficiaries;

    // Tracks how many active beneficiaries currently exist (0–5).
    uint256 public beneficiaryCount;

    // A plain-English description of the will, e.g. "This estate was
    // accumulated over 30 years of work. Distribute as specified."
    string public willDescription;

    // Every time the owner calls recordActivity(), this timestamp updates.
    // The death switch checks this against block.timestamp.
    uint256 public lastActivityTimestamp;

    // 180 days in seconds. The owner must prove they are alive at least
    // once every 180 days or the will can be triggered.
    uint256 public constant INACTIVITY_PERIOD = 180 days;

    // 7 days in seconds. After the trigger fires, the owner has 7 days
    // to cancel it by calling recordActivity() or cancelWillTrigger().
    uint256 public constant DISPUTE_WINDOW = 7 days;

    // Set to true when checkAndTrigger() fires. Starts the 7-day clock.
    bool public willTriggered;

    // The timestamp when the will was triggered. Used to calculate the
    // end of the 7-day dispute window.
    uint256 public triggerTimestamp;

    // Once finalized, the will is locked. No beneficiaries can be added or
    // removed, and the description cannot be changed. This is intentional:
    // a finalized will must be tamper-proof, just like a signed legal document.
    bool public willFinalized;

    // The address of the deployed AuditTrail contract. We call it on every
    // significant action so every event in this will is permanently recorded.
    address public auditTrailContract;

    // The address of the FraudGuard contract. When distributeEstate() sends a
    // large ETH outflow, FraudGuard is notified automatically so it can run
    // its detection checks without the user doing anything manually.
    // Set to address(0) if FraudGuard is not deployed (makes it optional).
    address public fraudGuardContract;

    // ─── EVENTS ──────────────────────────────────────────────────

    // Emitted when a new beneficiary is added to the will.
    event BeneficiaryAdded(
        address indexed wallet,
        string  name,
        uint8   percentage,
        string  relationship
    );

    // Emitted when a beneficiary is removed (soft-deleted).
    event BeneficiaryRemoved(address indexed wallet);

    // Emitted when the owner locks the will permanently.
    event WillFinalized(address indexed owner, uint256 timestamp);

    // Emitted when the owner calls recordActivity() to reset the death switch timer.
    event ActivityRecorded(address indexed owner, uint256 timestamp);

    // Emitted when the 180-day inactivity period has elapsed and the will fires.
    // estateValue is how much ETH is in the contract at trigger time.
    event WillTriggered(uint256 timestamp, uint256 estateValue);

    // Emitted for each beneficiary when distributeEstate() runs.
    event EstateDistributed(
        address indexed beneficiary,
        uint256 amount,
        string  name
    );

    // Emitted when the owner cancels the trigger within the 7-day dispute window.
    event WillCancelled(address indexed owner, uint256 timestamp);

    // ─── CONSTRUCTOR ─────────────────────────────────────────────

    // The constructor runs once at deployment.
    // _auditTrail is the address of the already-deployed AuditTrail contract.
    // Ownable(msg.sender) sets the deployer as the contract owner.
    constructor(address _auditTrail) Ownable(msg.sender) {
        require(_auditTrail != address(0), "WillRegistry: invalid audit trail address"); // sanity check

        auditTrailContract    = _auditTrail;  // store audit trail address
        lastActivityTimestamp = block.timestamp; // initialize the death switch timer to now
        willTriggered         = false;           // no trigger on deployment
        willFinalized         = false;           // will starts in draft mode
        beneficiaryCount      = 0;              // no beneficiaries yet
    }

    // ─── MODIFIERS ───────────────────────────────────────────────

    // Convenience modifier: reverts if the will has already been finalized.
    // Used on all functions that modify the will's contents.
    modifier notFinalized() {
        require(!willFinalized, "WillRegistry: will is already finalized");
        _;
    }

    // ─── INTERNAL HELPERS ────────────────────────────────────────

    // _log() is a private helper to call AuditTrail.logAction() with less repetition.
    // We cast the stored address to the IAuditTrail interface and call logAction.
    function _log(string memory actionType, string memory details, bytes32 dataHash) private {
        IAuditTrail(auditTrailContract).logAction(
            owner(),    // the wallet that owns this will (the testator)
            actionType, // the event label
            details,    // the human-readable description
            dataHash    // hash for integrity verification
        );
    }

    // ─── PUBLIC FUNCTIONS ─────────────────────────────────────────

    // setFraudGuard() — connects WillRegistry to a deployed FraudGuard contract.
    // Once set, large ETH outflows during estate distribution are automatically
    // reported to FraudGuard without any manual input from the user.
    // Call this once after deploying both contracts (the deploy script does it).
    function setFraudGuard(address _fraudGuard) external onlyOwner {
        fraudGuardContract = _fraudGuard; // store address for later use in distributeEstate
    }

    // addBeneficiary() — the owner adds a person to their will.
    // All conditions must pass before the beneficiary is stored.
    function addBeneficiary(
        address wallet,
        string  memory fullName,
        uint8   percentage,
        string  memory relationship
    ) external onlyOwner notFinalized {
        // Must have room for another beneficiary (max 5).
        require(beneficiaryCount < 5, "WillRegistry: maximum 5 beneficiaries allowed");

        // The beneficiary must have a real (non-zero) Ethereum address.
        require(wallet != address(0), "WillRegistry: invalid wallet address");

        // A person cannot leave their estate to themselves — that would be circular.
        require(wallet != owner(), "WillRegistry: cannot add owner as beneficiary");

        // Percentage must be meaningful (0% would just waste gas).
        require(percentage > 0, "WillRegistry: percentage must be greater than zero");
        require(percentage <= 100, "WillRegistry: percentage cannot exceed 100");

        // Make sure adding this beneficiary doesn't push total allocation over 100%.
        // If existing beneficiaries already take 80% and this one wants 30%, reject it.
        require(
            getTotalPercentage() + percentage <= 100,
            "WillRegistry: total percentage would exceed 100"
        );

        // Create the beneficiary struct and store it at the next open slot.
        beneficiaries[beneficiaryCount] = Beneficiary({
            wallet:       wallet,
            fullName:     fullName,
            percentage:   percentage,
            relationship: relationship,
            active:       true // mark as active so we know this slot is occupied
        });

        beneficiaryCount++; // increment the active count

        // Log this action to AuditTrail so it's permanently recorded.
        // The dataHash is a hash of the beneficiary data for integrity checking.
        _log(
            "BENEFICIARY_ADDED",
            string(abi.encodePacked("Beneficiary added: ", fullName, " at ", _uint8ToString(percentage), "%")),
            keccak256(abi.encodePacked(wallet, fullName, percentage, relationship))
        );

        emit BeneficiaryAdded(wallet, fullName, percentage, relationship);
    }

    // removeBeneficiary() — the owner removes a beneficiary from their will.
    // We use a soft-delete approach (setting active = false) so the array
    // structure stays intact. This avoids expensive array shifting operations.
    function removeBeneficiary(address wallet) external onlyOwner notFinalized {
        // Search the beneficiaries array for a matching wallet address.
        bool found = false;
        for (uint256 i = 0; i < 5; i++) {
            // Only look at active slots that match the target wallet.
            if (beneficiaries[i].active && beneficiaries[i].wallet == wallet) {
                beneficiaries[i].active = false; // soft-delete: mark as inactive
                beneficiaryCount--;              // one fewer active beneficiary
                found = true;

                _log(
                    "BENEFICIARY_REMOVED",
                    string(abi.encodePacked("Beneficiary removed: ", beneficiaries[i].fullName)),
                    keccak256(abi.encodePacked(wallet, block.timestamp))
                );

                emit BeneficiaryRemoved(wallet);
                break; // stop searching once we found the match
            }
        }
        require(found, "WillRegistry: beneficiary not found"); // revert if no match was found
    }

    // updateWillDescription() — lets the owner add a plain-English note
    // to their will. This could describe the estate, special wishes, etc.
    function updateWillDescription(string memory description) external onlyOwner notFinalized {
        willDescription = description; // update the stored description

        _log(
            "WILL_DESCRIPTION_UPDATED",
            "Will description was updated",
            keccak256(abi.encodePacked(description, block.timestamp))
        );
    }

    // finalizeWill() — locks the will permanently.
    // Once called, no beneficiaries can be added/removed and no changes can be made.
    // This is equivalent to signing a legal document — it becomes binding.
    // We require exactly 100% to ensure the entire estate is accounted for.
    // A will that only allocates 60% would leave 40% stranded in the contract forever.
    function finalizeWill() external onlyOwner notFinalized {
        // The percentages must add up to exactly 100 before we can finalize.
        // This guarantees 100% of the estate has a recipient.
        require(
            getTotalPercentage() == 100,
            "WillRegistry: total percentage must equal exactly 100"
        );

        // There must be at least one beneficiary — an empty will is meaningless.
        require(beneficiaryCount >= 1, "WillRegistry: need at least one beneficiary");

        willFinalized = true; // lock the will — no more changes allowed

        _log(
            "WILL_FINALIZED",
            "Will has been finalized and locked",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );

        emit WillFinalized(owner(), block.timestamp);
    }

    // recordActivity() — the owner calls this to prove they are alive.
    // This resets the 180-day inactivity clock.
    // If the will has already been triggered but we're still within the 7-day
    // dispute window, this also cancels the trigger (equivalent to a false alarm).
    function recordActivity() external onlyOwner {
        lastActivityTimestamp = block.timestamp; // reset the death switch clock

        // If the will was triggered but the dispute window hasn't expired yet,
        // calling this function also cancels the trigger. This is the safety valve
        // that protects owners who were simply traveling or offline.
        if (willTriggered && (block.timestamp - triggerTimestamp) < DISPUTE_WINDOW) {
            willTriggered = false; // cancel the trigger
            emit WillCancelled(owner(), block.timestamp);
        }

        _log(
            "ACTIVITY_RECORDED",
            "Owner recorded proof of life",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );

        emit ActivityRecorded(owner(), block.timestamp);
    }

    // checkAndTrigger() — called by anyone (typically an heir or automated service)
    // after 180 days of inactivity. If conditions are met, it fires the will.
    // Making this callable by anyone (not just the owner) is intentional:
    // if the owner is dead, they obviously cannot call it themselves.
    function checkAndTrigger() external {
        // The will must be finalized before it can be triggered.
        // We don't want a partially-configured will to execute prematurely.
        require(willFinalized, "WillRegistry: will must be finalized before triggering");

        // Prevent double-triggering (e.g., two people calling this simultaneously).
        require(!willTriggered, "WillRegistry: will already triggered");

        // The core check: has 180 days really passed since last activity?
        require(
            block.timestamp - lastActivityTimestamp >= INACTIVITY_PERIOD,
            "WillRegistry: inactivity period has not elapsed yet"
        );

        willTriggered    = true;           // arm the distribution mechanism
        triggerTimestamp = block.timestamp; // start the 7-day dispute clock now

        _log(
            "WILL_TRIGGERED",
            "Will has been triggered due to inactivity",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );

        // Include the estate value in the event so heirs know how much is at stake.
        emit WillTriggered(block.timestamp, address(this).balance);
    }

    // distributeEstate() — sends ETH to each beneficiary according to their percentage.
    // nonReentrant prevents a malicious beneficiary contract from calling back into
    // this function during their ETH transfer and draining extra funds.
    function distributeEstate() external nonReentrant {
        // The will must have been triggered first.
        require(willTriggered, "WillRegistry: will has not been triggered");

        // We must wait for the full 7-day dispute window to expire.
        // This gives the owner time to cancel if they are simply inactive.
        require(
            block.timestamp - triggerTimestamp >= DISPUTE_WINDOW,
            "WillRegistry: dispute window has not expired yet"
        );

        // There must be ETH in the contract to distribute.
        require(address(this).balance > 0, "WillRegistry: no funds in estate");

        // Capture the total balance BEFORE any transfers.
        // We must use a snapshot because address(this).balance changes as we send.
        uint256 totalBalance = address(this).balance;

        // Loop through all beneficiary slots and send each active one their share.
        for (uint256 i = 0; i < 5; i++) {
            if (!beneficiaries[i].active) continue; // skip removed beneficiaries

            // Calculate this beneficiary's share based on their percentage.
            // Integer division is safe here because we require total = 100%.
            // Minor rounding dust stays in the contract, which is acceptable.
            uint256 share = (totalBalance * beneficiaries[i].percentage) / 100;

            if (share == 0) continue; // skip if their share rounds to zero

            // Send ETH using the low-level call pattern.
            // This is the recommended way to send ETH in Solidity 0.8+.
            // transfer() and send() have a hard gas limit that can fail with
            // smart contract recipients. call() forwards all available gas.
            (bool success, ) = beneficiaries[i].wallet.call{value: share}("");
            require(success, "WillRegistry: ETH transfer to beneficiary failed");

            // Automatically notify FraudGuard about this large ETH outflow.
            // If this distribution was not triggered legitimately (e.g. an
            // attacker force-triggered the will early), FraudGuard will detect
            // the large transfer and begin the safe-transfer protection.
            // We wrap in a try/catch so a FraudGuard failure never blocks estate distribution.
            if (fraudGuardContract != address(0)) {
                try IFraudGuard(fraudGuardContract).reportSuspiciousActivity(
                    beneficiaries[i].wallet,
                    share,
                    "AUTO: Large ETH outflow detected during estate distribution"
                ) {} catch {} // silent - never block estate distribution
            }

            _log(
                "ESTATE_DISTRIBUTED",
                string(abi.encodePacked(
                    "Distributed ",
                    _uint8ToString(beneficiaries[i].percentage),
                    "% to ",
                    beneficiaries[i].fullName
                )),
                keccak256(abi.encodePacked(beneficiaries[i].wallet, share, block.timestamp))
            );

            emit EstateDistributed(
                beneficiaries[i].wallet,
                share,
                beneficiaries[i].fullName
            );
        }
    }

    // cancelWillTrigger() — the owner calls this to explicitly cancel a trigger.
    // Can only be called within the 7-day dispute window.
    // After 7 days, the trigger is permanent and estate distribution can begin.
    function cancelWillTrigger() external onlyOwner {
        require(willTriggered, "WillRegistry: will has not been triggered");

        // Check we are still within the dispute window.
        require(
            block.timestamp - triggerTimestamp < DISPUTE_WINDOW,
            "WillRegistry: dispute window has expired, cannot cancel"
        );

        willTriggered         = false;          // disarm the trigger
        lastActivityTimestamp = block.timestamp; // reset the inactivity clock

        _log(
            "WILL_TRIGGER_CANCELLED",
            "Owner cancelled the will trigger within dispute window",
            keccak256(abi.encodePacked(owner(), block.timestamp))
        );

        emit WillCancelled(owner(), block.timestamp);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────

    // getTotalPercentage() — sums up the percentages of all active beneficiaries.
    // Used internally to check we don't exceed 100% and to validate before finalization.
    function getTotalPercentage() public view returns (uint256 total) {
        for (uint256 i = 0; i < 5; i++) {
            if (beneficiaries[i].active) {
                total += beneficiaries[i].percentage; // add active beneficiary's share
            }
        }
        // implicit return of `total`
    }

    // getBeneficiaries() — returns all active beneficiaries as arrays.
    // The frontend uses this to populate the beneficiaries table.
    // We return parallel arrays (one per field) because Solidity doesn't allow
    // returning arrays of structs with dynamic string fields easily across ABI.
    function getBeneficiaries() external view returns (
        address[] memory wallets,
        string[]  memory names,
        uint8[]   memory percentages,
        string[]  memory relationships,
        bool[]    memory actives
    ) {
        wallets       = new address[](beneficiaryCount); // pre-allocate arrays of exact size needed
        names         = new string[](beneficiaryCount);
        percentages   = new uint8[](beneficiaryCount);
        relationships = new string[](beneficiaryCount);
        actives       = new bool[](beneficiaryCount);

        uint256 idx = 0; // index into our output arrays
        for (uint256 i = 0; i < 5; i++) {
            if (beneficiaries[i].active) {
                wallets[idx]       = beneficiaries[i].wallet;
                names[idx]         = beneficiaries[i].fullName;
                percentages[idx]   = beneficiaries[i].percentage;
                relationships[idx] = beneficiaries[i].relationship;
                actives[idx]       = true;
                idx++;
            }
        }
    }

    // getDaysUntilTrigger() — returns how many full days remain until
    // the 180-day inactivity period expires. Returns 0 if already past.
    // The frontend uses this to show a countdown clock.
    function getDaysUntilTrigger() external view returns (uint256) {
        uint256 elapsed = block.timestamp - lastActivityTimestamp; // seconds since last activity
        if (elapsed >= INACTIVITY_PERIOD) return 0;               // already past threshold
        return (INACTIVITY_PERIOD - elapsed) / 1 days;            // convert remaining seconds to days
    }

    // getDaysUntilDisputeExpiry() — returns days left in the 7-day dispute window.
    // Only meaningful when willTriggered is true.
    function getDaysUntilDisputeExpiry() external view returns (uint256) {
        if (!willTriggered) return 0;                                            // not triggered
        uint256 elapsed = block.timestamp - triggerTimestamp;                    // seconds since trigger
        if (elapsed >= DISPUTE_WINDOW) return 0;                                // window already expired
        return (DISPUTE_WINDOW - elapsed) / 1 days;                             // convert to days
    }

    // deposit() — the owner sends ETH to this contract to fund the estate.
    // Only the owner should fund their own will.
    function deposit() external payable onlyOwner {
        // ETH is automatically received when msg.value > 0.
        // No additional logic needed — the balance is tracked by the EVM.
    }

    // receive() — fallback for receiving ETH without function call data.
    // This allows the owner to send ETH via MetaMask's regular send flow.
    receive() external payable {}

    // ─── PRIVATE HELPERS ─────────────────────────────────────────

    // _uint8ToString() — converts a uint8 number to a string.
    // Solidity doesn't have a built-in integer-to-string conversion,
    // so we implement a simple one for use in log messages.
    function _uint8ToString(uint8 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint8 temp = value;
        uint8 digits;
        while (temp != 0) { digits++; temp /= 10; } // count digits
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint8(value % 10))); // ASCII '0' is 48
            value /= 10;
        }
        return string(buffer);
    }
}
