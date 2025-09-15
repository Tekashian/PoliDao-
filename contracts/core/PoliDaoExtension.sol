// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../libraries/ExtensionLogic.sol";
import "../libraries/LocationLogic.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Minimal interface to read owner from core
interface IOwned {
    function owner() external view returns (address);
}

contract PoliDaoExtension is Ownable, ReentrancyGuard {
    
    // ========== STORAGE AND DEPENDENCIES ==========
    
    /// @notice Unified storage contract
    PoliDaoStorage public storageContract;
    
    /// @notice Core contract address
    address public coreContract;
    
    // Zabezpieczenia modułu bezpieczeństwa
    address public securityModule;
    bool public securityModuleFrozen;
    mapping(address => bool) private securityModuleWhitelist;

    event SecurityModuleUpdated(address indexed newModule);
    event SecurityModuleFrozen();
    event SecurityModuleWhitelistUpdated(address indexed module, bool allowed);

    // Stałe selektory – delegatecall tylko do dozwolonych funkcji
    bytes4 private constant SELECTOR_SUSPEND =
        bytes4(keccak256("suspendFundraiser(uint256,string,address)"));
    bytes4 private constant SELECTOR_UNSUSPEND =
        bytes4(keccak256("unsuspendFundraiser(uint256,address)"));

    function _isSelectorAllowed(bytes4 sel) internal pure returns (bool) {
        return sel == SELECTOR_SUSPEND || sel == SELECTOR_UNSUSPEND;
    }

    function _forwardSecurityCall(bytes4 selector, bytes memory data) internal returns (bytes memory) {
        require(securityModule != address(0), "Extension: securityModule not set");
        require(securityModuleWhitelist[securityModule], "Extension: module not whitelisted");
        require(_isSelectorAllowed(selector), "Extension: selector not allowed");

        (bool ok, bytes memory ret) = securityModule.call(data); // no delegatecall
        require(ok, "Extension: security call failed");
        return ret;
    }

    // ========== EVENTS ==========
    
    /// @notice Emitted when core contract is updated
    event CoreContractUpdated(address indexed oldCore, address indexed newCore);
    
    // ========== MODIFIERS ==========
    
    /// @notice Ensures only core contract can call certain functions
    modifier onlyCore() {
        require(msg.sender == coreContract, "PoliDaoExtension: Only core contract");
        _;
    }
    
    /// @notice Ensures caller is authorized (core contract or authorized caller)
    modifier onlyAuthorized() {
        require(
            msg.sender == coreContract || 
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoExtension: Not authorized"
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
    constructor(address _storageContract, address _coreContract) Ownable(msg.sender) {
        require(_storageContract != address(0), "PoliDaoExtension: Invalid storage contract");
        require(_coreContract != address(0), "PoliDaoExtension: Invalid core contract");
        storageContract = PoliDaoStorage(_storageContract);
        coreContract = _coreContract;
    }

    // initializer for clone deployments
    bool private _initialized;

    function initialize(address _storageContract, address _coreContract /* , address _securityModule */) external /* initializer/onlyOnce */ {
        require(!_initialized, "PoliDaoExtension: already initialized");
        require(_storageContract != address(0), "PoliDaoExtension: Invalid storage contract");
        require(_coreContract != address(0), "PoliDaoExtension: Invalid core contract");

        storageContract = PoliDaoStorage(_storageContract);
        coreContract = _coreContract;

        // Set owner to Core's owner if available, else to caller (factory EOA via tx)
        address initialOwner = msg.sender;
        try IOwned(_coreContract).owner() returns (address coreOwner) {
            if (coreOwner != address(0)) {
                initialOwner = coreOwner;
            }
        } catch { /* keep msg.sender */ }
        _transferOwnership(initialOwner);

        _initialized = true;
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
    
    // Example hardened forwards (call instead of delegatecall + selector restriction)
    function suspendFundraiser(uint256 fundraiserId, string calldata reason, address caller)
        external
        onlyAuthorized
        nonReentrant
    {
        bytes memory data = abi.encodeWithSelector(SELECTOR_SUSPEND, fundraiserId, reason, caller);
        _forwardSecurityCall(SELECTOR_SUSPEND, data);
    }

    function unsuspendFundraiser(uint256 fundraiserId, address caller)
        external
        onlyAuthorized
        nonReentrant
    {
        bytes memory data = abi.encodeWithSelector(SELECTOR_UNSUSPEND, fundraiserId, caller);
        _forwardSecurityCall(SELECTOR_UNSUSPEND, data);
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
        revert("PoliDaoExtension: Emergency pause not implemented");
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
    
    // Whitelist zarządzana przez ownera
    function setSecurityModuleWhitelist(address module, bool allowed) external onlyOwner {
        require(module != address(0), "Extension: zero module");
        securityModuleWhitelist[module] = allowed;
        emit SecurityModuleWhitelistUpdated(module, allowed);
    }

    // Ustawienie modułu bezpieczeństwa – tylko z whitelisty
    function setSecurityModule(address module) external onlyOwner {
        require(!securityModuleFrozen, "Extension: securityModule frozen");
        require(module != address(0), "Extension: zero module");
        require(securityModuleWhitelist[module], "Extension: not whitelisted");
        securityModule = module;
        emit SecurityModuleUpdated(module);
    }

    // Zamrożenie adresu (brak możliwości zmiany po audycie)
    function freezeSecurityModule() external onlyOwner {
        require(securityModule != address(0), "Extension: not set");
        securityModuleFrozen = true;
        emit SecurityModuleFrozen();
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