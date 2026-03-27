// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// PropertyEscrow.sol — LexChain Decentralized Legal Platform
// This contract handles a property sale between a buyer and a seller.
// The buyer deposits the full agreed price into this contract.
// The money only releases to the seller when BOTH parties confirm the deal.
// If the deal falls through and 30 days pass, the buyer gets a full refund.
// If there is a dispute, either party can flag it — in a real production version,
// this would trigger a DAO arbitration vote. For this capstone, it flags the deal.
// This replaces the traditional lawyer-as-escrow-agent model, saving thousands.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // protects ETH transfers from re-entrancy
import "@openzeppelin/contracts/access/Ownable.sol";         // gives us onlyOwner for the buyer

// Minimal interface to call AuditTrail.logAction() without importing the full contract.
interface IAuditTrail {
    function logAction(
        address userAddress,
        string  memory actionType,
        string  memory details,
        bytes32 dataHash
    ) external;
}

// Minimal interface to automatically report large ETH movements to FraudGuard.
interface IFraudGuard {
    function reportSuspiciousActivity(
        address suspectRecipient,
        uint256 amountInvolved,
        string memory reason
    ) external returns (bool);
}

contract PropertyEscrow is ReentrancyGuard, Ownable {

    // ─── ENUMS ────────────────────────────────────────────────────

    // DealState tracks the lifecycle of the property deal.
    // State transitions: CREATED → FUNDED → (BUYER_CONFIRMED or SELLER_CONFIRMED) → COMPLETED
    // Alternative paths: FUNDED → REFUNDED (after timeout), any state → DISPUTED
    enum DealState {
        CREATED,           // deal exists, buyer has not yet sent funds
        FUNDED,            // buyer deposited the agreed amount
        BUYER_CONFIRMED,   // buyer says conditions are met, waiting for seller
        SELLER_CONFIRMED,  // seller says conditions are met, waiting for buyer
        COMPLETED,         // both confirmed — funds released to seller
        REFUNDED,          // timeout expired — funds returned to buyer
        DISPUTED           // one party raised a dispute — deal is frozen
    }

    // ─── STATE VARIABLES ─────────────────────────────────────────

    address public buyer;               // the person deploying and funding the contract
    address public seller;              // the person who will receive payment on completion
    uint256 public agreedPrice;         // the exact amount (in wei) the buyer must deposit
    string  public propertyDescription; // plain-English description of the property
    string  public propertyAddress;     // physical address of the property
    string  public dealConditions;      // what must happen for payment to release (plain English)

    DealState public currentState;      // current phase of the deal lifecycle

    uint256 public dealCreatedAt;       // timestamp of contract deployment
    uint256 public dealFundedAt;        // timestamp when buyer deposited funds

    // 30 days: if the deal is funded but not completed within 30 days,
    // the buyer can reclaim their funds. This protects buyers from sellers
    // who fund and then go silent or fail to meet conditions.
    uint256 public constant DEAL_TIMEOUT = 30 days;

    bool public buyerApproval;   // true when buyer has confirmed deal conditions are met
    bool public sellerApproval;  // true when seller has confirmed deal conditions are met

    address public auditTrailContract; // address of the shared AuditTrail contract

    // FraudGuard contract address. When funds release to seller or refund to buyer,
    // FraudGuard is automatically notified so it can check for suspicious patterns.
    address public fraudGuardContract;

    // ─── EVENTS ──────────────────────────────────────────────────

    // Emitted when the contract is first deployed.
    event DealCreated(
        address indexed buyer,
        address indexed seller,
        uint256 price,
        string  property
    );

    // Emitted when the buyer sends the deposit to fund the escrow.
    event DealFunded(address indexed buyer, uint256 amount, uint256 timestamp);

    // Emitted when the buyer confirms the deal conditions have been met.
    event BuyerConfirmed(address indexed buyer, uint256 timestamp);

    // Emitted when the seller confirms the deal conditions have been met.
    event SellerConfirmed(address indexed seller, uint256 timestamp);

    // Emitted when both parties confirm and funds are released to seller.
    event DealCompleted(address indexed seller, uint256 amount, uint256 timestamp);

    // Emitted when buyer requests and receives a refund after timeout.
    event DealRefunded(address indexed buyer, uint256 amount, uint256 timestamp);

    // Emitted when either party raises a formal dispute.
    event DisputeRaised(address indexed raisedBy, uint256 timestamp);

    // ─── CONSTRUCTOR ─────────────────────────────────────────────

    // The buyer deploys this contract, specifying the seller's address,
    // the agreed price, and the terms. Ownable(msg.sender) makes the
    // deployer (buyer) the owner, giving them exclusive access to owner-gated functions.
    constructor(
        address _seller,
        uint256 _agreedPrice,
        string  memory _propertyDescription,
        string  memory _propertyAddress,
        string  memory _dealConditions,
        address _auditTrail
    ) Ownable(msg.sender) {
        require(_seller != address(0),     "PropertyEscrow: seller cannot be zero address");
        require(_seller != msg.sender,     "PropertyEscrow: buyer and seller cannot be the same address");
        require(_agreedPrice > 0,          "PropertyEscrow: agreed price must be greater than zero");
        require(_auditTrail != address(0), "PropertyEscrow: invalid audit trail address");

        buyer               = msg.sender;          // deployer is the buyer
        seller              = _seller;             // store seller's address
        agreedPrice         = _agreedPrice;        // lock in the agreed price
        propertyDescription = _propertyDescription;
        propertyAddress     = _propertyAddress;
        dealConditions      = _dealConditions;
        auditTrailContract  = _auditTrail;

        currentState   = DealState.CREATED;    // start in CREATED state
        dealCreatedAt  = block.timestamp;       // record when the deal was created
        buyerApproval  = false;                 // no approvals yet
        sellerApproval = false;

        // NOTE: We do NOT call AuditTrail here in the constructor.
        // The constructor runs during deployment, before the deployer has had a chance
        // to call auditTrail.authorizeContract(thisAddress). Calling logAction() here
        // would revert with "caller not authorized" every time.
        // The first audit entry for this deal is written in fundDeal() instead,
        // which is always called after the contract is fully deployed and authorized.

        emit DealCreated(msg.sender, _seller, _agreedPrice, _propertyDescription);
    }

    // ─── INTERNAL HELPER ─────────────────────────────────────────

    // _log() reduces code repetition when logging to AuditTrail.
    function _log(
        address user,
        string memory actionType,
        string memory details,
        bytes32 dataHash
    ) private {
        IAuditTrail(auditTrailContract).logAction(user, actionType, details, dataHash);
    }

    // ─── PUBLIC FUNCTIONS ─────────────────────────────────────────

    // setFraudGuard() — wires PropertyEscrow to FraudGuard so large ETH
    // movements (deal completions and refunds) are automatically reported.
    function setFraudGuard(address _fraudGuard) external onlyOwner {
        fraudGuardContract = _fraudGuard;
    }

    // fundDeal() — the buyer sends the exact agreed price to this contract.
    // The amount must match exactly — we don't want partial funding or overpayment.
    // This is why we require msg.value == agreedPrice (not >= or <=).
    function fundDeal() external payable {
        require(msg.sender == buyer,               "PropertyEscrow: only buyer can fund this deal");
        require(currentState == DealState.CREATED, "PropertyEscrow: deal must be in CREATED state to fund");
        require(msg.value == agreedPrice,          "PropertyEscrow: must send exactly the agreed price");

        currentState = DealState.FUNDED;     // advance the state machine
        dealFundedAt = block.timestamp;      // start the 30-day timeout clock

        _log(
            buyer,
            "DEAL_FUNDED",
            string(abi.encodePacked("Deal funded with ", _weiToEthString(msg.value), " ETH")),
            keccak256(abi.encodePacked(buyer, msg.value, block.timestamp))
        );

        emit DealFunded(buyer, msg.value, block.timestamp);
    }

    // buyerConfirm() — the buyer confirms the deal conditions have been met.
    // For example: "I have inspected the property and the title deed has been transferred."
    // If the seller has already confirmed, this triggers automatic fund release.
    function buyerConfirm() external {
        require(msg.sender == buyer, "PropertyEscrow: only buyer can call buyerConfirm");

        // Buyer can confirm once the deal is funded, regardless of seller's state.
        require(
            currentState == DealState.FUNDED || currentState == DealState.SELLER_CONFIRMED,
            "PropertyEscrow: deal must be funded before confirming"
        );

        buyerApproval = true; // record buyer's approval

        // If both parties have confirmed, trigger the fund release immediately.
        if (sellerApproval) {
            _completeDeal(); // internal function handles the transfer
        } else {
            currentState = DealState.BUYER_CONFIRMED; // waiting for seller
        }

        _log(
            buyer,
            "BUYER_CONFIRMED",
            "Buyer confirmed deal conditions are met",
            keccak256(abi.encodePacked(buyer, block.timestamp))
        );

        emit BuyerConfirmed(buyer, block.timestamp);
    }

    // sellerConfirm() — the seller confirms the deal conditions have been met.
    // For example: "I have received the title deed transfer request and it's processing."
    // If the buyer has already confirmed, this triggers automatic fund release.
    function sellerConfirm() external {
        require(msg.sender == seller, "PropertyEscrow: only seller can call sellerConfirm");

        // Seller can confirm once the deal is funded, regardless of buyer's state.
        require(
            currentState == DealState.FUNDED || currentState == DealState.BUYER_CONFIRMED,
            "PropertyEscrow: deal must be funded before seller can confirm"
        );

        sellerApproval = true; // record seller's approval

        // If both parties have confirmed, trigger the fund release immediately.
        if (buyerApproval) {
            _completeDeal(); // internal function handles the transfer
        } else {
            currentState = DealState.SELLER_CONFIRMED; // waiting for buyer
        }

        _log(
            seller,
            "SELLER_CONFIRMED",
            "Seller confirmed deal conditions are met",
            keccak256(abi.encodePacked(seller, block.timestamp))
        );

        emit SellerConfirmed(seller, block.timestamp);
    }

    // _completeDeal() — internal function that releases funds to the seller.
    // This is marked internal because it should only be called from buyerConfirm()
    // or sellerConfirm() once both approvals are in. Making it external would
    // let anyone trigger it, which would be a critical security vulnerability.
    // nonReentrant prevents a malicious seller contract from calling back in
    // during the ETH transfer and draining additional funds.
    function _completeDeal() internal nonReentrant {
        currentState = DealState.COMPLETED; // mark deal as done first (checks-effects-interactions)

        uint256 amount = address(this).balance; // capture balance before transfer

        // Send all escrowed funds to the seller.
        // We use the low-level call pattern which is safer than transfer() or send().
        (bool success, ) = seller.call{value: amount}("");
        require(success, "PropertyEscrow: ETH transfer to seller failed");

        // Automatically notify FraudGuard about this large ETH transfer.
        // If the deal was manipulated or the seller address was changed by an
        // attacker, FraudGuard will detect the large outflow and begin protection.
        if (fraudGuardContract != address(0)) {
            try IFraudGuard(fraudGuardContract).reportSuspiciousActivity(
                seller,
                amount,
                "AUTO: Large ETH release detected in property deal completion"
            ) {} catch {} // silent - never block a legitimate deal completion
        }

        _log(
            seller,
            "DEAL_COMPLETED",
            string(abi.encodePacked("Deal completed, ", _weiToEthString(amount), " ETH released to seller")),
            keccak256(abi.encodePacked(seller, amount, block.timestamp))
        );

        emit DealCompleted(seller, amount, block.timestamp);
    }

    // requestRefund() — the buyer requests their money back after the 30-day timeout.
    // This protects buyers in situations where the seller disappears or fails to deliver.
    // The timeout must have elapsed — we don't give refunds on demand within 30 days,
    // as that would allow buyers to confirm receipt but then claim a refund anyway.
    function requestRefund() external nonReentrant {
        require(msg.sender == buyer, "PropertyEscrow: only buyer can request refund");

        // Can only refund from funded states (not after completion or previous refund).
        require(
            currentState == DealState.FUNDED ||
            currentState == DealState.BUYER_CONFIRMED ||
            currentState == DealState.SELLER_CONFIRMED,
            "PropertyEscrow: deal is not in a refundable state"
        );

        // The 30-day timeout must have passed.
        require(
            block.timestamp - dealFundedAt >= DEAL_TIMEOUT,
            "PropertyEscrow: timeout period has not elapsed yet"
        );

        currentState = DealState.REFUNDED; // update state before transfer (checks-effects-interactions)

        uint256 amount = address(this).balance; // capture balance before transfer

        // Return all funds to the buyer.
        (bool success, ) = buyer.call{value: amount}("");
        require(success, "PropertyEscrow: ETH transfer to buyer failed");

        // Notify FraudGuard about this large ETH movement on refund.
        if (fraudGuardContract != address(0)) {
            try IFraudGuard(fraudGuardContract).reportSuspiciousActivity(
                buyer,
                amount,
                "AUTO: Large ETH refund detected in property deal"
            ) {} catch {}
        }

        _log(
            buyer,
            "DEAL_REFUNDED",
            string(abi.encodePacked("Deal refunded after timeout: ", _weiToEthString(amount), " ETH returned to buyer")),
            keccak256(abi.encodePacked(buyer, amount, block.timestamp))
        );

        emit DealRefunded(buyer, amount, block.timestamp);
    }

    // raiseDispute() — either party can flag the deal as disputed.
    // In a full production version this would lock funds and trigger a DAO arbitration vote
    // where token holders vote on how to resolve the dispute. For this capstone version,
    // it simply changes state to DISPUTED so both parties can see there's a conflict recorded.
    function raiseDispute() external {
        require(
            msg.sender == buyer || msg.sender == seller,
            "PropertyEscrow: only buyer or seller can raise a dispute"
        );
        require(
            currentState != DealState.COMPLETED && currentState != DealState.REFUNDED,
            "PropertyEscrow: cannot dispute a completed or refunded deal"
        );

        currentState = DealState.DISPUTED; // freeze the deal

        _log(
            msg.sender,
            "DISPUTE_RAISED",
            "A dispute has been raised on this deal",
            keccak256(abi.encodePacked(msg.sender, block.timestamp))
        );

        emit DisputeRaised(msg.sender, block.timestamp);
    }

    // ─── VIEW FUNCTIONS ───────────────────────────────────────────

    // getDealState() — returns the current state as a human-readable string.
    // The frontend uses this to show a meaningful label instead of a number.
    function getDealState() external view returns (string memory) {
        if (currentState == DealState.CREATED)          return "CREATED";
        if (currentState == DealState.FUNDED)           return "FUNDED";
        if (currentState == DealState.BUYER_CONFIRMED)  return "BUYER_CONFIRMED";
        if (currentState == DealState.SELLER_CONFIRMED) return "SELLER_CONFIRMED";
        if (currentState == DealState.COMPLETED)        return "COMPLETED";
        if (currentState == DealState.REFUNDED)         return "REFUNDED";
        if (currentState == DealState.DISPUTED)         return "DISPUTED";
        return "UNKNOWN"; // fallback — should never reach this
    }

    // getDealSummary() — returns all key deal details in a single call.
    // This reduces the number of RPC calls the frontend needs to make.
    function getDealSummary() external view returns (
        address _buyer,
        address _seller,
        uint256 _agreedPrice,
        string  memory _propertyDescription,
        string  memory _propertyAddress,
        string  memory _dealConditions,
        uint256 _currentStateUint, // uint for easier frontend handling
        uint256 _dealCreatedAt,
        uint256 _dealFundedAt,
        bool    _buyerApproval,
        bool    _sellerApproval,
        uint256 _balance
    ) {
        return (
            buyer,
            seller,
            agreedPrice,
            propertyDescription,
            propertyAddress,
            dealConditions,
            uint256(currentState), // cast enum to uint for ABI compatibility
            dealCreatedAt,
            dealFundedAt,
            buyerApproval,
            sellerApproval,
            address(this).balance
        );
    }

    // ─── PRIVATE HELPERS ─────────────────────────────────────────

    // _weiToEthString() — converts a wei amount to a simple string like "1500000000000000000".
    // Used in log messages. A full decimal formatter is out of scope for Solidity.
    function _weiToEthString(uint256 weiAmount) private pure returns (string memory) {
        // Simple uint to string conversion for log messages.
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
