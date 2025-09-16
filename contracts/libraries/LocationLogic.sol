// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title LocationLogic
 * @notice Library containing business logic for location management
 * @dev Used by PoliDaoExtensions to handle fundraiser location updates
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 */
library LocationLogic {
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a fundraiser location is updated
    event LocationUpdated(
        uint256 indexed fundraiserId,
        string oldLocation,
        string newLocation
    );
    
    // ========== ERRORS ==========
    
    error FundraiserNotFound();
    error OnlyCreatorCanUpdate();
    error LocationTooLong();
    error SameLocation();
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Updates the location of a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param newLocation The new location string
     * @param caller Address calling the update
     */
    function updateLocation(
        PoliDaoStorage store,
        uint256 fundraiserId,
        string memory newLocation,
        address caller
    )
        internal
    {
        // ========== VALIDATION ==========
        
        // Check fundraiser exists
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        
        // Check caller is creator
        if (store.fundraiserCreators(fundraiserId) != caller) revert OnlyCreatorCanUpdate();
        
        // Check location length
        if (bytes(newLocation).length > store.MAX_LOCATION_LENGTH()) revert LocationTooLong();
        
        // Get old location for event
        string memory oldLocation = store.fundraiserLocations(fundraiserId);
        
        // Check if location is actually different
        if (keccak256(bytes(oldLocation)) == keccak256(bytes(newLocation))) revert SameLocation();
        
        // ========== UPDATE LOCATION ==========
        
        // Emit BEFORE external interaction (CEI)
        emit LocationUpdated(fundraiserId, oldLocation, newLocation);

        // External interaction to storage (state write)
        store.updateFundraiserLocation(fundraiserId, newLocation);
    }
    
    /**
     * @notice Gets the location of a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return location The location string
     */
    function getFundraiserLocation(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (string memory location) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        return store.fundraiserLocations(fundraiserId);
    }
    
    /**
     * @notice Validates location update parameters
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param newLocation The new location
     * @param caller Address wanting to update
     * @return isValid Whether update is valid
     * @return reason Reason if invalid
     */
    function validateLocationUpdate(
        PoliDaoStorage store,
        uint256 fundraiserId,
        string calldata newLocation,
        address caller
    ) external view returns (bool isValid, string memory reason) {
        
        if (store.fundraisers(fundraiserId).id == 0) {
            return (false, "Fundraiser not found");
        }
        
        if (store.fundraiserCreators(fundraiserId) != caller) {
            return (false, "Only creator can update location");
        }
        
        if (bytes(newLocation).length > store.MAX_LOCATION_LENGTH()) {
            return (false, "Location too long");
        }
        
        string memory oldLocation = store.fundraiserLocations(fundraiserId);
        if (keccak256(bytes(oldLocation)) == keccak256(bytes(newLocation))) {
            return (false, "Same as current location");
        }
        
        return (true, "Valid location update");
    }
    
    /**
     * @notice Checks if a user can update location for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param user User address to check
     * @return canUpdate Whether user can update location
     */
    function canUpdateLocation(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address user
    ) external view returns (bool canUpdate) {
        if (store.fundraisers(fundraiserId).id == 0) {
            return false;
        }
        
        return store.fundraiserCreators(fundraiserId) == user;
    }
    
    /**
     * @notice Gets location update constraints
     * @param store The storage contract instance
     * @return maxLength Maximum allowed location length
     */
    function getLocationConstraints(
        PoliDaoStorage store
    ) external view returns (uint256 maxLength) {
        return store.MAX_LOCATION_LENGTH();
    }
}