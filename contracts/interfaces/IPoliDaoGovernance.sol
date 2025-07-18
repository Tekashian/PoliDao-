// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoGovernance
 * @notice Interface for PoliDAO governance module
 * @dev Defines all governance-related functions and events
 */
interface IPoliDaoGovernance is IPoliDaoStructs {
    
    // ========== EVENTS (USUNIETO DUPLIKATY) ==========
    // Eventy ProposalCreated i Voted zostały usunięte - są w IPoliDaoStructs
    
    event ProposalExecuted(
        uint256 indexed proposalId, 
        bool passed
    );
    
    event ProposerAuthorized(
        address indexed proposer
    );
    
    event ProposerRevoked(
        address indexed proposer
    );
    
    event MainContractUpdated(
        address indexed oldContract, 
        address indexed newContract
    );
    
    event ProposalCooldownUpdated(
        uint256 oldCooldown, 
        uint256 newCooldown
    );
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Create a new proposal
     * @param question The proposal question
     * @param durationSeconds Voting duration in seconds
     * @return proposalId The ID of the created proposal
     */
    function createProposal(string calldata question, uint256 durationSeconds) 
        external 
        returns (uint256 proposalId);
    
    /**
     * @notice Vote on a proposal
     * @param proposalId The proposal ID
     * @param support Whether to vote yes (true) or no (false)
     */
    function vote(uint256 proposalId, bool support) external;
    
    /**
     * @notice Execute a proposal (mark as executed)
     * @param proposalId The proposal ID
     */
    function executeProposal(uint256 proposalId) external;
    
    /**
     * @notice Emergency close a proposal
     * @param proposalId The proposal ID
     */
    function emergencyCloseProposal(uint256 proposalId) external;
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
    /**
     * @notice Set proposal cooldown period
     * @param newCooldown New cooldown period in seconds
     */
    function setProposalCooldown(uint256 newCooldown) external;
    
    /**
     * @notice Authorize a proposer
     * @param proposer Address to authorize
     */
    function authorizeProposer(address proposer) external;
    
    /**
     * @notice Revoke proposer authorization
     * @param proposer Address to revoke
     */
    function revokeProposer(address proposer) external;
    
    /**
     * @notice Batch authorize proposers
     * @param proposers Array of addresses to authorize
     */
    function batchAuthorizeProposers(address[] calldata proposers) external;
    
    /**
     * @notice Pause the contract
     */
    function pause() external;
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external;
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get proposal details
     * @param proposalId The proposal ID
     * @return id Proposal ID
     * @return question Proposal question
     * @return yesVotes Number of yes votes
     * @return noVotes Number of no votes
     * @return endTime Voting end time
     * @return creator Proposal creator
     * @return exists Whether proposal exists
     * @return executed Whether proposal is executed
     * @return createdAt Creation timestamp
     */
    function getProposal(uint256 proposalId) 
        external 
        view 
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
        );
    
    /**
     * @notice Check if user has voted on a proposal
     * @param proposalId The proposal ID
     * @param voter The voter address
     * @return hasVoted Whether user has voted
     */
    function hasVoted(uint256 proposalId, address voter) external view returns (bool hasVoted);
    
    /**
     * @notice Get proposal status
     * @param proposalId The proposal ID
     * @return status Proposal status
     */
    function getProposalStatus(uint256 proposalId) external view returns (ProposalStatus status);
    
    /**
     * @notice Get proposal results
     * @param proposalId The proposal ID
     * @return yesVotes Number of yes votes
     * @return noVotes Number of no votes
     * @return totalVotes Total number of votes
     * @return yesPercentage Percentage of yes votes
     * @return passed Whether proposal passed
     */
    function getProposalResults(uint256 proposalId) 
        external 
        view 
        returns (
            uint256 yesVotes,
            uint256 noVotes,
            uint256 totalVotes,
            uint256 yesPercentage,
            bool passed
        );
    
    /**
     * @notice Get active proposals
     * @return activeProposals Array of active proposal IDs
     */
    function getActiveProposals() external view returns (uint256[] memory activeProposals);
    
    /**
     * @notice Get proposals by creator
     * @param creator The creator address
     * @return proposalIds Array of proposal IDs
     */
    function getProposalsByCreator(address creator) external view returns (uint256[] memory proposalIds);
    
    /**
     * @notice Get paginated proposals
     * @param offset Starting index
     * @param limit Number of proposals to return
     * @return ids Array of proposal IDs
     * @return total Total number of proposals
     */
    function getProposals(uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    /**
     * @notice Get proposal count
     * @return count Total number of proposals
     */
    function getProposalCount() external view returns (uint256 count);
    
    /**
     * @notice Get user's proposal count
     * @param user The user address
     * @return count Number of proposals created by user
     */
    function getUserProposalCount(address user) external view returns (uint256 count);
    
    /**
     * @notice Check if user can create proposal (cooldown check)
     * @param user The user address
     * @return canCreate Whether user can create proposal
     */
    function canCreateProposal(address user) external view returns (bool canCreate);
    
    /**
     * @notice Get remaining cooldown time for user
     * @param user The user address
     * @return remainingTime Remaining cooldown time in seconds
     */
    function getRemainingCooldown(address user) external view returns (uint256 remainingTime);
    
    /**
     * @notice Check if address is authorized proposer
     * @param proposer The proposer address
     * @return isAuthorized Whether address is authorized
     */
    function isAuthorizedProposer(address proposer) external view returns (bool isAuthorized);
    
    /**
     * @notice Get all proposal IDs
     * @return proposalIds Array of all proposal IDs
     */
    function getAllProposalIds() external view returns (uint256[] memory proposalIds);
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
    
    /**
     * @notice Get proposal cooldown period
     * @return cooldownPeriod Cooldown period in seconds
     */
    function proposalCooldown() external view returns (uint256 cooldownPeriod);
}