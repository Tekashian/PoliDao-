// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import "../core/PoliDaoCore.sol"; // removed: avoid pulling implementation into compilation unit
import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Minimalny interfejs EIP-2612 (permit)
interface IERC20Permit {
    function permit(
        address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s
    ) external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// [NEW] Minimal interface of Security module check
interface ISecurityDonationLimit {
    function checkDonationLimit(address token, uint256 amount) external view returns (bool ok, string memory reason);
}

// [NEW] Minimal interface to read config from Security
interface ISecurityConfig {
    function donationLimitUSDC() external view returns (uint256);
}

// Minimal interface for payout scheduling in Security
interface ISecurityPayouts {
    function checkAndConsumeWithdraw(uint256 fundraiserId, address actor, uint256 requestedAmount)
        external
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining);
    function checkAndConsumeRefund(uint256 fundraiserId, address actor, uint256 requestedAmount)
        external
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining);
}

// [ADD] Minimal interface for Core to avoid importing implementation
interface IPoliDaoCore {
    function paused() external view returns (bool);
    function getFundraiserCount() external view returns (uint256);
    function storageContract() external view returns (IPoliDaoStorage);

    function createFundraiserFor(address creator, IPoliDaoStructs.FundraiserCreationData calldata data)
        external
        returns (uint256);

    function donateFrom(uint256 fundraiserId, address donor, uint256 amount) external;
    function batchDonateFrom(address donor, uint256[] calldata fundraiserIds, uint256[] calldata amounts) external;

    function getDonationAmount(uint256 fundraiserId, address donor) external view returns (uint256);

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
        );

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
        );

    function canExtendFundraiser(uint256 fundraiserId) external view returns (bool, uint256, string memory);
    function canRefund(uint256 fundraiserId, address donor) external view returns (bool, string memory);

    function callModule(bytes32 moduleKey, bytes calldata data) external returns (bytes memory);
    function staticCallModule(bytes32 moduleKey, bytes calldata data) external view returns (bytes memory);

    function withdrawFundsFor(uint256 fundraiserId, address requester) external;
    function refundFor(uint256 fundraiserId, address donor) external;
    function refund(uint256 fundraiserId) external;
}

/**
 * @title PoliDaoRouter
 * @notice Security layer and router for PoliDAO platform
 * @dev Provides rate limiting, access control, and secure routing to core contract
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 * @custom:security-contact security@polidao.org
 */
