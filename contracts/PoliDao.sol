// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

/// @title PoliDAO - Ultra Modern Fundraising Platform (Gas Optimized & Security Enhanced)
/// @notice Supports EIP-2612 Permit, Account Abstraction, Multicall, Suspension & Location
contract PoliDAO is Ownable, Pausable, EIP712, Multicall {
    using ECDSA for bytes32;

    // ========== CUSTOM ERRORS (Gas Optimization) ==========
    
    error FundraiserNotFound(uint256 id);
    error InsufficientAmount(uint256 provided, uint256 required);
    error UnauthorizedAccess(address caller, address required);
    error FundraiserSuspendedError(uint256 id); // Renamed to avoid conflict with event
    error DeadlineExpired(uint256 deadline, uint256 current);
    error InvalidTokenAddress(address token);
    error AlreadyRefunded(address donor, uint256 fundraiserId);
    error InvalidFundraiserStatus(uint8 current, uint8 required);
    error DailyLimitExceeded(uint256 amount, uint256 limit);
    error ArrayLengthMismatch(uint256 length1, uint256 length2);
    error BatchAlreadyExecuted(bytes32 batchId);
    error InvalidMediaType(uint8 mediaType);
    error MediaLimitExceeded(uint256 current, uint256 limit);
    error ReentrantCall();

    // ========== OPTIMIZED CONSTANTS ==========
    
    bytes32 private constant DONATION_TYPEHASH = keccak256(
        "Donation(address donor,uint256 fundraiserId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MIN_EXTENSION_NOTICE = 7 days;
    uint256 public constant EXTENSION_FEE = 20e6; // $20 USDC
    uint256 public constant MAX_EXTENSION_DAYS = 90;
    uint256 public constant FAILED_FUNDRAISER_CLAIM_PERIOD = 7 days;
    uint256 public constant MAX_QUESTION_LENGTH = 500;
    uint256 public constant MAX_UPDATE_LENGTH = 1000;
    uint256 public constant MAX_TITLE_LENGTH = 100;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 2000;
    uint256 public constant MAX_IPFS_HASH_LENGTH = 100;
    uint256 public constant MAX_LOCATION_LENGTH = 200;
    uint256 private constant PRECISION = 10_000;
    uint256 private constant MAX_COMMISSION = 10_000;
    
    // MULTIMEDIA LIMITS
    uint256 public constant MAX_INITIAL_IMAGES = 10;
    uint256 public constant MAX_INITIAL_VIDEOS = 1;
    uint256 public constant MAX_MEDIA_BATCH = 20;
    uint256 public constant MAX_TOTAL_MEDIA = 200;
    uint256 public constant MAX_MEDIA_PER_UPDATE = 5;

    // REENTRANCY GUARD OPTIMIZATION
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ========== PACKED STRUCTURES (Gas Optimization) ==========

    enum FundraiserType { WITH_GOAL, WITHOUT_GOAL }
    enum FundraiserStatus { 
        ACTIVE, 
        SUCCESSFUL, 
        FAILED, 
        REFUND_PERIOD, 
        COMPLETED, 
        SUSPENDED
    }

    // Packed struct to save gas
    struct PackedFundraiserData {
        uint128 goalAmount;      // 16 bytes
        uint128 raisedAmount;    // 16 bytes
        uint64 endDate;          // 8 bytes
        uint64 originalEndDate;  // 8 bytes
        uint32 id;               // 4 bytes
        uint32 suspensionTime;   // 4 bytes (sufficient for timestamp delta)
        uint16 extensionCount;   // 2 bytes
        uint8 fundraiserType;    // 1 byte
        uint8 status;            // 1 byte
        bool isSuspended;        // 1 byte
        bool fundsWithdrawn;     // 1 byte
        // Total: 62 bytes (fits in 2 storage slots)
    }

    struct MediaItem {
        string ipfsHash;
        uint8 mediaType;
        string filename;
        uint256 fileSize;
        uint256 uploadTime;
        address uploader;
        string description;
    }

    struct FundraiserCreationData {
        string title;
        string description;
        uint256 endDate;
        FundraiserType fundraiserType;
        address token;
        uint256 goalAmount;
        string[] initialImages;
        string[] initialVideos;
        string metadataHash;
        string location;
    }

    struct Fundraiser {
        PackedFundraiserData packed;
        address creator;
        address token;
        string title;
        string description;
        string location;
        string metadataHash;
        string suspensionReason;
        uint256 refundDeadline;
        MediaItem[] gallery;
        address[] donors;
        mapping(address => uint256) donations;
        mapping(address => bool) hasRefunded;
        uint256[] updateIds;
        uint256 pinnedUpdateId;
    }

    struct FundraiserUpdate {
        uint256 id;
        uint256 fundraiserId;
        address author;
        string content;
        MediaItem[] attachments;
        uint256 timestamp;
        uint8 updateType;
        bool isPinned;
    }

    struct Proposal {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
        string metadataHash;
        mapping(address => bool) hasVoted;
    }

    // ========== OPTIMIZED STORAGE ==========

    uint256 public proposalCount;
    uint256 public fundraiserCount;
    uint256 public updateCount;
    uint256 private _status = _NOT_ENTERED; // Reentrancy guard

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Fundraiser) private fundraisers;
    mapping(uint256 => FundraiserUpdate) private fundraiserUpdates;

    uint256[] private proposalIds;
    uint256[] private fundraiserIds;

    // Meta-transaction support
    mapping(address => uint256) public nonces;
    
    // Batch operations tracking
    mapping(bytes32 => bool) public executedBatches;

    // Media tracking per fundraiser [images, videos, audio, documents]
    mapping(uint256 => uint256[4]) public mediaTypeCounts;

    // Token management
    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;
    mapping(address => uint256) private tokenIndex;

    // Commission system
    uint256 public donationCommission;
    uint256 public successCommission;
    uint256 public refundCommission;
    address public commissionWallet;
    address public feeToken;

    // Refund tracking
    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount;

    // Circuit breaker with user limits
    uint256 public maxDailyDonations = 1_000_000 * 10**18;
    uint256 public maxUserDailyDonation = 100_000 * 10**6; // $100k USDC per user
    mapping(uint256 => uint256) public dailyDonationCount;
    mapping(address => mapping(uint256 => uint256)) public userDailyDonations;

    // Selective pausing
    bool public votingPaused = false;
    bool public donationsPaused = false;
    bool public withdrawalsPaused = false;
    bool public updatesPaused = false;
    bool public mediaPaused = false;

    // Authorization system
    mapping(address => bool) public authorizedProposers;
    mapping(uint256 => mapping(address => bool)) public authorizedUpdaters;
    mapping(uint256 => mapping(address => bool)) public authorizedMediaManagers;

    // ========== OPTIMIZED EVENTS ==========

    event FundraiserCreated(uint256 indexed id, address indexed creator, address indexed token, 
                           string title, uint8 fundraiserType, uint256 goalAmount, uint256 endDate, string location);
    event FundraiserExtended(uint256 indexed id, uint256 newEndDate, uint256 extensionDays, uint256 feePaid);
    event FundraiserStatusChanged(uint256 indexed id, uint8 oldStatus, uint8 newStatus);
    
    event FundraiserSuspended(uint256 indexed id, address indexed suspendedBy, string reason, uint256 timestamp);
    event FundraiserUnsuspended(uint256 indexed id, address indexed unsuspendedBy, uint256 timestamp);
    event LocationUpdated(uint256 indexed id, string oldLocation, string newLocation);
    
    // Optimized donation events with indexed parameters
    event DonationMade(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 amount, uint256 netAmount);
    event DonationMadeWithPermit(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 amount);
    event DonationMadeWithMetaTx(uint256 indexed fundraiserId, address indexed donor, address indexed relayer, uint256 amount);
    event BatchDonationExecuted(bytes32 indexed batchId, address indexed donor, uint256 totalAmount);
    
    event DonationRefunded(uint256 indexed fundraiserId, address indexed donor, uint256 amountReturned, uint256 commissionTaken);
    event FundsWithdrawn(uint256 indexed fundraiserId, address indexed creator, uint256 amountAfterCommission);
    event ClosureInitiated(uint256 indexed fundraiserId, uint256 reclaimDeadline);
    
    event UpdatePosted(uint256 indexed updateId, uint256 indexed fundraiserId, address indexed author, string content, uint8 updateType);
    event UpdatePinned(uint256 indexed updateId, uint256 indexed fundraiserId);
    event UpdateUnpinned(uint256 indexed fundraiserId, uint256 indexed oldUpdateId);
    event MediaAdded(uint256 indexed fundraiserId, string ipfsHash, uint8 mediaType, string filename, address uploader);
    event MediaRemoved(uint256 indexed fundraiserId, uint256 mediaIndex, string ipfsHash);
    event MultimediaActivated(uint256 indexed fundraiserId);
    
    event TokenWhitelisted(address indexed token);
    event TokenRemoved(address indexed token);
    event DonationCommissionSet(uint256 newCommission);
    event SuccessCommissionSet(uint256 newCommission);
    event RefundCommissionSet(uint256 newCommission);
    event CommissionWalletChanged(address indexed oldWallet, address indexed newWallet);
    event FeeTokenSet(address indexed oldToken, address indexed newToken);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    
    event ProposalCreated(uint256 indexed id, string question, uint256 endTime, address indexed creator);
    event Voted(address indexed voter, uint256 indexed proposalId, bool support);
    event ProposerAuthorized(address indexed proposer);
    event ProposerRevoked(address indexed proposer);
    event UpdaterAuthorized(uint256 indexed fundraiserId, address indexed updater);
    event UpdaterRevoked(uint256 indexed fundraiserId, address indexed updater);
    event MediaManagerAuthorized(uint256 indexed fundraiserId, address indexed manager);
    event MediaManagerRevoked(uint256 indexed fundraiserId, address indexed manager);

    // ========== OPTIMIZED MODIFIERS ==========

    modifier whenVotingNotPaused() { 
        if (votingPaused) revert("Voting paused");
        _; 
    }
    
    modifier whenDonationsNotPaused() { 
        if (donationsPaused) revert("Donations paused");
        _; 
    }
    
    modifier whenWithdrawalsNotPaused() { 
        if (withdrawalsPaused) revert("Withdrawals paused");
        _; 
    }
    
    modifier whenUpdatesNotPaused() { 
        if (updatesPaused) revert("Updates paused");
        _; 
    }
    
    modifier whenMediaNotPaused() { 
        if (mediaPaused) revert("Media operations paused");
        _; 
    }

    modifier onlyAuthorizedProposer() {
        if (msg.sender != owner() && !authorizedProposers[msg.sender]) {
            revert UnauthorizedAccess(msg.sender, owner());
        }
        _;
    }

    modifier onlyFundraiserCreatorOrAuthorized(uint256 fundraiserId) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) {
            revert FundraiserNotFound(fundraiserId);
        }
        
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator && !authorizedUpdaters[fundraiserId][msg.sender]) {
            revert UnauthorizedAccess(msg.sender, f.creator);
        }
        _;
    }

    modifier onlyMediaManager(uint256 fundraiserId) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) {
            revert FundraiserNotFound(fundraiserId);
        }
        
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator && 
            !authorizedUpdaters[fundraiserId][msg.sender] && 
            !authorizedMediaManagers[fundraiserId][msg.sender]) {
            revert UnauthorizedAccess(msg.sender, f.creator);
        }
        _;
    }

    modifier validFundraiserId(uint256 fundraiserId) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) {
            revert FundraiserNotFound(fundraiserId);
        }
        _;
    }

    modifier circuitBreaker(uint256 amount) {
        if (amount > maxDailyDonations / 10) {
            uint256 today = block.timestamp / 1 days;
            if (dailyDonationCount[today] + amount > maxDailyDonations) {
                revert DailyLimitExceeded(amount, maxDailyDonations);
            }
            dailyDonationCount[today] += amount;
        }
        _;
    }

    modifier donationLimit(uint256 amount) {
        uint256 today = block.timestamp / 1 days;
        userDailyDonations[msg.sender][today] += amount;
        if (userDailyDonations[msg.sender][today] > maxUserDailyDonation) {
            revert DailyLimitExceeded(amount, maxUserDailyDonation);
        }
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidTokenAddress(addr);
        _;
    }

    modifier autoUpdateStatus(uint256 fundraiserId) {
        _;
        _updateFundraiserStatus(fundraiserId);
    }

    modifier whenFundraiserNotSuspended(uint256 fundraiserId) {
        if (fundraisers[fundraiserId].packed.isSuspended) {
            revert FundraiserSuspendedError(fundraiserId);
        }
        _;
    }

    // Optimized reentrancy guard
    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ========== CONSTRUCTOR ==========

    constructor(
        address initialOwner,
        address _commissionWallet,
        address _feeToken
    ) 
        Ownable(initialOwner) 
        EIP712("PoliDAO", "1")
        validAddress(initialOwner)
        validAddress(_commissionWallet)
        validAddress(_feeToken)
    {
        commissionWallet = _commissionWallet;
        feeToken = _feeToken;
    }

    // ========== ADMIN FUNCTIONS ==========

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function toggleVotingPause() external onlyOwner { votingPaused = !votingPaused; }
    function toggleDonationsPause() external onlyOwner { donationsPaused = !donationsPaused; }
    function toggleWithdrawalsPause() external onlyOwner { withdrawalsPaused = !withdrawalsPaused; }
    function toggleUpdatesPause() external onlyOwner { updatesPaused = !updatesPaused; }
    function toggleMediaPause() external onlyOwner { mediaPaused = !mediaPaused; }
    
    function emergencyPauseAll() public onlyOwner {
        _pause();
        votingPaused = true;
        donationsPaused = true;
        withdrawalsPaused = true;
        updatesPaused = true;
        mediaPaused = true;
    }

    // ========== INTERNAL UTILITY FUNCTIONS ==========

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _updateFundraiserStatus(uint256 fundraiserId) internal {
        Fundraiser storage f = fundraisers[fundraiserId];
        
        if (f.packed.status == uint8(FundraiserStatus.COMPLETED) || f.packed.isSuspended) return;
        
        uint8 oldStatus = f.packed.status;
        
        if (f.packed.fundraiserType == uint8(FundraiserType.WITH_GOAL)) {
            if (f.packed.status == uint8(FundraiserStatus.ACTIVE)) {
                if (f.packed.raisedAmount >= f.packed.goalAmount) {
                    f.packed.status = uint8(FundraiserStatus.SUCCESSFUL);
                } else if (block.timestamp > f.packed.endDate) {
                    f.packed.status = uint8(FundraiserStatus.FAILED);
                }
            }
        }
        
        if (oldStatus != f.packed.status) {
            emit FundraiserStatusChanged(fundraiserId, oldStatus, f.packed.status);
        }
    }

    function _executeDonation(uint256 fundraiserId, uint256 amount) internal returns (uint256 netAmount) {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (f.packed.status != uint8(FundraiserStatus.ACTIVE)) {
            revert InvalidFundraiserStatus(f.packed.status, uint8(FundraiserStatus.ACTIVE));
        }
        if (amount == 0) revert InsufficientAmount(amount, 1);
        
        IERC20 token = IERC20(f.token);
        
        uint256 commission = (amount * donationCommission) / PRECISION;
        netAmount = amount - commission;
        
        if (!token.transferFrom(msg.sender, address(this), amount)) revert("Transfer failed");
        
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += netAmount;
        f.packed.raisedAmount += uint128(netAmount);
        
        if (f.packed.fundraiserType == uint8(FundraiserType.WITH_GOAL) && 
            f.packed.raisedAmount >= f.packed.goalAmount && 
            f.packed.status == uint8(FundraiserStatus.ACTIVE)) {
            f.packed.status = uint8(FundraiserStatus.SUCCESSFUL);
            emit FundraiserStatusChanged(fundraiserId, uint8(FundraiserStatus.ACTIVE), uint8(FundraiserStatus.SUCCESSFUL));
        }
        
        if (commission > 0) {
            if (!token.transfer(commissionWallet, commission)) revert("Commission transfer failed");
        }
    }

    function _createInitialUpdate(uint256 fundraiserId, string memory description) internal {
        updateCount++;
        FundraiserUpdate storage update = fundraiserUpdates[updateCount];
        update.id = updateCount;
        update.fundraiserId = fundraiserId;
        update.author = msg.sender;
        update.content = description;
        update.timestamp = block.timestamp;
        update.updateType = 0;
        
        Fundraiser storage f = fundraisers[fundraiserId];
        for (uint256 i = 0; i < f.gallery.length; i++) {
            update.attachments.push(f.gallery[i]);
        }
        
        f.updateIds.push(updateCount);
        f.pinnedUpdateId = updateCount;
        
        emit UpdatePosted(updateCount, fundraiserId, msg.sender, description, 0);
        emit UpdatePinned(updateCount, fundraiserId);
    }

    // Internal helper for updates to avoid code duplication
    function _postUpdateInternal(
        uint256 fundraiserId,
        string calldata content,
        uint8 updateType,
        MediaItem[] memory attachments
    ) internal {
        if (bytes(content).length == 0 || bytes(content).length > MAX_UPDATE_LENGTH) {
            revert("Invalid content");
        }
        if (attachments.length > MAX_MEDIA_PER_UPDATE) revert("Too many attachments");

        updateCount++;
        FundraiserUpdate storage update = fundraiserUpdates[updateCount];
        update.id = updateCount;
        update.fundraiserId = fundraiserId;
        update.author = msg.sender;
        update.content = content;
        update.timestamp = block.timestamp;
        update.updateType = updateType;

        for (uint256 i = 0; i < attachments.length; i++) {
            MediaItem memory attachment = attachments[i];
            attachment.uploadTime = block.timestamp;
            attachment.uploader = msg.sender;
            update.attachments.push(attachment);
            
            fundraisers[fundraiserId].gallery.push(attachment);
            mediaTypeCounts[fundraiserId][attachment.mediaType]++;
            
            emit MediaAdded(fundraiserId, attachment.ipfsHash, attachment.mediaType, attachment.filename, msg.sender);
        }

        Fundraiser storage f = fundraisers[fundraiserId];
        f.updateIds.push(updateCount);

        if (updateType == 1 || updateType == 2) {
            if (f.pinnedUpdateId != 0) {
                fundraiserUpdates[f.pinnedUpdateId].isPinned = false;
                emit UpdateUnpinned(fundraiserId, f.pinnedUpdateId);
            }
            f.pinnedUpdateId = updateCount;
            update.isPinned = true;
            emit UpdatePinned(updateCount, fundraiserId);
        }

        emit UpdatePosted(updateCount, fundraiserId, msg.sender, content, updateType);
    }

    // ========== SUSPENSION SYSTEM ==========

    function suspendFundraiser(uint256 fundraiserId, string calldata reason) 
        external 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != owner() && msg.sender != f.creator) {
            revert UnauthorizedAccess(msg.sender, f.creator);
        }
        if (f.packed.isSuspended) revert("Already suspended");
        if (f.packed.status == uint8(FundraiserStatus.COMPLETED)) revert("Cannot suspend completed fundraiser");
        if (bytes(reason).length == 0) revert("Suspension reason required");

        f.packed.isSuspended = true;
        f.packed.suspensionTime = uint32(block.timestamp);
        f.suspensionReason = reason;
        
        uint8 oldStatus = f.packed.status;
        f.packed.status = uint8(FundraiserStatus.SUSPENDED);

        emit FundraiserSuspended(fundraiserId, msg.sender, reason, block.timestamp);
        emit FundraiserStatusChanged(fundraiserId, oldStatus, uint8(FundraiserStatus.SUSPENDED));
    }

    function unsuspendFundraiser(uint256 fundraiserId) 
        external 
        onlyOwner 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (!f.packed.isSuspended) revert("Not suspended");

        f.packed.isSuspended = false;
        f.packed.suspensionTime = 0;
        f.suspensionReason = "";
        
        uint8 newStatus;
        if (f.packed.fundraiserType == uint8(FundraiserType.WITHOUT_GOAL)) {
            newStatus = uint8(FundraiserStatus.ACTIVE);
        } else {
            if (f.packed.raisedAmount >= f.packed.goalAmount) {
                newStatus = uint8(FundraiserStatus.SUCCESSFUL);
            } else if (block.timestamp > f.packed.endDate) {
                newStatus = uint8(FundraiserStatus.FAILED);
            } else {
                newStatus = uint8(FundraiserStatus.ACTIVE);
            }
        }
        
        f.packed.status = newStatus;

        emit FundraiserUnsuspended(fundraiserId, msg.sender, block.timestamp);
        emit FundraiserStatusChanged(fundraiserId, uint8(FundraiserStatus.SUSPENDED), newStatus);
    }

    function refundFromSuspended(uint256 fundraiserId) 
        external 
        nonReentrant 
        whenNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (!f.packed.isSuspended) revert("Fundraiser not suspended");
        if (f.hasRefunded[msg.sender]) revert AlreadyRefunded(msg.sender, fundraiserId);

        uint256 donated = f.donations[msg.sender];
        if (donated == 0) revert("No donation found");

        f.hasRefunded[msg.sender] = true;
        f.packed.raisedAmount -= uint128(donated);
        f.donations[msg.sender] = 0;

        IERC20 token = IERC20(f.token);
        if (!token.transfer(msg.sender, donated)) revert("Refund failed");

        emit DonationRefunded(fundraiserId, msg.sender, donated, 0);
    }

    // ========== LOCATION MANAGEMENT ==========

    function updateLocation(uint256 fundraiserId, string calldata newLocation) 
        external 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);
        if (bytes(newLocation).length == 0 || bytes(newLocation).length > MAX_LOCATION_LENGTH) {
            revert("Invalid location");
        }

        string memory oldLocation = f.location;
        f.location = newLocation;

        emit LocationUpdated(fundraiserId, oldLocation, newLocation);
    }

    // ========== MODERN DONATION METHODS ==========

    function donate(uint256 fundraiserId, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        whenDonationsNotPaused 
        circuitBreaker(amount)
        donationLimit(amount)
        validFundraiserId(fundraiserId)
        whenFundraiserNotSuspended(fundraiserId)
        autoUpdateStatus(fundraiserId)
    {
        uint256 netAmount = _executeDonation(fundraiserId, amount);
        Fundraiser storage f = fundraisers[fundraiserId];
        emit DonationMade(fundraiserId, msg.sender, f.token, amount, netAmount);
    }

    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        whenDonationsNotPaused 
        circuitBreaker(amount)
        donationLimit(amount)
        validFundraiserId(fundraiserId)
        whenFundraiserNotSuspended(fundraiserId)
        autoUpdateStatus(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        
        IERC20Permit(f.token).permit(
            msg.sender, 
            address(this), 
            amount, 
            deadline, 
            v, 
            r, 
            s
        );
        
        _executeDonation(fundraiserId, amount);
        emit DonationMadeWithPermit(fundraiserId, msg.sender, f.token, amount);
    }

    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        whenDonationsNotPaused 
        circuitBreaker(amount)
        validFundraiserId(fundraiserId)
        whenFundraiserNotSuspended(fundraiserId)
        autoUpdateStatus(fundraiserId)
    {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        
        bytes32 structHash = keccak256(
            abi.encode(
                DONATION_TYPEHASH,
                donor,
                fundraiserId,
                amount,
                nonces[donor]++,
                deadline
            )
        );
        
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);
        if (signer != donor) revert("Invalid signature");
        
        Fundraiser storage f = fundraisers[fundraiserId];
        IERC20 token = IERC20(f.token);
        
        uint256 commission = (amount * donationCommission) / PRECISION;
        uint256 netAmount = amount - commission;
        
        if (!token.transferFrom(donor, address(this), amount)) revert("Transfer failed");
        
        if (f.donations[donor] == 0) {
            f.donors.push(donor);
        }
        f.donations[donor] += netAmount;
        f.packed.raisedAmount += uint128(netAmount);
        
        if (f.packed.fundraiserType == uint8(FundraiserType.WITH_GOAL) && 
            f.packed.raisedAmount >= f.packed.goalAmount && 
            f.packed.status == uint8(FundraiserStatus.ACTIVE)) {
            f.packed.status = uint8(FundraiserStatus.SUCCESSFUL);
            emit FundraiserStatusChanged(fundraiserId, uint8(FundraiserStatus.ACTIVE), uint8(FundraiserStatus.SUCCESSFUL));
        }
        
        if (commission > 0) {
            if (!token.transfer(commissionWallet, commission)) revert("Commission transfer failed");
        }
        
        emit DonationMadeWithMetaTx(fundraiserId, donor, msg.sender, netAmount);
    }

    function batchDonate(
        uint256[] calldata _fundraiserIds,
        uint256[] calldata amounts
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        whenDonationsNotPaused 
    {
        if (_fundraiserIds.length != amounts.length) {
            revert ArrayLengthMismatch(_fundraiserIds.length, amounts.length);
        }
        if (_fundraiserIds.length > 10) revert("Too many donations in batch");
        
        bytes32 batchId = keccak256(abi.encodePacked(msg.sender, block.timestamp, _fundraiserIds, amounts));
        if (executedBatches[batchId]) revert BatchAlreadyExecuted(batchId);
        executedBatches[batchId] = true;
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _fundraiserIds.length; i++) {
            if (_fundraiserIds[i] == 0 || _fundraiserIds[i] > fundraiserCount) {
                revert FundraiserNotFound(_fundraiserIds[i]);
            }
            if (fundraisers[_fundraiserIds[i]].packed.isSuspended) {
                revert FundraiserSuspendedError(_fundraiserIds[i]);
            }
            totalAmount += amounts[i];
            _executeDonation(_fundraiserIds[i], amounts[i]);
        }
        
        emit BatchDonationExecuted(batchId, msg.sender, totalAmount);
    }

    // ========== ONE-CLICK FUNDRAISER CREATION ==========

    function createFundraiser(FundraiserCreationData calldata data) 
        external 
        whenNotPaused 
        whenDonationsNotPaused 
        returns (uint256 fundraiserId)
    {
        if (bytes(data.title).length == 0 || bytes(data.title).length > MAX_TITLE_LENGTH) revert("Invalid title");
        if (bytes(data.description).length == 0 || bytes(data.description).length > MAX_DESCRIPTION_LENGTH) revert("Invalid description");
        if (bytes(data.location).length == 0 || bytes(data.location).length > MAX_LOCATION_LENGTH) revert("Invalid location");
        if (data.endDate <= block.timestamp) revert("End date must be in future");
        if (data.endDate > block.timestamp + MAX_DURATION) revert("End date too far");
        if (!isTokenWhitelisted[data.token]) revert InvalidTokenAddress(data.token);
        if (data.initialImages.length > MAX_INITIAL_IMAGES) revert("Too many initial images");
        if (data.initialVideos.length > MAX_INITIAL_VIDEOS) revert("Too many initial videos");
        
        if (data.fundraiserType == FundraiserType.WITH_GOAL && data.goalAmount == 0) {
            revert("Goal amount required for WITH_GOAL type");
        }
        
        fundraiserCount++;
        fundraiserId = fundraiserCount;
        
        Fundraiser storage f = fundraisers[fundraiserId];
        f.packed = PackedFundraiserData({
            id: uint32(fundraiserId),
            goalAmount: uint128(data.goalAmount),
            raisedAmount: 0,
            endDate: uint64(data.endDate),
            originalEndDate: uint64(data.endDate),
            extensionCount: 0,
            fundraiserType: uint8(data.fundraiserType),
            status: uint8(FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            suspensionTime: 0
        });
        
        f.creator = msg.sender;
        f.token = data.token;
        f.title = data.title;
        f.description = data.description;
        f.location = data.location;
        f.metadataHash = data.metadataHash;
        
        uint256[4] storage typeCounts = mediaTypeCounts[fundraiserId];
        
        // Add images
        for (uint256 i = 0; i < data.initialImages.length; i++) {
            if (bytes(data.initialImages[i]).length == 0) revert("Empty image hash");
            
            MediaItem memory newImage = MediaItem({
                ipfsHash: data.initialImages[i],
                mediaType: 0,
                filename: string.concat("image_", _toString(i), ".jpg"),
                fileSize: 0,
                uploadTime: block.timestamp,
                uploader: msg.sender,
                description: "Initial fundraiser image"
            });
            
            f.gallery.push(newImage);
            typeCounts[0]++;
            
            emit MediaAdded(fundraiserId, data.initialImages[i], 0, newImage.filename, msg.sender);
        }
        
        // Add videos
        for (uint256 i = 0; i < data.initialVideos.length; i++) {
            if (bytes(data.initialVideos[i]).length == 0) revert("Empty video hash");
            
            MediaItem memory newVideo = MediaItem({
                ipfsHash: data.initialVideos[i],
                mediaType: 1,
                filename: string.concat("video_", _toString(i), ".mp4"),
                fileSize: 0,
                uploadTime: block.timestamp,
                uploader: msg.sender,
                description: "Initial fundraiser video"
            });
            
            f.gallery.push(newVideo);
            typeCounts[1]++;
            
            emit MediaAdded(fundraiserId, data.initialVideos[i], 1, newVideo.filename, msg.sender);
        }
        
        if (data.initialImages.length > 0 || data.initialVideos.length > 0) {
            emit MultimediaActivated(fundraiserId);
        }
        
        _createInitialUpdate(fundraiserId, data.description);
        
        fundraiserIds.push(fundraiserId);
        
        emit FundraiserCreated(
            fundraiserId, msg.sender, data.token, data.title, uint8(data.fundraiserType),
            data.goalAmount, data.endDate, data.location
        );
        
        return fundraiserId;
    }

    // ========== MODERN UTILITY FUNCTIONS ==========

    function supportsPermit(address token) external view returns (bool) {
        try IERC20Permit(token).DOMAIN_SEPARATOR() returns (bytes32) {
            return true;
        } catch {
            return false;
        }
    }

    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    function verifyDonationSignature(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (bool) {
        if (block.timestamp > deadline) return false;
        
        bytes32 structHash = keccak256(
            abi.encode(
                DONATION_TYPEHASH,
                donor,
                fundraiserId,
                amount,
                nonces[donor],
                deadline
            )
        );
        
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);
        return signer == donor;
    }

    // ========== WITHDRAWAL & REFUND SYSTEM ==========

    function withdrawFunds(uint256 fundraiserId) 
        external 
        nonReentrant 
        whenNotPaused 
        whenWithdrawalsNotPaused 
        validFundraiserId(fundraiserId)
        whenFundraiserNotSuspended(fundraiserId)
        autoUpdateStatus(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);
        if (f.packed.fundsWithdrawn) revert("Already withdrawn");
        if (f.packed.raisedAmount == 0) revert("No funds to withdraw");
        
        bool canWithdraw = false;
        
        if (f.packed.fundraiserType == uint8(FundraiserType.WITHOUT_GOAL)) {
            canWithdraw = true;
        } else {
            if (f.packed.status == uint8(FundraiserStatus.SUCCESSFUL)) {
                canWithdraw = true;
            } else if (f.packed.status == uint8(FundraiserStatus.FAILED) && 
                      block.timestamp > f.refundDeadline) {
                canWithdraw = true;
            }
        }
        
        if (!canWithdraw) revert("Cannot withdraw yet");
        
        uint256 amount = f.packed.raisedAmount;
        f.packed.fundsWithdrawn = true;
        f.packed.raisedAmount = 0;
        f.packed.status = uint8(FundraiserStatus.COMPLETED);
        
        uint256 commission = (amount * successCommission) / PRECISION;
        uint256 netAmount = amount - commission;
        
        IERC20 token = IERC20(f.token);
        
        if (commission > 0) {
            if (!token.transfer(commissionWallet, commission)) revert("Commission failed");
        }
        if (!token.transfer(f.creator, netAmount)) revert("Withdrawal failed");
        
        emit FundsWithdrawn(fundraiserId, f.creator, netAmount);
        emit FundraiserStatusChanged(fundraiserId, f.packed.status, uint8(FundraiserStatus.COMPLETED));
    }

    function refund(uint256 fundraiserId) 
        external 
        nonReentrant 
        whenNotPaused 
        validFundraiserId(fundraiserId)
        autoUpdateStatus(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (f.packed.fundraiserType != uint8(FundraiserType.WITH_GOAL)) {
            revert("Only WITH_GOAL campaigns allow refunds");
        }
        if (f.hasRefunded[msg.sender]) revert AlreadyRefunded(msg.sender, fundraiserId);

        uint256 donated = f.donations[msg.sender];
        if (donated == 0) revert("No donation found");

        if (f.packed.status != uint8(FundraiserStatus.REFUND_PERIOD) ||
            block.timestamp > f.refundDeadline) {
            revert("Not in refund period");
        }

        uint256 period = block.timestamp / 30 days;
        monthlyRefundCount[msg.sender][period]++;

        uint256 commissionAmount = 0;
        if (monthlyRefundCount[msg.sender][period] > 1 && refundCommission > 0) {
            commissionAmount = (donated * refundCommission) / PRECISION;
        }

        f.hasRefunded[msg.sender] = true;
        f.packed.raisedAmount -= uint128(donated);
        f.donations[msg.sender] = 0;

        uint256 refundAmount = donated - commissionAmount;

        IERC20 token = IERC20(f.token);

        if (commissionAmount > 0) {
            if (!token.transfer(commissionWallet, commissionAmount)) revert("Commission failed");
        }
        if (!token.transfer(msg.sender, refundAmount)) revert("Refund failed");

        emit DonationRefunded(fundraiserId, msg.sender, refundAmount, commissionAmount);
    }

    function initiateClosure(uint256 fundraiserId) 
        external 
        whenNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);
        if (f.packed.fundraiserType != uint8(FundraiserType.WITH_GOAL)) {
            revert("Only WITH_GOAL campaigns");
        }
        if (f.packed.status != uint8(FundraiserStatus.FAILED)) revert("Must be failed first");

        f.packed.status = uint8(FundraiserStatus.REFUND_PERIOD);
        f.refundDeadline = block.timestamp + FAILED_FUNDRAISER_CLAIM_PERIOD;

        emit ClosureInitiated(fundraiserId, f.refundDeadline);
        emit FundraiserStatusChanged(fundraiserId, uint8(FundraiserStatus.FAILED), uint8(FundraiserStatus.REFUND_PERIOD));
    }

    // ========== MULTIMEDIA MANAGEMENT ==========

    function addMultimediaToFundraiser(uint256 fundraiserId, MediaItem[] calldata mediaItems)
        external
        whenNotPaused
        whenMediaNotPaused
        validFundraiserId(fundraiserId)
        onlyMediaManager(fundraiserId)
    {
        if (mediaItems.length > MAX_MEDIA_BATCH) revert("Too many media files");

        Fundraiser storage f = fundraisers[fundraiserId];
        uint256[4] storage typeCounts = mediaTypeCounts[fundraiserId];
        uint256 totalCurrent = f.gallery.length;
        
        if (totalCurrent + mediaItems.length > MAX_TOTAL_MEDIA) {
            revert MediaLimitExceeded(totalCurrent + mediaItems.length, MAX_TOTAL_MEDIA);
        }

        for (uint256 i = 0; i < mediaItems.length; i++) {
            MediaItem memory item = mediaItems[i];
            
            if (item.mediaType > 3) revert InvalidMediaType(item.mediaType);
            if (bytes(item.ipfsHash).length == 0) revert("Empty IPFS hash");
            
            uint256 typeLimit = getMediaTypeLimit(item.mediaType);
            if (typeCounts[item.mediaType] + 1 > typeLimit) {
                revert MediaLimitExceeded(typeCounts[item.mediaType] + 1, typeLimit);
            }
            
            MediaItem memory newItem = MediaItem({
                ipfsHash: item.ipfsHash,
                mediaType: item.mediaType,
                filename: item.filename,
                fileSize: item.fileSize,
                uploadTime: block.timestamp,
                uploader: msg.sender,
                description: item.description
            });
            
            f.gallery.push(newItem);
            typeCounts[item.mediaType]++;
            
            emit MediaAdded(fundraiserId, item.ipfsHash, item.mediaType, item.filename, msg.sender);
        }
    }

    function removeMediaFromFundraiser(uint256 fundraiserId, uint256 mediaIndex)
        external
        whenNotPaused
        whenMediaNotPaused
        validFundraiserId(fundraiserId)
        onlyMediaManager(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (mediaIndex >= f.gallery.length) revert("Invalid media index");
        
        MediaItem storage mediaToRemove = f.gallery[mediaIndex];
        uint8 mediaType = mediaToRemove.mediaType;
        string memory ipfsHash = mediaToRemove.ipfsHash;
        
        mediaTypeCounts[fundraiserId][mediaType]--;
        
        f.gallery[mediaIndex] = f.gallery[f.gallery.length - 1];
        f.gallery.pop();
        
        emit MediaRemoved(fundraiserId, mediaIndex, ipfsHash);
    }

    // ========== UPDATE SYSTEM ==========

    function postUpdateWithMultimedia(
        uint256 fundraiserId,
        string calldata content,
        uint8 updateType,
        MediaItem[] calldata attachments
    ) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
        validFundraiserId(fundraiserId)
        onlyFundraiserCreatorOrAuthorized(fundraiserId)
    {
        MediaItem[] memory attachmentsMemory = new MediaItem[](attachments.length);
        for (uint256 i = 0; i < attachments.length; i++) {
            attachmentsMemory[i] = attachments[i];
        }
        _postUpdateInternal(fundraiserId, content, updateType, attachmentsMemory);
    }

    function postUpdate(uint256 fundraiserId, string calldata content) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
        validFundraiserId(fundraiserId)
        onlyFundraiserCreatorOrAuthorized(fundraiserId)
    {
        MediaItem[] memory emptyAttachments = new MediaItem[](0);
        _postUpdateInternal(fundraiserId, content, 0, emptyAttachments);
    }

    function pinUpdate(uint256 updateId) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
    {
        if (updateId == 0 || updateId > updateCount) revert("Invalid update");
        
        FundraiserUpdate storage update = fundraiserUpdates[updateId];
        uint256 fundraiserId = update.fundraiserId;
        
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);

        if (f.pinnedUpdateId != 0 && f.pinnedUpdateId != updateId) {
            fundraiserUpdates[f.pinnedUpdateId].isPinned = false;
            emit UpdateUnpinned(fundraiserId, f.pinnedUpdateId);
        }

        f.pinnedUpdateId = updateId;
        update.isPinned = true;

        emit UpdatePinned(updateId, fundraiserId);
    }

    function unpinUpdate(uint256 fundraiserId) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);
        if (f.pinnedUpdateId == 0) revert("No pinned update");

        uint256 oldPinnedId = f.pinnedUpdateId;
        f.pinnedUpdateId = 0;
        fundraiserUpdates[oldPinnedId].isPinned = false;

        emit UpdateUnpinned(fundraiserId, oldPinnedId);
    }

    // ========== GOVERNANCE SYSTEM ==========

    function createProposal(string calldata question, uint256 duration) 
        external 
        whenNotPaused 
        whenVotingNotPaused 
        onlyAuthorizedProposer
    {
        if (bytes(question).length == 0 || bytes(question).length > MAX_QUESTION_LENGTH) {
            revert("Invalid question");
        }
        if (duration > MAX_DURATION) revert("Duration too long");

        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.question = question;
        p.endTime = block.timestamp + duration;
        p.creator = msg.sender;
        p.metadataHash = "";

        proposalIds.push(proposalCount);

        emit ProposalCreated(p.id, question, p.endTime, msg.sender);
    }

    function vote(uint256 proposalId, bool support) 
        external 
        whenNotPaused 
        whenVotingNotPaused 
    {
        Proposal storage p = proposals[proposalId];
        if (proposalId == 0 || proposalId > proposalCount) revert("Invalid proposal");
        if (block.timestamp > p.endTime) revert("Voting ended");
        if (p.hasVoted[msg.sender]) revert("Already voted");

        p.hasVoted[msg.sender] = true;
        if (support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }

        emit Voted(msg.sender, proposalId, support);
    }

    // ========== FUNDRAISER EXTENSION ==========

    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) 
        external 
        nonReentrant 
        whenNotPaused 
        validFundraiserId(fundraiserId)
        whenFundraiserNotSuspended(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator) revert UnauthorizedAccess(msg.sender, f.creator);
        if (f.packed.status != uint8(FundraiserStatus.ACTIVE)) revert("Can only extend active fundraisers");
        if (additionalDays == 0 || additionalDays > MAX_EXTENSION_DAYS) revert("Invalid extension period");
        
        uint256 timeLeft = f.packed.endDate > block.timestamp ? f.packed.endDate - block.timestamp : 0;
        if (timeLeft < MIN_EXTENSION_NOTICE) revert("Must extend at least 7 days before end");
        
        IERC20 paymentToken = IERC20(feeToken);
        if (!paymentToken.transferFrom(msg.sender, commissionWallet, EXTENSION_FEE)) {
            revert("Extension fee payment failed");
        }
        
        f.packed.endDate += uint64(additionalDays * 1 days);
        f.packed.extensionCount++;
        
        emit FundraiserExtended(fundraiserId, f.packed.endDate, additionalDays, EXTENSION_FEE);
    }

    // ========== COMMISSION MANAGEMENT ==========

    function setCommissionWallet(address newWallet) external onlyOwner validAddress(newWallet) {
        address oldWallet = commissionWallet;
        commissionWallet = newWallet;
        emit CommissionWalletChanged(oldWallet, newWallet);
    }
    
    function setFeeToken(address newToken) external onlyOwner validAddress(newToken) {
        address oldToken = feeToken;
        feeToken = newToken;
        emit FeeTokenSet(oldToken, newToken);
    }
    
    function setDonationCommission(uint256 bps) external onlyOwner {
        if (bps > MAX_COMMISSION) revert("Max 100%");
        donationCommission = bps;
        emit DonationCommissionSet(bps);
    }
    
    function setSuccessCommission(uint256 bps) external onlyOwner {
        if (bps > MAX_COMMISSION) revert("Max 100%");
        successCommission = bps;
        emit SuccessCommissionSet(bps);
    }
    
    function setRefundCommission(uint256 bps) external onlyOwner {
        if (bps > MAX_COMMISSION) revert("Max 100%");
        refundCommission = bps;
        emit RefundCommissionSet(bps);
    }
    
    function setMaxDailyDonations(uint256 newLimit) external onlyOwner {
        maxDailyDonations = newLimit;
    }

    function setMaxUserDailyDonation(uint256 newLimit) external onlyOwner {
        maxUserDailyDonation = newLimit;
    }

    // ========== TOKEN MANAGEMENT ==========

    function whitelistToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidTokenAddress(token);
        if (token.code.length == 0) revert("Not a contract");
        
        try IERC20(token).totalSupply() returns (uint256 supply) {
            if (supply == 0) revert("Token has zero supply");
        } catch {
            revert("Invalid ERC20 token");
        }
        
        if (isTokenWhitelisted[token]) revert("Already whitelisted");
        
        isTokenWhitelisted[token] = true;
        tokenIndex[token] = whitelistedTokens.length;
        whitelistedTokens.push(token);
        
        emit TokenWhitelisted(token);
    }

    function removeWhitelistToken(address token) external onlyOwner {
        if (!isTokenWhitelisted[token]) revert("Not whitelisted");
        
        isTokenWhitelisted[token] = false;
        
        uint256 index = tokenIndex[token];
        address lastToken = whitelistedTokens[whitelistedTokens.length - 1];
        
        whitelistedTokens[index] = lastToken;
        tokenIndex[lastToken] = index;
        whitelistedTokens.pop();
        delete tokenIndex[token];
        
        emit TokenRemoved(token);
    }

    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyOwner 
        validAddress(to) 
    {
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert("ETH transfer failed");
        } else {
            if (!IERC20(token).transfer(to, amount)) revert("Token transfer failed");
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }

    // ========== AUTHORIZATION MANAGEMENT ==========

    function authorizeProposer(address proposer) external onlyOwner validAddress(proposer) {
        authorizedProposers[proposer] = true;
        emit ProposerAuthorized(proposer);
    }

    function revokeProposer(address proposer) external onlyOwner {
        authorizedProposers[proposer] = false;
        emit ProposerRevoked(proposer);
    }

    function authorizeUpdater(uint256 fundraiserId, address updater) 
        external 
        validFundraiserId(fundraiserId)
        validAddress(updater)
    {
        if (msg.sender != fundraisers[fundraiserId].creator) {
            revert UnauthorizedAccess(msg.sender, fundraisers[fundraiserId].creator);
        }
        authorizedUpdaters[fundraiserId][updater] = true;
        emit UpdaterAuthorized(fundraiserId, updater);
    }

    function revokeUpdater(uint256 fundraiserId, address updater) 
        external 
        validFundraiserId(fundraiserId)
    {
        if (msg.sender != fundraisers[fundraiserId].creator) {
            revert UnauthorizedAccess(msg.sender, fundraisers[fundraiserId].creator);
        }
        authorizedUpdaters[fundraiserId][updater] = false;
        emit UpdaterRevoked(fundraiserId, updater);
    }

    function authorizeMediaManager(uint256 fundraiserId, address manager)
        external
        validFundraiserId(fundraiserId)
        validAddress(manager)
    {
        if (msg.sender != fundraisers[fundraiserId].creator) {
            revert UnauthorizedAccess(msg.sender, fundraisers[fundraiserId].creator);
        }
        authorizedMediaManagers[fundraiserId][manager] = true;
        emit MediaManagerAuthorized(fundraiserId, manager);
    }

    function revokeMediaManager(uint256 fundraiserId, address manager)
        external
        validFundraiserId(fundraiserId)
    {
        if (msg.sender != fundraisers[fundraiserId].creator) {
            revert UnauthorizedAccess(msg.sender, fundraisers[fundraiserId].creator);
        }
        authorizedMediaManagers[fundraiserId][manager] = false;
        emit MediaManagerRevoked(fundraiserId, manager);
    }

    // ========== VIEW FUNCTIONS ==========

    function getMediaTypeLimit(uint8 mediaType) public pure returns (uint256) {
        if (mediaType == 0) return 100;      // Images
        if (mediaType == 1) return 30;       // Videos
        if (mediaType == 2) return 20;       // Audio
        if (mediaType == 3) return 50;       // Documents
        return 0;
    }

    function getFundraiserDetails(uint256 fundraiserId) 
        external view 
        validFundraiserId(fundraiserId)
        returns (
            string memory title,
            string memory description,
            string memory location,
            uint256 endDate,
            uint8 fundraiserType,
            uint8 status,
            address token,
            uint256 goalAmount,
            uint256 raisedAmount,
            address creator,
            uint256 _updateCount,
            uint256 mediaCount,
            uint256 extensionCount,
            bool isSuspended,
            string memory suspensionReason
        ) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        return (
            f.title, f.description, f.location, f.packed.endDate, f.packed.fundraiserType, f.packed.status,
            f.token, f.packed.goalAmount, f.packed.raisedAmount, f.creator,
            f.updateIds.length, f.gallery.length, f.packed.extensionCount,
            f.packed.isSuspended, f.suspensionReason
        );
    }

    function getFundraiserProgress(uint256 fundraiserId) 
        external view 
        validFundraiserId(fundraiserId)
        returns (
            uint256 raised,
            uint256 goal,
            uint256 percentage,
            uint256 donorsCount,
            uint256 timeLeft,
            bool canExtend,
            uint256 refundDeadline,
            bool isSuspended,
            uint256 suspensionTime
        ) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        
        percentage = f.packed.goalAmount > 0 ? (f.packed.raisedAmount * 100) / f.packed.goalAmount : 100;
        if (percentage > 100) percentage = 100;
        
        timeLeft = block.timestamp >= f.packed.endDate ? 0 : f.packed.endDate - block.timestamp;
        
        return (f.packed.raisedAmount, f.packed.goalAmount, percentage, f.donors.length, timeLeft, 
                canExtend, f.refundDeadline, f.packed.isSuspended, f.packed.suspensionTime);
    }

    function getFundraiserUpdates(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external view 
        validFundraiserId(fundraiserId)
        returns (FundraiserUpdate[] memory updates, uint256 total) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        uint256[] storage updateIds = f.updateIds;
        total = updateIds.length;
        
        if (offset >= total) return (new FundraiserUpdate[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        updates = new FundraiserUpdate[](end - offset);
        
        for (uint256 i = 0; i < end - offset; i++) {
            uint256 updateIndex = total - 1 - offset - i;
            uint256 updateId = updateIds[updateIndex];
            updates[i] = fundraiserUpdates[updateId];
        }
    }

    function getFundraiserGallery(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external view 
        validFundraiserId(fundraiserId)
        returns (MediaItem[] memory media, uint256 total) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        total = f.gallery.length;
        
        if (offset >= total) return (new MediaItem[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        media = new MediaItem[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            media[i - offset] = f.gallery[i];
        }
    }

    function getDonors(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external view 
        validFundraiserId(fundraiserId)
        returns (address[] memory donors, uint256[] memory amounts, uint256 total) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        address[] storage allDonors = f.donors;
        total = allDonors.length;
        
        if (offset >= total) return (new address[](0), new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        donors = new address[](end - offset);
        amounts = new uint256[](end - offset);
        
        for (uint256 i = offset; i < end; i++) {
            donors[i - offset] = allDonors[i];
            amounts[i - offset] = f.donations[allDonors[i]];
        }
    }

    function getSuspensionInfo(uint256 fundraiserId) 
        external view 
        validFundraiserId(fundraiserId)
        returns (
            bool isSuspended,
            uint256 suspensionTime,
            string memory suspensionReason
        ) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        return (f.packed.isSuspended, f.packed.suspensionTime, f.suspensionReason);
    }

    // Legacy compatibility
    function getFundraiser(uint256 id) external view returns (
        uint256, address, address, uint256, uint256,
        uint256, bool, bool, uint256, bool
    ) {
        if (id == 0 || id > fundraiserCount) revert FundraiserNotFound(id);
        Fundraiser storage f = fundraisers[id];
        
        bool isFlexible = (f.packed.fundraiserType == uint8(FundraiserType.WITHOUT_GOAL));
        bool withdrawn = f.packed.fundsWithdrawn;
        bool closureInitiated = (f.packed.status == uint8(FundraiserStatus.REFUND_PERIOD));
        
        return (f.packed.id, f.creator, f.token, f.packed.goalAmount, f.packed.raisedAmount,
                f.packed.endDate, withdrawn, isFlexible, f.refundDeadline, closureInitiated);
    }

    function getProposal(uint256 proposalId) external view returns (
        uint256 id,
        string memory question,
        uint256 yesVotes,
        uint256 noVotes,
        uint256 endTime,
        address creator,
        string memory metadataHash
    ) {
        if (proposalId == 0 || proposalId > proposalCount) revert("Invalid proposal");
        Proposal storage p = proposals[proposalId];
        return (p.id, p.question, p.yesVotes, p.noVotes, p.endTime, p.creator, p.metadataHash);
    }

    function getUpdate(uint256 updateId) external view returns (
        uint256 id,
        uint256 fundraiserId,
        address author,
        string memory content,
        uint256 timestamp,
        uint8 updateType,
        bool isPinned,
        uint256 attachmentCount
    ) {
        if (updateId == 0 || updateId > updateCount) revert("Invalid update");
        FundraiserUpdate storage update = fundraiserUpdates[updateId];
        return (
            update.id,
            update.fundraiserId,
            update.author,
            update.content,
            update.timestamp,
            update.updateType,
            update.isPinned,
            update.attachments.length
        );
    }

    function getUpdateAttachments(uint256 updateId) external view returns (MediaItem[] memory) {
        if (updateId == 0 || updateId > updateCount) revert("Invalid update");
        return fundraiserUpdates[updateId].attachments;
    }

    // ========== SEARCH & FILTER FUNCTIONS ==========

    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256[] memory matchingIds = new uint256[](fundraiserCount);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].packed.status == status) {
                matchingIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = matchingIds[i];
        }
    }

    function getSuspendedFundraisers(uint256 offset, uint256 limit) 
        external view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256[] memory suspendedIds = new uint256[](fundraiserCount);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].packed.isSuspended) {
                suspendedIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = suspendedIds[i];
        }
    }

    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256[] memory creatorIds = new uint256[](fundraiserCount);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].creator == creator) {
                creatorIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = creatorIds[i];
        }
    }

    function getFundraisersByToken(address token, uint256 offset, uint256 limit) 
        external view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256[] memory tokenIds = new uint256[](fundraiserCount);
        uint256 count = 0;
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].token == token) {
                tokenIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = tokenIds[i];
        }
    }

    // ========== STATISTICS FUNCTIONS ==========

    function getPlatformStats() external view returns (
        uint256 totalFundraisers,
        uint256 totalProposals,
        uint256 totalUpdates,
        uint256 activeFundraisers,
        uint256 successfulFundraisers,
        uint256 suspendedFundraisers,
        uint256 totalWhitelistedTokens
    ) {
        uint256 active = 0;
        uint256 successful = 0;
        uint256 suspended = 0;
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].packed.status == uint8(FundraiserStatus.ACTIVE)) active++;
            if (fundraisers[i].packed.status == uint8(FundraiserStatus.SUCCESSFUL)) successful++;
            if (fundraisers[i].packed.isSuspended) suspended++;
        }
        
        return (
            fundraiserCount,
            proposalCount,
            updateCount,
            active,
            successful,
            suspended,
            whitelistedTokens.length
        );
    }

    function getFundraiserStats(uint256 fundraiserId) 
        external view 
        validFundraiserId(fundraiserId)
        returns (
            uint256 totalDonations,
            uint256 averageDonation,
            uint256 totalRefunds,
            uint256 mediaItems,
            uint256 updatesCount,
            uint256 daysActive,
            uint256 goalProgress
        ) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        
        totalDonations = f.packed.raisedAmount;
        averageDonation = f.donors.length > 0 ? f.packed.raisedAmount / f.donors.length : 0;
        
        uint256 refundCount = 0;
        for (uint256 i = 0; i < f.donors.length; i++) {
            if (f.hasRefunded[f.donors[i]]) {
                refundCount++;
            }
        }
        totalRefunds = refundCount;
        
        mediaItems = f.gallery.length;
        updatesCount = f.updateIds.length;
        
        uint256 startTime = block.timestamp - (f.packed.endDate - f.packed.originalEndDate + MAX_DURATION);
        daysActive = (block.timestamp - startTime) / 1 days;
        
        if (f.packed.goalAmount > 0) {
            goalProgress = (f.packed.raisedAmount * 10000) / f.packed.goalAmount;
            if (goalProgress > 10000) goalProgress = 10000;
        } else {
            goalProgress = 10000;
        }
        
        return (totalDonations, averageDonation, totalRefunds, mediaItems, updatesCount, daysActive, goalProgress);
    }

    // ========== SECURITY & EMERGENCY FUNCTIONS ==========

    function emergencyFreeze() external onlyOwner {
        emergencyPauseAll();
        
        for (uint256 i = 1; i <= fundraiserCount; i++) {
            if (fundraisers[i].packed.status == uint8(FundraiserStatus.ACTIVE) && !fundraisers[i].packed.isSuspended) {
                fundraisers[i].packed.isSuspended = true;
                fundraisers[i].packed.suspensionTime = uint32(block.timestamp);
                fundraisers[i].suspensionReason = "Emergency platform freeze";
                fundraisers[i].packed.status = uint8(FundraiserStatus.SUSPENDED);
                
                emit FundraiserSuspended(i, msg.sender, "Emergency platform freeze", block.timestamp);
            }
        }
    }

    function canRefund(uint256 fundraiserId, address donor) external view returns (bool, string memory reason) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) {
            return (false, "Invalid fundraiser");
        }
        
        Fundraiser storage f = fundraisers[fundraiserId];
        
        if (f.donations[donor] == 0) {
            return (false, "No donation found");
        }
        
        if (f.hasRefunded[donor]) {
            return (false, "Already refunded");
        }
        
        if (f.packed.isSuspended) {
            return (true, "Suspended fundraiser - unlimited refund");
        }
        
        if (f.packed.fundraiserType != uint8(FundraiserType.WITH_GOAL)) {
            return (false, "No refunds for WITHOUT_GOAL campaigns");
        }
        
        if (f.packed.status != uint8(FundraiserStatus.REFUND_PERIOD)) {
            return (false, "Not in refund period");
        }
        
        if (block.timestamp > f.refundDeadline) {
            return (false, "Refund deadline passed");
        }
        
        return (true, "Eligible for refund");
    }

    function batchUpdateStatuses(uint256[] calldata _fundraiserIds) external {
        for (uint256 i = 0; i < _fundraiserIds.length; i++) {
            if (_fundraiserIds[i] <= fundraiserCount && _fundraiserIds[i] > 0) {
                _updateFundraiserStatus(_fundraiserIds[i]);
            }
        }
    }

    // ========== GETTERS ==========
    
    function getAllFundraiserIds() external view returns (uint256[] memory) { return fundraiserIds; }
    function getAllProposalIds() external view returns (uint256[] memory) { return proposalIds; }
    function getWhitelistedTokens() external view returns (address[] memory) { return whitelistedTokens; }
    function getFundraiserCount() external view returns (uint256) { return fundraiserCount; }
    function getProposalCount() external view returns (uint256) { return proposalCount; }
    function getUpdateCount() external view returns (uint256) { return updateCount; }
    
    function canPropose(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
    }
    
    function canUpdate(uint256 fundraiserId, address updater) external view validFundraiserId(fundraiserId) returns (bool) {
        Fundraiser storage f = fundraisers[fundraiserId];
        return updater == f.creator || authorizedUpdaters[fundraiserId][updater];
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        return proposals[proposalId].hasVoted[voter];
    }

    function donationOf(uint256 id, address donor) external view returns (uint256) {
        if (id == 0 || id > fundraiserCount) return 0;
        return fundraisers[id].donations[donor];
    }

    // ========== UTILITY FUNCTIONS ==========

    function updateFundraiserStatus(uint256 fundraiserId) external validFundraiserId(fundraiserId) {
        _updateFundraiserStatus(fundraiserId);
    }

    receive() external payable {}
}