// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PoliDAO v3.1 - Production Ready Governance & Fundraising Platform
/// @notice Smart contract with authorization-only governance and ERC20 fundraising
/// @dev Streamlined architecture with enhanced security features
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

    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_QUESTION_LENGTH = 500;
    uint256 public constant RECLAIM_PERIOD = 14 days;
    uint256 public constant MAX_DONORS_BATCH = 100; // Gas optimization for getDonors

    // ========== STRUKTURY ==========

    struct Proposal {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
        mapping(address => bool) hasVoted;
    }

    struct ProposalSummary {
        uint256 id;
        string question;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 endTime;
        address creator;
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
        mapping(address => uint256) donations;
        mapping(address => bool) refunded;
        address[] donors;
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
    }

    // ========== STORAGE ==========

    uint256 public proposalCount;
    uint256 public fundraiserCount;

    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => Fundraiser) private fundraisers;

    uint256[] private proposalIds;
    uint256[] private fundraiserIds;

    // Token management
    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;
    mapping(address => uint256) private tokenIndex;

    // Commission system
    uint256 public donationCommission;
    uint256 public successCommission;
    uint256 public refundCommission;
    address public commissionWallet;

    // Refund tracking
    mapping(address => mapping(uint256 => uint256)) public monthlyRefundCount;

    // Circuit breaker
    uint256 public maxDailyDonations = 1000000 * 10**18;
    mapping(uint256 => uint256) public dailyDonationCount;

    // Selective pausing
    bool public votingPaused;
    bool public donationsPaused;
    bool public withdrawalsPaused;

    // Authorization system
    mapping(address => bool) public authorizedProposers;

    // ========== EVENTS ==========

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
    
    // Security events
    event CommissionWalletChanged(address indexed oldWallet, address indexed newWallet);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

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

    modifier onlyAuthorizedProposer() {
        if (msg.sender != owner() && !authorizedProposers[msg.sender]) {
            revert NotAuthorized();
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
            // ERC20 withdrawal
            IERC20(token).transfer(to, amount);
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
        require(bps <= 10_000, "Max 100%");
        donationCommission = bps;
        emit DonationCommissionSet(bps);
    }

    /// @notice Set success commission rate
    /// @param bps Commission rate in basis points (1 bps = 0.01%)
    function setSuccessCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        successCommission = bps;
        emit SuccessCommissionSet(bps);
    }

    /// @notice Set refund commission rate
    /// @param bps Commission rate in basis points (1 bps = 0.01%)
    function setRefundCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        refundCommission = bps;
        emit RefundCommissionSet(bps);
    }

    /// @notice Add token to whitelist
    /// @param token ERC20 token address to whitelist
    function whitelistToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidToken(token);
        if (token.code.length == 0) revert NotAContract(token);
        
        // Verify ERC20 compatibility
        try IERC20(token).totalSupply() returns (uint256) {
            // Token is likely ERC20 compatible
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

        fundraiserIds.push(fundraiserCount);

        emit FundraiserCreated(f.id, msg.sender, token, target, f.endTime, isFlexible);
    }

    /// @notice Donate to a fundraiser
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
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 commission = (amount * donationCommission) / 10_000;
        uint256 netAmount = amount - commission;

        f.raised += netAmount;
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += netAmount;

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
            commissionAmount = (donated * refundCommission) / 10_000;
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

    /// @notice Withdraw funds from fundraiser
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

        uint256 commission = (f.raised * successCommission) / 10_000;
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

    // ========== VIEW FUNCTIONS ==========

    /// @notice Check if address can create proposals
    /// @param proposer Address to check
    /// @return True if address can create proposals
    function canPropose(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
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
            creator: p.creator
        });
    }

    /// @notice Get fundraiser summary
    /// @param id Fundraiser ID
    /// @return Fundraiser summary struct
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
            closureInitiated: f.closureInitiated
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