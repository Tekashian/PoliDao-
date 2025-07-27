// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPoliDaoStructs - FIXED VERSION WITHOUT DUPLICATES
 * @notice Centralized interface for all shared data structures across PoliDAO modules
 * @dev This interface defines common enums, structs, and events used by all modules
 * @dev FIXED: Removed all duplicate events, cleaned up structure definitions
 */
interface IPoliDaoStructs {
    
    // ========== ENUMS ==========
    
    enum FundraiserType { WITH_GOAL, WITHOUT_GOAL }
    
    enum FundraiserStatus { 
        ACTIVE, 
        SUCCESSFUL, 
        FAILED, 
        REFUND_PERIOD, 
        COMPLETED, 
        SUSPENDED
    }
    
    enum ProposalStatus {
        ACTIVE,
        PASSED,
        FAILED,
        EXECUTED
    }
    
    // ========== CORE STRUCTURES ==========
    
    /**
     * @notice Media item structure for fundraiser galleries and updates
     */
    struct MediaItem {
        string ipfsHash;
        uint8 mediaType;  // 0=image, 1=video, 2=audio, 3=document
        string filename;
        uint256 uploadTime;
        address uploader;
        string description;
    }
    
    /**
     * @notice Packed fundraiser data for gas optimization - ENHANCED
     */
    struct PackedFundraiserData {
        uint128 goalAmount;      
        uint128 raisedAmount;    
        uint64 endDate;          
        uint64 originalEndDate;  // ADDED: For tracking extensions
        uint32 id;               
        uint32 suspensionTime;   
        uint16 extensionCount;   // ADDED: Number of extensions
        uint8 fundraiserType;    
        uint8 status;            
        bool isSuspended;        
        bool fundsWithdrawn;
        bool isFlexible;         // Whether fundraiser allows partial withdrawals
    }
    
