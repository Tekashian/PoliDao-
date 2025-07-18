// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDao
 * @notice Main interface for PoliDAO platform
 * @dev Defines all public functions of the main PoliDAO contract
 */
interface IPoliDao is IPoliDaoStructs {
    
    // ========== FUNDRAISER MANAGEMENT ==========
    
    /**
     * @notice Create a new fundraiser
     * @param data Fundraiser creation data
     * @return fundraiserId The ID of the created fundraiser
     */
    function createFundraiser(FundraiserCreationData calldata data) 
        external 
        returns (uint256 fundraiserId);
    
    /**
     * @notice Donate to a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     */
    function donate(uint256 fundraiserId, uint256 amount) external;
    
    /**
     * @notice Donate with EIP-2612 permit
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     * @param deadline Permit deadline
     * @param v Permit signature v
     * @param r Permit signature r
     * @param s Permit signature s
     */
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    /**
     * @notice Batch donate to multiple fundraisers
     * @param fundraiserIds Array of fundraiser IDs
     * @param amounts Array of donation amounts
     */
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external;
    
    /**
     * @notice Withdraw funds from successful fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function withdrawFunds(uint256 fundraiserId) external;
    
    /**
     * @notice Request refund from failed fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function refund(uint256 fundraiserId) external;
    
    /**
     * @notice Extend fundraiser duration
     * @param fundraiserId The fundraiser ID
     * @param additionalDays Additional days to extend
     */
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external;
    
    /**
     * @notice Suspend a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param reason Suspension reason
     */
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external;
    
    /**
     * @notice Unsuspend a fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function unsuspendFundraiser(uint256 fundraiserId) external;
    
    /**
     * @notice Update fundraiser location
     * @param fundraiserId The fundraiser ID
     * @param newLocation New location
     */
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external;
    
    // ========== GOVERNANCE FUNCTIONS ==========
    
    /**
     * @notice Create a governance proposal
     * @param question Proposal question
     * @param duration Voting duration in seconds
     */
    function createProposal(string calldata question, uint256 duration) external;
    
    /**
     * @notice Vote on a proposal
     * @param proposalId Proposal ID
     * @param support Vote support (true=yes, false=no)
     */
    function vote(uint256 proposalId, bool support) external;
    
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
    
    // ========== MEDIA FUNCTIONS ==========
    
    /**
     * @notice Add media to fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaItems Array of media items
     */
    function addMediaToFundraiser(uint256 fundraiserId, MediaItem[] calldata mediaItems) external;
    
    /**
     * @notice Remove media from fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaIndex Media index to remove
     */
    function removeMediaFromFundraiser(uint256 fundraiserId, uint256 mediaIndex) external;
    
    /**
     * @notice Authorize media manager
     * @param fundraiserId The fundraiser ID
     * @param manager Address to authorize
     */
    function authorizeMediaManager(uint256 fundraiserId, address manager) external;
    
    /**
     * @notice Revoke media manager authorization
     * @param fundraiserId The fundraiser ID
     * @param manager Address to revoke
     */
    function revokeMediaManager(uint256 fundraiserId, address manager) external;
    
    // ========== UPDATE FUNCTIONS ==========
    
    /**
     * @notice Post an update
     * @param fundraiserId The fundraiser ID
     * @param content Update content
     */
    function postUpdate(uint256 fundraiserId, string calldata content) external;
    
    /**
     * @notice Post update with media
     * @param fundraiserId The fundraiser ID
     * @param content Update content
     * @param updateType Update type
     * @param mediaIds Array of media IDs
     */
    function postUpdateWithMedia(
        uint256 fundraiserId, 
        string calldata content, 
        uint8 updateType, 
        uint256[] calldata mediaIds
    ) external;
    
    /**
     * @notice Pin an update
     * @param updateId Update ID to pin
     */
    function pinUpdate(uint256 updateId) external;
    
    /**
     * @notice Unpin update
     * @param fundraiserId The fundraiser ID
     */
    function unpinUpdate(uint256 fundraiserId) external;
    
    /**
     * @notice Authorize update manager
     * @param fundraiserId The fundraiser ID
     * @param updater Address to authorize
     */
    function authorizeUpdater(uint256 fundraiserId, address updater) external;
    
