// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title PoliDAO Upgradeable - Ultra Modern Fundraising Platform
/// @notice Upgradeable version using OpenZeppelin Proxy Pattern
contract PoliDAOUpgradeable is 
    Initializable,
    OwnableUpgradeable, 
    PausableUpgradeable, 
    EIP712Upgradeable, 
    MulticallUpgradeable,
    UUPSUpgradeable 
{
    using ECDSAUpgradeable for bytes32;

    // ========== CUSTOM ERRORS ==========
    
    error FundraiserNotFound(uint256 id);
    error InsufficientAmount(uint256 provided, uint256 required);
    error UnauthorizedAccess(address caller, address required);
    error FundraiserSuspendedError(uint256 id);
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

    // ========== CONSTANTS ==========
    
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

    // REENTRANCY GUARD
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ========== ENUMS & STRUCTS ==========

    enum FundraiserType { WITH_GOAL, WITHOUT_GOAL }
    enum FundraiserStatus { 
        ACTIVE, 
        SUCCESSFUL, 
        FAILED, 
        REFUND_PERIOD, 
        COMPLETED, 
        SUSPENDED
    }

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

    // ========== STORAGE ==========

    uint256 public proposalCount;
    uint256 public fundraiserCount;
    uint256 public updateCount;
    uint256 private _status; // Reentrancy guard

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Fundraiser) private fundraisers;
    mapping(uint256 => FundraiserUpdate) private fundraiserUpdates;

    uint256[] private proposalIds;
    uint256[] private fundraiserIds;

    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public executedBatches;
    mapping(uint256 => uint256[4]) public mediaTypeCounts;

    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;
    mapping(address => uint256) private tokenIndex;

    uint256 public donationCommission;
    uint256 public successCommission;
    uint256 public refundCommission;
    address public commissionWallet;
    address public feeToken;

    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount;

    uint256 public maxDailyDonations;
    uint256 public maxUserDailyDonation;
    mapping(uint256 => uint256) public dailyDonationCount;
    mapping(address => mapping(uint256 => uint256)) public userDailyDonations;

    bool public votingPaused;
    bool public donationsPaused;
    bool public withdrawalsPaused;
    bool public updatesPaused;
    bool public mediaPaused;

    mapping(address => bool) public authorizedProposers;
    mapping(uint256 => mapping(address => bool)) public authorizedUpdaters;
    mapping(uint256 => mapping(address => bool)) public authorizedMediaManagers;

    // ========== EVENTS ==========

    event FundraiserCreated(uint256 indexed id, address indexed creator, address indexed token, 
                           string title, uint8 fundraiserType, uint256 goalAmount, uint256 endDate, string location);
    event DonationMade(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 amount, uint256 netAmount);
    event FundsWithdrawn(uint256 indexed fundraiserId, address indexed creator, uint256 amountAfterCommission);
    
    // ... (dodaj inne eventy według potrzeb)

    // ========== MODIFIERS ==========

    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier validFundraiserId(uint256 fundraiserId) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) {
            revert FundraiserNotFound(fundraiserId);
        }
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidTokenAddress(addr);
        _;
    }

    // ========== INITIALIZER (zamiastor constructor) ==========

    function initialize(
        address initialOwner,
        address _commissionWallet,
        address _feeToken
    ) public initializer {
        __Ownable_init(initialOwner);
        __Pausable_init();
        __EIP712_init("PoliDAO", "1");
        __Multicall_init();
        __UUPSUpgradeable_init();

        require(initialOwner != address(0), "Invalid owner");
        require(_commissionWallet != address(0), "Invalid commission wallet");
        require(_feeToken != address(0), "Invalid fee token");

        commissionWallet = _commissionWallet;
        feeToken = _feeToken;
        
        // Initialize default values
        _status = _NOT_ENTERED;
        maxDailyDonations = 1_000_000 * 10**18;
        maxUserDailyDonation = 100_000 * 10**6;
        
        // Default commissions (0%)
        donationCommission = 0;
        successCommission = 0;
        refundCommission = 0;
    }

    // ========== UPGRADE AUTHORIZATION ==========

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ========== CORE FUNCTIONS ==========

    function createFundraiser(FundraiserCreationData calldata data) 
        external 
        whenNotPaused 
        returns (uint256 fundraiserId)
    {
        if (bytes(data.title).length == 0 || bytes(data.title).length > MAX_TITLE_LENGTH) revert("Invalid title");
        if (bytes(data.description).length == 0 || bytes(data.description).length > MAX_DESCRIPTION_LENGTH) revert("Invalid description");
        if (data.endDate <= block.timestamp) revert("End date must be in future");
        if (!isTokenWhitelisted[data.token]) revert InvalidTokenAddress(data.token);
        
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
        
        fundraiserIds.push(fundraiserId);
        
        emit FundraiserCreated(
            fundraiserId, msg.sender, data.token, data.title, uint8(data.fundraiserType),
            data.goalAmount, data.endDate, data.location
        );
        
        return fundraiserId;
    }

    function donate(uint256 fundraiserId, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        if (f.packed.status != uint8(FundraiserStatus.ACTIVE)) {
            revert InvalidFundraiserStatus(f.packed.status, uint8(FundraiserStatus.ACTIVE));
        }
        if (amount == 0) revert InsufficientAmount(amount, 1);
        
        IERC20Upgradeable token = IERC20Upgradeable(f.token);
        
        uint256 commission = (amount * donationCommission) / PRECISION;
        uint256 netAmount = amount - commission;
        
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += netAmount;
        f.packed.raisedAmount += uint128(netAmount);
        
        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission transfer failed");
        }
        
        emit DonationMade(fundraiserId, msg.sender, f.token, amount, netAmount);
    }

    // ========== ADMIN FUNCTIONS ==========

    function whitelistToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        require(!isTokenWhitelisted[token], "Already whitelisted");
        
        isTokenWhitelisted[token] = true;
        tokenIndex[token] = whitelistedTokens.length;
        whitelistedTokens.push(token);
    }

    function setCommissionWallet(address newWallet) external onlyOwner validAddress(newWallet) {
        commissionWallet = newWallet;
    }

    function setDonationCommission(uint256 bps) external onlyOwner {
        require(bps <= MAX_COMMISSION, "Max 100%");
        donationCommission = bps;
    }

    // ========== VIEW FUNCTIONS ==========

    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

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

    // ========== RECEIVE ==========

    receive() external payable {}
}