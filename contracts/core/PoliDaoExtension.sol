// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../libraries/ExtensionLogic.sol";
import "../libraries/LocationLogic.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PoliDaoExtensions
 * @notice Extension features for PoliDAO platform - handles advanced functionality
 * @dev Uses unified storage pattern with extension logic libraries
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 * @custom:security-contact security@polidao.org
 */
contract PoliDaoExtensions is ReentrancyGuard {
    
    // ========== STORAGE AND DEPENDENCIES ==========
    
    /// @notice Unified storage contract
    PoliDaoStorage public storageContract;
    
    /// @notice Core contract address
    address public coreContract;
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when core contract is updated
    event CoreContractUpdated(address indexed oldCore, address indexed newCore);
    
    // ========== MODIFIERS ==========
    
    /// @notice Ensures only core contract can call certain functions
    modifier onlyCore() {
        require(msg.sender == coreContract, "PoliDaoExtensions: Only core contract");
        _;
    }
    
    /// @notice Ensures caller is authorized (core contract or authorized caller)
    modifier onlyAuthorized() {
        require(
            msg.sender == coreContract || 
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoExtensions: Not authorized"
        );
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    /**
     * @notice Initializes the extensions contract
     * @param _storageContract Address of the unified storage contract
     * @param _coreContract Address of the core contract
     */
    // legacy constructor
    constructor(address _storageContract, address _coreContract) {
        require(_storageContract != address(0), "PoliDaoExtensions: Invalid storage contract");
        require(_coreContract != address(0), "PoliDaoExtensions: Invalid core contract");
        storageContract = PoliDaoStorage(_storageContract);
        coreContract = _coreContract;
    }

    // initializer for clone deployments
    bool private _initialized;

    function initialize(address _storageContract, address _coreContract) external {
        require(!_initialized, "PoliDaoExtensions: already initialized");
        require(_storageContract != address(0), "PoliDaoExtensions: Invalid storage contract");
        require(_coreContract != address(0), "PoliDaoExtensions: Invalid core contract");
        _initialized = true;
        storageContract = PoliDaoStorage(_storageContract);
        coreContract = _coreContract;
    }
    
    // ========== EXTENSION FUNCTIONS ==========
    
    /**
     * @notice Extends a fundraiser's end date
     * @param fundraiserId The fundraiser ID to extend
     * @param additionalDays Number of additional days
     * @param caller Original caller address
     */
    function extendFundraiser(
        uint256 fundraiserId, 
        uint256 additionalDays, 
        address caller
    ) external onlyAuthorized nonReentrant {
        ExtensionLogic.extendFundraiser(
            storageContract,
            fundraiserId,
            additionalDays,
            caller
        );
    }
    
    /**
     * @notice Updates the location of a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param newLocation The new location string
     * @param caller Original caller address
     */
    function updateLocation(
        uint256 fundraiserId, 
        string calldata newLocation, 
        address caller
    ) external onlyAuthorized {
        LocationLogic.updateLocation(
            storageContract,
            fundraiserId,
            newLocation,
            caller
        );
    }
    
    /**
     * @notice Suspends a fundraiser (delegates to security module)
     * @param fundraiserId The fundraiser ID
     * @param reason Suspension reason
     * @param caller Original caller address
     */
    function suspendFundraiser(
        uint256 fundraiserId, 
        string calldata reason,
        address caller
    ) external onlyAuthorized {
        address securityModule = storageContract.modules(keccak256("SECURITY_MODULE"));
        require(securityModule != address(0), "PoliDaoExtensions: Security module not set");
        
        // Delegate to security module
        (bool success,) = securityModule.delegatecall(
            abi.encodeWithSignature(
                "suspendFundraiser(uint256,string,address)",
                fundraiserId,
                reason,
                caller
            )
        );
        require(success, "PoliDaoExtensions: Suspension failed");
    }
    
    /**
     * @notice Unsuspends a fundraiser (delegates to security module)
     * @param fundraiserId The fundraiser ID
     * @param caller Original caller address
     */
    function unsuspendFundraiser(uint256 fundraiserId, address caller) 
        external onlyAuthorized {
        address securityModule = storageContract.modules(keccak256("SECURITY_MODULE"));
        require(securityModule != address(0), "PoliDaoExtensions: Security module not set");
        
        // Delegate to security module
        (bool success,) = securityModule.delegatecall(
            abi.encodeWithSignature(
                "unsuspendFundraiser(uint256,address)",
                fundraiserId,
                caller
            )
        );
        require(success, "PoliDaoExtensions: Unsuspension failed");
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Checks if a fundraiser can be extended
     * @param fundraiserId The fundraiser ID
     * @param caller Address wanting to extend
     * @return canExtend Whether the fundraiser can be extended
     * @return timeLeft Time remaining until fundraiser ends
     * @return reason Human-readable reason for the result
     */
    function canExtendFundraiser(uint256 fundraiserId, address caller) 
        external 
        view 
        returns (bool canExtend, uint256 timeLeft, string memory reason) 
    {
        return ExtensionLogic.canExtendFundraiser(storageContract, fundraiserId, caller);
    }
    
    /**
     * @notice Gets extension information for a fundraiser
     * @param fundraiserId The fundraiser ID
     * @return extensionCount Number of times extended
     * @return originalEndDate Original end date timestamp
     * @return currentEndDate Current end date timestamp
     * @return canExtendMore Whether more extensions are possible
     * @return maxExtensions Maximum allowed extensions
     */
    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            uint256 extensionCount,
            uint256 originalEndDate,
            uint256 currentEndDate,
            bool canExtendMore,
            uint256 maxExtensions
        ) 
    {
        return ExtensionLogic.getExtensionInfo(storageContract, fundraiserId);
    }
    
    /**
     * @notice Gets the location of a fundraiser
     * @param fundraiserId The fundraiser ID
     * @return location The location string
     */
    function getFundraiserLocation(uint256 fundraiserId) 
        external 
        view 
        returns (string memory location) 
    {
        return LocationLogic.getFundraiserLocation(storageContract, fundraiserId);
    }
    
    /**
     * @notice Calculates extension fee for a fundraiser
     * @return fee Extension fee amount
     * @return feeToken Token address for fee payment
     */
    function getExtensionFee() 
        external 
        view 
        returns (uint256 fee, address feeToken) 
    {
        return ExtensionLogic.getExtensionFee(storageContract);
    }
    
    /**
     * @notice Validates extension parameters
     * @param fundraiserId The fundraiser ID
     * @param additionalDays Number of days to extend
     * @param caller Address wanting to extend
     * @return isValid Whether extension is valid
     * @return reason Reason if invalid
     */
    function validateExtension(
        uint256 fundraiserId,
        uint256 additionalDays,
        address caller
    ) external view returns (bool isValid, string memory reason) {
        return ExtensionLogic.validateExtension(
            storageContract,
            fundraiserId,
            additionalDays,
            caller
        );
    }
    
    /**
     * @notice Validates location update parameters
     * @param fundraiserId The fundraiser ID
     * @param newLocation The new location
     * @param caller Address wanting to update
     * @return isValid Whether update is valid
     * @return reason Reason if invalid
     */
    function validateLocationUpdate(
        uint256 fundraiserId,
        string calldata newLocation,
        address caller
    ) external view returns (bool isValid, string memory reason) {
        return LocationLogic.validateLocationUpdate(
            storageContract,
            fundraiserId,
            newLocation,
            caller
        );
    }
    
    /**
     * @notice Checks if a user can update location for a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param user User address to check
     * @return canUpdate Whether user can update location
     */
    function canUpdateLocation(uint256 fundraiserId, address user) 
        external 
        view 
        returns (bool canUpdate) 
    {
        return LocationLogic.canUpdateLocation(storageContract, fundraiserId, user);
    }
    
    /**
     * @notice Gets time until extension deadline
     * @param fundraiserId The fundraiser ID
     * @return timeUntilDeadline Time until extension is no longer possible
     * @return canStillExtend Whether extension is still possible
     */
    function getTimeUntilExtensionDeadline(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 timeUntilDeadline, bool canStillExtend) 
    {
        return ExtensionLogic.getTimeUntilExtensionDeadline(storageContract, fundraiserId);
    }
    
    /**
     * @notice Gets location update constraints
     * @return maxLength Maximum allowed location length
     */
    function getLocationConstraints() 
        external 
        view 
        returns (uint256 maxLength) 
    {
        return LocationLogic.getLocationConstraints(storageContract);
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Emergency function to pause extensions (if needed in future)
     * @dev Currently not implemented, placeholder for future functionality
     */
    function emergencyPause() external view onlyCore {
        // Placeholder for future emergency functionality
        revert("PoliDaoExtensions: Emergency pause not implemented");
    }
    
    /**
     * @notice Gets contract status and configuration
     * @return storageAddress Address of storage contract
     * @return coreAddress Address of core contract
     * @return isAuthorized Whether this contract is authorized in storage
     */
    function getContractStatus() 
        external 
        view 
        returns (
            address storageAddress,
            address coreAddress,
            bool isAuthorized
        ) 
    {
        return (
            address(storageContract),
            coreContract,
            storageContract.isContractAuthorized(address(this))
        );
    }
    
    // ========== HELPER FUNCTIONS ==========
    
    /**
     * @notice Checks if fundraiser exists
     * @param fundraiserId The fundraiser ID
     * @return exists Whether the fundraiser exists
     */
    function fundraiserExists(uint256 fundraiserId) 
        external 
        view 
        returns (bool exists) 
    {
        return storageContract.fundraisers(fundraiserId).id != 0;
    }
    
    /**
     * @notice Gets fundraiser creator
     * @param fundraiserId The fundraiser ID
     * @return creator Creator address
     */
    function getFundraiserCreator(uint256 fundraiserId) 
        external 
        view 
        returns (address creator) 
    {
        return storageContract.fundraiserCreators(fundraiserId);
    }
    
    /**
     * @notice Gets fundraiser end date
     * @param fundraiserId The fundraiser ID
     * @return endDate End date timestamp
     */
    function getFundraiserEndDate(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 endDate) 
    {
        return storageContract.fundraisers(fundraiserId).endDate;
    }
    
    /**
     * @notice Checks if fundraiser is active
     * @param fundraiserId The fundraiser ID
     * @return isActive Whether the fundraiser is active
     */
    function isFundraiserActive(uint256 fundraiserId) 
        external 
        view 
        returns (bool isActive) 
    {
        IPoliDaoStructs.PackedFundraiserData memory data = storageContract.fundraisers(fundraiserId);
        return (
            data.id != 0 &&
            data.status == uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE) &&
            !data.isSuspended &&
            block.timestamp <= data.endDate
        );
    }
    
    /**
     * @notice Gets extension statistics
     * @return totalExtensions Total number of extensions across all fundraisers
     * @return averageExtensionDays Average number of days per extension
     * @return maxExtensionsAllowed Maximum extensions allowed per fundraiser
     */
    function getExtensionStatistics() 
        external 
        view 
        returns (
            uint256 totalExtensions,
            uint256 averageExtensionDays,
            uint256 maxExtensionsAllowed
        ) 
    {
        // This would require tracking in storage for real implementation
        // For now, return basic info
        maxExtensionsAllowed = storageContract.MAX_EXTENSIONS();
        
        // TODO: Implement actual statistics tracking
        totalExtensions = 0;
        averageExtensionDays = 0;
        
        return (totalExtensions, averageExtensionDays, maxExtensionsAllowed);
    }
}