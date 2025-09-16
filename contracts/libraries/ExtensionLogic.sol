// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../storage/PoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ExtensionLogic
 * @notice Library containing business logic for fundraiser extensions
 * @dev Used by PoliDaoExtensions to handle fundraiser time extensions
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 */
library ExtensionLogic {
    using SafeERC20 for IERC20;

    // ========== EVENTS ==========
    
    /// @notice Emitted when a fundraiser is extended
    event FundraiserExtended(
        uint256 indexed fundraiserId,
        uint256 newEndDate,
        uint256 additionalDays,
        uint256 extensionFee
    );
    
    // ========== ERRORS ==========
    
    error FundraiserNotFound();
    error OnlyCreatorCanExtend();
    error InvalidDays();
    error MaxExtensionsReached();
    error TooCloseToEnd();
    error ExtensionFeeTransferFailed();
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Extends a fundraiser's end date
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID to extend
     * @param additionalDays Number of additional days
     * @param caller Address calling the extension
     */
    function extendFundraiser(
        PoliDaoStorage store,
        uint256 fundraiserId,
        uint256 additionalDays,
        address caller
    )
        internal
    {
        // SECURITY: prevent arbitrary-from
        require(msg.sender == caller || store.isAuthorized(msg.sender), "ExtensionLogic: unauthorized");

        // ========== VALIDATION ==========
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        // Check fundraiser exists
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        // Check caller is creator
        if (store.fundraiserCreators(fundraiserId) != caller) revert OnlyCreatorCanExtend();
        
        // Check days validity
        if (additionalDays == 0 || additionalDays > store.MAX_EXTENSION_DAYS()) revert InvalidDays();
        
        // Check extension count
        if (fundraiser.extensionCount >= store.MAX_EXTENSIONS()) revert MaxExtensionsReached();
        
        // Check time left
        uint256 timeLeft = fundraiser.endDate > block.timestamp ? 
            fundraiser.endDate - block.timestamp : 0;
        if (timeLeft < store.MIN_EXTENSION_NOTICE()) revert TooCloseToEnd();
        
        // ========== CHARGE EXTENSION FEE ==========
        
        uint256 extensionFee = store.extensionFee();
        if (extensionFee > 0) {
            address feeToken = store.feeToken();
            address commissionWallet = store.commissionWallet();
            // Kluczowa zmiana: from = msg.sender (nie caller)
            IERC20(feeToken).safeTransferFrom(msg.sender, commissionWallet, extensionFee);
        }

        // ========== UPDATE FUNDRAISER ==========
        
        // Create updated fundraiser data
        IPoliDaoStructs.PackedFundraiserData memory updatedData = fundraiser;
        updatedData.endDate += uint64(additionalDays * 1 days);
        updatedData.extensionCount++;
        
        // Emit BEFORE external interaction (CEI)
        emit FundraiserExtended(fundraiserId, updatedData.endDate, additionalDays, extensionFee);

        // External interaction to storage (state write)
        store.updateFundraiser(fundraiserId, updatedData);
    }
    
    /**
     * @notice Checks if a fundraiser can be extended
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param caller Address wanting to extend
     * @return canExtend Whether the fundraiser can be extended
     * @return timeLeft Time remaining until fundraiser ends
     * @return reason Human-readable reason for the result
     */
    function canExtendFundraiser(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address caller
    ) external view returns (bool canExtend, uint256 timeLeft, string memory reason) {
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        if (fundraiser.id == 0) {
            return (false, 0, "Fundraiser not found");
        }
        
        if (store.fundraiserCreators(fundraiserId) != caller) {
            return (false, 0, "Only creator can extend");
        }
        
        if (fundraiser.extensionCount >= store.MAX_EXTENSIONS()) {
            return (false, 0, "Maximum extensions reached");
        }
        
        timeLeft = fundraiser.endDate > block.timestamp ? 
            fundraiser.endDate - block.timestamp : 0;
            
        if (timeLeft < store.MIN_EXTENSION_NOTICE()) {
            return (false, timeLeft, "Too close to deadline");
        }
        
        return (true, timeLeft, "Can extend");
    }
    
    /**
     * @notice Gets extension information for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return extensionCount Number of times extended
     * @return originalEndDate Original end date timestamp
     * @return currentEndDate Current end date timestamp
     * @return canExtendMore Whether more extensions are possible
     * @return maxExtensions Maximum allowed extensions
     */
    function getExtensionInfo(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (
        uint256 extensionCount,
        uint256 originalEndDate,
        uint256 currentEndDate,
        bool canExtendMore,
        uint256 maxExtensions
    ) {
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        extensionCount = fundraiser.extensionCount;
        originalEndDate = fundraiser.originalEndDate;
        currentEndDate = fundraiser.endDate;
        maxExtensions = store.MAX_EXTENSIONS();
        canExtendMore = extensionCount < maxExtensions;
        
        return (extensionCount, originalEndDate, currentEndDate, canExtendMore, maxExtensions);
    }
    
    /**
     * @notice Calculates extension fee for a fundraiser
     * @param store The storage contract instance
     * @return fee Extension fee amount
     * @return feeToken Token address for fee payment
     */
    function getExtensionFee(
        PoliDaoStorage store
    ) external view returns (uint256 fee, address feeToken) {
        return (store.extensionFee(), store.feeToken());
    }
    
    /**
     * @notice Validates extension parameters
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param additionalDays Number of days to extend
     * @param caller Address wanting to extend
     * @return isValid Whether extension is valid
     * @return reason Reason if invalid
     */
    function validateExtension(
        PoliDaoStorage store,
        uint256 fundraiserId,
        uint256 additionalDays,
        address caller
    ) external view returns (bool isValid, string memory reason) {
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        if (fundraiser.id == 0) {
            return (false, "Fundraiser not found");
        }
        
        if (store.fundraiserCreators(fundraiserId) != caller) {
            return (false, "Only creator can extend");
        }
        
        if (additionalDays == 0) {
            return (false, "Additional days must be greater than 0");
        }
        
        if (additionalDays > store.MAX_EXTENSION_DAYS()) {
            return (false, "Too many days");
        }
        
        if (fundraiser.extensionCount >= store.MAX_EXTENSIONS()) {
            return (false, "Maximum extensions reached");
        }
        
        uint256 timeLeft = fundraiser.endDate > block.timestamp ? 
            fundraiser.endDate - block.timestamp : 0;
            
        if (timeLeft < store.MIN_EXTENSION_NOTICE()) {
            return (false, "Too close to deadline");
        }
        
        return (true, "Valid extension");
    }
    
    /**
     * @notice Gets time until extension deadline
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return timeUntilDeadline Time until extension is no longer possible
     * @return canStillExtend Whether extension is still possible
     */
    function getTimeUntilExtensionDeadline(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (uint256 timeUntilDeadline, bool canStillExtend) {
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        uint256 extensionDeadline = fundraiser.endDate - store.MIN_EXTENSION_NOTICE();
        
        if (block.timestamp >= extensionDeadline) {
            return (0, false);
        }
        
        timeUntilDeadline = extensionDeadline - block.timestamp;
        canStillExtend = fundraiser.extensionCount < store.MAX_EXTENSIONS();
        
        return (timeUntilDeadline, canStillExtend);
    }
}