    /**
     * @notice Fundraiser creation data structure - ENHANCED
     */
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
        string location;        // ADDED: Location field
        bool isFlexible;        // Whether fundraiser should be flexible
    }
    
    /**
     * @notice Fundraiser update structure
     */
    struct FundraiserUpdate {
        uint256 id;
        uint256 fundraiserId;
        address author;
        string content;
        uint256 timestamp;
        uint8 updateType; // 0=regular, 1=important, 2=milestone
        bool isPinned;
        uint256[] mediaIds;
    }
    
    // ========== ANALYTICS STRUCTURES ==========
    
    /**
     * @notice Donor information structure
     */
    struct DonorInfo {
        address donor;
        uint256 amount;
        uint256 donationTime;
        bool hasRefunded;
    }
    
    /**
     * @notice Fundraiser analytics summary
     */
    struct FundraiserAnalytics {
        uint256 totalDonations;
        uint256 averageDonation;
        uint256 donorsCount;
        uint256 refundsCount;
        uint256 mediaItemsCount;
        uint256 updatesCount;
        uint256 daysActive;
        uint256 goalProgress; // In basis points
        uint256 velocity; // Donations per day
        bool hasReachedGoal;
        uint256 extensionCount; // ADDED
        string currentLocation; // ADDED
    }
    
    /**
     * @notice Extension information
     */
    struct ExtensionInfo {
        uint256 extensionCount;
        uint256 originalEndDate;
        uint256 currentEndDate;
        uint256 timeLeft;
        bool canExtend;
        string reason;
    }
    
    // ========== CORE EVENTS ==========
    
    // Fundraiser events
    event FundraiserCreated(
        uint256 indexed id, 
        address indexed creator, 
        address indexed token, 
        string title, 
        uint8 fundraiserType, 
        uint256 goalAmount, 
        uint256 endDate, 
        string location
    );
    
    event DonationMade(
        uint256 indexed fundraiserId, 
        address indexed donor, 
        address indexed token, 
        uint256 amount, 
        uint256 netAmount
    );
    
    event FundraiserStatusChanged(
        uint256 indexed id, 
        uint8 oldStatus, 
        uint8 newStatus
    );
    
    // ========== EXTENSION & LOCATION EVENTS ==========
    
    event FundraiserExtended(
        uint256 indexed id, 
        uint256 newEndDate, 
        uint256 extensionDays, 
        uint256 feePaid
    );
    
    event LocationUpdated(
        uint256 indexed id, 
        string oldLocation, 
        string newLocation
    );
    
    event ExtensionFeeSet(
        uint256 oldFee, 
        uint256 newFee
    );
    
    // ========== GOVERNANCE EVENTS ==========
    
    event ProposalCreated(
        uint256 indexed id, 
        string question, 
        uint256 endTime, 
        address indexed creator
    );
    
    event Voted(
        address indexed voter, 
        uint256 indexed proposalId, 
        bool support
    );
    
    // ========== MEDIA EVENTS ==========
    
    event MediaAdded(
        uint256 indexed fundraiserId, 
        string ipfsHash, 
        uint8 mediaType, 
        address uploader
    );
    
    event MediaRemoved(
        uint256 indexed fundraiserId, 
        uint256 mediaIndex, 
        string ipfsHash
    );
    
    // ========== UPDATE EVENTS ==========
    
    event UpdatePosted(
        uint256 indexed updateId, 
        uint256 indexed fundraiserId, 
        address indexed author, 
        string content, 
        uint8 updateType
    );
    
    event UpdatePinned(
        uint256 indexed updateId, 
        uint256 indexed fundraiserId
    );
    
    // ========== ANALYTICS EVENTS ==========
    
    event DonorsQueried(
        uint256 indexed fundraiserId,
        address indexed requester,
        uint256 offset,
        uint256 limit,
        uint256 totalDonors
    );
    
    event TopDonorsRetrieved(
        uint256 indexed fundraiserId,
        address indexed requester,
        uint256 limit,
        uint256 totalReturned
    );
    
    // ========== REFUND EVENTS ==========
    
    event RefundProcessed(
        uint256 indexed fundraiserId,
        address indexed donor,
        uint256 amount,
        uint256 commission
    );
    
    event ClosureInitiated(
        uint256 indexed fundraiserId,
        uint256 reclaimDeadline,
        address indexed initiatedBy
    );
    
    event FlexibleWithdrawal(
        uint256 indexed fundraiserId,
        address indexed creator,
        uint256 amount,
        uint256 totalWithdrawn
    );
    
    event DonationRefunded(
        uint256 indexed fundraiserId, 
        address indexed donor, 
        uint256 amountReturned, 
        uint256 commissionTaken
    );
    
    event FundsWithdrawn(
        uint256 indexed fundraiserId, 
        address indexed creator, 
        uint256 amountAfterCommission
    );
    
    // ========== WEB3 EVENTS ==========
    
    event DonationMadeWithPermit(
        uint256 indexed fundraiserId, 
        address indexed donor, 
        address indexed token, 
        uint256 amount
    );
    
    event DonationMadeWithMetaTx(
        uint256 indexed fundraiserId, 
        address indexed donor, 
        address indexed relayer, 
        uint256 amount
    );
    
    event BatchDonationExecuted(
        bytes32 indexed batchId, 
        address indexed donor, 
        uint256 totalAmount
    );
    
    // ========== MODULE MANAGEMENT EVENTS ==========
    
    event ModulesInitialized(
        address governance, 
        address media, 
        address updates, 
        address refunds
    );
    
    // ========== REFUND SPECIFIC EVENTS ==========
    
    event RefundsPausedForFundraiser(uint256 indexed fundraiserId);
    event RefundsUnpausedForFundraiser(uint256 indexed fundraiserId);
    event RefundCommissionSet(uint256 newCommission);
    
    // ========== ADMIN EVENTS ==========
    
    event FundraiserSuspended(
        uint256 indexed id, 
        address indexed suspendedBy, 
        string reason, 
        uint256 timestamp
    );
    
    event FundraiserUnsuspended(
        uint256 indexed id, 
        address indexed unsuspendedBy, 
        uint256 timestamp
    );
    
    event TokenWhitelisted(address indexed token);
    event CommissionWalletChanged(address indexed oldWallet, address indexed newWallet);
    
    // ========== SECURITY EVENTS ==========
    
    event SecurityLevelChanged(
        uint8 indexed oldLevel,
        uint8 indexed newLevel,
        address indexed initiator,
        string reason
    );
    
    event CircuitBreakerTriggered(
        string indexed functionName,
        address indexed caller,
        uint256 gasUsed,
        uint256 threshold,
        uint256 timestamp
    );
    
    event EmergencyPauseActivated(
        address indexed initiator,
        string reason,
        uint256 timestamp
    );
    
    event EmergencyPauseDeactivated(
        address indexed initiator,
        uint256 timestamp
    );
    
    event UserSuspended(
        address indexed user,
        address indexed suspendedBy,
        string reason,
        uint256 duration,
        uint256 timestamp
    );
    
    event UserUnsuspended(
        address indexed user,
        address indexed unsuspendedBy,
        uint256 timestamp
    );
    
    event TokenSuspended(
        address indexed token,
        address indexed suspendedBy,
        string reason,
        uint256 timestamp
    );
    
    event TokenUnsuspended(
        address indexed token,
        address indexed unsuspendedBy,
        uint256 timestamp
    );
    
    event SecurityGuardianAdded(
        address indexed guardian,
        address indexed addedBy,
        uint256 permissions
    );
    
    event SecurityGuardianRemoved(
        address indexed guardian,
        address indexed removedBy
    );
    
    event RateLimitExceeded(
        address indexed user,
        string functionName,
        uint256 attempts,
        uint256 limit,
        uint256 windowStart
    );
    
    // ========== COMMON ERRORS ==========
    
    error FundraiserNotFound(uint256 id);
    error UnauthorizedAccess(address caller, address required);
    error InvalidTokenAddress(address token);
    error InsufficientAmount(uint256 provided, uint256 required);
    error FundraiserSuspendedError(uint256 id);
    error DeadlineExpired(uint256 deadline, uint256 current);
    error AlreadyRefunded(address donor, uint256 fundraiserId);
    error InvalidFundraiserStatus(uint8 current, uint8 required);
    error DailyLimitExceeded(uint256 amount, uint256 limit);
    error ProposalNotFound(uint256 proposalId);
    error ProposalNotActive(uint256 proposalId);
    error AlreadyVoted(address voter, uint256 proposalId);
    error VotingEnded(uint256 proposalId);
    error EmptyQuestion();
    error InvalidProposalDuration(uint256 duration);
    error ReentrantCall();
    error ArrayLengthMismatch(uint256 length1, uint256 length2);
    error BatchAlreadyExecuted(bytes32 batchId);
    
    // ========== EXTENSION & LOCATION ERRORS ==========
    
    error InvalidExtensionPeriod(uint256 daysCount);
    error ExtensionNoticeToShort(uint256 timeLeft, uint256 required);
    error FundraiserCannotBeExtended(uint256 fundraiserId, string reason);
    error ExtensionFeePaymentFailed(uint256 required, address token);
    error InvalidLocation(string location);
    error LocationTooLong(uint256 length, uint256 maxLength);
    error ExtensionCountExceeded(uint256 current, uint256 max);
    
    // ========== ANALYTICS ERRORS ==========
    
    error InvalidDonorsQuery(uint256 fundraiserId, uint256 offset, uint256 limit);
    error DonorsDataNotAvailable(uint256 fundraiserId);
    error AnalyticsModuleNotSet();
    error UnauthorizedAnalyticsAccess(address caller);
    error DonorsCountMismatch(uint256 expected, uint256 actual);
    
    // ========== REFUND SPECIFIC ERRORS ==========
    
    error RefundNotAvailable(uint256 fundraiserId, address donor);
    error FlexibleFundraiserRefundDenied(uint256 fundraiserId);
    error ClosureNotInitiated(uint256 fundraiserId);
    error ClosureAlreadyInitiated(uint256 fundraiserId);
    error ReclaimPeriodExpired(uint256 fundraiserId);
    error RefundsPaused(uint256 fundraiserId);
    error InvalidRefundCommission(uint256 commission);
    error RefundsModuleNotSet();
    error OnlyRefundsModule(address caller);
    error RefundAlreadyProcessed(uint256 fundraiserId, address donor);
    error NoFundsToRefund(uint256 fundraiserId, address donor);
    error FlexibleFundraiserNotAllowed(uint256 fundraiserId);
    error InvalidFlexibleWithdrawal(uint256 fundraiserId);
    
    // ========== MODULE SPECIFIC ERRORS ==========
    
    error ModuleNotSet(string moduleName);
    error InvalidModuleAddress(address moduleAddress);
    error ModuleExecutionFailed(string moduleName);
    error UnauthorizedModuleAccess(address caller, address expectedModule);
    
    // ========== FEE MANAGEMENT ERRORS ==========
    
    error InvalidExtensionFee(uint256 fee);
    error InvalidFeeToken(address token);
    error FeeTokenNotSet();
    error CommissionTooHigh(uint256 commission, uint256 max);
    error InsufficientFeePayment(uint256 provided, uint256 required);
}