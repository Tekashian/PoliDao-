// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PoliDaoGovernance
 * @notice Governance module for PoliDAO - handles proposals and voting
 * @dev Manages proposal creation, voting mechanism, and proposal results
 */
contract PoliDaoGovernance is Ownable, Pausable {
    
    // ========== CUSTOM ERRORS ==========
    
    error ProposalNotFound(uint256 proposalId);
    error ProposalNotActive(uint256 proposalId);
    error AlreadyVoted(address voter, uint256 proposalId);
    error VotingEnded(uint256 proposalId);
    error UnauthorizedProposer(address caller);
    error InvalidProposalDuration(uint256 duration);
    error EmptyQuestion();
    error InvalidMainContract();
    
    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_PROPOSAL_DURATION = 30 days;
    uint256 public constant MIN_PROPOSAL_DURATION = 1 hours;
    uint256 public constant MAX_QUESTION_LENGTH = 500;
    
    // ========== STRUCTURES ==========
    
    /// @notice Structure for a single proposal
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
        mapping(address => bool) hasVoted;
    }
    
    enum ProposalStatus {
        ACTIVE,
        PASSED,
        FAILED,
        EXECUTED
    }
    
    // ========== STORAGE ==========
    
    address public mainContract;
    uint256 public proposalCount;
    
    mapping(uint256 => Proposal) private proposals;
    mapping(address => bool) public authorizedProposers;
    mapping(address => uint256) public userProposalCount;
    
    uint256[] public proposalIds;
    
    // Rate limiting
    uint256 public proposalCooldown = 1 days;
    mapping(address => uint256) public lastProposalTime;
    
    // ========== EVENTS ==========
    
    event ProposalCreated(uint256 indexed id, string question, uint256 endTime, address indexed creator);
    event Voted(address indexed voter, uint256 indexed proposalId, bool support);
    event ProposalExecuted(uint256 indexed proposalId, bool passed);
    event ProposerAuthorized(address indexed proposer);
    event ProposerRevoked(address indexed proposer);
    event MainContractUpdated(address indexed oldContract, address indexed newContract);
    event ProposalCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    
    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        if (msg.sender != mainContract) revert UnauthorizedProposer(msg.sender);
        _;
    }
    
    modifier onlyAuthorizedProposer() {
        if (msg.sender != owner() && !authorizedProposers[msg.sender]) {
            revert UnauthorizedProposer(msg.sender);
        }
        _;
    }
    
    modifier validProposal(uint256 proposalId) {
        if (proposalId == 0 || proposalId > proposalCount) {
            revert ProposalNotFound(proposalId);
        }
        if (!proposals[proposalId].exists) {
            revert ProposalNotFound(proposalId);
        }
        _;
    }
    
    modifier proposalActive(uint256 proposalId) {
        if (block.timestamp > proposals[proposalId].endTime) {
            revert VotingEnded(proposalId);
        }
        _;
    }
    
    modifier rateLimited() {
        if (msg.sender != owner()) {
            require(
                block.timestamp >= lastProposalTime[msg.sender] + proposalCooldown,
                "Proposal cooldown not met"
            );
        }
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract) Ownable(msg.sender) {
        if (_mainContract == address(0)) revert InvalidMainContract();
        mainContract = _mainContract;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        if (_newMainContract == address(0)) revert InvalidMainContract();
        address oldContract = mainContract;
        mainContract = _newMainContract;
        emit MainContractUpdated(oldContract, _newMainContract);
    }
    
    function setProposalCooldown(uint256 _newCooldown) external onlyOwner {
        uint256 oldCooldown = proposalCooldown;
        proposalCooldown = _newCooldown;
        emit ProposalCooldownUpdated(oldCooldown, _newCooldown);
    }
    
    function authorizeProposer(address proposer) external onlyOwner {
        require(proposer != address(0), "Invalid proposer");
        authorizedProposers[proposer] = true;
        emit ProposerAuthorized(proposer);
    }
    
    function revokeProposer(address proposer) external onlyOwner {
        authorizedProposers[proposer] = false;
        emit ProposerRevoked(proposer);
    }
    
    function batchAuthorizeProposers(address[] calldata proposers) external onlyOwner {
        for (uint256 i = 0; i < proposers.length; i++) {
            require(proposers[i] != address(0), "Invalid proposer");
            authorizedProposers[proposers[i]] = true;
            emit ProposerAuthorized(proposers[i]);
        }
    }
    
    // ========== PROPOSAL FUNCTIONS ==========
    
    /**
     * @notice Creates a new proposal
     * @param _question The proposal question
     * @param _durationSeconds Voting duration in seconds
     */
    function createProposal(string calldata _question, uint256 _durationSeconds) 
        external 
        whenNotPaused 
        onlyAuthorizedProposer 
        rateLimited 
    {
        if (bytes(_question).length == 0) revert EmptyQuestion();
        if (bytes(_question).length > MAX_QUESTION_LENGTH) revert("Question too long");
        if (_durationSeconds < MIN_PROPOSAL_DURATION || _durationSeconds > MAX_PROPOSAL_DURATION) {
            revert InvalidProposalDuration(_durationSeconds);
        }
        
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.question = _question;
        p.endTime = block.timestamp + _durationSeconds;
        p.creator = msg.sender;
        p.exists = true;
        p.createdAt = block.timestamp;
        
        proposalIds.push(proposalId);
        userProposalCount[msg.sender]++;
        lastProposalTime[msg.sender] = block.timestamp;
        
        emit ProposalCreated(proposalId, _question, p.endTime, msg.sender);
    }
    
    /**
     * @notice Vote on a proposal
     * @param _proposalId The proposal ID
     * @param _support Whether to vote yes (true) or no (false)
     */
    function vote(uint256 _proposalId, bool _support) 
        external 
        whenNotPaused 
        validProposal(_proposalId) 
        proposalActive(_proposalId) 
    {
        Proposal storage p = proposals[_proposalId];
        
        if (p.hasVoted[msg.sender]) {
            revert AlreadyVoted(msg.sender, _proposalId);
        }
        
        p.hasVoted[msg.sender] = true;
        
        if (_support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }
        
        emit Voted(msg.sender, _proposalId, _support);
    }
    
    /**
     * @notice Execute a proposal (mark as executed)
     * @param _proposalId The proposal ID
     */
    function executeProposal(uint256 _proposalId) 
        external 
        onlyOwner 
        validProposal(_proposalId) 
    {
        Proposal storage p = proposals[_proposalId];
        require(block.timestamp > p.endTime, "Voting still active");
        require(!p.executed, "Already executed");
        
        p.executed = true;
        bool passed = p.yesVotes > p.noVotes;
        
        emit ProposalExecuted(_proposalId, passed);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID
     */
    function getProposal(uint256 proposalId) 
        external 
        view 
        validProposal(proposalId) 
        returns (
            uint256 id,
            string memory question,
            uint256 yesVotes,
            uint256 noVotes,
            uint256 endTime,
            address creator,
            bool exists,
            bool executed,
            uint256 createdAt
        ) 
    {
        Proposal storage p = proposals[proposalId];
        return (
            p.id,
            p.question,
            p.yesVotes,
            p.noVotes,
            p.endTime,
            p.creator,
            p.exists,
            p.executed,
            p.createdAt
        );
    }
    
    /**
     * @notice Check if user has voted on a proposal
     * @param proposalId The proposal ID
     * @param voter The voter address
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        return proposals[proposalId].hasVoted[voter];
    }
    
    /**
     * @notice Get proposal status
     * @param proposalId The proposal ID
     */
    function getProposalStatus(uint256 proposalId) 
        external 
        view 
        validProposal(proposalId) 
        returns (ProposalStatus) 
    {
        Proposal storage p = proposals[proposalId];
        
        if (p.executed) {
            return ProposalStatus.EXECUTED;
        }
        
        if (block.timestamp <= p.endTime) {
            return ProposalStatus.ACTIVE;
        }
        
        return p.yesVotes > p.noVotes ? ProposalStatus.PASSED : ProposalStatus.FAILED;
    }
    
    /**
     * @notice Get proposal results
     * @param proposalId The proposal ID
     */
    function getProposalResults(uint256 proposalId) 
        external 
        view 
        validProposal(proposalId) 
        returns (
            uint256 yesVotes,
            uint256 noVotes,
            uint256 totalVotes,
            uint256 yesPercentage,
            bool passed
        ) 
    {
        Proposal storage p = proposals[proposalId];
        
        yesVotes = p.yesVotes;
        noVotes = p.noVotes;
        totalVotes = yesVotes + noVotes;
        
        if (totalVotes > 0) {
            yesPercentage = (yesVotes * 100) / totalVotes;
        }
        
        passed = yesVotes > noVotes;
    }
    
    /**
     * @notice Get active proposals
     */
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](proposalCount);
        uint256 activeCount = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists && block.timestamp <= proposals[i].endTime) {
                activeIds[activeCount] = i;
                activeCount++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            result[i] = activeIds[i];
        }
        
        return result;
    }
    
    /**
     * @notice Get proposals by creator
     * @param creator The creator address
     */
    function getProposalsByCreator(address creator) external view returns (uint256[] memory) {
        uint256[] memory creatorIds = new uint256[](proposalCount);
        uint256 creatorCount = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists && proposals[i].creator == creator) {
                creatorIds[creatorCount] = i;
                creatorCount++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](creatorCount);
        for (uint256 i = 0; i < creatorCount; i++) {
            result[i] = creatorIds[i];
        }
        
        return result;
    }
    
    /**
     * @notice Get paginated proposals
     * @param offset Starting index
     * @param limit Number of proposals to return
     */
    function getProposals(uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total) 
    {
        total = proposalCount;
        
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = proposalIds[i];
        }
    }
    
    /**
     * @notice Get proposal count
     */
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }
    
    /**
     * @notice Get user's proposal count
     * @param user The user address
     */
    function getUserProposalCount(address user) external view returns (uint256) {
        return userProposalCount[user];
    }
    
    /**
     * @notice Check if user can create proposal (cooldown check)
     * @param user The user address
     */
    function canCreateProposal(address user) external view returns (bool) {
        if (user == owner()) return true;
        if (!authorizedProposers[user]) return false;
        return block.timestamp >= lastProposalTime[user] + proposalCooldown;
    }
    
    /**
     * @notice Get remaining cooldown time for user
     * @param user The user address
     */
    function getRemainingCooldown(address user) external view returns (uint256) {
        if (user == owner()) return 0;
        if (!authorizedProposers[user]) return type(uint256).max;
        
        uint256 nextAllowedTime = lastProposalTime[user] + proposalCooldown;
        if (block.timestamp >= nextAllowedTime) {
            return 0;
        }
        
        return nextAllowedTime - block.timestamp;
    }
    
    /**
     * @notice Check if address is authorized proposer
     * @param proposer The proposer address
     */
    function isAuthorizedProposer(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
    }
    
    // ========== EMERGENCY FUNCTIONS ==========
    
    /**
     * @notice Emergency function to close a proposal
     * @param proposalId The proposal ID
     */
    function emergencyCloseProposal(uint256 proposalId) 
        external 
        onlyOwner 
        validProposal(proposalId) 
    {
        Proposal storage p = proposals[proposalId];
        p.endTime = block.timestamp;
        emit ProposalExecuted(proposalId, false);
    }
    
    /**
     * @notice Get all proposal IDs
     */
    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }
}