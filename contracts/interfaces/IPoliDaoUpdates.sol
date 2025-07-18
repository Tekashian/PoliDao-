// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoUpdates
 * @notice Interface for PoliDAO updates management module
 * @dev Defines all update-related functions and events
 */
interface IPoliDaoUpdates is IPoliDaoStructs {
    
    // ========== EVENTS (USUNIETO DUPLIKATY) ==========
    // Eventy UpdatePosted i UpdatePinned zostały usunięte - są w IPoliDaoStructs
    
    event UpdateUnpinned(
        uint256 indexed fundraiserId, 
        uint256 indexed oldUpdateId
    );
    
    event UpdaterAuthorized(
        uint256 indexed fundraiserId, 
        address indexed updater
    );
    
    event UpdaterRevoked(
        uint256 indexed fundraiserId, 
        address indexed updater
    );
    
    event MediaContractUpdated(
        address indexed oldContract, 
        address indexed newContract
    );
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Post a regular update
     * @param fundraiserId The fundraiser ID
     * @param content The update content
     * @param author The author address
     * @return updateId The ID of the created update
     */
    function postUpdate(
        uint256 fundraiserId,
        string calldata content,
        address author
    ) external returns (uint256 updateId);
    
    /**
     * @notice Post update with media attachments
     * @param fundraiserId The fundraiser ID
     * @param content The update content
     * @param updateType The update type (0=regular, 1=important, 2=milestone)
     * @param mediaIds Array of media IDs to attach
     * @param author The author address
     * @return updateId The ID of the created update
     */
    function postUpdateWithMedia(
        uint256 fundraiserId,
        string calldata content,
        uint8 updateType,
        uint256[] calldata mediaIds,
        address author
    ) external returns (uint256 updateId);
    
    /**
     * @notice Create initial update for new fundraiser
     * @param fundraiserId The fundraiser ID
     * @param description The fundraiser description
     * @param author The author address
     * @return updateId The ID of the created update
     */
    function createInitialUpdate(
        uint256 fundraiserId,
        string calldata description,
        address author
    ) external returns (uint256 updateId);
    
    /**
     * @notice Pin an update
     * @param updateId The update ID
     */
    function pinUpdate(uint256 updateId) external;
    
    /**
     * @notice Unpin update
     * @param fundraiserId The fundraiser ID
     */
    function unpinUpdate(uint256 fundraiserId) external;
    
    // ========== AUTHORIZATION FUNCTIONS ==========
    
    /**
     * @notice Authorize updater for fundraiser
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     */
    function authorizeUpdater(uint256 fundraiserId, address updater) external;
    
    /**
     * @notice Revoke updater authorization
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     */
    function revokeUpdater(uint256 fundraiserId, address updater) external;
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
    /**
     * @notice Set media contract address
     * @param newMediaContract New media contract address
     */
    function setMediaContract(address newMediaContract) external;
    
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
     * @notice Get update details
     * @param updateId The update ID
     * @return id Update ID
     * @return fundraiserId Fundraiser ID
     * @return author Author address
     * @return content Update content
     * @return timestamp Creation timestamp
     * @return updateType Update type
     * @return isPinned Whether update is pinned
     * @return mediaIds Array of attached media IDs
     */
    function getUpdate(uint256 updateId) 
        external 
        view 
        returns (
            uint256 id,
            uint256 fundraiserId,
            address author,
            string memory content,
            uint256 timestamp,
            uint8 updateType,
            bool isPinned,
            uint256[] memory mediaIds
        );
    
    /**
     * @notice Get fundraiser updates with pagination
     * @param fundraiserId The fundraiser ID
     * @param offset Starting index
     * @param limit Number of updates to return
     * @return updateIds Array of update IDs
     * @return total Total number of updates
     */
    function getFundraiserUpdates(
        uint256 fundraiserId,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory updateIds, uint256 total);
    
    /**
     * @notice Get pinned update for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return updateId ID of pinned update (0 if none)
     */
    function getPinnedUpdate(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 updateId);
    
    /**
     * @notice Get updates by author
     * @param author The author address
     * @param offset Starting index
     * @param limit Number of updates to return
     * @return updateIds Array of update IDs
     * @return total Total number of updates
     */
    function getUpdatesByAuthor(
        address author,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory updateIds, uint256 total);
    
    /**
     * @notice Get recent updates across all fundraisers
     * @param limit Number of recent updates to return
     * @return updateIds Array of update IDs
     */
    function getRecentUpdates(uint256 limit) 
        external 
        view 
        returns (uint256[] memory updateIds);
    
    /**
     * @notice Get update count for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return count Number of updates for fundraiser
     */
    function getFundraiserUpdateCount(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 count);
    
    /**
     * @notice Get user's update count
     * @param user The user address
     * @return count Number of updates created by user
     */
    function getUserUpdateCount(address user) 
        external 
        view 
        returns (uint256 count);
    
    /**
     * @notice Check if address is authorized updater
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     * @return isAuthorized Whether address is authorized
     */
    function isAuthorizedUpdater(uint256 fundraiserId, address updater) 
        external 
        view 
        returns (bool isAuthorized);
    
    /**
     * @notice Get total update count
     * @return count Total number of updates
     */
    function getUpdateCount() external view returns (uint256 count);
    
    /**
     * @notice Get update media attachments
     * @param updateId The update ID
     * @return mediaIds Array of media IDs attached to update
     */
    function getUpdateMediaIds(uint256 updateId) 
        external 
        view 
        returns (uint256[] memory mediaIds);
    
    /**
     * @notice Check if update has media attachments
     * @param updateId The update ID
     * @return hasAttachments Whether update has media attachments
     */
    function hasMediaAttachments(uint256 updateId) 
        external 
        view 
        returns (bool hasAttachments);
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
    
    /**
     * @notice Get media contract address
     * @return contractAddress Media contract address
     */
    function mediaContract() external view returns (address contractAddress);
}