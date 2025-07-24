// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDao - ZAKTUALIZOWANY INTERFACE
 * @notice Main interface for PoliDAO platform with missing functions added
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
    
    // ========== NOWE FUNKCJE - BRAKUJĄCE ==========
    
    /**
     * @notice Extend fundraiser duration for a fee
     * @param fundraiserId The fundraiser ID
     * @param additionalDays Additional days to extend (max 90)
     */
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external;
    
    /**
     * @notice Update fundraiser location
     * @param fundraiserId The fundraiser ID
     * @param newLocation New location string
     */
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external;
    
    /**
     * @notice Check if fundraiser can be extended
     * @param fundraiserId The fundraiser ID
     * @return canExtend Whether fundraiser can be extended
     * @return timeLeft Time left until end
     * @return reason Reason if cannot extend
     */
    function canExtendFundraiser(uint256 fundraiserId) 
        external 
        view 
        returns (bool canExtend, uint256 timeLeft, string memory reason);
    
    // ========== SUSPENSION FUNCTIONS ==========
    
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
     * @notice Get detailed fundraiser information - ROZSZERZONA
     * @param fundraiserId The fundraiser ID
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
     * @notice Get fundraiser progress - ROZSZERZONA
     * @param fundraiserId The fundraiser ID
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
     * @notice Get fundraiser donors - PRZENIESIONA DO ANALYTICS MODULE
     * @dev This function will delegate to Analytics module
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
    
    // ========== NOWE VIEW FUNCTIONS ==========
    
    /**
     * @notice Get all fee information - NOWA FUNKCJA
     * @return donationFee Donation commission in basis points
     * @return successFee Success commission in basis points
     * @return refundFee Refund commission in basis points
     * @return extensionFeeAmount Extension fee amount
     * @return feeTokenAddress Token used for extension payments
     * @return commissionWalletAddress Wallet receiving commissions
     */
    function getFeeInfo() 
        external 
        view 
        returns (
            uint256 donationFee,
            uint256 successFee,
            uint256 refundFee,
            uint256 extensionFeeAmount,
            address feeTokenAddress,
            address commissionWalletAddress
        );
    
    /**
     * @notice Get basic fundraiser info
     * @param id Fundraiser ID
     */
    function getFundraiserBasicInfo(uint256 id) 
        external 
        view 
        returns (
            string memory title,
            address creator,
            address token,
            uint256 raised,
            uint256 goal,
            uint256 endDate,
            uint8 status,
            bool isFlexible
        );
    
    /**
     * @notice Get fundraiser creator
     * @param fundraiserId The fundraiser ID
     * @return creator Creator address
     */
    function getFundraiserCreator(uint256 fundraiserId) external view returns (address creator);
    
    // ========== ADMIN FUNCTIONS - FEE MANAGEMENT ==========
    
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
     * @notice Set all commission rates - ROZSZERZONA O REFUND
     * @param _donation Donation commission in basis points
     * @param _success Success commission in basis points
     * @param _refund Refund commission in basis points
     */
    function setCommissions(
        uint256 _donation,
        uint256 _success,
        uint256 _refund
    ) external;
    
    /**
     * @notice Set extension fee - NOWA FUNKCJA
     * @param _extensionFee New extension fee amount
     */
    function setExtensionFee(uint256 _extensionFee) external;
    
    /**
     * @notice Set fee token for extensions - NOWA FUNKCJA
     * @param _feeToken New fee token address
     */
    function setFeeToken(address _feeToken) external;
    
    /**
     * @notice Set commission wallet
     * @param newWallet New commission wallet address
     */
    function setCommissionWallet(address newWallet) external;
    
    // ========== MODULE MANAGEMENT ==========
    
    /**
     * @notice Set individual module
     * @param moduleKey Module identifier
     * @param moduleAddress Module contract address
     */
    function setModule(bytes32 moduleKey, address moduleAddress) external;
    
    /**
     * @notice Set all modules at once
     */
    function setModules(
        address governance, 
        address media, 
        address updates, 
        address refunds,
        address security,
        address web3,
        address analytics
    ) external;
    
    /**
     * @notice Get module address
     * @param moduleKey Module identifier
     * @return moduleAddress Module contract address
     */
    function getModule(bytes32 moduleKey) external view returns (address moduleAddress);
    
    /**
     * @notice Delegate call to module
     * @param moduleKey Module identifier
     * @param data Call data
     * @return result Return data
     */
    function delegateCall(bytes32 moduleKey, bytes calldata data) 
        external 
        returns (bytes memory result);
    
    /**
     * @notice Static call to module
     * @param moduleKey Module identifier
     * @param data Call data
     * @return result Return data
     */
    function staticCall(bytes32 moduleKey, bytes calldata data) 
        external 
        view 
        returns (bytes memory result);
    
    // ========== MODULE KEYS ==========
    
    function GOVERNANCE_MODULE() external view returns (bytes32);
    function MEDIA_MODULE() external view returns (bytes32);
    function UPDATES_MODULE() external view returns (bytes32);
    function REFUNDS_MODULE() external view returns (bytes32);
    function SECURITY_MODULE() external view returns (bytes32);
    function WEB3_MODULE() external view returns (bytes32);
    function ANALYTICS_MODULE() external view returns (bytes32);
    
    // ========== HELPER FUNCTIONS FOR MODULES ==========
    
    /**
     * @notice Get fundraiser data for modules
     */
    function getFundraiserData(uint256 fundraiserId) 
        external 
        view 
        returns (
            address creator,
            address token,
            uint256 raisedAmount,
            uint256 goalAmount,
            uint256 endDate,
            uint8 status,
            bool isFlexible
        );
    
    /**
     * @notice Update fundraiser state (only refunds module)
     */
    function updateFundraiserState(
        uint256 fundraiserId, 
        uint256 newRaisedAmount, 
        uint8 newStatus
    ) external;
    
    /**
     * @notice Get donation amount for specific donor
     */
    function getDonationAmount(uint256 fundraiserId, address donor) 
        external 
        view 
        returns (uint256);
    
    /**
     * @notice Update donation amount (only refunds module)
     */
    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) 
        external;
    
    // ========== ANALYTICS HELPER FUNCTIONS ==========
    
    /**
     * @notice Get fundraiser donors array (only analytics module)
     */
    function getFundraiserDonors(uint256 fundraiserId) 
        external 
        view 
        returns (address[] memory donors);
    
    /**
     * @notice Get donor count (analytics module)
     */
    function getDonorCount(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 count);
    
    /**
     * @notice Get fundraiser location
     */
    function getFundraiserLocation(uint256 fundraiserId) 
        external 
        view 
        returns (string memory location);
    
    /**
     * @notice Get extension information
     */
    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            uint256 extensionCount,
            uint256 originalEndDate,
            uint256 currentEndDate
        );
    
    // ========== SYSTEM FUNCTIONS ==========
    
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