contract PoliDaoRouter is Ownable, ReentrancyGuard {
    
    // ========== CORE CONTRACT ==========
    
    /// @notice Address of the core contract
    // PoliDaoCore public coreContract;
    IPoliDaoCore public coreContract;

    // [ADDED] Security module address used for USDC donation limit checks
    address public security;

    // [NEW] Fallback limit for deterministic enforcement when security is unset or returns zero (6 decimals)
    uint256 private constant DEFAULT_USDC_LIMIT = 1_100_000;
    
    // ========== RATE LIMITING ==========
    
    /// @notice Rate limit for donations per user per hour
    uint256 public donationRateLimit = 10;
    
    /// @notice Rate limit for fundraiser creation per user per day
    uint256 public creationRateLimit = 3;
    
    /// @notice Rate limit time window (1 hour)
    uint256 public constant RATE_LIMIT_WINDOW = 1 hours;
    
    /// @notice Rate limit time window for creation (1 day)
    uint256 public constant CREATION_RATE_LIMIT_WINDOW = 1 days;
    
    /// @notice Mapping of user donations count in current window
    mapping(address => mapping(uint256 => uint256)) public userDonationCount;
    
    /// @notice Mapping of user creation count in current window
    mapping(address => mapping(uint256 => uint256)) public userCreationCount;
    
    // ========== ACCESS CONTROL ==========
    
    /// @notice Mapping of banned users
    mapping(address => bool) public bannedUsers;
    
    /// @notice Mapping of whitelisted users (bypass rate limits)
    mapping(address => bool) public whitelistedUsers;
    
    /// @notice Minimum balance required to create fundraisers
    uint256 public minimumBalanceRequired = 0;
    
    // ========== EMERGENCY CONTROLS ==========
    
    /// @notice Emergency stop for donations
    bool public donationsDisabled = false;
    
    /// @notice Emergency stop for fundraiser creation
    bool public creationDisabled = false;
    
    /// @notice Emergency stop for extensions
    bool public extensionsDisabled = false;
    
    // ========== HEALTH MONITORING ==========
    
    /**
     * @notice Gets router health status
     * @return isHealthy Whether the router is functioning properly
     * @return lastTransaction Timestamp of last successful transaction
     * @return successRate Success rate percentage (basis points)
     * @return totalTx Total transactions processed
     * @return failedTx Failed transactions count
     */
    function getHealthStatus()
        external
        view
        returns (
            bool isHealthy,
            uint256 lastTransaction,
            uint256 successRate,
            uint256 totalTx,
            uint256 failedTx
        )
    {
        totalTx = totalTransactions;
        failedTx = failedTransactions;
        lastTransaction = lastSuccessfulTransaction;
        
        // Calculate success rate (in basis points)
        if (totalTx > 0) {
            successRate = ((totalTx - failedTx) * 10000) / totalTx;
        } else {
            successRate = 10000; // 100% if no transactions yet
        }
        
        // Consider healthy if:
        // - Success rate > 95%
        // - Last successful transaction within 24 hours (if any transactions exist)
        isHealthy = (
            successRate >= 9500 &&
            (totalTx == 0 || block.timestamp - lastTransaction <= 24 hours)
        );
        
        return (isHealthy, lastTransaction, successRate, totalTx, failedTx);
    }
    
    /**
     * @notice Gets rate limit status for a user
     * @param user User address to check
     * @return donationCount Current donation count in window
     * @return creationCount Current creation count in window
     * @return donationLimit Max donations allowed
     * @return creationLimit Max creations allowed
     * @return isWhitelisted Whether user is whitelisted
     * @return isBanned Whether user is banned
     */
    function getUserStatus(address user)
        external
        view
        returns (
            uint256 donationCount,
            uint256 creationCount,
            uint256 donationLimit,
            uint256 creationLimit,
            bool isWhitelisted,
            bool isBanned
        )
    {
        uint256 donationWindow = block.timestamp / RATE_LIMIT_WINDOW;
        uint256 creationWindow = block.timestamp / CREATION_RATE_LIMIT_WINDOW;
        
        return (
            userDonationCount[user][donationWindow],
            userCreationCount[user][creationWindow],
            donationRateLimit,
            creationRateLimit,
            whitelistedUsers[user],
            bannedUsers[user]
        );
    }
    
    /**
     * @notice Gets router configuration
    * @return donationRate Current donation rate limit
    * @return creationRate Current creation rate limit
    * @return minBalance Minimum balance requirement
    * @return donationsEnabledFlag Whether donations are enabled
    * @return creationEnabledFlag Whether creation is enabled
    * @return extensionsEnabledFlag Whether extensions are enabled
     */
    function getRouterConfig()
        external
        view
        returns (
            uint256 donationRate,
            uint256 creationRate,
            uint256 minBalance,
            bool donationsEnabledFlag,
            bool creationEnabledFlag,
            bool extensionsEnabledFlag
        )
    {
        return (
            donationRateLimit,
            creationRateLimit,
            minimumBalanceRequired,
            !donationsDisabled,
            !creationDisabled,
            !extensionsDisabled
        );
    }
    
    /**
     * @notice Resets failed transaction counter (admin function)
     */
    function resetFailedTransactions() external onlyOwner {
        failedTransactions = 0;
    }
    
    /**
     * @notice Emergency function to reset user rate limits
     * @param user User address to reset
     */
    function resetUserRateLimits(address user) external onlyOwner {
        uint256 donationWindow = block.timestamp / RATE_LIMIT_WINDOW;
        uint256 creationWindow = block.timestamp / CREATION_RATE_LIMIT_WINDOW;
        
        userDonationCount[user][donationWindow] = 0;
        userCreationCount[user][creationWindow] = 0;
    }
    
    // ========== INTERNAL FUNCTIONS ==========
    
    /**
     * @notice Internal function to increment transaction counter
     */
    function _incrementTransactionCount() internal {
        totalTransactions++;
    }
    
    /**
     * @notice Checks if core contract is responsive
     * @return isResponsive Whether core contract responds to calls
     */
    function _checkCoreContractHealth() internal view returns (bool isResponsive) {
        try coreContract.getFundraiserCount() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }
    
    // [ADDED] Resolve current USDC donation limit with safe fallback
    function _currentUsdcLimit() internal view returns (uint256) {
        if (security != address(0)) {
            // Try read from Security; if unset (0) or call fails, use default
            try ISecurityConfig(security).donationLimitUSDC() returns (uint256 lim) {
                if (lim != 0) {
                    return lim;
                }
            } catch {
                // ignore
            }
        }
        return DEFAULT_USDC_LIMIT;
    }

    // [CHANGED] Public getter reflects the effective limit (Security or default)
    function currentDonationLimit() external view returns (uint256) {
        return _currentUsdcLimit();
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    /**
     * @notice Emergency circuit breaker - disables all functions
     */
    function emergencyStop() external onlyOwner {
        donationsDisabled = true;
        creationDisabled = true;
        extensionsDisabled = true;
        emit EmergencyControlToggled("all", true);
    }
    
    /**
     * @notice Emergency function to enable all functions
     */
    function emergencyRestart() external onlyOwner {
        donationsDisabled = false;
        creationDisabled = false;
        extensionsDisabled = false;
        emit EmergencyControlToggled("all", false);
    }
    
    // ========== UPGRADE COMPATIBILITY ==========
    
    /**
     * @notice Gets contract version and compatibility info
     * @return version Router version
     * @return coreAddress Address of core contract
     * @return isCompatible Whether router is compatible with core
     */
    function getVersionInfo()
        external
        view
        returns (
            string memory version,
            address coreAddress,
            bool isCompatible
        )
    {
        version = "1.0.0-UNIFIED";
        coreAddress = address(coreContract);
        isCompatible = _checkCoreContractHealth();
        
        return (version, coreAddress, isCompatible);
    }
    /// @notice Last successful transaction timestamp
    uint256 public lastSuccessfulTransaction;
    
    /// @notice Total transactions processed
    uint256 public totalTransactions;
    
    /// @notice Failed transactions count
    uint256 public failedTransactions;
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when rate limits are updated
    event RateLimitsUpdated(uint256 donationLimit, uint256 creationLimit);
    
    /// @notice Emitted when user is banned
    event UserBanned(address indexed user);
    
    /// @notice Emitted when user is unbanned
    event UserUnbanned(address indexed user);
    
    /// @notice Emitted when user is whitelisted
    event UserWhitelisted(address indexed user);
    
    /// @notice Emitted when user whitelist is removed
    event UserWhitelistRemoved(address indexed user);
    
    /// @notice Emitted when emergency controls are toggled
    event EmergencyControlToggled(string control, bool enabled);
    
    /// @notice Emitted when minimum balance requirement is updated
    event MinimumBalanceUpdated(uint256 oldBalance, uint256 newBalance);
    
    // ========== MODIFIERS ==========
    
    /// @notice Ensures user is not banned
    modifier notBanned() {
        require(!bannedUsers[msg.sender], "PoliDaoRouter: User banned");
        _;
    }
    
    /// @notice Ensures donations are enabled
    modifier donationsEnabled() {
        require(!donationsDisabled, "PoliDaoRouter: Donations disabled");
        _;
    }
    
    /// @notice Ensures creation is enabled
    modifier creationEnabled() {
        require(!creationDisabled, "PoliDaoRouter: Creation disabled");
        _;
    }
    
    /// @notice Ensures extensions are enabled
    modifier extensionsEnabled() {
        require(!extensionsDisabled, "PoliDaoRouter: Extensions disabled");
        _;
    }
    
    /// @notice Rate limiting for donations
    modifier rateLimitDonations() {
        if (!whitelistedUsers[msg.sender]) {
            uint256 currentWindow = block.timestamp / RATE_LIMIT_WINDOW;
            require(
                userDonationCount[msg.sender][currentWindow] < donationRateLimit,
                "PoliDaoRouter: Donation rate limit exceeded"
            );
            userDonationCount[msg.sender][currentWindow]++;
        }
        _;
    }
    
    /// @notice Rate limiting for fundraiser creation
    modifier rateLimitCreation() {
        if (!whitelistedUsers[msg.sender]) {
            uint256 currentWindow = block.timestamp / CREATION_RATE_LIMIT_WINDOW;
            require(
                userCreationCount[msg.sender][currentWindow] < creationRateLimit,
                "PoliDaoRouter: Creation rate limit exceeded"
            );
            userCreationCount[msg.sender][currentWindow]++;
        }
        _;
    }
    
    /// @notice Ensures user meets minimum balance requirement
    modifier checkMinimumBalance() {
        if (minimumBalanceRequired > 0 && !whitelistedUsers[msg.sender]) {
            require(
                msg.sender.balance >= minimumBalanceRequired,
                "PoliDaoRouter: Insufficient balance"
            );
        }
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    /**
     * @notice Initializes the router contract
     * @param _coreContract Address of the core contract
     */
    constructor(address _coreContract) Ownable(msg.sender) {
        require(_coreContract != address(0), "PoliDaoRouter: Invalid core contract");
        // coreContract = PoliDaoCore(_coreContract);
        coreContract = IPoliDaoCore(_coreContract);
        lastSuccessfulTransaction = block.timestamp;
    }

    // initializer for clone deployments
    bool private _initialized;

    function initialize(address _coreContract, address initialOwner) external {
        require(!_initialized, "PoliDaoRouter: already initialized");
        require(_coreContract != address(0), "PoliDaoRouter: Invalid core contract");
        _initialized = true;
        // coreContract = PoliDaoCore(_coreContract);
        coreContract = IPoliDaoCore(_coreContract);
        lastSuccessfulTransaction = block.timestamp;
        transferOwnership(initialOwner);
    }
    
    // ========== CORE FUNCTION ROUTING ==========
    
    /**
     * @notice Routes fundraiser creation to core contract
     * @param data Fundraiser creation data
     * @return fundraiserId The created fundraiser ID
     */
    function createFundraiser(IPoliDaoStructs.FundraiserCreationData calldata data)
        external
        coreNotPaused
        nonReentrant
        notBanned
        creationEnabled
        rateLimitCreation
        checkMinimumBalance
        returns (uint256)
    {
        return coreContract.createFundraiserFor(msg.sender, data);
    }

    /**
     * @notice Donate to a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param amount Donation amount
     */
    function donate(uint256 fundraiserId, uint256 amount)
        external
        coreNotPaused
        nonReentrant
        notBanned
        donationsEnabled
        rateLimitDonations
    {
        // [ENFORCE] Router-level deterministic enforcement
        uint256 limit = _currentUsdcLimit();
        require(amount <= limit, "Donation exceeds USDC limit");

        // [OPTIONAL] Security hook (if configured)
        if (security != address(0)) {
            address token = coreContract.storageContract().fundraiserTokens(fundraiserId);
            (bool ok, string memory reason) = ISecurityDonationLimit(security).checkDonationLimit(token, amount);
            require(ok, bytes(reason).length > 0 ? reason : "Donation exceeds limit");
        }
        coreContract.donateFrom(fundraiserId, msg.sender, amount);
    }

    /**
     * @notice Donate using permit (EIP-2612)
     * @param fundraiserId The fundraiser ID
     * @param amount Donation amount
     * @param deadline Permit deadline
     * @param v Permit v
     * @param r Permit r
     * @param s Permit s
     */
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        coreNotPaused
        nonReentrant
        notBanned
        donationsEnabled
        rateLimitDonations
    {
        // [ENFORCE] Router-level deterministic enforcement
        uint256 limit = _currentUsdcLimit();
        require(amount <= limit, "Donation exceeds USDC limit");

        // [OPTIONAL] Security hook (if configured)
        if (security != address(0)) {
            address tokenAddr = coreContract.storageContract().fundraiserTokens(fundraiserId);
            (bool ok, string memory reason) = ISecurityDonationLimit(security).checkDonationLimit(tokenAddr, amount);
            require(ok, bytes(reason).length > 0 ? reason : "Donation exceeds limit");
        }

        // Proceed with permit + donate
        address token = coreContract.storageContract().fundraiserTokens(fundraiserId);
        require(token != address(0), "Router: invalid fundraiser/token");
        IERC20Permit(token).permit(msg.sender, address(coreContract), amount, deadline, v, r, s);
        coreContract.donateFrom(fundraiserId, msg.sender, amount);
    }

    /**
     * @notice Routes batch donation
     * @param fundraiserIds Array of fundraiser IDs
     * @param amounts Array of amounts
     */
    function batchDonate(uint256[] calldata fundraiserIds, uint256[] calldata amounts)
        external
        coreNotPaused
        nonReentrant
        notBanned
        donationsEnabled
    {
        // [ENFORCE] Router-level deterministic enforcement per entry
        uint256 limit = _currentUsdcLimit();
        uint256 len = fundraiserIds.length;
        for (uint256 i = 0; i < len; i++) {
            require(amounts[i] <= limit, "Donation exceeds USDC limit");
        }

        // [OPTIONAL] Security hook per entry (if configured)
        if (security != address(0)) {
            for (uint256 i = 0; i < len; i++) {
                address token = coreContract.storageContract().fundraiserTokens(fundraiserIds[i]);
                (bool ok, string memory reason) = ISecurityDonationLimit(security).checkDonationLimit(token, amounts[i]);
                require(ok, bytes(reason).length > 0 ? reason : "Donation exceeds limit");
            }
        }

        coreContract.batchDonateFrom(msg.sender, fundraiserIds, amounts);
    }

    // ========== PAGINATION / LISTING ==========
    /**
     * @notice Returns fundraiser IDs in a paginated window (IDs assumed 1..count)
     */
    function listFundraisers(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 count = coreContract.getFundraiserCount();
        if (offset >= count || limit == 0) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > count) end = count;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = offset + i + 1;
        }
    }

    /**
     * @notice Returns user donations for a scan window of fundraiser IDs
     * @param user address to scan
     * @param startId first fundraiser id (>=1)
     * @param limit max ids to scan
     */
    function listUserDonations(address user, uint256 startId, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256[] memory amounts)
    {
        uint256 count = coreContract.getFundraiserCount();
        if (startId < 1 || startId > count || limit == 0) {
            return (new uint256[](0), new uint256[](0));
        }
        uint256 endId = startId + limit - 1;
        if (endId > count) endId = count;
        uint256 cap = endId - startId + 1;

        uint256[] memory tmpIds = new uint256[](cap);
        uint256[] memory tmpAmts = new uint256[](cap);
        uint256 n = 0;
        for (uint256 id = startId; id <= endId; id++) {
            uint256 a = coreContract.getDonationAmount(id, user);
            if (a > 0) {
                tmpIds[n] = id;
                tmpAmts[n] = a;
                n++;
            }
        }
        ids = new uint256[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = tmpIds[i];
            amounts[i] = tmpAmts[i];
        }
    }
    
    // ========== VIEW FUNCTIONS (PASSTHROUGH) ==========
    
    /**
     * @notice Gets fundraiser details from core contract
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
        return coreContract.getFundraiserDetails(fundraiserId);
    }
    
    /**
     * @notice Gets fundraiser progress from core contract
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
        return coreContract.getFundraiserProgress(fundraiserId);
    }
    
    /**
     * @notice Gets fundraiser count from core contract
     */
    function getFundraiserCount() external view returns (uint256) {
        return coreContract.getFundraiserCount();
    }
    
    /**
     * @notice Gets donation amount from core contract
     */
    function getDonationAmount(uint256 fundraiserId, address donor) external view returns (uint256) {
        return coreContract.getDonationAmount(fundraiserId, donor);
    }
    
    /**
     * @notice Convenience getters for fundraiser metadata stored in Storage
     * @dev Uses low-level staticcall to avoid interface drift.
     */
    function getFundraiserMetadata(uint256 fundraiserId) external view returns (string memory) {
        address s = address(coreContract.storageContract());
        (bool ok, bytes memory res) = s.staticcall(abi.encodeWithSignature("getFundraiserMetadata(uint256)", fundraiserId));
        if (!ok) {
            // fallback to public mapping accessor if older Storage
            (ok, res) = s.staticcall(abi.encodeWithSignature("fundraiserMetadata(uint256)", fundraiserId));
            require(ok, "Router: metadata read failed");
        }
        return abi.decode(res, (string));
    }

    function getFundraiserInitialImage(uint256 fundraiserId) external view returns (string memory) {
        address s = address(coreContract.storageContract());
        (bool ok, bytes memory res) = s.staticcall(abi.encodeWithSignature("getFundraiserInitialImage(uint256)", fundraiserId));
        if (!ok) {
            // fallback to public mapping accessor if older Storage
            (ok, res) = s.staticcall(abi.encodeWithSignature("fundraiserInitialImage(uint256)", fundraiserId));
            require(ok, "Router: initialImage read failed");
        }
        return abi.decode(res, (string));
    }

    /**
     * @notice Checks if fundraiser can be extended
     */
    function canExtendFundraiser(uint256 fundraiserId)
        external
        view
        returns (bool canExtend, uint256 timeLeft, string memory reason)
    {
        return coreContract.canExtendFundraiser(fundraiserId);
    }
    
    /**
     * @notice Checks if donor can get refund
     */
    function canRefund(uint256 fundraiserId, address donor)
        external
        view
        returns (bool canRefundResult, string memory reason)
    {
        return coreContract.canRefund(fundraiserId, donor);
    }

    /**
     * @notice Sprawdza wsparcie EIP-2612 przez token (na podstawie obecności nonces i DOMAIN_SEPARATOR)
     */
    function supportsPermit(address token) external view returns (bool) {
        (bool ok1, ) = token.staticcall(abi.encodeWithSelector(IERC20Permit.nonces.selector, address(0)));
        (bool ok2, ) = token.staticcall(abi.encodeWithSelector(IERC20Permit.DOMAIN_SEPARATOR.selector));
        return ok1 && ok2;
    }

    /**
     * @notice Zwraca nonce dla danego tokena i właściciela (EIP-2612)
     */
    function getPermitNonce(address token, address owner) external view returns (uint256) {
        return IERC20Permit(token).nonces(owner);
    }

    /**
     * @notice Checks whether a module is active (i.e., module address set)
     */
    function isModuleActive(bytes32 moduleKey) external view returns (bool) {
        address module = address(coreContract.storageContract().modules(moduleKey));
        return module != address(0);
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Updates rate limits
     * @param _donationRateLimit New donation rate limit
     * @param _creationRateLimit New creation rate limit
     */
    function setRateLimits(uint256 _donationRateLimit, uint256 _creationRateLimit) external onlyOwner {
        require(_donationRateLimit > 0 && _donationRateLimit <= 100, "PoliDaoRouter: Invalid donation rate limit");
        require(_creationRateLimit > 0 && _creationRateLimit <= 50, "PoliDaoRouter: Invalid creation rate limit");
        
        donationRateLimit = _donationRateLimit;
        creationRateLimit = _creationRateLimit;
        
        emit RateLimitsUpdated(_donationRateLimit, _creationRateLimit);
    }
    
    /**
     * @notice Bans a user
     * @param user User address to ban
     */
    function banUser(address user) external onlyOwner {
        require(user != address(0), "PoliDaoRouter: Invalid user");
        require(user != owner(), "PoliDaoRouter: Cannot ban owner");
        
        bannedUsers[user] = true;
        emit UserBanned(user);
    }
    
    /**
     * @notice Unbans a user
     * @param user User address to unban
     */
    function unbanUser(address user) external onlyOwner {
        require(bannedUsers[user], "PoliDaoRouter: User not banned");
        
        bannedUsers[user] = false;
        emit UserUnbanned(user);
    }
    
    /**
     * @notice Whitelists a user (bypass rate limits)
     * @param user User address to whitelist
     */
    function whitelistUser(address user) external onlyOwner {
        require(user != address(0), "PoliDaoRouter: Invalid user");
        
        whitelistedUsers[user] = true;
        emit UserWhitelisted(user);
    }
    
    /**
     * @notice Removes user from whitelist
     * @param user User address to remove from whitelist
     */
    function removeFromWhitelist(address user) external onlyOwner {
        require(whitelistedUsers[user], "PoliDaoRouter: User not whitelisted");
        
        whitelistedUsers[user] = false;
        emit UserWhitelistRemoved(user);
    }
    
    /**
     * @notice Sets minimum balance requirement
     * @param _minimumBalance New minimum balance required
     */
    function setMinimumBalance(uint256 _minimumBalance) external onlyOwner {
        uint256 oldBalance = minimumBalanceRequired;
        minimumBalanceRequired = _minimumBalance;
        emit MinimumBalanceUpdated(oldBalance, _minimumBalance);
    }
    
    /**
     * @notice Emergency control toggles
     */
    function toggleDonations() external onlyOwner {
        donationsDisabled = !donationsDisabled;
        emit EmergencyControlToggled("donations", donationsDisabled);
    }
    
    function toggleCreation() external onlyOwner {
        creationDisabled = !creationDisabled;
        emit EmergencyControlToggled("creation", creationDisabled);
    }
    
    function toggleExtensions() external onlyOwner {
        extensionsDisabled = !extensionsDisabled;
        emit EmergencyControlToggled("extensions", extensionsDisabled);
    }
    
    // [ADDED] Set security module address
    function setSecurity(address _security) external onlyOwner {
        security = _security;
    }

    // ====== CORE PAUSE BRIDGE ======
    modifier coreNotPaused() {
        require(!coreContract.paused(), "PoliDaoRouter: Core paused");
        _;
    }

    // ====== MODULE ALLOWLIST FOR GENERIC ROUTING ======
    // moduleKey -> selector -> allowed
    mapping(bytes32 => mapping(bytes4 => bool)) private _allowedSelectors;
    event ModuleSelectorAllowed(bytes32 indexed moduleKey, bytes4 indexed selector, bool allowed);

    function setAllowedSelector(bytes32 moduleKey, bytes4 selector, bool allowed) external onlyOwner {
        _allowedSelectors[moduleKey][selector] = allowed;
        emit ModuleSelectorAllowed(moduleKey, selector, allowed);
    }

    function setAllowedSelectorsBatch(bytes32 moduleKey, bytes4[] calldata selectors, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < selectors.length; i++) {
            _allowedSelectors[moduleKey][selectors[i]] = allowed;
            emit ModuleSelectorAllowed(moduleKey, selectors[i], allowed);
        }
    }

    function routeModule(bytes32 moduleKey, bytes calldata data)
        external
        coreNotPaused
        nonReentrant
        returns (bytes memory)
    {
        require(data.length >= 4, "Router: data too short");
         bytes4 sel;
        assembly {
            sel := calldataload(data.offset)
        }
         require(_allowedSelectors[moduleKey][sel], "Router: selector not allowed");
         return coreContract.callModule(moduleKey, data);
    }

    function routeModuleStatic(bytes32 moduleKey, bytes calldata data)
        external
        view
        returns (bytes memory)
    {
        require(data.length >= 4, "Router: data too short");
         bytes4 sel;
        assembly {
            sel := calldataload(data.offset)
        }
         require(_allowedSelectors[moduleKey][sel], "Router: selector not allowed");
         return coreContract.staticCallModule(moduleKey, data);
    }

    /**
     * @notice Withdraw helper respecting Security payout schedule.
     * @dev Calls Security to enforce non-stacking tranches and returns how much can be withdrawn now.
     *      Does not forward to Core here to keep compatibility with MockCore; upstream can proceed with the returned amount.
     */
    function withdrawWithSchedule(uint256 fundraiserId, uint256 requestedAmount)
        external
        coreNotPaused
        nonReentrant
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining)
    {
        require(security != address(0), "Router: security not set");
        return ISecurityPayouts(security).checkAndConsumeWithdraw(fundraiserId, msg.sender, requestedAmount);
    }

    /**
     * @notice Refund helper respecting Security payout schedule.
     * @dev Calls Security to enforce non-stacking tranches and returns how much can be refunded now.
     *      Does not forward to Core here to keep compatibility with MockCore; upstream can proceed with the returned amount.
     */
    function refundWithSchedule(uint256 fundraiserId, uint256 requestedAmount)
        external
        coreNotPaused
        nonReentrant
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining)
    {
        require(security != address(0), "Router: security not set");
        return ISecurityPayouts(security).checkAndConsumeRefund(fundraiserId, msg.sender, requestedAmount);
    }

    // [ADD] Creator wypłaca środki przez Router → Core.onlyRouter
    function withdrawFunds(uint256 fundraiserId)
        external
        coreNotPaused
        nonReentrant
    {
        coreContract.withdrawFundsFor(fundraiserId, msg.sender);
    }

    function claimRefund(uint256 fundraiserId)
        external
        coreNotPaused
        nonReentrant
    {
        coreContract.refundFor(fundraiserId, msg.sender);
    }

    function startRefundPeriod(uint256 fundraiserId)
        external
        onlyOwner
        coreNotPaused
        nonReentrant
    {
        coreContract.refund(fundraiserId);
    }
}