// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../libraries/ExtensionLogic.sol";
import "../libraries/LocationLogic.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPoliDaoSecurity.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IExtensionSecurityAdmin.sol"; // <--- DODANE

contract PoliDaoExtension is Ownable, ReentrancyGuard, IPoliDaoStructs, IExtensionSecurityAdmin { // <--- rozszerzone dziedziczenie
    // ========== STORAGE AND DEPENDENCIES ==========
    PoliDaoStorage public storageContract;
    address public coreContract;

    // ========== SECURITY MODULE ==========
    address public securityModule;
    bool public securityModuleFrozen;
    mapping(address => bool) private securityModuleWhitelist;

    event SecurityModuleUpdated(address indexed newModule);
    event SecurityModuleFrozen();
    event SecurityModuleWhitelistUpdated(address indexed module, bool allowed);
    // ========== EVENTS ==========
    event ExtensionInitialized(address indexed storageContract, address indexed coreContract, address indexed caller); // <--- NOWY EVENT

    constructor() Ownable(msg.sender) {}

    // ========== INITIALIZE ==========
    bool private _initialized;

    function initialize(address _storageContract, address _coreContract) external onlyOwner {
        require(!_initialized, "Extension: already initialized");
        require(_storageContract != address(0), "Extension: storage zero");
        require(_coreContract != address(0), "Extension: core zero");
        storageContract = PoliDaoStorage(_storageContract);
        coreContract = _coreContract;
        _initialized = true;
        emit ExtensionInitialized(_storageContract, _coreContract, msg.sender); // <--- EMISJA
    }

    // ========== ACCESS CONTROL ==========
    modifier onlyCore() {
        require(msg.sender == coreContract, "Extension: only core");
        _;
    }

    // ========== SECURITY ADMIN (bez delegatecall/low-level) ==========
    function setSecurityModuleWhitelist(address module, bool allowed) external onlyOwner {
        require(module != address(0), "Extension: zero module");
        securityModuleWhitelist[module] = allowed;
        emit SecurityModuleWhitelistUpdated(module, allowed);
    }

    // Jednorazowe ustawienie modułu + auto-freeze
    function setSecurityModule(address module) external onlyOwner {
        require(!securityModuleFrozen, "Extension: securityModule frozen");
        require(module != address(0), "Extension: zero module");
        require(securityModuleWhitelist[module], "Extension: not whitelisted");

        uint256 size;
        assembly { size := extcodesize(module) }
        require(size > 0, "Extension: not a contract");

        // sanity-check interfejsu (bez wiązania typów zwrotnych)
        try IPoliDaoSecurity(module).isUserSuspended(address(0)) {
            // ok
        } catch {
            revert("Extension: invalid security interface");
        }

        securityModule = module;
        emit SecurityModuleUpdated(module);

        securityModuleFrozen = true; // auto-freeze
        emit SecurityModuleFrozen();
    }

    function freezeSecurityModule() external onlyOwner {
        require(securityModule != address(0), "Extension: not set");
        securityModuleFrozen = true;
        emit SecurityModuleFrozen();
    }

    // ========== SECURITY FORWARDS (IPoliDaoSecurity; brak low-level/delegatecall) ==========
    function suspendFundraiser(uint256 fundraiserId, string calldata reason)
        external
        onlyCore
        nonReentrant
    {
        require(securityModule != address(0), "Extension: securityModule not set");
        IPoliDaoSecurity(securityModule).suspendFundraiser(fundraiserId, reason);
    }

    function unsuspendFundraiser(uint256 fundraiserId)
        external
        onlyCore
        nonReentrant
    {
        require(securityModule != address(0), "Extension: securityModule not set");
        IPoliDaoSecurity(securityModule).unsuspendFundraiser(fundraiserId);
    }

    // ========== WRAPPERS EXTENSION LOGIC ==========
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays, address caller)
        external
        onlyCore
        nonReentrant
    {
        ExtensionLogic.extendFundraiser(storageContract, fundraiserId, additionalDays, caller);
    }

    function updateLocation(uint256 fundraiserId, string calldata newLocation, address caller)
        external
        onlyCore
    {
        LocationLogic.updateLocation(storageContract, fundraiserId, newLocation, caller);
    }

    // ========== VIEWS ==========
    function canExtendFundraiser(uint256 fundraiserId, address caller)
        external view returns (bool canExtend, uint256 timeLeft, string memory reason)
    {
        return ExtensionLogic.canExtendFundraiser(storageContract, fundraiserId, caller);
    }

    function getExtensionInfo(uint256 fundraiserId)
        external view returns (
            uint256 extensionCount,
            uint256 originalEndDate,
            uint256 currentEndDate,
            bool canExtendMore,
            uint256 maxExtensions
        )
    {
        return ExtensionLogic.getExtensionInfo(storageContract, fundraiserId);
    }

    function getExtensionFee() external view returns (uint256 fee, address feeToken) {
        return ExtensionLogic.getExtensionFee(storageContract);
    }

    function validateExtension(uint256 fundraiserId, uint256 additionalDays, address caller)
        external view returns (bool isValid, string memory reason)
    {
        return ExtensionLogic.validateExtension(storageContract, fundraiserId, additionalDays, caller);
    }

    function validateLocationUpdate(uint256 fundraiserId, string calldata newLocation, address caller)
        external view returns (bool isValid, string memory reason)
    {
        return LocationLogic.validateLocationUpdate(storageContract, fundraiserId, newLocation, caller);
    }

    function canUpdateLocation(uint256 fundraiserId, address user)
        external view returns (bool canUpdate)
    {
        return LocationLogic.canUpdateLocation(storageContract, fundraiserId, user);
    }

    function getTimeUntilExtensionDeadline(uint256 fundraiserId)
        external view returns (uint256 timeUntilDeadline, bool canStillExtend)
    {
        return ExtensionLogic.getTimeUntilExtensionDeadline(storageContract, fundraiserId);
    }

    function getLocationConstraints() external view returns (uint256 maxLength) {
        return LocationLogic.getLocationConstraints(storageContract);
    }
}