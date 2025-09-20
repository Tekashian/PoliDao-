// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "./../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPoliDaoRefunds.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../libraries/FundraiserLogic.sol";
import "../storage/PoliDaoStorage.sol";

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
    using Address for address;
    
    // ========== STORAGE AND DEPENDENCIES ==========
    IPoliDaoStorage public storageContract;
    address public extensionsContract;
    address public routerContract;

    // ========== MODULE ADDRESSES (ADDED – required for upgrades) ==========
    address public governanceModule;
    address public mediaModule;
    address public updatesModule;
    address public refundsModule;
    address public securityModule;
    address public web3Module;
    address public analyticsModule;

    // Batch limits (keep in sync with Web3)
    uint256 public constant MAX_BATCH_SIZE = 50;

    // ---- UPGRADE CONTROL ----
    bool private _modulesMutable = true;
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a fundraiser is created
    event FundraiserCreated(
        uint256 indexed fundraiserId,
        address indexed creator,
        address token,
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

    /// @notice Emitted when a module notification is attempted (best-effort)
    event ModuleNotificationSucceeded(bytes32 indexed moduleKey, address indexed module, bytes4 selector);
    event ModuleNotificationFailed(bytes32 indexed moduleKey, address indexed module, bytes4 selector, bytes reason);
    event ModuleUpgraded(string indexed moduleType, address indexed oldModule, address indexed newModule);
    event ModuleDisabled(string indexed moduleType, address indexed oldModule);
    event ModulesLocked();
    event ModuleDisableFlagSet(bytes32 indexed moduleKey, bool disabled);

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

    modifier onlyAuthorizedOrOwner() {
        require(
            msg.sender == owner() ||
            msg.sender == extensionsContract ||
            msg.sender == routerContract ||
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoCore: Not authorized"
        );
        _;
    }

    // ========== ACCESS COMPAT (dla testów oczekujących starego komunikatu) ==========
    modifier onlyOwnerCompat() {
        require(msg.sender == owner(), "Ownable: caller is not the owner");
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
    function createFundraiser(IPoliDaoStructs.FundraiserCreationData memory data)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 fundraiserId)
    {
        // Basic input validation
        require(bytes(data.title).length > 0, "PoliDaoCore: Title required");
        require(data.endDate > block.timestamp, "PoliDaoCore: Invalid end date");
        require(storageContract.isTokenWhitelisted(data.token), "PoliDaoCore: Token not whitelisted");

        if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "PoliDaoCore: Goal amount required");
        }

        // Removed unused local `packed`

        require(
            storageContract.isTokenWhitelisted(data.token),
            "PoliDaoCore: Token not whitelisted"
        );

        fundraiserId = FundraiserLogic.createFundraiserLogic(
            PoliDaoStorage(address(storageContract)),
            data,
            msg.sender
        );

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
        onlyAuthorizedOrOwner
    {
        require(storageContract.fundraisers(fundraiserId).id != 0, "PoliDaoCore: Fundraiser not found");
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
        IPoliDaoStructs.PackedFundraiserData memory fundraiserData = storageContract.fundraisers(fundraiserId);
        require(fundraiserData.id != 0, "PoliDaoCore: Fundraiser not found");
        require(fundraiserData.status == uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE), "PoliDaoCore: Fundraiser not active");
        require(block.timestamp <= fundraiserData.endDate, "PoliDaoCore: Fundraiser ended");
        require(!fundraiserData.isSuspended, "PoliDaoCore: Fundraiser suspended");

        address token = storageContract.fundraiserTokens(fundraiserId);

        // ADDED: transfer przed zapisem (CEI), całość i tak jest atomowa przy revercie
        IERC20(token).safeTransferFrom(msg.sender, address(storageContract), amount);

        storageContract.addDonation(fundraiserId, msg.sender, amount);
        emit DonationMade(fundraiserId, msg.sender, token, amount, amount);
    }
    
    /**
     * @notice Batch donacja w imieniu wskazanego donora; 1 zewnętrzny call do storage
     */
    function donateBatchFrom(
        address donor,
        address token,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    )
        public
        nonReentrant
        whenNotPaused
    {
        require(fundraiserIds.length == amounts.length, "Core: length mismatch");
        require(fundraiserIds.length > 0, "Core: empty batch");
        require(fundraiserIds.length <= MAX_BATCH_SIZE, "Core: batch too large");

        uint256 total = 0;
        unchecked {
            for (uint256 i = 0; i < amounts.length; ++i) {
                uint256 id = fundraiserIds[i];
                uint256 amt = amounts[i];
                require(amt > 0, "Core: zero amount");

                // Validate fundraiser state
                IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(id);
                require(f.id != 0, "Core: fundraiser not found");
                require(f.status == uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE), "Core: fundraiser not active");
                require(!f.isSuspended, "Core: fundraiser suspended");
                require(block.timestamp <= f.endDate, "Core: fundraiser ended");

                // Enforce same token across batch
                require(storageContract.fundraiserTokens(id) == token, "Core: mixed tokens in batch");

                total += amt;
            }
        }
        require(total > 0, "Core: zero total");
        IERC20(token).safeTransferFrom(donor, address(storageContract), total);
        storageContract.batchAddDonations(donor, token, fundraiserIds, amounts);
    }

    /**
     * @notice Batch donate (minimal stub)
     */
    function batchDonate(uint256[] calldata fundraiserIds, uint256[] calldata amounts)
        external
        nonReentrant
        whenNotPaused
    {
        require(fundraiserIds.length == amounts.length, "Core: length mismatch");
        require(fundraiserIds.length > 0, "Core: empty batch");
        require(fundraiserIds.length <= MAX_BATCH_SIZE, "Core: batch too large");

        address token = storageContract.fundraiserTokens(fundraiserIds[0]);
        donateBatchFrom(msg.sender, token, fundraiserIds, amounts);
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
        
        // Address.functionCall bez errorMessage overload
        bytes memory returnData = extensionsContract.functionCall(
            data
        );
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
        
        // Address.functionCall bez errorMessage overload
        bytes memory returnData = module.functionCall(
            data
        );
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
        
        // Address.functionStaticCall bez errorMessage overload
        bytes memory returnData = Address.functionStaticCall(
            module,
            data
        );
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
    function suspendFundraiser(uint256 fundraiserId, string calldata reason)
        external
        whenNotPaused
        nonReentrant
        onlyAuthorizedOrOwner
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        if (!f.isSuspended) {
            f.isSuspended = true;
            f.suspensionTime = uint32(block.timestamp);
            storageContract.updateFundraiser(fundraiserId, f);
        }
        emit FundraiserSuspended(fundraiserId, msg.sender, reason, block.timestamp);
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
    function addMediaToFundraiser(
        uint256 /*fundraiserId*/,
        IPoliDaoStructs.MediaItem[] calldata /*mediaItems*/
    ) external whenNotPaused nonReentrant {
        // No-op placeholder for compilation; modules should handle actual media storage
    }

    /**
     * @notice Posts an update to a fundraiser (minimal stub)
     */
    function postUpdate(uint256 /*fundraiserId*/, string calldata /*content*/) external whenNotPaused nonReentrant {
        // No-op placeholder
    }

    /**
     * @notice Updates a fundraiser's location (called by router)
     * @param fundraiserId The fundraiser ID
     * @param newLocation New location string
     */
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external whenNotPaused nonReentrant onlyRouter {
        require(storageContract.fundraisers(fundraiserId).id != 0, "PoliDaoCore: Fundraiser not found");
        storageContract.updateFundraiserLocation(fundraiserId, newLocation);
    }

    /**
     * @notice Withdraw funds for a fundraiser (minimal implementation)
     * @param fundraiserId The fundraiser ID
     */
    function withdrawFunds(uint256 fundraiserId) external whenNotPaused nonReentrant onlyAuthorizedOrOwner {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        require(!f.fundsWithdrawn, "PoliDaoCore: Already withdrawn");
        require(block.timestamp > f.endDate, "PoliDaoCore: Fundraiser not ended");

        // Restrict to creator or authorized/owner/router
        address creator = storageContract.fundraiserCreators(fundraiserId);
        require(
            msg.sender == creator ||
            msg.sender == owner() ||
            msg.sender == routerContract ||
            storageContract.isContractAuthorized(msg.sender),
            "PoliDaoCore: Not creator or authorized"
        );

        f.fundsWithdrawn = true;
        storageContract.updateFundraiser(fundraiserId, f);
    }

    /**
     * @notice Trigger refund period for a fundraiser (minimal implementation)
     * @param fundraiserId The fundraiser ID
     */
    function refund(uint256 fundraiserId)
        external
        whenNotPaused
        nonReentrant
        onlyAuthorizedOrOwner
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        address refundsMod = _resolveModule("REFUNDS");
        f.status = uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD);
        storageContract.updateFundraiser(fundraiserId, f);
        if (refundsMod != address(0)) {
            try IPoliDaoRefunds(refundsMod).initiateClosure(
                fundraiserId,
                storageContract.fundraiserCreators(fundraiserId),
                f.endDate
            ) {} catch {}
        }
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Sets all module addresses at once
     */
    function setModules(
        address _governance,
        address _media,
        address _updates,
        address _refunds,
        address _security,
        address _web3,
        address _analytics
    ) external onlyOwnerCompat {
        require(governanceModule == address(0) && mediaModule == address(0), "Already initialized");

        // zero-address validation (added)
        require(
            _governance != address(0) &&
            _media != address(0) &&
            _updates != address(0) &&
            _refunds != address(0) &&
            _security != address(0) &&
            _web3 != address(0) &&
            _analytics != address(0),
            "PoliDaoCore: zero module addr"
        );

        governanceModule = _governance;
        mediaModule = _media;
        updatesModule = _updates;
        refundsModule = _refunds;
        securityModule = _security;
        web3Module = _web3;
        analyticsModule = _analytics;
        _modulesMutable = true;
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
    /**
     * @dev Internal helper that resolves a module (state override first, then storage fallback)
     *      and performs a low-level call. Emits success/failure events.
     *      If module address is zero → no-op.
     * @param moduleKey Human‑readable key ("REFUNDS","MEDIA",...)
     * @param data Encoded calldata for the target module.
     */
    function _notifyModule(string memory moduleKey, bytes memory data) internal {
        address module = _resolveModule(moduleKey);
        if (module == address(0)) return;

        bytes4 selector;
        if (data.length >= 4) { assembly { selector := mload(add(data, 32)) } }

        try this._invokeModule(module, data) {
            emit ModuleNotificationSucceeded(keccak256(bytes(moduleKey)), module, selector);
        } catch (bytes memory reason) {
            emit ModuleNotificationFailed(keccak256(bytes(moduleKey)), module, selector, reason);
        }
    }

    // Wrapper enabling try/catch around Address.functionCall (no return value)
    function _invokeModule(address module, bytes memory data) external {
        require(msg.sender == address(this), "PoliDaoCore: only self");
        bytes memory ret = module.functionCall(data);
        // Touch the return to avoid unused-return finding
        if (ret.length > 0) {
            // no-op
        }
    }

    // ---- MODULE STATE FLAGS ----
    mapping(bytes32 => bool) private _moduleDisabled;

    function isModuleDisabled(string memory label) external view returns (bool) {
        return _moduleDisabled[_hash(label)];
    }

    function _hash(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    // Resolves module address preferring override state variable, falling back to storage mapping.
    function _resolveModule(string memory moduleKey) internal view returns (address) {
        bytes32 h = _hash(moduleKey);
        if (_moduleDisabled[h]) return address(0);
        if (h == _hash("GOVERNANCE")) {
            return governanceModule != address(0) ? governanceModule : storageContract.modules(h);
        }
        if (h == _hash("MEDIA")) {
            return mediaModule != address(0) ? mediaModule : storageContract.modules(h);
        }
        if (h == _hash("UPDATES")) {
            return updatesModule != address(0) ? updatesModule : storageContract.modules(h);
        }
        if (h == _hash("REFUNDS")) {
            return refundsModule != address(0) ? refundsModule : storageContract.modules(h);
        }
        if (h == _hash("SECURITY")) {
            return securityModule != address(0) ? securityModule : storageContract.modules(h);
        }
        if (h == _hash("WEB3")) {
            return web3Module != address(0) ? web3Module : storageContract.modules(h);
        }
        if (h == _hash("ANALYTICS")) {
            return analyticsModule != address(0) ? analyticsModule : storageContract.modules(h);
        }
        return storageContract.modules(h);
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

    // DODAJ (helpery – sekcja internal)
    function _assertMutable() internal view {
        require(_modulesMutable, "Modules locked");
    }

    function _moduleKey(string memory label) internal pure returns (bytes32) {
        return keccak256(bytes(label));
    }

    function _upgradeModule(string memory label, address oldAddr, address newAddr) internal {
        bytes32 key = keccak256(bytes(label));

        // DISABLE PATH: allow zero address to fully disable + clear mapping, set flag, emit event
        if (newAddr == address(0)) {
            _moduleDisabled[key] = true;                 // moved: always set flag
            emit ModuleDisabled(label, oldAddr);          // moved: always emit, even if oldAddr == 0
            // best-effort: clear storage mapping (ignore errors)
            try storageContract.setModule(key, address(0)) {} catch {}
            return;
        }

        // ENABLE/UPGRADE PATH
        require(_hasCode(newAddr), "Not a contract");
        _moduleDisabled[key] = false;
        emit ModuleUpgraded(label, oldAddr, newAddr);

        // best-effort: authorize + sync mapping (ignore errors)
        if (!_isAuthorized(newAddr)) {
            try storageContract.authorizeContract(newAddr) {} catch {}
        }
        try storageContract.setModule(key, newAddr) {} catch {}
    }

    function _isAuthorized(address a) internal view returns (bool) {
        return storageContract.isContractAuthorized(a);
    }

    function upgradeGovernanceModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("GOVERNANCE");
        _upgradeModule("GOVERNANCE", oldEffective, newAddr);
        governanceModule = newAddr;
    }
    function upgradeMediaModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("MEDIA");
        _upgradeModule("MEDIA", oldEffective, newAddr);
        mediaModule = newAddr;
    }
    function upgradeUpdatesModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("UPDATES");
        _upgradeModule("UPDATES", oldEffective, newAddr);
        updatesModule = newAddr;
    }
    function upgradeRefundsModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("REFUNDS");
        _upgradeModule("REFUNDS", oldEffective, newAddr);
        refundsModule = newAddr;
    }
    function upgradeSecurityModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("SECURITY");
        _upgradeModule("SECURITY", oldEffective, newAddr);
        securityModule = newAddr;
    }
    function upgradeWeb3Module(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("WEB3");
        _upgradeModule("WEB3", oldEffective, newAddr);
        web3Module = newAddr;
    }
    function upgradeAnalyticsModule(address newAddr) external onlyOwnerCompat {
        _assertMutable();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule("ANALYTICS");
        _upgradeModule("ANALYTICS", oldEffective, newAddr);
        analyticsModule = newAddr;
    }

    function lockModuleUpgrades() external onlyOwnerCompat {
        _modulesMutable = false;
        emit ModulesLocked();
    }

    function areModuleUpgradesOpen() external view returns (bool) {
        return _modulesMutable;
    }
}