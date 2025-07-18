// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoUpdates
 * @notice Updates management module for PoliDAO
 * @dev Handles fundraiser updates, pinning system, and media attachments
 */
contract PoliDaoUpdates is Ownable, Pausable, IPoliDaoStructs {
    
    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_UPDATE_LENGTH = 1000;
    uint256 public constant MAX_MEDIA_PER_UPDATE = 5;
    
    // ========== STORAGE ==========
    
    address public mainContract;
    address public mediaContract;
    uint256 public updateCount;
    
    // Update ID => Update
    mapping(uint256 => FundraiserUpdate) public updates;
    
    // Fundraiser ID => Update IDs array
    mapping(uint256 => uint256[]) public fundraiserUpdates;
    
    // Fundraiser ID => Pinned Update ID
    mapping(uint256 => uint256) public pinnedUpdateId;
    
    // Authorization for updates
    mapping(uint256 => mapping(address => bool)) public authorizedUpdaters;
    
    // User => total updates count
    mapping(address => uint256) public userUpdateCount;
    
    // ========== EVENTS ==========
    
    event UpdateUnpinned(uint256 indexed fundraiserId, uint256 indexed oldUpdateId);
    event UpdaterAuthorized(uint256 indexed fundraiserId, address indexed updater);
    event UpdaterRevoked(uint256 indexed fundraiserId, address indexed updater);
    event MediaContractUpdated(address indexed oldContract, address indexed newContract);
    
    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    modifier onlyAuthorizedUpdater(uint256 fundraiserId) {
        require(
            msg.sender == mainContract || 
            authorizedUpdaters[fundraiserId][msg.sender], 
            "Not authorized"
        );
        _;
    }
    
    modifier validUpdateId(uint256 updateId) {
        require(updateId > 0 && updateId <= updateCount, "Invalid update ID");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract, address _mediaContract) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
        require(_mediaContract != address(0), "Invalid media contract");
        mainContract = _mainContract;
        mediaContract = _mediaContract;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        mainContract = _newMainContract;
    }
    
    function setMediaContract(address _newMediaContract) external onlyOwner {
        require(_newMediaContract != address(0), "Invalid address");
        address oldContract = mediaContract;
        mediaContract = _newMediaContract;
        emit MediaContractUpdated(oldContract, _newMediaContract);
    }
    
    // ========== UPDATE FUNCTIONS ==========
    
    /**
     * @notice Post a regular update
     * @param fundraiserId The fundraiser ID
     * @param content The update content
     * @param author The author address
     */
    function postUpdate(
        uint256 fundraiserId,
        string calldata content,
        address author
    ) 
        external 
        whenNotPaused 
        onlyMainContract
        returns (uint256 updateId)
    {
        require(bytes(content).length > 0, "Empty content");
        require(bytes(content).length <= MAX_UPDATE_LENGTH, "Content too long");
        
        updateCount++;
        updateId = updateCount;
        
        FundraiserUpdate storage update = updates[updateId];
        update.id = updateId;
        update.fundraiserId = fundraiserId;
        update.author = author;
        update.content = content;
        update.timestamp = block.timestamp;
        update.updateType = 0; // Regular update
        update.isPinned = false;
        
        // Add to fundraiser updates
        fundraiserUpdates[fundraiserId].push(updateId);
        
        // Update user counter
        userUpdateCount[author]++;
        
        emit UpdatePosted(updateId, fundraiserId, author, content, 0);
        
        return updateId;
    }
    
    /**
     * @notice Post update with media attachments
     * @param fundraiserId The fundraiser ID
     * @param content The update content
     * @param updateType The update type (0=regular, 1=important, 2=milestone)
     * @param mediaIds Array of media IDs to attach
     * @param author The author address
     */
    function postUpdateWithMedia(
        uint256 fundraiserId,
        string calldata content,
        uint8 updateType,
        uint256[] calldata mediaIds,
        address author
    ) 
        external 
        whenNotPaused 
        onlyMainContract
        returns (uint256 updateId)
    {
        require(bytes(content).length > 0, "Empty content");
        require(bytes(content).length <= MAX_UPDATE_LENGTH, "Content too long");
        require(mediaIds.length <= MAX_MEDIA_PER_UPDATE, "Too many media attachments");
        require(updateType <= 2, "Invalid update type");
        
        updateCount++;
        updateId = updateCount;
        
        FundraiserUpdate storage update = updates[updateId];
        update.id = updateId;
        update.fundraiserId = fundraiserId;
        update.author = author;
        update.content = content;
        update.timestamp = block.timestamp;
        update.updateType = updateType;
        update.isPinned = false;
        
        // Add media references
        for (uint256 i = 0; i < mediaIds.length; i++) {
            update.mediaIds.push(mediaIds[i]);
        }
        
        // Add to fundraiser updates
        fundraiserUpdates[fundraiserId].push(updateId);
        
        // Update user counter
        userUpdateCount[author]++;
        
        // Auto-pin important updates and milestones
        if (updateType == 1 || updateType == 2) {
            _pinUpdate(updateId, fundraiserId);
        }
        
        emit UpdatePosted(updateId, fundraiserId, author, content, updateType);
        
        return updateId;
    }
    
    /**
     * @notice Create initial update for new fundraiser
     * @param fundraiserId The fundraiser ID
     * @param description The fundraiser description
     * @param author The author address
     */
    function createInitialUpdate(
        uint256 fundraiserId,
        string calldata description,
        address author
    ) 
        external 
        whenNotPaused 
        onlyMainContract
        returns (uint256 updateId)
    {
        updateCount++;
        updateId = updateCount;
        
        FundraiserUpdate storage update = updates[updateId];
        update.id = updateId;
        update.fundraiserId = fundraiserId;
        update.author = author;
        update.content = description;
        update.timestamp = block.timestamp;
        update.updateType = 0; // Regular update
        update.isPinned = true; // Initial update is always pinned
        
        // Add to fundraiser updates
        fundraiserUpdates[fundraiserId].push(updateId);
        
        // Set as pinned update
        pinnedUpdateId[fundraiserId] = updateId;
        
        // Update user counter
        userUpdateCount[author]++;
        
        emit UpdatePosted(updateId, fundraiserId, author, description, 0);
        emit UpdatePinned(updateId, fundraiserId);
        
        return updateId;
    }
    
    /**
     * @notice Pin an update
     * @param updateId The update ID
     */
    function pinUpdate(uint256 updateId) 
        external 
        whenNotPaused 
        validUpdateId(updateId)
    {
        FundraiserUpdate storage update = updates[updateId];
        uint256 fundraiserId = update.fundraiserId;
        
        // Check authorization through main contract
        require(
            msg.sender == mainContract || 
            authorizedUpdaters[fundraiserId][msg.sender], 
            "Not authorized"
        );
        
        _pinUpdate(updateId, fundraiserId);
    }
    
    /**
     * @notice Unpin update
     * @param fundraiserId The fundraiser ID
     */
    function unpinUpdate(uint256 fundraiserId) 
        external 
        whenNotPaused
    {
        require(
            msg.sender == mainContract || 
            authorizedUpdaters[fundraiserId][msg.sender], 
            "Not authorized"
        );
        
        uint256 currentPinnedId = pinnedUpdateId[fundraiserId];
        require(currentPinnedId != 0, "No pinned update");
        
        // Unpin current update
        updates[currentPinnedId].isPinned = false;
        pinnedUpdateId[fundraiserId] = 0;
        
        emit UpdateUnpinned(fundraiserId, currentPinnedId);
    }
    
    // ========== AUTHORIZATION FUNCTIONS ==========
    
    /**
     * @notice Authorize updater for fundraiser
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     */
    function authorizeUpdater(uint256 fundraiserId, address updater) 
        external 
        onlyMainContract
    {
        require(updater != address(0), "Invalid updater");
        authorizedUpdaters[fundraiserId][updater] = true;
        emit UpdaterAuthorized(fundraiserId, updater);
    }
    
    /**
     * @notice Revoke updater authorization
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     */
    function revokeUpdater(uint256 fundraiserId, address updater) 
        external 
        onlyMainContract
    {
        authorizedUpdaters[fundraiserId][updater] = false;
        emit UpdaterRevoked(fundraiserId, updater);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get update details
     * @param updateId The update ID
     */
    function getUpdate(uint256 updateId) 
        external 
        view 
        validUpdateId(updateId)
        returns (
            uint256 id,
            uint256 fundraiserId,
            address author,
            string memory content,
            uint256 timestamp,
            uint8 updateType,
            bool isPinned,
            uint256[] memory mediaIds
        ) 
    {
        FundraiserUpdate storage update = updates[updateId];
        return (
            update.id,
            update.fundraiserId,
            update.author,
            update.content,
            update.timestamp,
            update.updateType,
            update.isPinned,
            update.mediaIds
        );
    }
    
    /**
     * @notice Get fundraiser updates with pagination
     * @param fundraiserId The fundraiser ID
     * @param offset Starting index
     * @param limit Number of updates to return
     */
    function getFundraiserUpdates(
        uint256 fundraiserId,
        uint256 offset,
        uint256 limit
    ) 
        external 
        view 
        returns (uint256[] memory updateIds, uint256 total) 
    {
        uint256[] storage allUpdateIds = fundraiserUpdates[fundraiserId];
        total = allUpdateIds.length;
        
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        updateIds = new uint256[](end - offset);
        
        // Return in reverse order (newest first)
        for (uint256 i = 0; i < end - offset; i++) {
            uint256 reverseIndex = total - 1 - offset - i;
            updateIds[i] = allUpdateIds[reverseIndex];
        }
    }
    
    /**
     * @notice Get pinned update for fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function getPinnedUpdate(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 updateId) 
    {
        return pinnedUpdateId[fundraiserId];
    }
    
    /**
     * @notice Get updates by author
     * @param author The author address
     * @param offset Starting index
     * @param limit Number of updates to return
     */
    function getUpdatesByAuthor(
        address author,
        uint256 offset,
        uint256 limit
    ) 
        external 
        view 
        returns (uint256[] memory updateIds, uint256 total) 
    {
        // Count total updates by author
        uint256 count = 0;
        uint256[] memory authorUpdateIds = new uint256[](updateCount);
        
        for (uint256 i = 1; i <= updateCount; i++) {
            if (updates[i].author == author) {
                authorUpdateIds[count] = i;
                count++;
            }
        }
        
        total = count;
        
        if (offset >= total) {
            return (new uint256[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        updateIds = new uint256[](end - offset);
        
        // Return in reverse order (newest first)
        for (uint256 i = 0; i < end - offset; i++) {
            uint256 reverseIndex = total - 1 - offset - i;
            updateIds[i] = authorUpdateIds[reverseIndex];
        }
    }
    
    /**
     * @notice Get recent updates across all fundraisers
     * @param limit Number of recent updates to return
     */
    function getRecentUpdates(uint256 limit) 
        external 
        view 
        returns (uint256[] memory updateIds) 
    {
        if (limit > updateCount) limit = updateCount;
        
        updateIds = new uint256[](limit);
        
        // Return most recent updates
        for (uint256 i = 0; i < limit; i++) {
            updateIds[i] = updateCount - i;
        }
    }
    
    /**
     * @notice Get update count for fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function getFundraiserUpdateCount(uint256 fundraiserId) 
        external 
        view 
        returns (uint256) 
    {
        return fundraiserUpdates[fundraiserId].length;
    }
    
    /**
     * @notice Get user's update count
     * @param user The user address
     */
    function getUserUpdateCount(address user) 
        external 
        view 
        returns (uint256) 
    {
        return userUpdateCount[user];
    }
    
    /**
     * @notice Check if address is authorized updater
     * @param fundraiserId The fundraiser ID
     * @param updater The updater address
     */
    function isAuthorizedUpdater(uint256 fundraiserId, address updater) 
        external 
        view 
        returns (bool) 
    {
        return authorizedUpdaters[fundraiserId][updater];
    }
    
    /**
     * @notice Get total update count
     */
    function getUpdateCount() external view returns (uint256) {
        return updateCount;
    }
    
    /**
     * @notice Get update media attachments
     * @param updateId The update ID
     */
    function getUpdateMediaIds(uint256 updateId) 
        external 
        view 
        validUpdateId(updateId)
        returns (uint256[] memory) 
    {
        return updates[updateId].mediaIds;
    }
    
    /**
     * @notice Check if update has media attachments
     * @param updateId The update ID
     */
    function hasMediaAttachments(uint256 updateId) 
        external 
        view 
        validUpdateId(updateId)
        returns (bool) 
    {
        return updates[updateId].mediaIds.length > 0;
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Internal function to pin an update
     * @param updateId The update ID
     * @param fundraiserId The fundraiser ID
     */
    function _pinUpdate(uint256 updateId, uint256 fundraiserId) internal {
        uint256 currentPinnedId = pinnedUpdateId[fundraiserId];
        
        // Unpin current update if exists
        if (currentPinnedId != 0 && currentPinnedId != updateId) {
            updates[currentPinnedId].isPinned = false;
            emit UpdateUnpinned(fundraiserId, currentPinnedId);
        }
        
        // Pin new update
        updates[updateId].isPinned = true;
        pinnedUpdateId[fundraiserId] = updateId;
        
        emit UpdatePinned(updateId, fundraiserId);
    }
}