// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PoliDAO v3.5 - Enhanced Governance & Fundraising Platform with Multimedia
/// @notice Smart contract with authorization-only governance, ERC20 fundraising, and multimedia support
/// @dev All original functionalities preserved + multimedia support added after fundraiser creation
/// @author PoliDAO Team
/// @custom:security-contact security@polidao.io
contract PoliDAO is Ownable, ReentrancyGuard, Pausable {
    // ========== CUSTOM ERRORS ==========
    
    error NotAuthorized();
    error InvalidDuration(uint256 duration);
    error QuestionTooLong(uint256 length);
    error EmptyQuestion();
    error InvalidToken(address token);
    error NotAContract(address token);
    error DailyLimitExceeded(uint256 requested, uint256 limit);
    error InvalidRecipient(address recipient);
    error TransferFailed();
    error PaginationError(uint256 offset, uint256 total);
    error UpdateTooLong(uint256 length);
    error EmptyUpdate();
    error InvalidUpdateId(uint256 updateId);
    error NotFundraiserCreator();
    error InvalidIPFSHash(string hash);
    error MediaLimitExceeded(uint256 provided, uint256 limit);
    error InvalidMediaType(uint8 mediaType);

    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_QUESTION_LENGTH = 500;
    uint256 public constant MAX_UPDATE_LENGTH = 1000;
    uint256 public constant MAX_IPFS_HASH_LENGTH = 100;
    uint256 public constant RECLAIM_PERIOD = 14 days;
    uint256 public constant MAX_DONORS_BATCH = 100;
    uint256 public constant MAX_UPDATES_BATCH = 50;
    uint256 private constant PRECISION = 10_000; // For basis points calculations
    uint256 private constant MAX_COMMISSION = 10_000; // 100% in basis points
    
    // MULTIMEDIA LIMITS (FREE for everyone)
    uint256 public constant MAX_MEDIA_BATCH = 20;              // 20 files at once
    uint256 public constant MAX_TOTAL_MEDIA = 200;             // 200 total per fundraiser
    uint256 public constant MAX_IMAGES = 100;                  // 100 images
    uint256 public constant MAX_VIDEOS = 30;                   // 30 videos 
    uint256 public constant MAX_AUDIO = 20;                    // 20 audio files
    uint256 public constant MAX_DOCUMENTS = 50;                // 50 documents

    // ========== MULTIMEDIA STRUCTURES ==========

    /// @notice Media item structure for IPFS integration
    struct MediaItem {
        string ipfsHash;        // IPFS file hash
        uint8 mediaType;        // 0=image, 1=video, 2=audio, 3=document
        string filename;        // Original filename
        uint256 fileSize;       // Size in bytes
        uint256 uploadTime;     // When added
        address uploader;       // Who added it
        string description;     // File description
    }

    /// @notice Update with multimedia support
    struct FundraiserUpdate {
        uint256 id;
        uint256 fundraiserId;
        address author;
        string content;         // Update content
        uint256 timestamp;
        bool isPinned;
        uint8 updateType;       // 0=general, 1=milestone, 2=urgent, 3=final
        MediaItem[] attachments; // Attached multimedia
    }

    // ========== ENHANCED STRUCTURES ==========

    struct Proposal {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
        string metadataHash;    // IPFS hash for additional data
        mapping(address => bool) hasVoted;
    }

    struct ProposalSummary {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
        string metadataHash;
    }

    struct Fundraiser {
        uint256 id;
        address creator;
        address token;
        uint256 target;
        uint256 raised;
        uint256 endTime;
        bool withdrawn;
        bool isFlexible;
        uint256 reclaimDeadline;
        bool closureInitiated;
        string metadataHash;    // IPFS hash for metadata
        MediaItem[] gallery;    // Multimedia gallery
        mapping(address => uint256) donations;
        mapping(address => bool) refunded;
        address[] donors;
        uint256[] updateIds;    // Update IDs
        uint256 pinnedUpdateId; // Pinned update ID
    }

    struct FundraiserSummary {
        uint256 id;
        address creator;
        address token;
        uint256 target;
        uint256 raised;
        uint256 endTime;
        bool isFlexible;
        bool closureInitiated;
        uint256 updateCount;
        uint256 pinnedUpdateId;
        uint256 mediaCount;
        string metadataHash;
    }

    // ========== STORAGE ==========

    uint256 public proposalCount;
    uint256 public fundraiserCount;
    uint256 public updateCount;

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Fundraiser) private fundraisers;
    mapping(uint256 => FundraiserUpdate) private fundraiserUpdates;

    uint256[] private proposalIds;
    uint256[] private fundraiserIds;

    // Media tracking per fundraiser [images, videos, audio, documents]
    mapping(uint256 => uint256[4]) public mediaTypeCounts;

    // Token management
    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;
    mapping(address => uint256) private tokenIndex;

    // Commission system (ONLY standard commissions - NO multimedia bonus)
    uint256 public donationCommission;      // Donation commission
    uint256 public successCommission;       // Withdrawal commission
    uint256 public refundCommission;        // Refund commission
    address public commissionWallet;

    // Refund tracking
    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount;

    // Circuit breaker - ✅ FIX: Better number formatting
    uint256 public maxDailyDonations = 1_000_000 * 10**18;
    mapping(uint256 => uint256) public dailyDonationCount;

    // Selective pausing - ✅ FIX: Explicit initialization
    bool public votingPaused = false;
    bool public donationsPaused = false;
    bool public withdrawalsPaused = false;
    bool public updatesPaused = false;      // ✅ FIX: Initialize to false
    bool public mediaPaused = false;

    // Authorization system
    mapping(address => bool) public authorizedProposers;
    mapping(uint256 => mapping(address => bool)) public authorizedUpdaters;
    mapping(uint256 => mapping(address => bool)) public authorizedMediaManagers;

    // Multimedia flags
    mapping(uint256 => bool) public hasMultimedia;

    // ========== EVENTS ==========

    // Original events
    event ProposalCreated(uint256 indexed id, string question, uint256 endTime, address indexed creator);
    event Voted(address indexed voter, uint256 indexed proposalId, bool support);
    event FundraiserCreated(uint256 indexed id, address indexed creator, address token, uint256 target, uint256 endTime, bool isFlexible);
    event DonationMade(uint256 indexed id, address indexed donor, uint256 amount);
    event DonationRefunded(uint256 indexed id, address indexed donor, uint256 amountReturned, uint256 commissionTaken);
    event FundsWithdrawn(uint256 indexed id, address indexed creator, uint256 amountAfterCommission);
    event TokenWhitelisted(address indexed token);
    event TokenRemoved(address indexed token);
    event ClosureInitiated(uint256 indexed id, uint256 reclaimDeadline);
    event DonationCommissionSet(uint256 newCommission);
    event SuccessCommissionSet(uint256 newCommission);
    event RefundCommissionSet(uint256 newCommission);
    event MaxDailyDonationsSet(uint256 newLimit);
    event VotingPauseToggled(bool paused);
    event DonationsPauseToggled(bool paused);
    event WithdrawalsPauseToggled(bool paused);
    event ProposerAuthorized(address indexed proposer);
    event ProposerRevoked(address indexed proposer);
    event CommissionWalletChanged(address indexed oldWallet, address indexed newWallet);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    
    // New multimedia events
    event UpdatePosted(uint256 indexed updateId, uint256 indexed fundraiserId, address indexed author, string content, uint8 updateType);
    event UpdatePinned(uint256 indexed updateId, uint256 indexed fundraiserId);
    event UpdateUnpinned(uint256 indexed fundraiserId, uint256 indexed oldUpdateId);
    event MediaAdded(uint256 indexed fundraiserId, string ipfsHash, uint8 mediaType, string filename, address uploader);
    event MediaRemoved(uint256 indexed fundraiserId, uint256 mediaIndex, string ipfsHash);
    event MultimediaActivated(uint256 indexed fundraiserId);
    event UpdaterAuthorized(uint256 indexed fundraiserId, address indexed updater);
    event UpdaterRevoked(uint256 indexed fundraiserId, address indexed updater);
    event MediaManagerAuthorized(uint256 indexed fundraiserId, address indexed manager);
    event MediaManagerRevoked(uint256 indexed fundraiserId, address indexed manager);
    event MediaPauseToggled(bool paused);

    // ========== MODIFIERS ==========

    modifier whenVotingNotPaused() {
        require(!votingPaused, "Voting paused");
        _;
    }

    modifier whenDonationsNotPaused() {
        require(!donationsPaused, "Donations paused");
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        require(!withdrawalsPaused, "Withdrawals paused");
        _;
    }

    modifier whenUpdatesNotPaused() {
        require(!updatesPaused, "Updates paused");
        _;
    }

    modifier whenMediaNotPaused() {
        require(!mediaPaused, "Media operations paused");
        _;
    }

    modifier onlyAuthorizedProposer() {
        if (msg.sender != owner() && !authorizedProposers[msg.sender]) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyFundraiserCreatorOrAuthorized(uint256 fundraiserId) {
        if (fundraiserId > fundraiserCount || fundraiserId == 0) {
            revert InvalidUpdateId(fundraiserId);
        }
        
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator && !authorizedUpdaters[fundraiserId][msg.sender]) {
            revert NotFundraiserCreator();
        }
        _;
    }

    modifier onlyMediaManager(uint256 fundraiserId) {
        if (fundraiserId > fundraiserCount || fundraiserId == 0) {
            revert InvalidUpdateId(fundraiserId);
        }
        
        Fundraiser storage f = fundraisers[fundraiserId];
        if (msg.sender != f.creator && 
            !authorizedUpdaters[fundraiserId][msg.sender] && 
            !authorizedMediaManagers[fundraiserId][msg.sender]) {
            revert NotFundraiserCreator();
        }
        _;
    }

    modifier validFundraiserId(uint256 fundraiserId) {
        if (fundraiserId > fundraiserCount || fundraiserId == 0) {
            revert InvalidUpdateId(fundraiserId);
        }
        _;
    }

    modifier validIPFSHash(string memory hash) {
        if (bytes(hash).length > MAX_IPFS_HASH_LENGTH) {
            revert InvalidIPFSHash(hash);
        }
        _;
    }

    modifier validMediaType(uint8 mediaType) {
        if (mediaType > 3) {
            revert InvalidMediaType(mediaType);
        }
        _;
    }

    modifier circuitBreaker(uint256 amount) {
        if (amount > maxDailyDonations / 10) {
            uint256 today = block.timestamp / 1 days;
            if (dailyDonationCount[today] + amount > maxDailyDonations) {
                revert DailyLimitExceeded(dailyDonationCount[today] + amount, maxDailyDonations);
            }
            dailyDonationCount[today] += amount;
        }
        _;
    }

    modifier validAddress(address addr) {
        if (addr == address(0)) revert InvalidRecipient(addr);
        _;
    }

    // ========== CONSTRUCTOR ==========

    /// @notice Initializes the PoliDAO contract
    /// @param initialOwner Address that will own the contract
    /// @param _commissionWallet Address that will receive commission payments
    constructor(address initialOwner, address _commissionWallet) 
        Ownable(initialOwner) 
        validAddress(initialOwner)
        validAddress(_commissionWallet)
    {
        commissionWallet = _commissionWallet;
    }

    // ========== ADMIN FUNCTIONS ==========

    /// @notice Pauses all contract operations
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses all contract operations
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Toggles voting functionality
    function toggleVotingPause() external onlyOwner {
        votingPaused = !votingPaused;
        emit VotingPauseToggled(votingPaused);
    }

    /// @notice Toggles donation functionality
    function toggleDonationsPause() external onlyOwner {
        donationsPaused = !donationsPaused;
        emit DonationsPauseToggled(donationsPaused);
    }

    /// @notice Toggles withdrawal functionality
    function toggleWithdrawalsPause() external onlyOwner {
        withdrawalsPaused = !withdrawalsPaused;
        emit WithdrawalsPauseToggled(withdrawalsPaused);
    }

    /// @notice Toggle multimedia operations
    function toggleMediaPause() external onlyOwner {
        mediaPaused = !mediaPaused;
        emit MediaPauseToggled(mediaPaused);
    }

    /// @notice Emergency pause for all operations
    function emergencyPauseAll() external onlyOwner {
        _pause();
        votingPaused = true;
        donationsPaused = true;
        withdrawalsPaused = true;
        mediaPaused = true;
        
        emit VotingPauseToggled(true);
        emit DonationsPauseToggled(true);
        emit WithdrawalsPauseToggled(true);
        emit MediaPauseToggled(true);
    }

    /// @notice Changes the commission wallet address
    /// @param newWallet New wallet address for receiving commissions
    function setCommissionWallet(address newWallet) external onlyOwner validAddress(newWallet) {
        address oldWallet = commissionWallet;
        commissionWallet = newWallet;
        emit CommissionWalletChanged(oldWallet, newWallet);
    }

    /// @notice Emergency function to withdraw stuck tokens
    /// @param token Token address (address(0) for ETH)
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyOwner 
        validAddress(to) 
    {
        if (token == address(0)) {
            // ETH withdrawal
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ✅ FIX: Add return value check for ERC20 transfer
            require(IERC20(token).transfer(to, amount), "Emergency transfer failed");
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }

    /// @notice Authorize address to create proposals
    /// @param proposer Address to authorize
    function authorizeProposer(address proposer) external onlyOwner validAddress(proposer) {
        authorizedProposers[proposer] = true;
        emit ProposerAuthorized(proposer);
    }

    /// @notice Revoke proposal creation authorization
    /// @param proposer Address to revoke authorization from
    function revokeProposer(address proposer) external onlyOwner {
        authorizedProposers[proposer] = false;
        emit ProposerRevoked(proposer);
    }

    /// @notice Set maximum daily donation limit
    /// @param newLimit New daily limit
    function setMaxDailyDonations(uint256 newLimit) external onlyOwner {
        maxDailyDonations = newLimit;
        emit MaxDailyDonationsSet(newLimit);
    }

    /// @notice Set donation commission rate
    /// @param bps Commission rate in basis points (1 bps = 0.01%)
    function setDonationCommission(uint256 bps) external onlyOwner {
        require(bps <= MAX_COMMISSION, "Max 100%");
        donationCommission = bps;
        emit DonationCommissionSet(bps);
    }

    /// @notice Set success commission rate
    /// @param bps Commission rate in basis points (1 bps = 0.01%)
    function setSuccessCommission(uint256 bps) external onlyOwner {
        require(bps <= MAX_COMMISSION, "Max 100%");
        successCommission = bps;
        emit SuccessCommissionSet(bps);
    }

    /// @notice Set refund commission rate
    /// @param bps Commission rate in basis points (1 bps = 0.01%)
    function setRefundCommission(uint256 bps) external onlyOwner {
        require(bps <= MAX_COMMISSION, "Max 100%");
        refundCommission = bps;
        emit RefundCommissionSet(bps);
    }

    /// @notice Add token to whitelist
    /// @param token ERC20 token address to whitelist
    function whitelistToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidToken(token);
        if (token.code.length == 0) revert NotAContract(token);
        
        // ✅ FIX: Proper try-catch for return value with supply validation
        try IERC20(token).totalSupply() returns (uint256 supply) {
            // Token is ERC20 compatible, supply check passed
            require(supply > 0, "Token has zero supply");
        } catch {
            revert InvalidToken(token);
        }
        
        require(!isTokenWhitelisted[token], "Already whitelisted");
        
        isTokenWhitelisted[token] = true;
        tokenIndex[token] = whitelistedTokens.length;
        whitelistedTokens.push(token);
        
        emit TokenWhitelisted(token);
    }

    /// @notice Remove token from whitelist
    /// @param token Token address to remove
    function removeWhitelistToken(address token) external onlyOwner {
        require(isTokenWhitelisted[token], "Not whitelisted");
        
        isTokenWhitelisted[token] = false;
        
        uint256 index = tokenIndex[token];
        address lastToken = whitelistedTokens[whitelistedTokens.length - 1];
        
        // Swap with last element and pop
        whitelistedTokens[index] = lastToken;
        tokenIndex[lastToken] = index;
        
        whitelistedTokens.pop();
        delete tokenIndex[token];
        
        emit TokenRemoved(token);
    }

    // ========== GOVERNANCE ==========

    /// @notice Create new proposal (authorization required)
    /// @param question Proposal question (1-500 characters)
    /// @param duration Voting duration in seconds (max 365 days)
    /// @dev Functions using block.timestamp for time comparisons
    /// Note: block.timestamp has ~15 second tolerance by miners
    /// This is acceptable for fundraiser durations (hours/days)
    function createProposal(string calldata question, uint256 duration) 
        external 
        whenNotPaused 
        whenVotingNotPaused 
        onlyAuthorizedProposer
    {
        if (bytes(question).length == 0) revert EmptyQuestion();
        if (bytes(question).length > MAX_QUESTION_LENGTH) {
            revert QuestionTooLong(bytes(question).length);
        }
        if (duration > MAX_DURATION) {
            revert InvalidDuration(duration);
        }

        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.question = question;
        p.endTime = block.timestamp + duration;
        p.creator = msg.sender;
        p.metadataHash = ""; // Empty by default

        proposalIds.push(proposalCount);

        emit ProposalCreated(p.id, question, p.endTime, msg.sender);
    }

    /// @notice Vote on a proposal
    /// @param proposalId ID of the proposal
    /// @param support True for "yes", false for "no"
    function vote(uint256 proposalId, bool support) 
        external 
        whenNotPaused 
        whenVotingNotPaused 
    {
        Proposal storage p = proposals[proposalId];
        
        require(proposalId <= proposalCount && proposalId > 0, "Invalid proposal");
        // ✅ DOCUMENTED: 15s tolerance acceptable for voting periods
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!p.hasVoted[msg.sender], "Already voted");

        p.hasVoted[msg.sender] = true;
        if (support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }

        emit Voted(msg.sender, proposalId, support);
    }

    // ========== FUNDRAISING ==========

    /// @notice Create new fundraiser
    /// @param token Whitelisted ERC20 token address
    /// @param target Target amount (0 for flexible fundraiser)
    /// @param duration Duration in seconds
    /// @param isFlexible True for flexible mode, false for target mode
    function createFundraiser(address token, uint256 target, uint256 duration, bool isFlexible)
        external
        whenNotPaused
    {
        require(isTokenWhitelisted[token], "Token not allowed");
        if (duration > MAX_DURATION) {
            revert InvalidDuration(duration);
        }

        fundraiserCount++;
        Fundraiser storage f = fundraisers[fundraiserCount];
        f.id = fundraiserCount;
        f.creator = msg.sender;
        f.token = token;
        f.target = target;
        f.endTime = block.timestamp + duration;
        f.isFlexible = isFlexible;
        f.metadataHash = ""; // Empty by default

        fundraiserIds.push(fundraiserCount);

        emit FundraiserCreated(f.id, msg.sender, token, target, f.endTime, isFlexible);
    }

    /// @notice Donation with standard commission (NO multimedia bonus)
    /// @param id Fundraiser ID
    /// @param amount Amount to donate
    function donate(uint256 id, uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        whenDonationsNotPaused 
        circuitBreaker(amount)
    {
        Fundraiser storage f = fundraisers[id];
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        require(block.timestamp <= f.endTime, "Fundraiser ended");
        require(amount > 0, "Zero amount");

        IERC20 token = IERC20(f.token);
        
        // ✅ FIX: Calculate commission before external calls
        uint256 commission = (amount * donationCommission) / PRECISION;
        uint256 netAmount = amount - commission;

        // External call
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        // ✅ FIX: Update state after calculating but before commission transfer
        f.raised += netAmount;
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += netAmount;

        // Send commission after state updates
        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission transfer failed");
        }

        emit DonationMade(id, msg.sender, netAmount);
    }

    /// @notice Refund donation
    /// @param id Fundraiser ID
    function refund(uint256 id) external nonReentrant whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        require(!f.refunded[msg.sender], "Already refunded");

        uint256 donated = f.donations[msg.sender];
        require(donated > 0, "No donation found");

        if (!f.isFlexible) {
            require(block.timestamp > f.endTime, "Fundraiser still active");
            require(f.raised < f.target || f.closureInitiated, "No refunds available");
            if (f.closureInitiated) {
                require(block.timestamp <= f.reclaimDeadline, "Reclaim period ended");
            }
        }

        uint256 period = block.timestamp / 30 days;
        monthlyRefundCount[msg.sender][period]++;

        uint256 commissionAmount = 0;
        if (monthlyRefundCount[msg.sender][period] > 1 && refundCommission > 0) {
            commissionAmount = (donated * refundCommission) / PRECISION;
        }

        f.refunded[msg.sender] = true;
        f.raised -= donated;
        f.donations[msg.sender] = 0;

        IERC20 token = IERC20(f.token);
        if (commissionAmount > 0) {
            require(token.transfer(commissionWallet, commissionAmount), "Commission transfer failed");
        }
        require(token.transfer(msg.sender, donated - commissionAmount), "Refund transfer failed");

        emit DonationRefunded(id, msg.sender, donated - commissionAmount, commissionAmount);
    }

    /// @notice Withdraw with standard commission (NO multimedia bonus)
    /// @param id Fundraiser ID
    function withdraw(uint256 id) 
        external 
        nonReentrant 
        whenNotPaused 
        whenWithdrawalsNotPaused 
    {
        Fundraiser storage f = fundraisers[id];
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        require(msg.sender == f.creator, "Not creator");
        require(!f.withdrawn || f.isFlexible, "Already withdrawn");

        IERC20 token = IERC20(f.token);

        if (f.isFlexible) {
            uint256 amount = f.raised;
            require(amount > 0, "No funds");
            f.raised = 0;
            require(token.transfer(f.creator, amount), "Transfer failed");
            emit FundsWithdrawn(id, f.creator, amount);
            return;
        }

        if (f.raised >= f.target) {
            require(!f.withdrawn, "Already withdrawn");
            f.withdrawn = true;
        } else {
            require(block.timestamp > f.endTime, "Too early");
            require(f.closureInitiated && block.timestamp >= f.reclaimDeadline, "Not ready");
            f.withdrawn = true;
        }

        // Calculate ONLY standard success commission - NO multimedia bonus
        uint256 commission = (f.raised * successCommission) / PRECISION;
        uint256 netAmount = f.raised - commission;
        f.raised = 0;

        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission transfer failed");
        }
        require(token.transfer(f.creator, netAmount), "Transfer failed");

        emit FundsWithdrawn(id, f.creator, netAmount);
    }

    /// @notice Initiate closure period for failed fundraiser
    /// @param id Fundraiser ID
    function initiateClosure(uint256 id) external whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(msg.sender == f.creator, "Not creator");
        require(!f.isFlexible, "Only non-flexible fundraisers");
        require(block.timestamp > f.endTime, "Too early");
        require(!f.closureInitiated, "Already initiated");

        f.closureInitiated = true;
        f.reclaimDeadline = block.timestamp + RECLAIM_PERIOD;

        emit ClosureInitiated(id, f.reclaimDeadline);
    }

    // ========== MULTIMEDIA MANAGEMENT ==========

    /// @notice Add multimedia to existing fundraiser
    /// @param fundraiserId ID of fundraiser
    /// @param mediaItems Array of media to add
    function addMultimediaToFundraiser(uint256 fundraiserId, MediaItem[] calldata mediaItems)
        external
        whenNotPaused
        whenMediaNotPaused
        validFundraiserId(fundraiserId)
        onlyMediaManager(fundraiserId)
    {
        if (mediaItems.length > MAX_MEDIA_BATCH) {
            revert MediaLimitExceeded(mediaItems.length, MAX_MEDIA_BATCH);
        }

        Fundraiser storage f = fundraisers[fundraiserId];
        uint256[4] storage typeCounts = mediaTypeCounts[fundraiserId];
        uint256 totalCurrent = f.gallery.length;
        
        // Check total limit
        if (totalCurrent + mediaItems.length > MAX_TOTAL_MEDIA) {
            revert MediaLimitExceeded(totalCurrent + mediaItems.length, MAX_TOTAL_MEDIA);
        }

        bool wasEmpty = (totalCurrent == 0);

        for (uint256 i = 0; i < mediaItems.length; i++) {
            MediaItem memory item = mediaItems[i];
            
            // Validate media type
            if (item.mediaType > 3) {
                revert InvalidMediaType(item.mediaType);
            }
            
            // Validate IPFS hash
            if (bytes(item.ipfsHash).length == 0) {
                revert InvalidIPFSHash(item.ipfsHash);
            }
            
            // Check type-specific limits
            uint256 typeLimit = getMediaTypeLimit(item.mediaType);
            if (typeCounts[item.mediaType] + 1 > typeLimit) {
                revert MediaLimitExceeded(typeCounts[item.mediaType] + 1, typeLimit);
            }
            
            // Create media item with metadata
            MediaItem memory newItem = MediaItem({
                ipfsHash: item.ipfsHash,
                mediaType: item.mediaType,
                filename: item.filename,
                fileSize: item.fileSize,
                uploadTime: block.timestamp,
                uploader: msg.sender,
                description: item.description
            });
            
            // Add to gallery
            f.gallery.push(newItem);
            typeCounts[item.mediaType]++;
            
            emit MediaAdded(fundraiserId, item.ipfsHash, item.mediaType, item.filename, msg.sender);
        }

        // Mark as multimedia fundraiser (for tracking purposes only)
        if (wasEmpty && mediaItems.length > 0) {
            hasMultimedia[fundraiserId] = true;
            emit MultimediaActivated(fundraiserId);
        }
    }

    /// @notice Remove media from fundraiser
    /// @param fundraiserId ID of fundraiser
    /// @param mediaIndex Index of media to remove
    function removeMediaFromFundraiser(uint256 fundraiserId, uint256 mediaIndex)
        external
        whenNotPaused
        whenMediaNotPaused
        validFundraiserId(fundraiserId)
        onlyMediaManager(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(mediaIndex < f.gallery.length, "Invalid media index");
        
        MediaItem storage mediaToRemove = f.gallery[mediaIndex];
        uint8 mediaType = mediaToRemove.mediaType;
        string memory ipfsHash = mediaToRemove.ipfsHash;
        
        // Update counters
        mediaTypeCounts[fundraiserId][mediaType]--;
        
        // Remove from array (swap with last and pop)
        f.gallery[mediaIndex] = f.gallery[f.gallery.length - 1];
        f.gallery.pop();
        
        emit MediaRemoved(fundraiserId, mediaIndex, ipfsHash);
    }

    /// @notice Authorize address to manage media for fundraiser
    /// @param fundraiserId ID of fundraiser
    /// @param manager Address to authorize
    function authorizeMediaManager(uint256 fundraiserId, address manager)
        external
        whenNotPaused
        validFundraiserId(fundraiserId)
        validAddress(manager)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        
        authorizedMediaManagers[fundraiserId][manager] = true;
        emit MediaManagerAuthorized(fundraiserId, manager);
    }

    /// @notice Revoke media management authorization
    /// @param fundraiserId ID of fundraiser
    /// @param manager Address to revoke
    function revokeMediaManager(uint256 fundraiserId, address manager)
        external
        whenNotPaused
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        
        authorizedMediaManagers[fundraiserId][manager] = false;
        emit MediaManagerRevoked(fundraiserId, manager);
    }

    // ========== UPDATE SYSTEM WITH MULTIMEDIA ==========

    /// @notice Post update with multimedia attachments
    /// @param fundraiserId Fundraiser ID
    /// @param content Text content
    /// @param updateType Type of update
    /// @param attachments Multimedia attachments
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
        if (bytes(content).length > MAX_UPDATE_LENGTH) {
            revert UpdateTooLong(bytes(content).length);
        }
        if (attachments.length > 10) { // Max 10 attachments per update
            revert MediaLimitExceeded(attachments.length, 10);
        }

        updateCount++;
        FundraiserUpdate storage update = fundraiserUpdates[updateCount];
        update.id = updateCount;
        update.fundraiserId = fundraiserId;
        update.author = msg.sender;
        update.content = content;
        update.timestamp = block.timestamp;
        update.updateType = updateType;

        // Add attachments
        for (uint256 i = 0; i < attachments.length; i++) {
            MediaItem memory attachment = attachments[i];
            attachment.uploadTime = block.timestamp;
            attachment.uploader = msg.sender;
            update.attachments.push(attachment);
        }

        Fundraiser storage f = fundraisers[fundraiserId];
        f.updateIds.push(updateCount);

        emit UpdatePosted(updateCount, fundraiserId, msg.sender, content, updateType);
    }

    /// @notice Post simple text update (legacy support)
    function postUpdate(uint256 fundraiserId, string calldata content) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
        validFundraiserId(fundraiserId)
        onlyFundraiserCreatorOrAuthorized(fundraiserId)
    {
        if (bytes(content).length > MAX_UPDATE_LENGTH) {
            revert UpdateTooLong(bytes(content).length);
        }

        updateCount++;
        FundraiserUpdate storage update = fundraiserUpdates[updateCount];
        update.id = updateCount;
        update.fundraiserId = fundraiserId;
        update.author = msg.sender;
        update.content = content;
        update.timestamp = block.timestamp;
        update.updateType = 0; // general update

        Fundraiser storage f = fundraisers[fundraiserId];
        f.updateIds.push(updateCount);

        emit UpdatePosted(updateCount, fundraiserId, msg.sender, content, 0);
    }

    /// @notice Pin update to top
    function pinUpdate(uint256 updateId) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
    {
        require(updateId <= updateCount && updateId > 0, "Invalid update");
        
        FundraiserUpdate storage update = fundraiserUpdates[updateId];
        uint256 fundraiserId = update.fundraiserId;
        
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");

        uint256 oldPinnedId = f.pinnedUpdateId;
        if (oldPinnedId != 0) {
            fundraiserUpdates[oldPinnedId].isPinned = false;
            emit UpdateUnpinned(fundraiserId, oldPinnedId);
        }

        f.pinnedUpdateId = updateId;
        update.isPinned = true;

        emit UpdatePinned(updateId, fundraiserId);
    }

    /// @notice Unpin current pinned update
    function unpinUpdate(uint256 fundraiserId) 
        external 
        whenNotPaused 
        whenUpdatesNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        require(f.pinnedUpdateId != 0, "No pinned update");

        uint256 oldPinnedId = f.pinnedUpdateId;
        f.pinnedUpdateId = 0;
        fundraiserUpdates[oldPinnedId].isPinned = false;

        emit UpdateUnpinned(fundraiserId, oldPinnedId);
    }

    /// @notice Authorize updater
    function authorizeUpdater(uint256 fundraiserId, address updater) 
        external 
        whenNotPaused 
        validFundraiserId(fundraiserId)
        validAddress(updater)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        
        authorizedUpdaters[fundraiserId][updater] = true;
        emit UpdaterAuthorized(fundraiserId, updater);
    }

    /// @notice Revoke updater authorization
    function revokeUpdater(uint256 fundraiserId, address updater) 
        external 
        whenNotPaused 
        validFundraiserId(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        
        authorizedUpdaters[fundraiserId][updater] = false;
        emit UpdaterRevoked(fundraiserId, updater);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Get media type limit
    function getMediaTypeLimit(uint8 mediaType) public pure returns (uint256) {
        if (mediaType == 0) return MAX_IMAGES;      // Images
        if (mediaType == 1) return MAX_VIDEOS;      // Videos
        if (mediaType == 2) return MAX_AUDIO;       // Audio
        if (mediaType == 3) return MAX_DOCUMENTS;   // Documents
        return 0;
    }

    /// @notice Check if can add more media
    function canAddMedia(uint256 fundraiserId, uint8 mediaType, uint256 quantity) 
        external view 
        returns (bool canAdd, string memory reason) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        uint256 totalCurrent = f.gallery.length;
        uint256 typeCurrent = mediaTypeCounts[fundraiserId][mediaType];
        uint256 typeLimit = getMediaTypeLimit(mediaType);
        
        if (totalCurrent + quantity > MAX_TOTAL_MEDIA) {
            return (false, "Total media limit exceeded (200 max)");
        }
        
        if (typeCurrent + quantity > typeLimit) {
            return (false, "Media type limit exceeded");
        }
        
        if (quantity > MAX_MEDIA_BATCH) {
            return (false, "Batch size too large (20 max)");
        }
        
        return (true, "Can add media");
    }

    /// @notice Get multimedia statistics for fundraiser
    function getMediaStatistics(uint256 fundraiserId) 
        external view 
        validFundraiserId(fundraiserId)
        returns (uint256 images, uint256 videos, uint256 audio, uint256 documents, uint256 total) 
    {
        uint256[4] storage counts = mediaTypeCounts[fundraiserId];
        images = counts[0];
        videos = counts[1];
        audio = counts[2];
        documents = counts[3];
        total = fundraisers[fundraiserId].gallery.length;
    }

    /// @notice Get fundraiser gallery (paginated)
    function getFundraiserGallery(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external view 
        validFundraiserId(fundraiserId)
        returns (MediaItem[] memory media, uint256 total) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        total = f.gallery.length;
        
        if (offset >= total) {
            return (new MediaItem[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        media = new MediaItem[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            media[i - offset] = f.gallery[i];
        }
    }

    /// @notice Get update with attachments
    function getUpdateWithAttachments(uint256 updateId) 
        external view 
        returns (FundraiserUpdate memory) 
    {
        require(updateId <= updateCount && updateId > 0, "Invalid update");
        return fundraiserUpdates[updateId];
    }

    /// @notice Check if address can create proposals
    /// @param proposer Address to check
    /// @return True if address can create proposals
    function canPropose(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
    }

    /// @notice Check if address can manage media for fundraiser
    function canManageMedia(uint256 fundraiserId, address manager) 
        external view 
        validFundraiserId(fundraiserId)
        returns (bool) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        return manager == f.creator || 
               authorizedUpdaters[fundraiserId][manager] || 
               authorizedMediaManagers[fundraiserId][manager];
    }

    /// @notice Get remaining time for proposal voting
    /// @param proposalId Proposal ID
    /// @return Remaining time in seconds (0 if ended)
    function timeLeftOnProposal(uint256 proposalId) external view returns (uint256) {
        if (proposalId > proposalCount || proposalId == 0) return 0;
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.endTime) return 0;
        return p.endTime - block.timestamp;
    }

    /// @notice Get remaining time for fundraiser
    /// @param id Fundraiser ID
    /// @return Remaining time in seconds (0 if ended)
    function timeLeftOnFundraiser(uint256 id) external view returns (uint256) {
        if (id > fundraiserCount || id == 0) return 0;
        Fundraiser storage f = fundraisers[id];
        if (block.timestamp >= f.endTime) return 0;
        return f.endTime - block.timestamp;
    }

    /// @notice Get all proposal IDs
    /// @return Array of proposal IDs
    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }

    /// @notice Get all fundraiser IDs
    /// @return Array of fundraiser IDs
    function getAllFundraiserIds() external view returns (uint256[] memory) {
        return fundraiserIds;
    }

    /// @notice Get proposal summary
    /// @param proposalId Proposal ID
    /// @return Proposal summary struct
    function getProposalSummary(uint256 proposalId) external view returns (ProposalSummary memory) {
        require(proposalId <= proposalCount && proposalId > 0, "Invalid proposal");
        Proposal storage p = proposals[proposalId];
        
        return ProposalSummary({
            id: p.id,
            question: p.question,
            yesVotes: p.yesVotes,
            noVotes: p.noVotes,
            endTime: p.endTime,
            creator: p.creator,
            metadataHash: p.metadataHash
        });
    }

    /// @notice Get enhanced fundraiser summary
    /// @param id Fundraiser ID
    /// @return Enhanced fundraiser summary struct
    function getFundraiserSummary(uint256 id) external view returns (FundraiserSummary memory) {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        Fundraiser storage f = fundraisers[id];
        
        return FundraiserSummary({
            id: f.id,
            creator: f.creator,
            token: f.token,
            target: f.target,
            raised: f.raised,
            endTime: f.endTime,
            isFlexible: f.isFlexible,
            closureInitiated: f.closureInitiated,
            updateCount: f.updateIds.length,
            pinnedUpdateId: f.pinnedUpdateId,
            mediaCount: f.gallery.length,
            metadataHash: f.metadataHash
        });
    }

    /// @notice Get donors with pagination
    /// @param id Fundraiser ID
    /// @param offset Starting index
    /// @param limit Maximum number of donors to return
    /// @return donors Array of donor addresses
    /// @return total Total number of donors
    function getDonorsPaginated(uint256 id, uint256 offset, uint256 limit) 
        external view returns (address[] memory donors, uint256 total) 
    {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        require(limit <= MAX_DONORS_BATCH, "Limit too high");
        
        address[] storage allDonors = fundraisers[id].donors;
        total = allDonors.length;
        
        if (offset >= total) {
            return (new address[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        donors = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            donors[i - offset] = allDonors[i];
        }
    }

    /// @notice Get total number of donors for a fundraiser
    /// @param id Fundraiser ID
    /// @return Number of unique donors
    function getDonorsCount(uint256 id) external view returns (uint256) {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        return fundraisers[id].donors.length;
    }

    /// @notice Check contract health
    function healthCheck() external view returns (
        bool contractNotPaused,
        bool votingEnabled,
        bool donationsEnabled,
        bool withdrawalsEnabled,
        uint256 totalFundraisers,
        uint256 totalProposals
    ) {
        return (
            !paused(),
            !votingPaused,
            !donationsPaused,
            !withdrawalsPaused,
            fundraiserCount,
            proposalCount
        );
    }

    // ========== LEGACY SUPPORT FUNCTIONS ==========

    /// @notice Get proposal data (legacy format)
    /// @param id Proposal ID
    /// @return id, question, yesVotes, noVotes, endTime, exists
    function getProposal(uint256 id) external view returns (
        uint256, string memory, uint256, uint256, uint256, bool
    ) {
        require(id <= proposalCount && id > 0, "Invalid proposal");
        Proposal storage p = proposals[id];
        return (p.id, p.question, p.yesVotes, p.noVotes, p.endTime, true);
    }

    /// @notice Get proposal creator
    /// @param proposalId Proposal ID
    /// @return Creator address
    function getProposalCreator(uint256 proposalId) external view returns (address) {
        require(proposalId <= proposalCount && proposalId > 0, "Invalid proposal");
        return proposals[proposalId].creator;
    }

    /// @notice Get fundraiser data (legacy format)
    /// @param id Fundraiser ID
    /// @return id, creator, token, target, raised, endTime, withdrawn, isFlexible, reclaimDeadline, closureInitiated
    function getFundraiser(uint256 id) external view returns (
        uint256, address, address, uint256, uint256,
        uint256, bool, bool, uint256, bool
    ) {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        Fundraiser storage f = fundraisers[id];
        return (
            f.id, f.creator, f.token, f.target, f.raised,
            f.endTime, f.withdrawn, f.isFlexible, f.reclaimDeadline, f.closureInitiated
        );
    }

    /// @notice Get all donors (legacy function - limited to prevent gas issues)
    /// @param id Fundraiser ID
    /// @return Array of donor addresses (first 100 donors only)
    function getDonors(uint256 id) external view returns (address[] memory) {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        address[] storage allDonors = fundraisers[id].donors;
        
        uint256 length = allDonors.length;
        if (length > MAX_DONORS_BATCH) {
            length = MAX_DONORS_BATCH;
        }
        
        address[] memory result = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = allDonors[i];
        }
        
        return result;
    }

    // ========== UTILITY FUNCTIONS ==========

    /// @notice Get total number of proposals
    /// @return Number of proposals
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    /// @notice Get total number of fundraisers
    /// @return Number of fundraisers
    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

    /// @notice Get total number of updates
    /// @return Number of updates
    function getUpdateCount() external view returns (uint256) {
        return updateCount;
    }

    /// @notice Check if address has voted on proposal
    /// @param proposalId Proposal ID
    /// @param voter Voter address
    /// @return True if voted
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        if (proposalId > proposalCount || proposalId == 0) return false;
        return proposals[proposalId].hasVoted[voter];
    }

    /// @notice Get donation amount for address
    /// @param id Fundraiser ID
    /// @param donor Donor address
    /// @return Donation amount
    function donationOf(uint256 id, address donor) external view returns (uint256) {
        if (id > fundraiserCount || id == 0) return 0;
        return fundraisers[id].donations[donor];
    }

    /// @notice Check if address has been refunded
    /// @param id Fundraiser ID
    /// @param donor Donor address
    /// @return True if refunded
    function hasRefunded(uint256 id, address donor) external view returns (bool) {
        if (id > fundraiserCount || id == 0) return false;
        return fundraisers[id].refunded[donor];
    }

    /// @notice Get all whitelisted tokens
    /// @return Array of token addresses
    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }

    /// @notice Get daily donation count for specific day
    /// @param day Day timestamp divided by 1 days
    /// @return Donation count for that day
    function getDailyDonationCount(uint256 day) external view returns (uint256) {
        return dailyDonationCount[day];
    }

    /// @notice Get today's donation count
    /// @return Today's donation count
    function getTodayDonationCount() external view returns (uint256) {
        return dailyDonationCount[block.timestamp / 1 days];
    }

    // ========== RECEIVE FUNCTION ==========

    /// @notice Receive function to accept ETH (for emergency purposes)
    receive() external payable {
        // ETH can be sent to contract for emergency withdrawal
    }
}