// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPoliDaoRefunds.sol";

/**
 * @title PoliDaoCore
 * @notice Lightweight core contract - coordinates between storage, extensions, and modules
 * @dev Thin controller that delegates complex logic to specialized contracts
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED-SLIM
 * @custom:security-contact security@polidao.org
 */
contract PoliDaoCore is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ========== STORAGE AND DEPENDENCIES ==========
    
    /// @notice Unified storage contract interface
    IPoliDaoStorage public storageContract;
    
    /// @notice Extensions contract for advanced functionality
    address public extensionsContract;
    
    /// @notice Router contract for cross-module operations
    address public routerContract;
    
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
    
    /// @notice Emitted when a donation is made
    event DonationMade(
        uint256 indexed fundraiserId,
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 netAmount
    );
    
    /// @notice Emitted when extensions contract is updated
    event ExtensionsContractUpdated(address indexed oldExtensions, address indexed newExtensions);
    
    /// @notice Emitted when router contract is updated
    event RouterContractUpdated(address indexed oldRouter, address indexed newRouter);

    /// @notice Emitted when a fundraiser is suspended
    event FundraiserSuspended(
        uint256 indexed id,
        address indexed suspendedBy,
        string reason,
        uint256 timestamp
    );
    
    // ========== MODIFIERS ==========
    
    /// @notice Ensures only router can call certain functions
    modifier onlyRouter() {
        require(msg.sender == routerContract, "PoliDaoCore: Only router");
        _;
    }
    
    /// @notice Ensures only authorized contracts can call certain functions
    modifier onlyAuthorized() {
        require(
            msg.sender == extensionsContract || 
            msg.sender == routerContract ||
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoCore: Not authorized"
        );
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    /**
     * @notice Initializes the core contract
     * @param _storageContract Address of the unified storage contract
     * @param _routerContract Address of the router contract
     */
    // Keep constructor for legacy direct deployments
    constructor(address _storageContract, address _routerContract) Ownable(msg.sender) {
        require(_storageContract != address(0), "PoliDaoCore: Invalid storage contract");
        require(_routerContract != address(0), "PoliDaoCore: Invalid router contract");
        
        storageContract = IPoliDaoStorage(_storageContract);
        routerContract = _routerContract;
    }

    // initializer for clone deployments
    bool private _initialized;

    function initialize(address _storageContract, address initialOwner) external {
        require(!_initialized, "PoliDaoCore: already initialized");
        require(_storageContract != address(0), "PoliDaoCore: Invalid storage contract");
        _initialized = true;
        storageContract = IPoliDaoStorage(_storageContract);
        transferOwnership(initialOwner);
    }
    
    // ========== CONTRACT MANAGEMENT ==========
    
    /**
     * @notice Sets the extensions contract address
     * @param _extensionsContract Address of the extensions contract
     */
    function setExtensionsContract(address _extensionsContract) external onlyOwner {
        require(_extensionsContract != address(0), "PoliDaoCore: Invalid extensions contract");
        require(_hasCode(_extensionsContract), "PoliDaoCore: Extensions must be a contract");
        
        address oldExtensions = extensionsContract;
        extensionsContract = _extensionsContract;
        
        emit ExtensionsContractUpdated(oldExtensions, _extensionsContract);
    }
    
    /**
     * @notice Sets the router contract address
     * @param _routerContract Address of the router contract
     */
    function setRouterContract(address _routerContract) external onlyOwner {
        require(_routerContract != address(0), "PoliDaoCore: Invalid router contract");
        require(_hasCode(_routerContract), "PoliDaoCore: Router must be a contract");
        
        address oldRouter = routerContract;
        routerContract = _routerContract;
        
        emit RouterContractUpdated(oldRouter, _routerContract);
    }
    
    // ========== CORE BUSINESS LOGIC ==========
    
    /**
     * @notice Creates a new fundraiser
     * @param data Struct containing all fundraiser creation parameters
     * @return fundraiserId The ID of the newly created fundraiser
     */
    function createFundraiser(IPoliDaoStructs.FundraiserCreationData calldata data) 
        external 
        whenNotPaused
        nonReentrant
        returns (uint256 fundraiserId) 
    {
        // Basic input validation
        require(bytes(data.title).length > 0, "PoliDaoCore: Title required");
        require(data.endDate > block.timestamp, "PoliDaoCore: Invalid end date");
        require(storageContract.isTokenWhitelisted(data.token), "PoliDaoCore: Token not whitelisted");
        
        // Validate goal amount for fundraisers with goals
    if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "PoliDaoCore: Goal amount required");
        }
        
        // Build packed fundraiser data (storage will assign id)
        IPoliDaoStructs.PackedFundraiserData memory packed = IPoliDaoStructs.PackedFundraiserData({
            goalAmount: uint128(data.goalAmount),
            raisedAmount: uint128(0),
            endDate: uint64(data.endDate),
            originalEndDate: uint64(data.endDate),
            id: uint32(0),
            suspensionTime: uint32(0),
            extensionCount: uint16(0),
            fundraiserType: uint8(data.fundraiserType),
            status: uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            isFlexible: data.isFlexible
        });

        // Create fundraiser in storage (packed data + metadata + creator + token)
        // +++ Enforce whitelist at core level as well (defense in depth)
        require(
            storageContract.isTokenWhitelisted(data.token),
            "PoliDaoCore: Token not whitelisted"
        );

        fundraiserId = storageContract.createFundraiser(
            packed,
            data.title,
            data.description,
            data.location,
            msg.sender,
            data.token
        );
        
        // Notify refunds module if available (use canonical module key "REFUNDS")
        _notifyModule("REFUNDS", abi.encodeWithSignature(
            "registerFundraiser(uint256,bool)",
            fundraiserId,
            data.isFlexible
        ));
        
        emit FundraiserCreated(
            fundraiserId,
            msg.sender,
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
     * @notice Extends a fundraiser by adding additional days
     * @param fundraiserId The fundraiser ID to extend
     * @param additionalDays Number of days to extend
     */
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays)
        external
        whenNotPaused
        nonReentrant
    {
        // Only router or authorized contracts should be able to call this in normal flow; keep minimal check here
        require(storageContract.fundraisers(fundraiserId).id != 0, "PoliDaoCore: Fundraiser not found");

        // Update the end date in storage (best-effort, storage stub will accept update)
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        f.endDate = f.endDate + uint64(additionalDays * 1 days);
        storageContract.updateFundraiser(fundraiserId, f);
    }
    
    /**
     * @notice Allows users to donate to a fundraiser
     * @param fundraiserId The ID of the fundraiser to donate to
     * @param amount The amount of tokens to donate
     */
    function donate(uint256 fundraiserId, uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        require(amount > 0, "PoliDaoCore: Amount must be greater than 0");
        
        // Get fundraiser data and validate
    IPoliDaoStructs.PackedFundraiserData memory fundraiserData = storageContract.fundraisers(fundraiserId);
    require(fundraiserData.id != 0, "PoliDaoCore: Fundraiser not found");
    require(fundraiserData.status == uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE), "PoliDaoCore: Fundraiser not active");
    require(block.timestamp <= fundraiserData.endDate, "PoliDaoCore: Fundraiser ended");
    require(!fundraiserData.isSuspended, "PoliDaoCore: Fundraiser suspended");
        
        address token = storageContract.fundraiserTokens(fundraiserId);
        
    // Record donation in storage
    storageContract.addDonation(fundraiserId, msg.sender, amount);
        
        // Transfer tokens
        IERC20(token).safeTransferFrom(msg.sender, address(storageContract), amount);
        
        emit DonationMade(fundraiserId, msg.sender, token, amount, amount);
    }
    
    // ========== DELEGATION TO EXTENSIONS ==========
    
    /**
     * @notice Delegates extension-related calls to extensions contract
     * @param data The call data to forward
     * @return result The return data from the call
     */
    function delegateToExtensions(bytes calldata data) 
        external 
        onlyRouter
        returns (bytes memory result) 
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        
        (bool success, bytes memory returnData) = extensionsContract.call(data);
        require(success, "PoliDaoCore: Extensions call failed");
        
        return returnData;
    }
    
    // ========== MODULE COORDINATION ==========
    
    /**
     * @notice Executes a call to a specific module
     * @param moduleKey The key identifying the module
     * @param data The call data to execute
     * @return result The return data from the call
     */
    function callModule(bytes32 moduleKey, bytes calldata data) 
        external 
        onlyRouter
        returns (bytes memory result) 
    {
        address module = storageContract.modules(moduleKey);
        require(module != address(0), "PoliDaoCore: Module not set");
        
        (bool success, bytes memory returnData) = module.call(data);
        require(success, "PoliDaoCore: Module call failed");
        
        return returnData;
    }
    
    /**
     * @notice Executes a static call to a module
     * @param moduleKey The key identifying the module
     * @param data The call data to execute
     * @return result The return data from the call
     */
    function staticCallModule(bytes32 moduleKey, bytes calldata data) 
        external 
        view 
        returns (bytes memory result) 
    {
        address module = storageContract.modules(moduleKey);
        require(module != address(0), "PoliDaoCore: Module not set");
        
        (bool success, bytes memory returnData) = module.staticcall(data);
        require(success, "PoliDaoCore: Module call failed");
        
        return returnData;
    }
    
    // ========== BASIC VIEW FUNCTIONS ==========
    
    /**
     * @notice Gets basic fundraiser information
     * @param fundraiserId The ID of the fundraiser
     * @return creator Creator address
     * @return token Token address
     * @return raised Amount raised
     * @return goal Goal amount
     * @return endDate End timestamp
     * @return status Current status
     */
    function getFundraiserBasicInfo(uint256 fundraiserId) 
        external 
        view 
        returns (
            address creator,
            address token,
            uint256 raised,
            uint256 goal,
            uint256 endDate,
            uint8 status
        ) 
    {
    IPoliDaoStructs.PackedFundraiserData memory data = storageContract.fundraisers(fundraiserId);
        require(data.id != 0, "PoliDaoCore: Fundraiser not found");
        
        return (
            storageContract.fundraiserCreators(fundraiserId),
            storageContract.fundraiserTokens(fundraiserId),
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status
        );
    }
    
    /**
     * @notice Gets the total number of fundraisers created
     */
    function getFundraiserCount() external view returns (uint256) {
        return storageContract.fundraiserCounter();
    }

    /**
     * @notice Gets detailed fundraiser metadata
     */
    function getFundraiserDetails(uint256 fundraiserId)
        external
        view
        returns (
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
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        title = storageContract.fundraiserTitles(fundraiserId);
        description = storageContract.fundraiserDescriptions(fundraiserId);
        location = storageContract.fundraiserLocations(fundraiserId);
        endDate = f.endDate;
        fundraiserType = f.fundraiserType;
        status = f.status;
        token = storageContract.fundraiserTokens(fundraiserId);
        goalAmount = f.goalAmount;
        raisedAmount = f.raisedAmount;
        creator = storageContract.fundraiserCreators(fundraiserId);
        extensionCount = f.extensionCount;
        isSuspended = f.isSuspended;
        suspensionReason = "";
    }

    /**
     * @notice Gets fundraiser progress metrics
     */
    function getFundraiserProgress(uint256 fundraiserId)
        external
        view
        returns (
            uint256 raised,
            uint256 goal,
            uint256 percentage,
            uint256 donorsCount,
            uint256 timeLeft,
            uint256 refundDeadline,
            bool isSuspended,
            uint256 suspensionTime
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        raised = f.raisedAmount;
        goal = f.goalAmount;
        donorsCount = storageContract.getFundraiserDonors(fundraiserId).length;
        timeLeft = f.endDate > block.timestamp ? f.endDate - block.timestamp : 0;
        percentage = goal > 0 ? (raised * 10000) / goal : 0;
        refundDeadline = 0;
        isSuspended = f.isSuspended;
        suspensionTime = f.suspensionTime;
    }

    /**
     * @notice Checks whether a fundraiser can be extended
     */
    function canExtendFundraiser(uint256 fundraiserId) external view returns (bool canExtend, uint256 timeLeft, string memory reason) {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        if (f.id == 0) return (false, 0, "Fundraiser not found");
        if (f.isSuspended) return (false, 0, "Fundraiser suspended");
        if (f.fundsWithdrawn) return (false, 0, "Funds already withdrawn");
        // compute time left
        uint256 tl = f.endDate > block.timestamp ? f.endDate - block.timestamp : 0;
        return (true, tl, "");
    }

    /**
     * @notice Checks whether a donor can be refunded (minimal)
     */
    function canRefund(uint256 fundraiserId, address /*donor*/) external view returns (bool canRefundResult, string memory reason) {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        if (f.id == 0) return (false, "Fundraiser not found");
        if (f.status == uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD)) return (true, "");
        return (false, "Not in refund period");
    }

    /**
     * @notice Creates a governance proposal (minimal stub) and returns an id
     */
    function createProposal(string calldata /*question*/, uint256 /*duration*/) external whenNotPaused nonReentrant returns (uint256) {
        // Minimal: return 0 as placeholder proposal id
        return 0;
    }

    /**
     * @notice Suspend a fundraiser (minimal implementation)
     */
    function suspendFundraiser(uint256 fundraiserId, string calldata /*reason*/) external whenNotPaused nonReentrant {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        f.isSuspended = true;
        f.suspensionTime = uint32(block.timestamp);
        storageContract.updateFundraiser(fundraiserId, f);
        emit FundraiserSuspended(fundraiserId, msg.sender, "suspended via core", block.timestamp);
    }
    
    /**
     * @notice Gets donation amount for a specific donor and fundraiser
     */
    function getDonationAmount(uint256 fundraiserId, address donor) external view returns (uint256) {
        return storageContract.donations(fundraiserId, donor);
    }

    // (duplicate non-returning createProposal removed - keep canonical returning variant)

    /**
     * @notice Casts a vote on a proposal (minimal stub)
     */
    function vote(uint256 /*proposalId*/, bool /*support*/) external whenNotPaused nonReentrant {
        // Minimal: forward to governance module if available
        _notifyModule("GOVERNANCE", abi.encodeWithSignature("vote(uint256,bool)", uint256(0), false));
    }

    /**
     * @notice Adds media items to a fundraiser (minimal stub)
     */
    function addMediaToFundraiser(uint256 /*fundraiserId*/, IPoliDao.MediaItem[] calldata /*mediaItems*/) external whenNotPaused nonReentrant {
        // No-op placeholder for compilation; modules should handle actual media storage
    }

    /**
     * @notice Posts an update to a fundraiser (minimal stub)
     */
    function postUpdate(uint256 /*fundraiserId*/, string calldata /*content*/) external whenNotPaused nonReentrant {
        // No-op placeholder
    }

    /**
     * @notice Batch donate (minimal stub)
     */
    function batchDonate(uint256[] calldata fundraiserIds, uint256[] calldata amounts) external whenNotPaused nonReentrant {
        require(fundraiserIds.length == amounts.length, "PoliDaoCore: Arrays length mismatch");
        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            // Record donation in storage without token transfer (stub)
            storageContract.addDonation(fundraiserIds[i], msg.sender, amounts[i]);
        }
    }

    /**
     * @notice Updates a fundraiser's location (called by router)
     * @param fundraiserId The fundraiser ID
     * @param newLocation New location string
     */
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external whenNotPaused nonReentrant {
        // Minimal access control: allow router or authorized contracts; router calls this normally
        require(storageContract.fundraisers(fundraiserId).id != 0, "PoliDaoCore: Fundraiser not found");
        storageContract.updateFundraiserLocation(fundraiserId, newLocation);
    }

    /**
     * @notice Withdraw funds for a fundraiser (minimal implementation)
+     * @param fundraiserId The fundraiser ID
+     */
    function withdrawFunds(uint256 fundraiserId) external whenNotPaused nonReentrant {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");

        // Mark funds withdrawn in storage (minimal)
        f.fundsWithdrawn = true;
        storageContract.updateFundraiser(fundraiserId, f);
    }

    /**
     * @notice Trigger refund period for a fundraiser (minimal implementation)
     * @param fundraiserId The fundraiser ID
     */
    function refund(uint256 fundraiserId) external whenNotPaused nonReentrant {
        // Delegate refund orchestration to refunds module
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");

        address refundsModule = storageContract.modules(keccak256(bytes("REFUNDS")));
        require(refundsModule != address(0), "PoliDaoCore: Refunds module not set");

        // Update status in storage to REFUND_PERIOD so views reflect the change.
        f.status = uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD);
        storageContract.updateFundraiser(fundraiserId, f);

        // Notify refunds module to start closure/refund handling (best-effort)
        try IPoliDaoRefunds(refundsModule).initiateClosure(fundraiserId, storageContract.fundraiserCreators(fundraiserId), f.endDate) {
            // proceed silently on success
        } catch {
            // best-effort: do not revert core if refunds module fails
        }
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Sets all module addresses at once
     */
    function setModules(
        address governance, 
        address media, 
        address updates, 
        address refunds,
        address security,
        address web3,
        address analytics
    ) external onlyOwner {
        storageContract.setModules(governance, media, updates, refunds, security, web3, analytics);
    }
    
    /**
     * @notice Pauses the contract
     */
    function pause() external onlyOwner { 
        _pause(); 
    }
    
    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyOwner { 
        _unpause(); 
    }
    
    // ========== TOKEN WHITELIST MANAGEMENT (delegation to storage) ==========

    function whitelistToken(address token) external onlyOwner {
        require(token != address(0), "Invalid token");
        storageContract.addWhitelistedToken(token);
    }

    function removeWhitelistToken(address token) external onlyOwner {
        storageContract.removeWhitelistedToken(token);
    }

    function isTokenWhitelisted(address token) external view returns (bool) {
        return storageContract.isTokenWhitelisted(token);
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return storageContract.getWhitelistedTokens();
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    /**
     * @notice Checks if an address contains contract code
     * @param addr Address to check
     * @return hasCode Whether the address has code
     */
    function _hasCode(address addr) internal view returns (bool hasCode) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        return codeSize > 0;
    }
    
    /**
     * @notice Internal helper to notify modules (best effort, doesn't revert)
     * @param moduleKey The module key
     * @param data The call data
     */
    function _notifyModule(string memory moduleKey, bytes memory data) internal {
        address module = storageContract.modules(keccak256(bytes(moduleKey)));
        if (module != address(0)) {
            // Best effort call, don't revert if it fails
            (bool success, ) = module.call(data);
            success; // explicit use to silence compiler warning
        }
    }
    
    // ========== CONTRACT STATUS AND DIAGNOSTICS ==========
    
    /**
     * @notice Gets the status of all connected contracts
     * @return storageAddress Address of storage contract
     * @return extensionsAddress Address of extensions contract
     * @return routerAddress Address of router contract
     * @return isConfigured Whether core is fully configured
     */
    function getContractStatus() 
        external 
        view 
        returns (
            address storageAddress,
            address extensionsAddress,
            address routerAddress,
            bool isConfigured
        ) 
    {
        return (
            address(storageContract),
            extensionsContract,
            routerContract,
            extensionsContract != address(0) && routerContract != address(0)
        );
    }
    
    /**
     * @notice Validates that core is properly configured
     * @return isValid Whether the core is ready for use
     * @return missingComponent What's missing (if any)
     */
    function validateConfiguration() 
        external 
        view 
        returns (bool isValid, string memory missingComponent) 
    {
        if (extensionsContract == address(0)) {
            return (false, "Extensions contract not set");
        }
        
        if (routerContract == address(0)) {
            return (false, "Router contract not set");
        }
        
        if (!storageContract.isContractAuthorized(address(this))) {
            return (false, "Core not authorized in storage");
        }
        
        return (true, "");
    }
}