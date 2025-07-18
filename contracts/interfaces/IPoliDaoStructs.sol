// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPoliDaoStructs
 * @notice Centralized interface for all shared data structures across PoliDAO modules
 * @dev This interface defines common enums, structs, and events used by all modules
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
     * @notice Packed fundraiser data for gas optimization
     */
    struct PackedFundraiserData {
        uint128 goalAmount;      
        uint128 raisedAmount;    
        uint64 endDate;          
        uint64 originalEndDate;  
        uint32 id;               
        uint32 suspensionTime;   
        uint16 extensionCount;   
        uint8 fundraiserType;    
        uint8 status;            
        bool isSuspended;        
        bool fundsWithdrawn;     
    }
    
    /**
     * @notice Fundraiser creation data structure
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
        string location;
    }
    
    /**
     * @notice Governance proposal structure
     */
    struct Proposal {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
        bool exists;
        bool executed;
        uint256 createdAt;
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
    
    // ========== COMMON EVENTS ==========
    
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
    
    // Governance events
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
    
    // Media events
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
    
    // Update events
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
    
    // Additional events (moved from main contract to avoid duplication)
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
    
    event ModulesInitialized(address governance, address media, address updates);
    
    event FundraiserExtended(
        uint256 indexed id, 
        uint256 newEndDate, 
        uint256 extensionDays, 
        uint256 feePaid
    );
    
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
    
    event LocationUpdated(
        uint256 indexed id, 
        string oldLocation, 
        string newLocation
    );
    
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
    
    event ClosureInitiated(
        uint256 indexed fundraiserId, 
        uint256 reclaimDeadline
    );
    
    event TokenWhitelisted(address indexed token);
    event TokenRemoved(address indexed token);
    event DonationCommissionSet(uint256 newCommission);
    event SuccessCommissionSet(uint256 newCommission);
    event RefundCommissionSet(uint256 newCommission);
    event CommissionWalletChanged(address indexed oldWallet, address indexed newWallet);
    event FeeTokenSet(address indexed oldToken, address indexed newToken);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    
    // ========== COMMON ERRORS ==========
    // UWAGA: Te errory zostały przeniesione z głównego kontraktu aby uniknąć duplikacji
    
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
}