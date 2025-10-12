// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "./../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../libraries/FundraiserLogic.sol";
// DODANE
import "../libraries/DonationLogic.sol";
import "../libraries/WithdrawLogic.sol";
import "../libraries/RefundLogic.sol";

/**
 * @title PoliDaoCore
 * @notice Lightweight core contract - coordinates between storage, extensions, and modules
 * @dev Thin controller that delegates complex logic to specialized contracts
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED-SLIM
 * @custom:security-contact security@polidao.org
 */
contract PoliDaoCore is Ownable, Pausable, ReentrancyGuard {
    using Address for address;

    error FundraiserNotFound();
    error TokenNotSet();

    // ========== CUSTOM ERRORS (tańsze niż stringi) ==========
    error InvalidAmount();
    error InvalidInput();
    error NotImplemented();
    error DonationsClosed();
    error RefundNotAllowed();

    // [ADD] Konfiguracja opłat (BPS) i portfela prowizji
    address public feeRecipient;
    uint16  public donationFeeBps;            // 0..10000 (domyślnie 0)
    uint16  public successWithdrawFeeBps;     // fee przy withdraw sukcesu (domyślnie 0)
    uint16  public flexibleWithdrawFeeBps;    // fee przy withdraw NO_GOAL lub fail po endDate (domyślnie 0)

    // [ADD] Flaga “wypłaty rozpoczęte” blokująca dalsze refundy w części scenariuszy
    mapping(uint256 => bool) public withdrawalsStarted;

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
        uint256 newRaised
    );

    // DODANE: event wymagany przez test withdraw.integration.test.js
    event FundsWithdrawn(uint256 indexed fundraiserId, address indexed creator, address indexed token, uint256 amount);
    event ExtensionsContractUpdated(address indexed oldExtensions, address indexed newExtensions);
    event RouterContractUpdated(address indexed oldRouter, address indexed newRouter);

    // DODANE: brakujące eventy używane w kodzie
    event FundraiserSuspended(uint256 indexed fundraiserId, address indexed by, string reason, uint256 timestamp);
    event ModuleNotificationSucceeded(bytes32 indexed moduleKey, address module, bytes4 selector);
    event ModuleNotificationFailed(bytes32 indexed moduleKey, address module, bytes4 selector, bytes reason);
    event ModuleDisabled(string label, address oldAddr);
    event ModuleUpgraded(string label, address oldAddr, address newAddr);

    // New events for module management
    event ModuleUpgradesLocked();

    // ========== MODIFIERS ==========
    /// @notice Ensures only router can call certain functions
    modifier onlyRouter() {
        require(msg.sender == routerContract, "PoliDaoCore: only router");
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

    // ========== CONSTRUCTOR ==========
    constructor(address _storageContract, address _routerContract) Ownable(msg.sender) { 
        require(_storageContract != address(0), "PoliDaoCore: Invalid storage contract");
        require(_routerContract != address(0), "PoliDaoCore: Invalid router contract");
        
        storageContract = IPoliDaoStorage(_storageContract);
        routerContract = _routerContract;
        emit RouterContractUpdated(address(0), _routerContract);
    }

    // initializer for clone deployments
    bool private _initialized;

    function initialize(address _storageContract, address initialOwner) external {
        require(!_initialized, "PoliDaoCore: already initialized");
        require(_storageContract != address(0), "PoliDaoCore: Invalid storage contract");
        require(initialOwner != address(0), "PoliDaoCore: Invalid owner"); // opcjonalnie
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
    
    // ========== ADMIN: SET ROUTER ==========
    function setRouterContract(address _router) external onlyOwner {
        require(_router != address(0), "PoliDaoCore: invalid router");
        address old = routerContract;
        routerContract = _router;
        emit RouterContractUpdated(old, _router);
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
        fundraiserId = FundraiserLogic.createFundraiserLogic(
            PoliDaoStorage(address(storageContract)), data, msg.sender
        );
        _notifyModule("REFUNDS", abi.encodeWithSignature("registerFundraiser(uint256,bool)", fundraiserId, data.isFlexible));
        emit FundraiserCreated(
            fundraiserId, msg.sender, data.token, data.title,
            uint8(data.fundraiserType), data.goalAmount, data.endDate, data.location
        );
        return fundraiserId;
    }

    /**
     * @notice Creates a new fundraiser (for router)
     */
    function createFundraiserFor(
        address creator,
        IPoliDaoStructs.FundraiserCreationData memory data
    )
        external
        whenNotPaused
        nonReentrant
        onlyRouter
        returns (uint256 fundraiserId)
    {
        require(creator != address(0), "PoliDaoCore: Creator required");
        require(bytes(data.title).length > 0, "PoliDaoCore: Title required");
        require(data.endDate > block.timestamp, "PoliDaoCore: Invalid end date");
        require(storageContract.isTokenWhitelisted(data.token), "PoliDaoCore: Token not whitelisted");
        if (data.fundraiserType == IPoliDaoStructs.FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "PoliDaoCore: Goal amount required");
        }
        fundraiserId = FundraiserLogic.createFundraiserLogic(
            PoliDaoStorage(address(storageContract)), data, creator
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
     */
    function donate(uint256 fundraiserId, uint256 amount) 
        external
        whenNotPaused
        nonReentrant 
    { 
        if (amount == 0) revert InvalidAmount();

        IPoliDaoStructs.PackedFundraiserData memory fPrev = storageContract.fundraisers(fundraiserId);
        if (fPrev.id == 0) revert FundraiserNotFound();

        bool timeEnded = (fPrev.endDate != 0 && block.timestamp > fPrev.endDate);
        bool isWithGoal = (fPrev.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && fPrev.goalAmount > 0 && fPrev.raisedAmount >= fPrev.goalAmount);

        if (fPrev.fundsWithdrawn) revert DonationsClosed();
        if (!isWithGoal && timeEnded) revert DonationsClosed();
        if (isWithGoal && timeEnded && !goalReached) revert DonationsClosed();

        address token = storageContract.fundraiserTokens(fundraiserId);
        if (token == address(0)) revert TokenNotSet();

        uint256 received = DonationLogic.donateWithFee(
            storageContract,
            fundraiserId,
            msg.sender,
            amount,
            feeRecipient,
            donationFeeBps
        );

        // [NOWE] Księgowanie wpłaty w Storage
        storageContract.addDonation(fundraiserId, msg.sender, received);

        uint256 newRaised = uint256(fPrev.raisedAmount) + received;
        emit DonationMade(fundraiserId, msg.sender, token, received, newRaised);
    }
    
    /**
     * @notice Donate to a fundraiser on behalf of donor (router context)
     * @dev FE musi wykonać approve przed donacją: IERC20(token).approve(spender = address(this), amount)
     *      Alternatywnie użyj router.donateWithPermit (EIP-2612).
     */
    function donateFrom(uint256 fundraiserId, address donor, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        if (amount == 0) revert InvalidAmount();

        IPoliDaoStructs.PackedFundraiserData memory fPrev = storageContract.fundraisers(fundraiserId);
        if (fPrev.id == 0) revert FundraiserNotFound();

        bool timeEnded = (fPrev.endDate != 0 && block.timestamp > fPrev.endDate);
        bool isWithGoal = (fPrev.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && fPrev.goalAmount > 0 && fPrev.raisedAmount >= fPrev.goalAmount);

        if (fPrev.fundsWithdrawn) revert DonationsClosed();
        if (!isWithGoal && timeEnded) revert DonationsClosed();
        if (isWithGoal && timeEnded && !goalReached) revert DonationsClosed();

        address token = storageContract.fundraiserTokens(fundraiserId);
        if (token == address(0)) revert TokenNotSet();

        uint256 received = DonationLogic.donateWithFee(
            storageContract,
            fundraiserId,
            donor,
            amount,
            feeRecipient,
            donationFeeBps
        );

        // [NOWE] Księgowanie wpłaty w Storage
        storageContract.addDonation(fundraiserId, donor, received);

        uint256 newRaised = uint256(fPrev.raisedAmount) + received;
        emit DonationMade(fundraiserId, donor, token, received, newRaised);
    }

    function batchDonateFrom(address donor, uint256[] calldata fundraiserIds, uint256[] calldata amounts)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(fundraiserIds.length == amounts.length && fundraiserIds.length > 0, "PoliDaoCore: arrays mismatch");
        IPoliDaoStorage s = storageContract;

        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;

            IPoliDaoStructs.PackedFundraiserData memory fPrev = s.fundraisers(fundraiserIds[i]);
            if (fPrev.id == 0) revert FundraiserNotFound();
            address token = s.fundraiserTokens(fundraiserIds[i]);
            if (token == address(0)) revert TokenNotSet();

            uint256 received = DonationLogic.donateWithFee(
                s, fundraiserIds[i], donor, amt, feeRecipient, donationFeeBps
            );

            // [NOWE] Księgowanie wpłaty w Storage
            s.addDonation(fundraiserIds[i], donor, received);

            uint256 newRaised = uint256(fPrev.raisedAmount) + received;
            emit DonationMade(fundraiserIds[i], donor, token, received, newRaised);
        }
    }

    // ========== DELEGATION TO EXTENSIONS ==========

    function delegateToExtensions(bytes calldata data) 
        external 
        onlyRouter
        returns (bytes memory result) 
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        bytes memory returnData = extensionsContract.functionCall(data);
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
     * @notice Gets basic fundraiser information (backward compatible, uint8 statuses)
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
    * @notice Typed version: returns enums for nicer FE mapping
    */
   function getFundraiserBasicInfoTyped(uint256 fundraiserId)
       external
       view
       returns (
           address creator,
           address token,
           uint256 raised,
           uint256 goal,
           uint256 endDate,
           IPoliDaoStructs.FundraiserStatus status
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
           IPoliDaoStructs.FundraiserStatus(data.status)
       );
   }

    /**
     * @notice Gets the total number of fundraisers created
     */
    function getFundraiserCount() external view returns (uint256) {
        return storageContract.fundraiserCounter();
    }

    /**
     * @notice Gets detailed fundraiser metadata (backward compatible)
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
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
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
    * @notice Typed version: returns enums for nicer FE mapping
    */
    function getFundraiserDetailsTyped(uint256 fundraiserId)
        external
        view
        returns (
            string memory title,
            string memory description,
            string memory location,
            uint256 endDate,
            IPoliDaoStructs.FundraiserType fundraiserType,
            IPoliDaoStructs.FundraiserStatus status,
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
        require(f.id != 0, "PoliDaoCore: Fundraiser not found");
        title = storageContract.fundraiserTitles(fundraiserId);
        description = storageContract.fundraiserDescriptions(fundraiserId);
        location = storageContract.fundraiserLocations(fundraiserId);
        endDate = f.endDate;
        fundraiserType = IPoliDaoStructs.FundraiserType(f.fundraiserType);
        status = IPoliDaoStructs.FundraiserStatus(f.status);
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
        require(f.id != 0, "PoliDaoCore: Fundraiser not found"); // opcjonalnie
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

        bool isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        if (f.fundsWithdrawn) return (false, "Funds withdrawn");
        if (withdrawalsStarted[fundraiserId]) return (false, "Refunds blocked by withdrawal");

        if (isWithGoal) {
            if (goalReached) return (false, "Goal reached");
            return (true, "");
        } else {
            return (true, "");
        }
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
    function withdrawFunds(uint256 fundraiserId) external whenNotPaused nonReentrant {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        // bool timeEnded = (f.endDate != 0 && block.timestamp > f.endDate); // removed unused
        bool isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        uint16 wFee = (isWithGoal && goalReached) ? successWithdrawFeeBps : flexibleWithdrawFeeBps;

        (address creator, address token, uint256 paidNet, /*gross*/, bool _goalReached, bool _timeEnded, bool _isWithGoal) =
            WithdrawLogic.withdrawWithFee(
                storageContract,
                fundraiserId,
                msg.sender,
                owner(),
                feeRecipient,
                wFee
            );

        // Po pierwszej wypłacie blokuj refundy:
        // - WITH_GOAL i !goalReached (po endDate), albo
        // - NO_GOAL (wypłata do endDate)
        if ((_isWithGoal && !_goalReached && _timeEnded) || (!_isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }

        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
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
        RefundLogic.startRefundPeriodStrict(
            storageContract,
            fundraiserId,
            _resolveModule("REFUNDS")
        );
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
    ) external onlyOwner {
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
        return addr.code.length > 0;
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
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }

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

    // ---- upgrade helpers ----
    function _isAuthorized(address a) internal view returns (bool) {
        return storageContract.isContractAuthorized(a);
    }

    function upgradeModule(string calldata label, address newAddr) external onlyOwner nonReentrant {
        _assertMutable();
        if (bytes(label).length == 0) revert InvalidInput();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule(label);
        _upgradeModule(label, oldEffective, newAddr);
        // Sync optional state variable for faster resolve
        bytes32 h = _hash(label);
        if (h == _hash("GOVERNANCE")) governanceModule = newAddr;
        else if (h == _hash("MEDIA")) mediaModule = newAddr;
        else if (h == _hash("UPDATES")) updatesModule = newAddr;
        else if (h == _hash("REFUNDS")) refundsModule = newAddr;
        else if (h == _hash("SECURITY")) securityModule = newAddr;
        else if (h == _hash("WEB3")) web3Module = newAddr;
        else if (h == _hash("ANALYTICS")) analyticsModule = newAddr;
    }

    // New: lock further module upgrades (owner-only)
    function lockModuleUpgrades() external onlyOwner {
        _modulesMutable = false;
        emit ModuleUpgradesLocked();
    }

    function areModuleUpgradesOpen() external view returns (bool) {
        return _modulesMutable;
    }

    function extendFundraiserFor(uint256 fundraiserId, address requester, uint256 additionalDays)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        // delegate do Extensions: signature: extendFundraiser(uint256,address,uint256)
        extensionsContract.functionCall(
            abi.encodeWithSignature("extendFundraiser(uint256,address,uint256)", fundraiserId, requester, additionalDays)
        );
    }

    function updateLocationFor(uint256 fundraiserId, address requester, string calldata newLocation)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(extensionsContract != address(0), "PoliDaoCore: Extensions contract not set");
        // delegate do Extensions: updateLocation(uint256,address,string)
        extensionsContract.functionCall(
            abi.encodeWithSignature("updateLocation(uint256,address,string)", fundraiserId, requester, newLocation)
        );
    }

    function withdrawFundsFor(uint256 fundraiserId, address requester)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        // bool timeEnded = (f.endDate != 0 && block.timestamp > f.endDate); // removed unused
        bool isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        uint16 wFee = (isWithGoal && goalReached) ? successWithdrawFeeBps : flexibleWithdrawFeeBps;

        (address creator, address token, uint256 paidNet, /*gross*/, bool _goalReached, bool _timeEnded, bool _isWithGoal) =
            WithdrawLogic.withdrawWithFee(
                storageContract,
                fundraiserId,
                requester,
                owner(),
                feeRecipient,
                wFee
            );

        if ((_isWithGoal && !_goalReached && _timeEnded) || (!_isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }

        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
    }

    function refundFor(uint256 fundraiserId, address donor)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        bool isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        // Blokady refundów
        if (f.fundsWithdrawn) revert RefundNotAllowed();
        if (withdrawalsStarted[fundraiserId]) revert RefundNotAllowed();
        if (isWithGoal && goalReached) revert RefundNotAllowed();

        // Auto start REFUND_PERIOD – wymagany przez moduł refundów
        if (f.status != uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD)) {
            RefundLogic.startRefundPeriodStrict(
                storageContract,
                fundraiserId,
                _resolveModule("REFUNDS")
            );
        }

        _notifyModule("REFUNDS", abi.encodeWithSignature("claimRefund(uint256,address)", fundraiserId, donor));
    }

    /**
     * @notice Address to use as spender for ERC20 approvals before donate/batchDonate
     */
    function spenderAddress() external view returns (address) {
        return address(this);
    }

    // Keep only admin setters here (no duplicates)
    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "invalid recipient");
        feeRecipient = _recipient;
    }

    function setDonationFeeBps(uint16 bps) external onlyOwner {
        require(bps <= 10_000, "bps too high");
        donationFeeBps = bps;
    }

    function setWithdrawFeesBps(uint16 _successBps, uint16 _flexBps) external onlyOwner {
        require(_successBps <= 10_000 && _flexBps <= 10_000, "bps too high");
        successWithdrawFeeBps = _successBps;
        flexibleWithdrawFeeBps = _flexBps;
    }
}