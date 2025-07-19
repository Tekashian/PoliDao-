// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoRefunds
 * @notice Refunds management module for PoliDAO
 * @dev Handles refund logic, closure periods, and flexible fundraiser withdrawals
 */
contract PoliDaoRefunds is Ownable, Pausable, IPoliDaoStructs {
    
    // ========== CONSTANTS ==========
    
    uint256 public constant RECLAIM_PERIOD = 14 days;
    uint256 public constant MAX_REFUND_COMMISSION = 500; // 5%
    
    // ========== STORAGE ==========
    
    address public mainContract;
    
    // Refund tracking per fundraiser
    mapping(uint256 => mapping(address => bool)) public hasRefunded;
    mapping(uint256 => mapping(address => uint256)) public refundAmounts;
    
    // Closure management for non-flexible fundraisers
    mapping(uint256 => bool) public closureInitiated;
    mapping(uint256 => uint256) public reclaimDeadline;
    
    // Flexible fundraiser tracking (multiple withdrawals)
    mapping(uint256 => bool) public isFlexibleFundraiser;
    mapping(uint256 => uint256) public totalWithdrawnByCreator;
    
    // Refund commission (in basis points)
    uint256 public refundCommission = 100; // 1%
    address public commissionWallet;
    
    // Emergency pause for specific fundraisers
    mapping(uint256 => bool) public isRefundsPaused;
    
    // ========== EVENTS - USUNIĘTO DUPLIKATY ==========
    // Wszystkie eventy są już zdefiniowane w IPoliDaoStructs
    
    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    modifier refundsNotPaused(uint256 fundraiserId) {
        require(!isRefundsPaused[fundraiserId], "Refunds paused for this fundraiser");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract, address _commissionWallet) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
        require(_commissionWallet != address(0), "Invalid commission wallet");
        mainContract = _mainContract;
        commissionWallet = _commissionWallet;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        mainContract = _newMainContract;
    }
    
    function setRefundCommission(uint256 _commission) external onlyOwner {
        require(_commission <= MAX_REFUND_COMMISSION, "Commission too high");
        refundCommission = _commission;
        emit RefundCommissionSet(_commission);
    }
    
    function setCommissionWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid wallet");
        commissionWallet = _newWallet;
    }
    
    function pauseRefundsForFundraiser(uint256 fundraiserId) external onlyOwner {
        isRefundsPaused[fundraiserId] = true;
        emit RefundsPausedForFundraiser(fundraiserId);
    }
    
    function unpauseRefundsForFundraiser(uint256 fundraiserId) external onlyOwner {
        isRefundsPaused[fundraiserId] = false;
        emit RefundsUnpausedForFundraiser(fundraiserId);
    }
    
    // ========== MAIN CONTRACT INTEGRATION ==========
    
    /**
     * @notice Register fundraiser as flexible (called during creation)
     * @param fundraiserId The fundraiser ID
     * @param isFlexible Whether fundraiser allows partial withdrawals
     */
    function registerFundraiser(uint256 fundraiserId, bool isFlexible) 
        external 
        onlyMainContract 
    {
        isFlexibleFundraiser[fundraiserId] = isFlexible;
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Validate refund conditions
     * @dev Made external to allow try/catch in view functions
     */
    function validateRefundConditions(
        uint256 fundraiserId,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external view {
        // Flexible fundraisers don't allow refunds
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers don't allow refunds");
        
        // Cannot refund if goal was reached
        require(!goalReached, "Goal reached - no refunds available");
        
        // Must be after end time for non-flexible fundraisers
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        
        // If closure was initiated, must be within reclaim period
        if (closureInitiated[fundraiserId]) {
            require(
                block.timestamp <= reclaimDeadline[fundraiserId], 
                "Reclaim period expired"
            );
        }
    }
    
    /**
     * @notice Internal validation function
     */
    function _validateRefundConditionsInternal(
        uint256 fundraiserId,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) internal view {
        // Flexible fundraisers don't allow refunds
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers don't allow refunds");
        
        // Cannot refund if goal was reached
        require(!goalReached, "Goal reached - no refunds available");
        
        // Must be after end time for non-flexible fundraisers
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        
        // If closure was initiated, must be within reclaim period
        if (closureInitiated[fundraiserId]) {
            require(
                block.timestamp <= reclaimDeadline[fundraiserId], 
                "Reclaim period expired"
            );
        }
    }
    
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
    ) 
        external 
        whenNotPaused 
        onlyMainContract
        refundsNotPaused(fundraiserId)
    {
        require(!hasRefunded[fundraiserId][donor], "Already refunded");
        require(donationAmount > 0, "No donation to refund");
        
        // Validate refund conditions
        _validateRefundConditionsInternal(
            fundraiserId,
            fundraiserStatus,
            fundraiserEndTime,
            goalReached
        );
        
        // Mark as refunded
        hasRefunded[fundraiserId][donor] = true;
        refundAmounts[fundraiserId][donor] = donationAmount;
        
        // Calculate commission
        uint256 commission = (donationAmount * refundCommission) / 10000;
        uint256 refundAmount = donationAmount - commission;
        
        IERC20 tokenContract = IERC20(token);
        
        // Transfer commission
        if (commission > 0) {
            require(tokenContract.transfer(commissionWallet, commission), "Commission transfer failed");
        }
        
        // Transfer refund to donor
        require(tokenContract.transfer(donor, refundAmount), "Refund transfer failed");
        
        emit RefundProcessed(fundraiserId, donor, refundAmount, commission);
    }
    
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
    ) 
        external 
        whenNotPaused 
        onlyMainContract
    {
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers cannot initiate closure");
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        require(!closureInitiated[fundraiserId], "Closure already initiated");
        
        closureInitiated[fundraiserId] = true;
        reclaimDeadline[fundraiserId] = block.timestamp + RECLAIM_PERIOD;
        
        emit ClosureInitiated(fundraiserId, reclaimDeadline[fundraiserId], creator);
    }
    
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
    ) 
        external 
        whenNotPaused 
        onlyMainContract
    {
        require(isFlexibleFundraiser[fundraiserId], "Not a flexible fundraiser");
        require(withdrawAmount > 0, "Nothing to withdraw");
        
        // Update total withdrawn
        totalWithdrawnByCreator[fundraiserId] += withdrawAmount;
        
        // Transfer to creator (commission already deducted in main contract)
        require(IERC20(token).transfer(creator, withdrawAmount), "Withdrawal transfer failed");
        
        emit FlexibleWithdrawal(
            fundraiserId, 
            creator, 
            withdrawAmount, 
            totalWithdrawnByCreator[fundraiserId]
        );
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Check if donor can request refund
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param donationAmount The donation amount
     * @param fundraiserStatus Current fundraiser status
     * @param fundraiserEndTime Fundraiser end time
     * @param goalReached Whether goal was reached
     * @return canRefundResult Whether refund is possible
     * @return reason Reason why refund is/isn't possible
     */
    function canRefund(
        uint256 fundraiserId,
        address donor,
        uint256 donationAmount,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) 
        external 
        view 
        returns (bool canRefundResult, string memory reason) 
    {
        // Basic checks
        if (hasRefunded[fundraiserId][donor]) {
            return (false, "Already refunded");
        }
        
        if (donationAmount == 0) {
            return (false, "No donation found");
        }
        
        if (isRefundsPaused[fundraiserId]) {
            return (false, "Refunds paused");
        }
        
        // Check refund conditions
        try this.validateRefundConditions(
            fundraiserId,
            fundraiserStatus,
            fundraiserEndTime,
            goalReached
        ) {
            return (true, "Refund available");
        } catch {
            if (isFlexibleFundraiser[fundraiserId]) {
                return (false, "Flexible fundraisers don't allow refunds");
            }
            
            if (goalReached) {
                return (false, "Goal reached - no refunds");
            }
            
            if (block.timestamp <= fundraiserEndTime) {
                return (false, "Fundraiser still active");
            }
            
            if (closureInitiated[fundraiserId] && 
                block.timestamp > reclaimDeadline[fundraiserId]) {
                return (false, "Reclaim period expired");
            }
            
            return (false, "Refund not available");
        }
    }
    
    /**
     * @notice Get refund information for donor
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
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
        ) 
    {
        return (
            hasRefunded[fundraiserId][donor],
            refundAmounts[fundraiserId][donor],
            closureInitiated[fundraiserId],
            reclaimDeadline[fundraiserId],
            isFlexibleFundraiser[fundraiserId]
        );
    }
    
    /**
     * @notice Get flexible fundraiser withdrawal info
     * @param fundraiserId The fundraiser ID
     */
    function getFlexibleInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            bool isFlexible,
            uint256 totalWithdrawn
        ) 
    {
        return (
            isFlexibleFundraiser[fundraiserId],
            totalWithdrawnByCreator[fundraiserId]
        );
    }
}