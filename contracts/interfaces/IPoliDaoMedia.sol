// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoMedia
 * @notice Interface for PoliDAO media management module
 * @dev Defines all media-related functions and events
 */
interface IPoliDaoMedia is IPoliDaoStructs {
    
    // ========== EVENTS (USUNIETO DUPLIKATY) ==========
    // Eventy MediaAdded i MediaRemoved zostały usunięte - są w IPoliDaoStructs
    
    event MediaManagerAuthorized(
        uint256 indexed fundraiserId, 
        address indexed manager
    );
    
    event MediaManagerRevoked(
        uint256 indexed fundraiserId, 
        address indexed manager
    );
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Add media to fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaItems Array of media items to add
     */
    function addMediaToFundraiser(
        uint256 fundraiserId,
        MediaItem[] calldata mediaItems
    ) external;
    
    /**
     * @notice Add initial media during fundraiser creation
     * @param fundraiserId The fundraiser ID
     * @param initialImages Array of image IPFS hashes
     * @param initialVideos Array of video IPFS hashes
     * @param creator The fundraiser creator
     */
    function addInitialMedia(
        uint256 fundraiserId,
        string[] calldata initialImages,
        string[] calldata initialVideos,
        address creator
    ) external;
    
    /**
     * @notice Remove media from fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaIndex The media index in gallery
     */
    function removeMediaFromFundraiser(
        uint256 fundraiserId,
        uint256 mediaIndex
    ) external;
    
    // ========== AUTHORIZATION FUNCTIONS ==========
    
    /**
     * @notice Authorize media manager for fundraiser
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
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
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
     * @notice Get fundraiser gallery
     * @param fundraiserId The fundraiser ID
     * @return mediaItems Array of media items
     */
    function getFundraiserGallery(uint256 fundraiserId) 
        external 
        view 
        returns (MediaItem[] memory mediaItems);
    
    /**
     * @notice Get media counts for fundraiser
     * @param fundraiserId The fundraiser ID
     * @return counts Array of media counts by type [images, videos, audio, documents]
     * @return total Total number of media items
     */
    function getMediaCounts(uint256 fundraiserId) 
        external 
        view 
        returns (uint256[4] memory counts, uint256 total);
    
    /**
     * @notice Get media item by index
     * @param fundraiserId The fundraiser ID
     * @param mediaIndex The media index
     * @return mediaItem MediaItem struct
     */
    function getMediaItem(uint256 fundraiserId, uint256 mediaIndex) 
        external 
        view 
        returns (MediaItem memory mediaItem);
    
    /**
     * @notice Check if address is authorized media manager
     * @param fundraiserId The fundraiser ID
     * @param manager The manager address
     * @return isAuthorized Whether address is authorized
     */
    function isAuthorizedMediaManager(uint256 fundraiserId, address manager) 
        external 
        view 
        returns (bool isAuthorized);
    
    /**
     * @notice Check if fundraiser has media
     * @param fundraiserId The fundraiser ID
     * @return hasMedia Whether fundraiser has any media
     */
    function hasMedia(uint256 fundraiserId) external view returns (bool hasMedia);
    
    /**
     * @notice Get gallery size
     * @param fundraiserId The fundraiser ID
     * @return size Number of media items in gallery
     */
    function getGallerySize(uint256 fundraiserId) external view returns (uint256 size);
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
}