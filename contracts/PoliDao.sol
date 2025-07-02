// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PoliDAO v3.0 - Simplified Authorization Model
/// @notice Smart contract with authorization-only governance and ERC20 fundraising
/// @dev Streamlined architecture with owner + authorized proposers model only
contract PoliDAO is Ownable, ReentrancyGuard, Pausable {
    // ========== CUSTOM ERRORS ==========
    
    error NotAuthorized();
    error InvalidDuration(uint256 duration);
    error QuestionTooLong(uint256 length);
    error EmptyQuestion();
    error InvalidToken(address token);
    error NotAContract(address token);
    error DailyLimitExceeded(uint256 requested, uint256 limit);

    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_QUESTION_LENGTH = 500;
    uint256 public constant RECLAIM_PERIOD = 14 days;

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

    // SIMPLIFIED: Only authorized proposers (owner + authorized users)
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

    /// @dev SIMPLIFIED: Only owner or authorized proposers can create proposals
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

    // ========== CONSTRUCTOR ==========

    constructor(address initialOwner, address _commissionWallet) Ownable(initialOwner) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
    }

    // ========== ADMIN FUNCTIONS ==========

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function toggleVotingPause() external onlyOwner {
        votingPaused = !votingPaused;
        emit VotingPauseToggled(votingPaused);
    }

    function toggleDonationsPause() external onlyOwner {
        donationsPaused = !donationsPaused;
        emit DonationsPauseToggled(donationsPaused);
    }

    function toggleWithdrawalsPause() external onlyOwner {
        withdrawalsPaused = !withdrawalsPaused;
        emit WithdrawalsPauseToggled(withdrawalsPaused);
    }

    /// @notice Authorize address to create proposals
    function authorizeProposer(address proposer) external onlyOwner {
        require(proposer != address(0), "Invalid address");
        authorizedProposers[proposer] = true;
        emit ProposerAuthorized(proposer);
    }

    /// @notice Revoke proposal creation authorization
    function revokeProposer(address proposer) external onlyOwner {
        authorizedProposers[proposer] = false;
        emit ProposerRevoked(proposer);
    }

    function setMaxDailyDonations(uint256 newLimit) external onlyOwner {
        maxDailyDonations = newLimit;
        emit MaxDailyDonationsSet(newLimit);
    }

    function setDonationCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        donationCommission = bps;
        emit DonationCommissionSet(bps);
    }

    function setSuccessCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        successCommission = bps;
        emit SuccessCommissionSet(bps);
    }

    function setRefundCommission(uint256 bps) external onlyOwner {
        require(bps <= 10_000, "Max 100%");
        refundCommission = bps;
        emit RefundCommissionSet(bps);
    }

    function whitelistToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidToken(token);
        if (token.code.length == 0) revert NotAContract(token);
        
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

    function removeWhitelistToken(address token) external onlyOwner {
        require(isTokenWhitelisted[token], "Not whitelisted");
        
        isTokenWhitelisted[token] = false;
        
        uint256 index = tokenIndex[token];
        address lastToken = whitelistedTokens[whitelistedTokens.length - 1];
        
        whitelistedTokens[index] = lastToken;
        tokenIndex[lastToken] = index;
        
        whitelistedTokens.pop();
        delete tokenIndex[token];
        
        emit TokenRemoved(token);
    }

    // ========== GOVERNANCE ==========

    /// @notice SIMPLIFIED: Single function for creating proposals (authorization-only)
    /// @param question Proposal question
    /// @param duration Voting duration in seconds
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

    function initiateClosure(uint256 id) external whenNotPaused {
        Fundraiser storage f = fundraisers[id];
        require(msg.sender == f.creator, "Not creator");
        require(!f.isFlexible, "Flexible fundraisers only");
        require(block.timestamp > f.endTime, "Too early");
        require(!f.closureInitiated, "Already initiated");

        f.closureInitiated = true;
        f.reclaimDeadline = block.timestamp + RECLAIM_PERIOD;

        emit ClosureInitiated(id, f.reclaimDeadline);
    }

    // ========== VIEW FUNCTIONS ==========

    /// @notice Check if address can create proposals
    function canPropose(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
    }

    function timeLeftOnProposal(uint256 proposalId) external view returns (uint256) {
        if (proposalId > proposalCount || proposalId == 0) return 0;
        Proposal storage p = proposals[proposalId];
        if (block.timestamp >= p.endTime) return 0;
        return p.endTime - block.timestamp;
    }

    function timeLeftOnFundraiser(uint256 id) external view returns (uint256) {
        if (id > fundraiserCount || id == 0) return 0;
        Fundraiser storage f = fundraisers[id];
        if (block.timestamp >= f.endTime) return 0;
        return f.endTime - block.timestamp;
    }

    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }

    function getAllFundraiserIds() external view returns (uint256[] memory) {
        return fundraiserIds;
    }

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

    function getProposal(uint256 id) external view returns (
        uint256, string memory, uint256, uint256, uint256, bool
    ) {
        require(id <= proposalCount && id > 0, "Invalid proposal");
        Proposal storage p = proposals[id];
        return (p.id, p.question, p.yesVotes, p.noVotes, p.endTime, true);
    }

    function getProposalCreator(uint256 proposalId) external view returns (address) {
        require(proposalId <= proposalCount && proposalId > 0, "Invalid proposal");
        return proposals[proposalId].creator;
    }

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

    function getDonors(uint256 id) external view returns (address[] memory) {
        require(id <= fundraiserCount && id > 0, "Invalid fundraiser");
        return fundraisers[id].donors;
    }

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        if (proposalId > proposalCount || proposalId == 0) return false;
        return proposals[proposalId].hasVoted[voter];
    }

    function donationOf(uint256 id, address donor) external view returns (uint256) {
        if (id > fundraiserCount || id == 0) return 0;
        return fundraisers[id].donations[donor];
    }

    function hasRefunded(uint256 id, address donor) external view returns (bool) {
        if (id > fundraiserCount || id == 0) return false;
        return fundraisers[id].refunded[donor];
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }

    function getDailyDonationCount(uint256 day) external view returns (uint256) {
        return dailyDonationCount[day];
    }

    function getTodayDonationCount() external view returns (uint256) {
        return dailyDonationCount[block.timestamp / 1 days];
    }
}