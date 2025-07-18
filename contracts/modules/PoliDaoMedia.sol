// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoMedia
 * @notice Simple media management module for PoliDAO
 * @dev Handles basic media operations for fundraisers
 */
contract PoliDaoMedia is Ownable, Pausable, IPoliDaoStructs {
    
    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_MEDIA_BATCH = 10;
    uint256 public constant MAX_TOTAL_MEDIA = 100;
    uint256 public constant MAX_IPFS_HASH_LENGTH = 100;
    
    // ========== STORAGE ==========
    
    address public mainContract;
    
    // Fundraiser ID => Media Gallery
    mapping(uint256 => MediaItem[]) public fundraiserGallery;
    
    // Media tracking per fundraiser [images, videos, audio, documents]
    mapping(uint256 => uint256[4]) public mediaTypeCounts;
    
    // Authorization for media management
    mapping(uint256 => mapping(address => bool)) public authorizedMediaManagers;
    
    // ========== EVENTS ==========
    
    event MediaManagerAuthorized(uint256 indexed fundraiserId, address indexed manager);
    event MediaManagerRevoked(uint256 indexed fundraiserId, address indexed manager);
    
    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    modifier onlyMediaManager(uint256 fundraiserId) {
        require(
            msg.sender == mainContract || 
            authorizedMediaManagers[fundraiserId][msg.sender], 
            "Not authorized"
        );
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
        mainContract = _mainContract;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        mainContract = _newMainContract;
    }
    
    // ========== MEDIA FUNCTIONS ==========
    
    /**
     * @notice Add media to fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaItems Array of media items to add
     */
    function addMediaToFundraiser(
        uint256 fundraiserId,
        MediaItem[] calldata mediaItems
    ) 
        external 
        whenNotPaused 
        onlyMainContract
    {
        require(mediaItems.length <= MAX_MEDIA_BATCH, "Too many media items");
        
        MediaItem[] storage gallery = fundraiserGallery[fundraiserId];
        require(gallery.length + mediaItems.length <= MAX_TOTAL_MEDIA, "Media limit exceeded");
        
        uint256[4] storage typeCounts = mediaTypeCounts[fundraiserId];
        
        for (uint256 i = 0; i < mediaItems.length; i++) {
            MediaItem memory item = mediaItems[i];
            
            // Basic validation
            require(bytes(item.ipfsHash).length > 0, "Empty IPFS hash");
            require(bytes(item.ipfsHash).length <= MAX_IPFS_HASH_LENGTH, "IPFS hash too long");
            require(item.mediaType <= 3, "Invalid media type");
            
            // Create media item
            MediaItem memory newItem = MediaItem({
                ipfsHash: item.ipfsHash,
                mediaType: item.mediaType,
                filename: item.filename,
                uploadTime: block.timestamp,
                uploader: tx.origin, // Real user
                description: item.description
            });
            
            gallery.push(newItem);
            typeCounts[item.mediaType]++;
            
            emit MediaAdded(fundraiserId, item.ipfsHash, item.mediaType, tx.origin);
        }
    }
    
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
    ) 
        external 
        onlyMainContract
    {
        require(initialImages.length <= 10, "Too many images");
        require(initialVideos.length <= 3, "Too many videos");
        
        MediaItem[] storage gallery = fundraiserGallery[fundraiserId];
        uint256[4] storage typeCounts = mediaTypeCounts[fundraiserId];
        
        // Add images
        for (uint256 i = 0; i < initialImages.length; i++) {
            require(bytes(initialImages[i]).length > 0, "Empty image hash");
            
            MediaItem memory newImage = MediaItem({
                ipfsHash: initialImages[i],
                mediaType: 0, // image
                filename: string.concat("image_", _toString(i + 1), ".jpg"),
                uploadTime: block.timestamp,
                uploader: creator,
                description: "Initial image"
            });
            
            gallery.push(newImage);
            typeCounts[0]++;
            
            emit MediaAdded(fundraiserId, initialImages[i], 0, creator);
        }
        
        // Add videos
        for (uint256 i = 0; i < initialVideos.length; i++) {
            require(bytes(initialVideos[i]).length > 0, "Empty video hash");
            
            MediaItem memory newVideo = MediaItem({
                ipfsHash: initialVideos[i],
                mediaType: 1, // video
                filename: string.concat("video_", _toString(i + 1), ".mp4"),
                uploadTime: block.timestamp,
                uploader: creator,
                description: "Initial video"
            });
            
            gallery.push(newVideo);
            typeCounts[1]++;
            
            emit MediaAdded(fundraiserId, initialVideos[i], 1, creator);
        }
    }
    
    /**
     * @notice Remove media from fundraiser
     * @param fundraiserId The fundraiser ID
     * @param mediaIndex The media index in gallery
     */
    function removeMediaFromFundraiser(
        uint256 fundraiserId,
        uint256 mediaIndex
    ) 
        external 
        whenNotPaused 
        onlyMediaManager(fundraiserId)
    {
        MediaItem[] storage gallery = fundraiserGallery[fundraiserId];
        require(mediaIndex < gallery.length, "Invalid media index");
        
        MediaItem storage mediaToRemove = gallery[mediaIndex];
        uint8 mediaType = mediaToRemove.mediaType;
        string memory ipfsHash = mediaToRemove.ipfsHash;
        
        // Update counter
        mediaTypeCounts[fundraiserId][mediaType]--;
        
        // Remove from gallery (move last to deleted position and pop)
        gallery[mediaIndex] = gallery[gallery.length - 1];
        gallery.pop();
        
        emit MediaRemoved(fundraiserId, mediaIndex, ipfsHash);
    }
    
    // ========== AUTHORIZATION FUNCTIONS ==========
    
    /**
     * @notice Authorize media manager for fundraiser
     */
    function authorizeMediaManager(uint256 fundraiserId, address manager) 
        external 
        onlyMainContract
    {
        require(manager != address(0), "Invalid manager");
        authorizedMediaManagers[fundraiserId][manager] = true;
        emit MediaManagerAuthorized(fundraiserId, manager);
    }
    
    /**
     * @notice Revoke media manager authorization
     */
    function revokeMediaManager(uint256 fundraiserId, address manager) 
        external 
        onlyMainContract
    {
        authorizedMediaManagers[fundraiserId][manager] = false;
        emit MediaManagerRevoked(fundraiserId, manager);
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get fundraiser gallery
     * @param fundraiserId The fundraiser ID
     */
    function getFundraiserGallery(uint256 fundraiserId) 
        external 
        view 
        returns (MediaItem[] memory) 
    {
        return fundraiserGallery[fundraiserId];
    }
    
    /**
     * @notice Get media counts for fundraiser
     * @param fundraiserId The fundraiser ID
     */
    function getMediaCounts(uint256 fundraiserId) 
        external 
        view 
        returns (uint256[4] memory counts, uint256 total) 
    {
        counts = mediaTypeCounts[fundraiserId];
        total = fundraiserGallery[fundraiserId].length;
    }
    
    /**
     * @notice Get media item by index
     * @param fundraiserId The fundraiser ID
     * @param mediaIndex The media index
     */
    function getMediaItem(uint256 fundraiserId, uint256 mediaIndex) 
        external 
        view 
        returns (MediaItem memory) 
    {
        require(mediaIndex < fundraiserGallery[fundraiserId].length, "Invalid index");
        return fundraiserGallery[fundraiserId][mediaIndex];
    }
    
    /**
     * @notice Check if address is authorized media manager
     * @param fundraiserId The fundraiser ID
     * @param manager The manager address
     */
    function isAuthorizedMediaManager(uint256 fundraiserId, address manager) 
        external 
        view 
        returns (bool) 
    {
        return authorizedMediaManagers[fundraiserId][manager];
    }
    
    /**
     * @notice Check if fundraiser has media
     * @param fundraiserId The fundraiser ID
     */
    function hasMedia(uint256 fundraiserId) external view returns (bool) {
        return fundraiserGallery[fundraiserId].length > 0;
    }
    
    /**
     * @notice Get gallery size
     * @param fundraiserId The fundraiser ID
     */
    function getGallerySize(uint256 fundraiserId) external view returns (uint256) {
        return fundraiserGallery[fundraiserId].length;
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Convert uint256 to string
     * @param value The value to convert
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}