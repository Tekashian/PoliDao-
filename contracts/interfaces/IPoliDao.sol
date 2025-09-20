// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDao - ZAKTUALIZOWANY INTERFACE
 * @notice Main interface for PoliDAO platform with missing functions added
 * @dev Defines all public functions of the main PoliDAO contract
 */
interface IPoliDao {
    
    // ========== FUNDRAISER MANAGEMENT ==========
    
    /**
     * @notice Create a new fundraiser
     * @param data Fundraiser creation data
     * @return fundraiserId The ID of the created fundraiser
     */
    function createFundraiser(
        IPoliDaoStructs.FundraiserCreationData calldata data,
        string memory title,
        string memory description,
        string memory location,
        address token
    ) external returns (uint256 fundraiserId);

    /**
     * @notice Makes a donation to a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     */
    function donate(uint256 fundraiserId, uint256 amount) external;
    function donateBatchFrom(
        address donor,
        address token,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external;
    
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
    
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external;
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external;
    function canExtendFundraiser(uint256 fundraiserId) 
        external 
        view 
        returns (bool canExtend, uint256 timeLeft, string memory reason);
    
    // ========== SUSPENSION FUNCTIONS ==========
    
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external;
    function unsuspendFundraiser(uint256 fundraiserId) external;
    
    // ========== GOVERNANCE FUNCTIONS ==========
    
    function createProposal(string calldata question, uint256 duration) external;
    function vote(uint256 proposalId, bool support) external;
    function authorizeProposer(address proposer) external;
    function revokeProposer(address proposer) external;
    
    // ========== MEDIA FUNCTIONS ==========
    
    function addMediaToFundraiser(uint256 fundraiserId, IPoliDaoStructs.MediaItem[] calldata mediaItems) external;
    function removeMediaFromFundraiser(uint256 fundraiserId, uint256 mediaIndex) external;
    function authorizeMediaManager(uint256 fundraiserId, address manager) external;
    function revokeMediaManager(uint256 fundraiserId, address manager) external;
    
    // ========== UPDATE FUNCTIONS ==========
    
    function postUpdate(uint256 fundraiserId, string calldata content) external;
    function postUpdateWithMedia(
        uint256 fundraiserId, 
        string calldata content, 
        uint8 updateType, 
        uint256[] calldata mediaIds
    ) external;
    function pinUpdate(uint256 updateId) external;
    function unpinUpdate(uint256 fundraiserId) external;
    function authorizeUpdater(uint256 fundraiserId, address updater) external;
    function revokeUpdater(uint256 fundraiserId, address updater) external;
    
    // ========== VIEW FUNCTIONS ==========
    
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
    
    function getDonors(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory donors, uint256[] memory amounts, uint256 total);
    
    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    function getFundraiserCount() external view returns (uint256 count);
    function donationOf(uint256 fundraiserId, address donor) external view returns (uint256 amount);
    
    function canRefund(uint256 fundraiserId, address donor) 
        external 
        view 
        returns (bool canRefund, string memory reason);
    
    function getWhitelistedTokens() external view returns (address[] memory tokens);
    function isTokenWhitelisted(address token) external view returns (bool isWhitelisted);
    
    // ========== NOWE VIEW FUNCTIONS ==========
    
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
    
    function getFundraiserCreator(uint256 fundraiserId) external view returns (address creator);
    
    // ========== ADMIN FUNCTIONS - FEE MANAGEMENT ==========
    
    function whitelistToken(address token) external;
    function removeWhitelistToken(address token) external;
    
    function setCommissions(
        uint256 _donation,
        uint256 _success,
        uint256 _refund
    ) external;
    
    function setExtensionFee(uint256 _extensionFee) external;
    function setFeeToken(address _feeToken) external;
    function setCommissionWallet(address newWallet) external;
    
    // ========== MODULE MANAGEMENT ==========
    
    function setModule(bytes32 moduleKey, address moduleAddress) external;
    
    function setModules(
        address governance, 
        address media, 
        address updates, 
        address refunds,
        address security,
        address web3,
        address analytics
    ) external;
    
    function getModule(bytes32 moduleKey) external view returns (address moduleAddress);
    
    function delegateCall(bytes32 moduleKey, bytes calldata data) 
        external 
        returns (bytes memory result);
    
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
    
    function updateFundraiserState(
        uint256 fundraiserId, 
        uint256 newRaisedAmount, 
        uint8 newStatus
    ) external;
    
    function getDonationAmount(uint256 fundraiserId, address donor) 
        external 
        view 
        returns (uint256);
    
    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) 
        external;
    
    // ========== ANALYTICS HELPER FUNCTIONS ==========
    
    function getFundraiserDonors(uint256 fundraiserId) 
        external 
        view 
        returns (address[] memory donors);
    
    function getDonorCount(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 count);
    
    function getFundraiserLocation(uint256 fundraiserId) 
        external 
        view 
        returns (string memory location);
    
    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            uint256 extensionCount,
            uint256 originalEndDate,
            uint256 currentEndDate
        );
    
    // ========== SYSTEM FUNCTIONS ==========
    
    function pause() external;
    function unpause() external;
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}