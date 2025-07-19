// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoRefunds
 * @notice Interface for PoliDAO refunds management module
 * @dev Defines all refund-related functions and events
 */
interface IPoliDaoRefunds is IPoliDaoStructs {
    
    // ========== EVENTS - USUNIĘTO DUPLIKATY ==========
    // Wszystkie eventy są już zdefiniowane w IPoliDaoStructs
    
    // ========== MAIN CONTRACT INTEGRATION ==========
    
    /**
     * @notice Register fundraiser type during creation
     * @param fundraiserId The fundraiser ID
     * @param isFlexible Whether fundraiser allows partial withdrawals
     */
    function registerFundraiser(uint256 fundraiserId, bool isFlexible) external;
    
    // ========== REFUND FUNCTIONS ==========
    
    /**
     * @notice Process refund for a donor
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param donationAmount The original donation amount
     * @param token The token address
     * @param fundraiserStatus Current fundraiser status
     * @param fundraiserEndTime Fundraiser end time
     * @param goalReached Whether goal was reached
     */
    function processRefund(
        uint256 fundraiserId,
        address donor,
        uint256 donationAmount,
        address token,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external;
    
    /**
     * @notice Initiate closure period for non-flexible fundraiser
     * @param fundraiserId The fundraiser ID
     * @param creator The fundraiser creator
     * @param fundraiserEndTime Fundraiser end time
     */
    function initiateClosure(
        uint256 fundraiserId,
        address creator,
        uint256 fundraiserEndTime
    ) external;
    
    /**
     * @notice Process flexible fundraiser withdrawal
     * @param fundraiserId The fundraiser ID
     * @param creator The fundraiser creator
     * @param withdrawAmount Amount to withdraw
     * @param token The token address
     */
    function processFlexibleWithdrawal(
        uint256 fundraiserId,
        address creator,
        uint256 withdrawAmount,
        address token
    ) external;
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
    /**
     * @notice Set refund commission rate
     * @param commission Commission in basis points
     */
    function setRefundCommission(uint256 commission) external;
    
    /**
     * @notice Set commission wallet
     * @param newWallet New commission wallet address
     */
    function setCommissionWallet(address newWallet) external;
    
    /**
     * @notice Pause refunds for specific fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function pauseRefundsForFundraiser(uint256 fundraiserId) external;
    
    /**
     * @notice Unpause refunds for specific fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function unpauseRefundsForFundraiser(uint256 fundraiserId) external;
    
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
     * @notice Check if donor can request refund
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param donationAmount The donation amount
     * @param fundraiserStatus Current fundraiser status
     * @param fundraiserEndTime Fundraiser end time
     * @param goalReached Whether goal was reached
     * @return canRefund Whether refund is possible
     * @return reason Reason why refund is/isn't possible
     */
    function canRefund(
        uint256 fundraiserId,
        address donor,
        uint256 donationAmount,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external view returns (bool canRefund, string memory reason);
    
    /**
     * @notice Get refund information for donor
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return hasRefundedStatus Whether donor has received refund
     * @return refundedAmount Amount that was refunded
     * @return closureInitiatedStatus Whether closure period started
     * @return deadline Refund deadline
     * @return isFlexible Whether fundraiser is flexible
     */
    function getRefundInfo(uint256 fundraiserId, address donor) 
        external 
        view 
        returns (
            bool hasRefundedStatus,
            uint256 refundedAmount,
            bool closureInitiatedStatus,
            uint256 deadline,
            bool isFlexible
        );
    
    /**
     * @notice Get flexible fundraiser withdrawal info
     * @param fundraiserId The fundraiser ID
     * @return isFlexible Whether fundraiser is flexible
     * @return totalWithdrawn Total amount withdrawn by creator
     */
    function getFlexibleInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            bool isFlexible,
            uint256 totalWithdrawn
        );
    
    /**
     * @notice Check if donor has already received refund
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return hasRefunded Whether donor received refund
     */
    function hasRefunded(uint256 fundraiserId, address donor) external view returns (bool hasRefunded);
    
    /**
     * @notice Get refund amount for donor
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return amount Refunded amount
     */
    function refundAmounts(uint256 fundraiserId, address donor) external view returns (uint256 amount);
    
    /**
     * @notice Check if closure was initiated for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return initiated Whether closure was initiated
     */
    function closureInitiated(uint256 fundraiserId) external view returns (bool initiated);
    
    /**
     * @notice Get reclaim deadline for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return deadline Reclaim deadline timestamp
     */
    function reclaimDeadline(uint256 fundraiserId) external view returns (uint256 deadline);
    
    /**
     * @notice Check if fundraiser is flexible type
     * @param fundraiserId The fundraiser ID
     * @return isFlexible Whether fundraiser is flexible
     */
    function isFlexibleFundraiser(uint256 fundraiserId) external view returns (bool isFlexible);
    
    /**
     * @notice Get total withdrawn by creator for flexible fundraiser
     * @param fundraiserId The fundraiser ID
     * @return amount Total withdrawn amount
     */
    function totalWithdrawnByCreator(uint256 fundraiserId) external view returns (uint256 amount);
    
    /**
     * @notice Check if refunds are paused for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return isPaused Whether refunds are paused
     */
    function isRefundsPaused(uint256 fundraiserId) external view returns (bool isPaused);
    
    /**
     * @notice Get refund commission rate
     * @return commission Commission rate in basis points
     */
    function refundCommission() external view returns (uint256 commission);
    
    /**
     * @notice Get commission wallet address
     * @return wallet Commission wallet address
     */
    function commissionWallet() external view returns (address wallet);
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
    
    /**
     * @notice Get reclaim period constant
     * @return period Reclaim period in seconds
     */
    function RECLAIM_PERIOD() external view returns (uint256 period);
}