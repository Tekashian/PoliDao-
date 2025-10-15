// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "./../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../libraries/FundraiserLogic.sol";
// DODANE
import "../libraries/WithdrawLogic.sol";
import "../libraries/RefundLogic.sol";
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
    using Address for address;
    using SafeERC20 for IERC20;

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

    // ========== MODULE ADDRESSES =========
    address public governanceModule;
    address public mediaModule;
    address public updatesModule;
    address public securityModule;
    address public web3Module;
    address public analyticsModule;

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
    // NEW refund lifecycle events (library‑only architecture)
    event RefundPeriodEntered(uint256 indexed fundraiserId, address indexed caller);
    event RefundClaimed(uint256 indexed fundraiserId, address indexed donor, address indexed token, uint256 netAmount, uint256 commission);

    // DODANE: brakujące eventy używane w kodzie
    event FundraiserSuspended(uint256 indexed fundraiserId, address indexed by, string reason, uint256 timestamp);
    event ModuleUpgraded(string label, address oldAddr, address newAddr);
    // RESTORED (required by constructor/setters)
    event RouterContractUpdated(address indexed oldRouter, address indexed newRouter);
    event ExtensionsContractUpdated(address indexed oldExtensions, address indexed newExtensions);

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
        require(amount > 0, "PoliDaoCore: amount=0");
        address token = storageContract.fundraiserTokens(fundraiserId);
        require(token != address(0), "PoliDaoCore: token");
        // Pobierz gross do Core (approve Core w testach)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 fee = 0;
        if (feeRecipient != address(0) && donationFeeBps > 0) {
            fee = (amount * donationFeeBps) / 10_000;
            if (fee > 0) {
                IERC20(token).safeTransfer(feeRecipient, fee);
            }
        }
        uint256 net = amount - fee;
        // Przekazujemy netto do Storage (fundusze zbiórki)
        IERC20(token).safeTransfer(address(storageContract), net);
        // Zapis netto (walidacje statusu/czasu w addDonation)
        storageContract.addDonation(fundraiserId, msg.sender, net);
        {
            IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserId);
            uint256 newRaised = fr.raisedAmount;
            emit DonationMade(fundraiserId, msg.sender, token, net, newRaised);
            return;
        }
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
        require(amount > 0, "PoliDaoCore: amount=0");
        address token = storageContract.fundraiserTokens(fundraiserId);
        require(token != address(0), "PoliDaoCore: token");
        IERC20(token).safeTransferFrom(donor, address(this), amount);
        uint256 fee = 0;
        if (feeRecipient != address(0) && donationFeeBps > 0) {
            fee = (amount * donationFeeBps) / 10_000;
            if (fee > 0) IERC20(token).safeTransfer(feeRecipient, fee);
        }
        uint256 net = amount - fee;
        IERC20(token).safeTransfer(address(storageContract), net);
        storageContract.addDonation(fundraiserId, donor, net);
        {
            IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserId);
            emit DonationMade(fundraiserId, donor, token, net, fr.raisedAmount);
        }
    }

    function batchDonateFrom(address donor, uint256[] calldata fundraiserIds, uint256[] calldata amounts)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        require(fundraiserIds.length == amounts.length && fundraiserIds.length > 0, "PoliDaoCore: arrays mismatch");
        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            address token = storageContract.fundraiserTokens(fundraiserIds[i]);
            require(token != address(0), "PoliDaoCore: token");
            IERC20(token).safeTransferFrom(donor, address(this), amt);
            uint256 fee = 0;
            if (feeRecipient != address(0) && donationFeeBps > 0) {
                fee = (amt * donationFeeBps) / 10_000;
                if (fee > 0) IERC20(token).safeTransfer(feeRecipient, fee);
            }
            uint256 net = amt - fee;
            IERC20(token).safeTransfer(address(storageContract), net);
            storageContract.addDonation(fundraiserIds[i], donor, net);
            {
                IPoliDaoStructs.PackedFundraiserData memory fr = storageContract.fundraisers(fundraiserIds[i]);
                emit DonationMade(fundraiserIds[i], donor, token, net, fr.raisedAmount);
            }
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

    // ========== LOCATION / EXTENSION (router) ==========
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

    // ========== WITHDRAW / REFUND ==========
    function withdrawFunds(uint256 fundraiserId) external whenNotPaused nonReentrant {
        (
            address creator,
            address token,
            uint256 paidNet,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        ) = WithdrawLogic.executeWithdraw(
                storageContract,
                fundraiserId,
                msg.sender,
                owner(),
                feeRecipient,
                successWithdrawFeeBps,
                flexibleWithdrawFeeBps
            );
        if ((isWithGoal && !goalReached && timeEnded) || (!isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }
        // Record withdrawal totals for analytics
        try PoliDaoStorage(address(storageContract)).recordWithdrawal(fundraiserId, paidNet) {} catch {}
        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
    }

    function withdrawFundsFor(uint256 fundraiserId, address requester)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        (
            address creator,
            address token,
            uint256 paidNet,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        ) = WithdrawLogic.executeWithdraw(
                storageContract,
                fundraiserId,
                requester,
                owner(),
                feeRecipient,
                successWithdrawFeeBps,
                flexibleWithdrawFeeBps
            );

        if ((isWithGoal && !goalReached && timeEnded) || (!isWithGoal)) {
            withdrawalsStarted[fundraiserId] = true;
        }
        // Record withdrawal totals for analytics
        try PoliDaoStorage(address(storageContract)).recordWithdrawal(fundraiserId, paidNet) {} catch {}
        emit FundsWithdrawn(fundraiserId, creator, token, paidNet);
    }

    function refund(uint256 /* fundraiserId */)
        external
        whenNotPaused
        nonReentrant
        onlyAuthorizedOrOwner
    {
        // Refund period removed; keep function but make it a no-op (or revert if you prefer)
        // For compatibility, do nothing here.
        // emit RefundPeriodEntered(fundraiserId, msg.sender); // optional: remove to avoid confusion
        revert RefundNotAllowed();
    }
    
    function refundFor(uint256 fundraiserId, address donor)
        external
        whenNotPaused
        nonReentrant
        onlyRouter
    {
        // Block refunds if withdrawals already started (strict interpretation of "nie zostala wyplacona")
        require(!withdrawalsStarted[fundraiserId], "PoliDaoCore: withdrawals started");

        // Execute donor refund directly; tranche via Security
        (uint256 netAmount, uint256 commission, address token) =
            RefundLogic.claimRefund(storageContract, fundraiserId, donor, withdrawalsStarted[fundraiserId]);
        emit RefundClaimed(fundraiserId, donor, token, netAmount, commission);
    }

    // ========== MODULE MGMT (simplified) ==========
    function setModules(
        address _governance,
        address _media,
        address _updates,
        address /*_refunds*/,
        address _security,
        address _web3,
        address _analytics
    ) external onlyOwner {
        require(governanceModule == address(0) && mediaModule == address(0), "Already initialized");
        require(
            _governance != address(0) &&
            _media != address(0) &&
            _updates != address(0) &&
            _security != address(0) &&
            _web3 != address(0) &&
            _analytics != address(0),
            "PoliDaoCore: zero module addr"
        );
        governanceModule = _governance;
        mediaModule = _media;
        updatesModule = _updates;
        securityModule = _security;
        web3Module = _web3;
        analyticsModule = _analytics;
    }

    function upgradeModule(string calldata label, address newAddr) external onlyOwner nonReentrant {
        if (bytes(label).length == 0) revert InvalidInput();
        if (newAddr != address(0)) require(_hasCode(newAddr), "Not a contract");
        address oldEffective = _resolveModule(label);
        emit ModuleUpgraded(label, oldEffective, newAddr);
        bytes32 h = keccak256(bytes(label));
        if (h == keccak256("GOVERNANCE")) governanceModule = newAddr;
        else if (h == keccak256("MEDIA")) mediaModule = newAddr;
        else if (h == keccak256("UPDATES")) updatesModule = newAddr;
        else if (h == keccak256("SECURITY")) securityModule = newAddr;
        else if (h == keccak256("WEB3")) web3Module = newAddr;
        else if (h == keccak256("ANALYTICS")) analyticsModule = newAddr;
        // best-effort sync
        try storageContract.setModule(h, newAddr) {} catch {}
        if (newAddr != address(0) && !storageContract.isContractAuthorized(newAddr)) {
            try storageContract.authorizeContract(newAddr) {} catch {}
        }
    }

    // ========== STATUS / CONFIG ==========
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

    function validateConfiguration()
        external
        view
        returns (bool isValid, string memory missingComponent)
    {
        if (extensionsContract == address(0)) return (false, "Extensions contract not set");
        if (routerContract == address(0)) return (false, "Router contract not set");
        if (!storageContract.isContractAuthorized(address(this))) return (false, "Core not authorized in storage");
        return (true, "");
    }

    // ========== INTERNAL HELPERS ==========
    function _resolveModule(string memory moduleKey) internal view returns (address) {
        bytes32 h = keccak256(bytes(moduleKey));
        if (h == keccak256("GOVERNANCE") && governanceModule != address(0)) return governanceModule;
        if (h == keccak256("MEDIA") && mediaModule != address(0)) return mediaModule;
        if (h == keccak256("UPDATES") && updatesModule != address(0)) return updatesModule;
        if (h == keccak256("SECURITY") && securityModule != address(0)) return securityModule;
        if (h == keccak256("WEB3") && web3Module != address(0)) return web3Module;
        if (h == keccak256("ANALYTICS") && analyticsModule != address(0)) return analyticsModule;
        return storageContract.modules(h);
    }

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    // ========== TOKEN WHITELIST (delegation) / FEES / SPENDER ==========
    // ...existing whitelist & fee setter functions unchanged...

    function spenderAddress() external view returns (address) {
        return address(this);
    }

    // ========== FEE SETTERS (needed by tests) ==========
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function setDonationFeeBps(uint16 _bps) external onlyOwner {
        require(_bps <= 10_000, "bps>100%");
        donationFeeBps = _bps;
    }

    function setWithdrawFeesBps(uint16 _successBps, uint16 _flexibleBps) external onlyOwner {
        require(_successBps <= 10_000 && _flexibleBps <= 10_000, "bps>100%");
        successWithdrawFeeBps = _successBps;
        flexibleWithdrawFeeBps = _flexibleBps;
    }
}