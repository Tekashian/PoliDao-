// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoGovernance - POPRAWIONA WERSJA
 * @notice Enhanced Governance module for PoliDAO with selective pausing and emergency functions
 * @dev Manages proposal creation, voting mechanism, selective pausing, and emergency governance
 */
contract PoliDaoGovernance is Ownable, Pausable, IPoliDaoStructs {
    
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
    
    // ========== SELECTIVE PAUSING STATE ==========
    
    bool public votingPaused = false;
    bool public proposalCreationPaused = false;
    bool public proposalExecutionPaused = false;
    
    // ========== ENHANCED EVENTS ==========
    
    // NOTE: ProposalCreated and Voted are inherited from IPoliDaoStructs
    event ProposalExecuted(uint256 indexed proposalId, bool passed);
    event ProposerAuthorized(address indexed proposer);
    event ProposerRevoked(address indexed proposer);
    event MainContractUpdated(address indexed oldContract, address indexed newContract);
    event ProposalCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    
    // NEW EVENTS
    event VotingPauseToggled(bool isPaused);
    event ProposalCreationPauseToggled(bool isPaused);
    event ProposalExecutionPauseToggled(bool isPaused);
    event EmergencyGovernanceFreeze(address indexed initiator, uint256 timestamp);
    event EmergencyGovernanceUnfreeze(address indexed initiator, uint256 timestamp);
    event BatchProposalsExecuted(uint256[] proposalIdsArray, address indexed executor);
    event EmergencyProposalClosed(uint256 indexed proposalId, string reason, address indexed closer);
    
    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Unauthorized proposer");
        _;
    }
    
    modifier onlyAuthorizedProposer() {
        require(msg.sender == owner() || authorizedProposers[msg.sender], "Unauthorized proposer");
        _;
    }
    
    modifier validProposal(uint256 proposalId) {
        require(proposalId > 0 && proposalId <= proposalCount, "Proposal not found");
        require(proposals[proposalId].exists, "Proposal not found");
        _;
    }
    
    modifier proposalActive(uint256 proposalId) {
        require(block.timestamp <= proposals[proposalId].endTime, "Voting ended");
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
    
    // NEW MODIFIERS
    modifier whenVotingNotPaused() {
        require(!votingPaused, "Voting paused");
        _;
    }
    
    modifier whenProposalCreationNotPaused() {
        require(!proposalCreationPaused, "Proposal creation paused");
        _;
    }
    
    modifier whenProposalExecutionNotPaused() {
        require(!proposalExecutionPaused, "Proposal execution paused");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
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
        require(_newMainContract != address(0), "Invalid main contract");
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
    
    // ========== NEW SELECTIVE PAUSING FUNCTIONS ==========
    
    /**
     * @notice Toggle voting pause - allows disabling voting while keeping proposal creation
     */
    function toggleVotingPause() external onlyOwner {
        votingPaused = !votingPaused;
        emit VotingPauseToggled(votingPaused);
    }
    
    /**
     * @notice Toggle proposal creation pause - stops new proposals while allowing voting on existing
     */
    function toggleProposalCreationPause() external onlyOwner {
        proposalCreationPaused = !proposalCreationPaused;
        emit ProposalCreationPauseToggled(proposalCreationPaused);
    }
    
    /**
     * @notice Toggle proposal execution pause - stops execution while allowing voting and creation
     */
    function toggleProposalExecutionPause() external onlyOwner {
        proposalExecutionPaused = !proposalExecutionPaused;
        emit ProposalExecutionPauseToggled(proposalExecutionPaused);
    }
    
    /**
     * @notice Emergency freeze all governance functions
     */
    function emergencyGovernanceFreeze() external onlyOwner {
        _pause();
        votingPaused = true;
        proposalCreationPaused = true;
        proposalExecutionPaused = true;
        
        emit EmergencyGovernanceFreeze(msg.sender, block.timestamp);
        emit VotingPauseToggled(true);
        emit ProposalCreationPauseToggled(true);
        emit ProposalExecutionPauseToggled(true);
    }
    
    /**
     * @notice Emergency unfreeze all governance functions
     */
    function emergencyGovernanceUnfreeze() external onlyOwner {
        _unpause();
        votingPaused = false;
        proposalCreationPaused = false;
        proposalExecutionPaused = false;
        
        emit EmergencyGovernanceUnfreeze(msg.sender, block.timestamp);
        emit VotingPauseToggled(false);
        emit ProposalCreationPauseToggled(false);
        emit ProposalExecutionPauseToggled(false);
    }
    
    // ========== ENHANCED PROPOSAL FUNCTIONS ==========
    
    /**
     * @notice Creates a new proposal - now with selective pausing
     * @param _question The proposal question
     * @param _durationSeconds Voting duration in seconds
     */
    function createProposal(string calldata _question, uint256 _durationSeconds) 
        external 
        whenNotPaused 
        whenProposalCreationNotPaused
        onlyAuthorizedProposer 
        rateLimited 
        returns (uint256)
    {
        require(bytes(_question).length > 0, "Empty question");
        require(bytes(_question).length <= MAX_QUESTION_LENGTH, "Question too long");
        require(_durationSeconds >= MIN_PROPOSAL_DURATION && _durationSeconds <= MAX_PROPOSAL_DURATION, "Invalid proposal duration");
        
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
        
        return proposalId;
    }
    
    /**
     * @notice Vote on a proposal - now with selective pausing
     * @param _proposalId The proposal ID
     * @param _support Whether to vote yes (true) or no (false)
     */
    function vote(uint256 _proposalId, bool _support) 
        external 
        whenNotPaused 
        whenVotingNotPaused
        validProposal(_proposalId) 
        proposalActive(_proposalId) 
    {
        Proposal storage p = proposals[_proposalId];
        
        require(!p.hasVoted[msg.sender], "Already voted");
        
        p.hasVoted[msg.sender] = true;
        
        if (_support) {
            p.yesVotes++;
        } else {
            p.noVotes++;
        }
        
        emit Voted(msg.sender, _proposalId, _support);
    }
    
    /**
     * @notice Execute a proposal - now with selective pausing
     * @param _proposalId The proposal ID
     */
    function executeProposal(uint256 _proposalId) 
        external 
        onlyOwner 
        whenProposalExecutionNotPaused
        validProposal(_proposalId) 
    {
        Proposal storage p = proposals[_proposalId];
        require(block.timestamp > p.endTime, "Voting still active");
        require(!p.executed, "Already executed");
        
        p.executed = true;
        bool passed = p.yesVotes > p.noVotes;
        
        emit ProposalExecuted(_proposalId, passed);
    }
    
    // ========== NEW BATCH FUNCTIONS ==========
    
    /**
     * @notice Batch execute multiple proposals
     * @param proposalIdsArray Array of proposal IDs to execute
     */
    function batchExecuteProposals(uint256[] calldata proposalIdsArray) 
        external 
        onlyOwner 
        whenProposalExecutionNotPaused
    {
        require(proposalIdsArray.length > 0, "Empty proposal list");
        require(proposalIdsArray.length <= 20, "Too many proposals"); // Limit to prevent gas issues
        
        for (uint256 i = 0; i < proposalIdsArray.length; i++) {
            uint256 proposalId = proposalIdsArray[i];
            
            if (proposalId == 0 || proposalId > proposalCount) continue;
            if (!proposals[proposalId].exists) continue;
            
            Proposal storage p = proposals[proposalId];
            if (block.timestamp <= p.endTime) continue; // Skip active proposals
            if (p.executed) continue; // Skip already executed
            
            p.executed = true;
            bool passed = p.yesVotes > p.noVotes;
            emit ProposalExecuted(proposalId, passed);
        }
        
        emit BatchProposalsExecuted(proposalIdsArray, msg.sender);
    }
    
    /**
     * @notice Get proposals that are ready for execution
     */
    function getProposalsReadyForExecution() external view returns (uint256[] memory) {
        uint256[] memory readyIds = new uint256[](proposalCount);
        uint256 readyCount = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists && 
                !proposals[i].executed && 
                block.timestamp > proposals[i].endTime) {
                readyIds[readyCount] = i;
                readyCount++;
            }
        }
        
        // Resize array
        uint256[] memory result = new uint256[](readyCount);
        for (uint256 i = 0; i < readyCount; i++) {
            result[i] = readyIds[i];
        }
        
        return result;
    }
    
    // ========== ENHANCED VIEW FUNCTIONS ==========
    
    /**
     * @notice Get detailed governance status
     */
    function getGovernanceStatus() external view returns (
        bool isGloballyPaused,
        bool isVotingPaused,
        bool isProposalCreationPaused,
        bool isProposalExecutionPaused,
        uint256 totalProposals,
        uint256 activeProposals,
        uint256 readyForExecution
    ) {
        isGloballyPaused = paused();
        isVotingPaused = votingPaused;
        isProposalCreationPaused = proposalCreationPaused;
        isProposalExecutionPaused = proposalExecutionPaused;
        totalProposals = proposalCount;
        
        // Count active proposals
        uint256 activeCount = 0;
        uint256 readyCount = 0;
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists) {
                if (block.timestamp <= proposals[i].endTime) {
                    activeCount++;
                } else if (!proposals[i].executed) {
                    readyCount++;
                }
            }
        }
        
        activeProposals = activeCount;
        readyForExecution = readyCount;
    }
    
    /**
     * @notice Get proposal details with enhanced status info
     * @param proposalId The proposal ID
     */
    function getProposalWithStatus(uint256 proposalId) 
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
            uint256 createdAt,
            ProposalStatus status,
            uint256 timeRemaining,
            uint256 participationRate
        ) 
    {
        Proposal storage p = proposals[proposalId];
        
        // Calculate status
        ProposalStatus currentStatus;
        if (p.executed) {
            currentStatus = ProposalStatus.EXECUTED;
        } else if (block.timestamp <= p.endTime) {
            currentStatus = ProposalStatus.ACTIVE;
        } else {
            currentStatus = p.yesVotes > p.noVotes ? ProposalStatus.PASSED : ProposalStatus.FAILED;
        }
        
        // Calculate time remaining
        uint256 remaining = 0;
        if (block.timestamp < p.endTime) {
            remaining = p.endTime - block.timestamp;
        }
        
        // Calculate participation rate (total votes)
        uint256 totalVotes = p.yesVotes + p.noVotes;
        
        return (
            p.id,
            p.question,
            p.yesVotes,
            p.noVotes,
            p.endTime,
            p.creator,
            p.exists,
            p.executed,
            p.createdAt,
            currentStatus,
            remaining,
            totalVotes
        );
    }
    
    // ========== ORIGINAL VIEW FUNCTIONS ==========
    
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
    
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        if (proposalId == 0 || proposalId > proposalCount) return false;
        return proposals[proposalId].hasVoted[voter];
    }
    
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
        
        passed = yesVotes > p.noVotes;
    }
    
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256[] memory activeIds = new uint256[](proposalCount);
        uint256 activeCount = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists && block.timestamp <= proposals[i].endTime) {
                activeIds[activeCount] = i;
                activeCount++;
            }
        }
        
        uint256[] memory result = new uint256[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            result[i] = activeIds[i];
        }
        
        return result;
    }
    
    function getProposalsByCreator(address creator) external view returns (uint256[] memory) {
        uint256[] memory creatorIds = new uint256[](proposalCount);
        uint256 creatorCount = 0;
        
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].exists && proposals[i].creator == creator) {
                creatorIds[creatorCount] = i;
                creatorCount++;
            }
        }
        
        uint256[] memory result = new uint256[](creatorCount);
        for (uint256 i = 0; i < creatorCount; i++) {
            result[i] = creatorIds[i];
        }
        
        return result;
    }
    
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
    
    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }
    
    function getUserProposalCount(address user) external view returns (uint256) {
        return userProposalCount[user];
    }
    
    function canCreateProposal(address user) external view returns (bool) {
        if (proposalCreationPaused) return false;
        if (user == owner()) return true;
        if (!authorizedProposers[user]) return false;
        return block.timestamp >= lastProposalTime[user] + proposalCooldown;
    }
    
    function getRemainingCooldown(address user) external view returns (uint256) {
        if (user == owner()) return 0;
        if (!authorizedProposers[user]) return type(uint256).max;
        
        uint256 nextAllowedTime = lastProposalTime[user] + proposalCooldown;
        if (block.timestamp >= nextAllowedTime) {
            return 0;
        }
        
        return nextAllowedTime - block.timestamp;
    }
    
    function isAuthorizedProposer(address proposer) external view returns (bool) {
        return proposer == owner() || authorizedProposers[proposer];
    }
    
    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }
    
    // ========== ENHANCED EMERGENCY FUNCTIONS ==========
    
    /**
     * @notice Enhanced emergency function to close a proposal
     * @param proposalId The proposal ID
     * @param reason Reason for emergency closure
     */
    function emergencyCloseProposal(uint256 proposalId, string calldata reason) 
        external 
        onlyOwner 
        validProposal(proposalId) 
    {
        Proposal storage p = proposals[proposalId];
        p.endTime = block.timestamp;
        emit ProposalExecuted(proposalId, false);
        
        // Additional event for emergency closure
        emit EmergencyProposalClosed(proposalId, reason, msg.sender);
    }
    
    /**
     * @notice Original emergency close for backward compatibility
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
}