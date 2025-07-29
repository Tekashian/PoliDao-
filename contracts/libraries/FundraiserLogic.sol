// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title FundraiserLogic
 * @notice Library containing business logic for fundraiser operations
 * @dev Used by PoliDaoCore to handle fundraiser creation and management
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 */
library FundraiserLogic {
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a fundraiser is created
    event FundraiserCreated(
        uint256 indexed fundraiserId,
        address indexed creator,
        address indexed token,
        string title,
        uint8 fundraiserType,
        uint256 goalAmount,
        uint256 endDate,
        string location
    );
    
    // ========== ERRORS ==========
    
    error InvalidTitle();
    error TitleTooLong();
    error DescriptionTooLong();
    error LocationTooLong();
    error InvalidEndDate();
    error EndDateTooFar();
    error TokenNotWhitelisted();
    error GoalAmountRequired();
    error GoalAmountTooLarge();
    error FundraiserNotFound();
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Creates a new fundraiser with validation
     * @param store The storage contract instance
     * @param data Fundraiser creation data
     * @param creator Address of the fundraiser creator
     * @return fundraiserId The ID of the newly created fundraiser
     */
    function createFundraiserLogic(
        PoliDaoStorage store,
        IPoliDaoStructs.FundraiserCreationData calldata data,
        address creator
    ) external returns (uint256 fundraiserId) {
        
        // ========== INPUT VALIDATION ==========
        
        // Title validation
        if (bytes(data.title).length == 0) revert InvalidTitle();
        if (bytes(data.title).length > store.MAX_TITLE_LENGTH()) revert TitleTooLong();
        
        // Description validation
        if (bytes(data.description).length > store.MAX_DESCRIPTION_LENGTH()) revert DescriptionTooLong();
        
        // Location validation
        if (bytes(data.location).length > store.MAX_LOCATION_LENGTH()) revert LocationTooLong();
        
        // End date validation
        if (data.endDate <= block.timestamp) revert InvalidEndDate();
        if (data.endDate > block.timestamp + store.MAX_FUTURE_DATE()) revert EndDateTooFar();
        
        // Token validation
        if (!store.isTokenWhitelisted(data.token)) revert TokenNotWhitelisted();
        
        // Goal amount validation for fundraisers with goals
        if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            if (data.goalAmount == 0) revert GoalAmountRequired();
            if (data.goalAmount > type(uint128).max) revert GoalAmountTooLarge();
        }
        
        // ========== CREATE PACKED DATA ==========
        
        IPoliDaoStructs.PackedFundraiserData memory packedData = IPoliDaoStructs.PackedFundraiserData({
            goalAmount: uint128(data.goalAmount),
            raisedAmount: 0,
            endDate: uint64(data.endDate),
            originalEndDate: uint64(data.endDate),
            id: 0, // Will be set by storage contract
            suspensionTime: 0,
            extensionCount: 0,
            fundraiserType: uint8(data.fundraiserType),
            status: uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            isFlexible: data.isFlexible
        });
        
        // ========== STORE IN STORAGE CONTRACT ==========
        
        fundraiserId = store.createFundraiser(
            packedData,
            data.title,
            data.description,
            data.location,
            creator,
            data.token
        );
        
        // ========== EMIT EVENT ==========
        
        emit FundraiserCreated(
            fundraiserId,
            creator,
            data.token,
            data.title,
            uint8(data.fundraiserType),
            data.goalAmount,
            data.endDate,
            data.location
        );
        
        return fundraiserId;
    }
    
    /**
     * @notice Gets comprehensive fundraiser details
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return title Fundraiser title
     * @return description Fundraiser description
     * @return location Fundraiser location
     * @return endDate End timestamp
     * @return fundraiserType Type of fundraiser
     * @return status Current status
     * @return token Token address
     * @return goalAmount Goal amount
     * @return raisedAmount Raised amount
     * @return creator Creator address
     * @return extensionCount Number of extensions
     * @return isSuspended Whether suspended
     * @return suspensionReason Suspension reason (empty for now)
     */
    function getFundraiserDetails(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (
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
    ) {
        IPoliDaoStructs.PackedFundraiserData memory data = store.fundraisers(fundraiserId);
        if (data.id == 0) revert FundraiserNotFound();
        
        return (
            store.fundraiserTitles(fundraiserId),
            store.fundraiserDescriptions(fundraiserId),
            store.fundraiserLocations(fundraiserId),
            data.endDate,
            data.fundraiserType,
            data.status,
            store.fundraiserTokens(fundraiserId),
            data.goalAmount,
            data.raisedAmount,
            store.fundraiserCreators(fundraiserId),
            data.extensionCount,
            data.isSuspended,
            "" // Suspension reason handled by security module
        );
    }
    
    /**
     * @notice Gets basic fundraiser information
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return title Fundraiser title
     * @return creator Creator address
     * @return token Token address
     * @return raised Amount raised
     * @return goal Goal amount
     * @return endDate End timestamp
     * @return status Current status
     * @return isFlexible Whether flexible withdrawals are allowed
     */
    function getFundraiserBasicInfo(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (
        string memory title,
        address creator,
        address token,
        uint256 raised,
        uint256 goal,
        uint256 endDate,
        uint8 status,
        bool isFlexible
    ) {
        IPoliDaoStructs.PackedFundraiserData memory data = store.fundraisers(fundraiserId);
        if (data.id == 0) revert FundraiserNotFound();
        
        return (
            store.fundraiserTitles(fundraiserId),
            store.fundraiserCreators(fundraiserId),
            store.fundraiserTokens(fundraiserId),
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status,
            data.isFlexible
        );
    }
    
    /**
     * @notice Gets fundraiser data for modules
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return creator Creator address
     * @return token Token address
     * @return raisedAmount Amount raised so far
     * @return goalAmount Target goal amount
     * @return endDate End timestamp
     * @return status Current status
     * @return isFlexible Whether fundraiser allows partial withdrawals
     */
    function getFundraiserData(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (
        address creator,
        address token,
        uint256 raisedAmount,
        uint256 goalAmount,
        uint256 endDate,
        uint8 status,
        bool isFlexible
    ) {
        IPoliDaoStructs.PackedFundraiserData memory data = store.fundraisers(fundraiserId);
        if (data.id == 0) revert FundraiserNotFound();
        
        return (
            store.fundraiserCreators(fundraiserId),
            store.fundraiserTokens(fundraiserId),
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status,
            data.isFlexible
        );
    }
    
    /**
     * @notice Validates if a fundraiser exists
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID to validate
     * @return exists Whether the fundraiser exists
     */
    function validateFundraiserExists(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (bool exists) {
        return store.fundraisers(fundraiserId).id != 0;
    }
    
    /**
     * @notice Checks if a fundraiser is active and can receive donations
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return isActive Whether the fundraiser is active
     * @return reason Reason if not active
     */
    function isFundraiserActive(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (bool isActive, string memory reason) {
        IPoliDaoStructs.PackedFundraiserData memory data = store.fundraisers(fundraiserId);
        
        if (data.id == 0) {
            return (false, "Fundraiser not found");
        }
        
        if (data.status != uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE)) {
            return (false, "Fundraiser not active");
        }
        
        if (block.timestamp > data.endDate) {
            return (false, "Fundraiser ended");
        }
        
        if (data.isSuspended) {
            return (false, "Fundraiser suspended");
        }
        
        return (true, "Active");
    }
    
    /**
     * @notice Gets fundraiser creator
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return creator Creator address
     */
    function getFundraiserCreator(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (address creator) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        return store.fundraiserCreators(fundraiserId);
    }
    
    /**
     * @notice Gets total fundraiser count
     * @param store The storage contract instance
     * @return count Total number of fundraisers
     */
    function getFundraiserCount(
        PoliDaoStorage store
    ) external view returns (uint256 count) {
        return store.fundraiserCounter();
    }
}