    /**
     * @notice Revoke update manager authorization
     * @param fundraiserId The fundraiser ID
     * @param updater Address to revoke
     */
    function revokeUpdater(uint256 fundraiserId, address updater) external;
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get fundraiser details
     * @param fundraiserId The fundraiser ID
     * @return title Tytuł zbiórki
     * @return description Opis zbiórki
     * @return location Lokalizacja zbiórki
     * @return endDate Data zakończenia
     * @return fundraiserType Typ zbiórki
     * @return status Status zbiórki
     * @return token Adres tokenu
     * @return goalAmount Cel zbiórki
     * @return raisedAmount Zebrana kwota
     * @return creator Twórca zbiórki
     * @return extensionCount Liczba przedłużeń
     * @return isSuspended Czy zawieszona
     * @return suspensionReason Powód zawieszenia
     */
    function getFundraiserDetails(uint256 fundraiserId) 
        external 
        view 
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
            uint256 extensionCount,
            bool isSuspended,
            string memory suspensionReason
        );
    
    /**
     * @notice Get fundraiser progress
     * @param fundraiserId The fundraiser ID
     * @return raised Zebrana kwota
     * @return goal Cel zbiórki
     * @return percentage Procent ukończenia
     * @return donorsCount Liczba darczyńców
     * @return timeLeft Pozostały czas
     * @return refundDeadline Deadline zwrotu
     * @return isSuspended Czy zawieszona
     * @return suspensionTime Czas zawieszenia
     */
    function getFundraiserProgress(uint256 fundraiserId) 
        external 
        view 
        returns (
            uint256 raised,
            uint256 goal,
            uint256 percentage,
            uint256 donorsCount,
            uint256 timeLeft,
            uint256 refundDeadline,
            bool isSuspended,
            uint256 suspensionTime
        );
    
    /**
     * @notice Get fundraiser donors
     * @param fundraiserId The fundraiser ID
     * @param offset Starting index
     * @param limit Number of donors to return
     * @return donors Array of donor addresses
     * @return amounts Array of donation amounts
     * @return total Total number of donors
     */
    function getDonors(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory donors, uint256[] memory amounts, uint256 total);
    
    /**
     * @notice Get fundraisers by status
     * @param status Fundraiser status
     * @param offset Starting index
     * @param limit Number of fundraisers to return
     * @return ids Array of fundraiser IDs
     * @return total Total number of fundraisers
     */
    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    /**
     * @notice Get fundraisers by creator
     * @param creator Creator address
     * @param offset Starting index
     * @param limit Number of fundraisers to return
     * @return ids Array of fundraiser IDs
     * @return total Total number of fundraisers
     */
    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    /**
     * @notice Get total fundraiser count
     * @return count Total number of fundraisers
     */
    function getFundraiserCount() external view returns (uint256 count);
    
    /**
     * @notice Get user's donation amount
     * @param fundraiserId The fundraiser ID
     * @param donor Donor address
     * @return amount Donation amount
     */
    function donationOf(uint256 fundraiserId, address donor) external view returns (uint256 amount);
    
    /**
     * @notice Check if user can request refund
     * @param fundraiserId The fundraiser ID
     * @param donor Donor address
     * @return canRefund Whether refund is possible
     * @return reason Reason string
     */
    function canRefund(uint256 fundraiserId, address donor) 
        external 
        view 
        returns (bool canRefund, string memory reason);
    
    /**
     * @notice Get whitelisted tokens
     * @return tokens Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory tokens);
    
    /**
     * @notice Check if token is whitelisted
     * @param token Token address
     * @return isWhitelisted Whether token is whitelisted
     */
    function isTokenWhitelisted(address token) external view returns (bool isWhitelisted);
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Whitelist a token
     * @param token Token address to whitelist
     */
    function whitelistToken(address token) external;
    
    /**
     * @notice Remove token from whitelist
     * @param token Token address to remove
     */
    function removeWhitelistToken(address token) external;
    
    /**
     * @notice Set commission rates
     * @param donationCommission Donation commission in basis points
     * @param successCommission Success commission in basis points
     * @param refundCommission Refund commission in basis points
     */
    function setCommissions(
        uint256 donationCommission,
        uint256 successCommission,
        uint256 refundCommission
    ) external;
    
    /**
     * @notice Set commission wallet
     * @param newWallet New commission wallet address
     */
    function setCommissionWallet(address newWallet) external;
    
    /**
     * @notice Pause the contract
     */
    function pause() external;
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external;
    
    /**
     * @notice Emergency withdraw
     * @param token Token address (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}