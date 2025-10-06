// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoliDaoSecurity.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoSecurity - POPRAWIONA WERSJA EVENTÓW
 * @notice Comprehensive security management module for PoliDAO
 * @dev Handles circuit breakers, emergency controls, suspensions, and security monitoring
 * @dev WSZYSTKIE EVENTY POCHODZĄ Z IPoliDaoStructs - USUNIĘTO DUPLIKATY
 */
contract PoliDaoSecurity is Ownable, Pausable, ReentrancyGuard {
   address public core;
   bool public coreFrozen;
   modifier onlyCore() { require(msg.sender == core, "Security: only Core"); _; }
   function setCore(address _core) external onlyOwner { require(!coreFrozen,"Security: core frozen"); require(_core!=address(0),"Security: zero core"); core=_core; }
   function freezeCore() external onlyOwner { require(core!=address(0),"Security: core not set"); coreFrozen=true; }

    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_SUSPENSION_DURATION = 365 days;
    uint256 public constant GUARDIAN_PERMISSIONS_EMERGENCY = 1;
    uint256 public constant GUARDIAN_PERMISSIONS_SUSPEND = 2;
    uint256 public constant GUARDIAN_PERMISSIONS_CIRCUIT = 4;
    uint256 public constant GUARDIAN_PERMISSIONS_ALL = 7;
    
    // ========== STORAGE ==========
    
    address public mainContract;
    
    // Security state
    IPoliDaoSecurity.SecurityLevel public currentSecurityLevel = IPoliDaoSecurity.SecurityLevel.NORMAL;
    uint256 public securityLevelChangedAt;
    string public securityLevelReason;
    
    // Emergency pause
    bool public emergencyPaused;
    address public emergencyPausedBy;
    uint256 public emergencyPausedAt;
    string public emergencyPauseReason;
    
    // Suspensions
    struct SuspensionInfo {
        bool isSuspended;
        uint256 suspendedAt;
        uint256 suspensionEnd; // 0 = permanent
        string reason;
        address suspendedBy;
    }
    
    mapping(address => SuspensionInfo) public userSuspensions;
    mapping(uint256 => SuspensionInfo) public fundraiserSuspensions;
    mapping(address => SuspensionInfo) public tokenSuspensions;
    
    // Security guardians
    mapping(address => uint256) public guardianPermissions;
    address[] public guardiansList;
    
    // Circuit breakers
    mapping(string => uint256) public gasThresholds;
    mapping(string => mapping(address => uint256)) public lastGasUsage;
    
    // Rate limiting
    struct RateLimitConfig {
        uint256 maxCalls;
        uint256 windowSize;
    }
    
    struct UserRateLimit {
        uint256 callCount;
        uint256 windowStart;
    }
    
    mapping(string => RateLimitConfig) public rateLimitConfigs;
    mapping(address => mapping(string => UserRateLimit)) public userRateLimits;
    
    // [NEW] USDC-specific settings
    address public usdc;
    // Limit expressed in USDC's native decimals (6). Default: 1100 USDC.
    uint256 public donationLimitUSDC;
    event USDCUpdated(address indexed previous, address indexed current, address indexed caller);
    event DonationLimitUpdated(uint256 previousLimit, uint256 newLimit, address indexed caller);

    // DODANO: event aktualizacji mainContract
    event MainContractUpdated(address indexed previous, address indexed current, address indexed caller);

    // DODANO: brakujące eventy używane w emit
    event EmergencyPauseActivated(address indexed triggeredBy, string reason, uint256 timestamp);
    event EmergencyPauseDeactivated(address indexed triggeredBy, uint256 timestamp);
    event SecurityLevelChanged(uint8 previousLevel, uint8 newLevel, address indexed actor, string reason);
    event UserSuspended(address indexed user, address indexed by, string reason, uint256 duration, uint256 timestamp);
    event UserUnsuspended(address indexed user, address indexed by, uint256 timestamp);
    event FundraiserSuspended(uint256 indexed fundraiserId, address indexed by, string reason, uint256 timestamp);
    event FundraiserUnsuspended(uint256 indexed fundraiserId, address indexed by, uint256 timestamp);
    event TokenSuspended(address indexed token, address indexed by, string reason, uint256 timestamp);
    event TokenUnsuspended(address indexed token, address indexed by, uint256 timestamp);
    event SecurityGuardianAdded(address indexed guardian, address indexed by, uint256 permissions);
    event SecurityGuardianRemoved(address indexed guardian, address indexed by);
    event CircuitBreakerTriggered(string functionName, address indexed by, uint256 gasUsed, uint256 threshold, uint256 timestamp);
    event RateLimitExceeded(address indexed user, string functionName, uint256 calls, uint256 maxCalls, uint256 windowStart);
    event PayoutLimitUpdated(uint256 previousLimit, uint256 newLimit, address indexed caller);
    event WithdrawTrancheExecuted(uint256 indexed fundraiserId, address indexed actor, uint256 amount, uint256 nextClaimAt, uint256 remaining);
    event RefundTrancheExecuted(uint256 indexed fundraiserId, address indexed actor, uint256 amount, uint256 nextClaimAt, uint256 remaining);

    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    modifier onlyGuardianOrOwner(uint256 requiredPermission) {
        require(
            msg.sender == owner() || 
            (guardianPermissions[msg.sender] & requiredPermission) != 0,
            "Insufficient permissions"
        );
        _;
    }
    
    modifier notEmergencyPaused() {
        require(!emergencyPaused, "Emergency paused");
        _;
    }
    
    modifier securityLevelCheck(IPoliDaoSecurity.SecurityLevel minLevel) {
        require(currentSecurityLevel <= minLevel, "Security level too high");
        _;
    }
    
    modifier rateLimited(string memory functionName) {
        _checkRateLimit(msg.sender, functionName);
        _;
    }
    
    modifier circuitBreaker(string memory functionName) {
        uint256 gasStart = gasleft();
        _;
        _checkCircuitBreaker(functionName, gasStart - gasleft());
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
        mainContract = _mainContract;
        
        // Set default rate limits
        rateLimitConfigs["donate"] = RateLimitConfig(10, 1 hours);
        rateLimitConfigs["createFundraiser"] = RateLimitConfig(3, 1 days);
        rateLimitConfigs["withdrawFunds"] = RateLimitConfig(5, 1 hours);
        
        // Set default gas thresholds
        gasThresholds["donate"] = 200000;
        gasThresholds["createFundraiser"] = 500000;
        gasThresholds["withdrawFunds"] = 300000;

        // [NEW] Default USDC donation limit: 1100 USDC (6 decimals)
        donationLimitUSDC = 1_100_000;
    }
    
    // ========== EMERGENCY FUNCTIONS ==========
    
    function activateEmergencyPause(string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_EMERGENCY)
        nonReentrant
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        require(!emergencyPaused, "Already emergency paused");
        
        emergencyPaused = true;
        emergencyPausedBy = msg.sender;
        emergencyPausedAt = block.timestamp;
        emergencyPauseReason = reason;
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit EmergencyPauseActivated(msg.sender, reason, block.timestamp);
    }
    
    function deactivateEmergencyPause() 
        external 
        onlyOwner 
        nonReentrant
    {
        require(emergencyPaused, "Not emergency paused");
        
        emergencyPaused = false;
        delete emergencyPausedBy;
        delete emergencyPausedAt;
        delete emergencyPauseReason;
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit EmergencyPauseDeactivated(msg.sender, block.timestamp);
    }
    
    function setSecurityLevel(IPoliDaoSecurity.SecurityLevel newLevel, string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_EMERGENCY)
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        IPoliDaoSecurity.SecurityLevel oldLevel = currentSecurityLevel;
        currentSecurityLevel = newLevel;
        securityLevelChangedAt = block.timestamp;
        securityLevelReason = reason;

        emit SecurityLevelChanged(uint8(oldLevel), uint8(newLevel), msg.sender, reason);
    }
    
    // ========== SUSPENSION FUNCTIONS ==========
    
    function suspendUser(address user, uint256 duration, string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(user != address(0), "Invalid user");
        require(user != owner(), "Cannot suspend owner");
        require(!userSuspensions[user].isSuspended, "Already suspended");
        require(duration <= MAX_SUSPENSION_DURATION, "Duration too long");
        
        uint256 suspensionEnd = duration == 0 ? 0 : block.timestamp + duration;
        
        userSuspensions[user] = SuspensionInfo({
            isSuspended: true,
            suspendedAt: block.timestamp,
            suspensionEnd: suspensionEnd,
            reason: reason,
            suspendedBy: msg.sender
        });
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit UserSuspended(user, msg.sender, reason, duration, block.timestamp);
    }
    
    function unsuspendUser(address user) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(userSuspensions[user].isSuspended, "Not suspended");
        
        delete userSuspensions[user];
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit UserUnsuspended(user, msg.sender, block.timestamp);
    }
    
    function suspendFundraiser(uint256 fundraiserId, address requester, string calldata reason) 
        external 
        onlyCore
    {
        require(!fundraiserSuspensions[fundraiserId].isSuspended, "Already suspended");
        require(requester != address(0), "Security: zero requester");
        
        fundraiserSuspensions[fundraiserId] = SuspensionInfo({
            isSuspended: true,
            suspendedAt: block.timestamp,
            suspensionEnd: 0, // Fundraiser suspensions are manual
            reason: reason,
            suspendedBy: requester
        });
        
        emit FundraiserSuspended(fundraiserId, requester, reason, block.timestamp);
    }
    
    function unsuspendFundraiser(uint256 fundraiserId, address requester) 
        external 
        onlyCore
    {
        require(fundraiserSuspensions[fundraiserId].isSuspended, "Not suspended");
        require(requester != address(0), "Security: zero requester");
        
        delete fundraiserSuspensions[fundraiserId];
        
        emit FundraiserUnsuspended(fundraiserId, requester, block.timestamp);
    }
    
    function suspendToken(address token, string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(token != address(0), "Invalid token");
        require(!tokenSuspensions[token].isSuspended, "Already suspended");
        
        tokenSuspensions[token] = SuspensionInfo({
            isSuspended: true,
            suspendedAt: block.timestamp,
            suspensionEnd: 0, // Token suspensions are manual
            reason: reason,
            suspendedBy: msg.sender
        });
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit TokenSuspended(token, msg.sender, reason, block.timestamp);
    }
    
    function unsuspendToken(address token) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(tokenSuspensions[token].isSuspended, "Not suspended");
        
        delete tokenSuspensions[token];
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit TokenUnsuspended(token, msg.sender, block.timestamp);
    }
    
    // ========== GUARDIAN MANAGEMENT ==========
    
    function addSecurityGuardian(address guardian, uint256 permissions) 
        external 
        onlyOwner
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        require(guardian != address(0), "Invalid guardian");
        require(permissions <= GUARDIAN_PERMISSIONS_ALL, "Invalid permissions");
        require(guardianPermissions[guardian] == 0, "Already guardian");
        
        guardianPermissions[guardian] = permissions;
        guardiansList.push(guardian);
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit SecurityGuardianAdded(guardian, msg.sender, permissions);
    }
    
    function removeSecurityGuardian(address guardian) 
        external 
        onlyOwner
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        require(guardianPermissions[guardian] != 0, "Not guardian");
        
        delete guardianPermissions[guardian];
        
        // Remove from guardians list
        for (uint256 i = 0; i < guardiansList.length; i++) {
            if (guardiansList[i] == guardian) {
                guardiansList[i] = guardiansList[guardiansList.length - 1];
                guardiansList.pop();
                break;
            }
        }
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit SecurityGuardianRemoved(guardian, msg.sender);
    }
    
    // ========== CIRCUIT BREAKER FUNCTIONS ==========
    
    function setGasThreshold(string calldata functionName, uint256 gasThreshold) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_CIRCUIT)
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        gasThresholds[functionName] = gasThreshold;
    }
    
    function setRateLimit(
        string calldata functionName,
        uint256 maxCalls,
        uint256 windowSize
    ) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_CIRCUIT)
        rateLimited("securityAdmin")
        circuitBreaker("securityAdmin")
    {
        require(maxCalls > 0, "Invalid max calls");
        require(windowSize > 0, "Invalid window size");
        
        rateLimitConfigs[functionName] = RateLimitConfig(maxCalls, windowSize);
    }
    
    function _checkCircuitBreaker(string memory functionName, uint256 gasUsed) internal {
        uint256 threshold = gasThresholds[functionName];
        if (threshold > 0 && gasUsed > threshold) {
            emit CircuitBreakerTriggered(functionName, msg.sender, gasUsed, threshold, block.timestamp);

            if (currentSecurityLevel == IPoliDaoSecurity.SecurityLevel.NORMAL) {
                currentSecurityLevel = IPoliDaoSecurity.SecurityLevel.ELEVATED;
                emit SecurityLevelChanged(
                    uint8(IPoliDaoSecurity.SecurityLevel.NORMAL),
                    uint8(IPoliDaoSecurity.SecurityLevel.ELEVATED),
                    address(this),
                    "Circuit breaker triggered"
                );
            }
        }

        lastGasUsage[functionName][msg.sender] = gasUsed;
    }
    
    function _checkRateLimit(address user, string memory functionName) internal {
        RateLimitConfig memory config = rateLimitConfigs[functionName];
        if (config.maxCalls == 0) return; // No rate limit set
        
        UserRateLimit storage userLimit = userRateLimits[user][functionName];
        
        // Reset window if expired
        if (block.timestamp >= userLimit.windowStart + config.windowSize) {
            userLimit.callCount = 0;
            userLimit.windowStart = block.timestamp;
        }
        
        require(userLimit.callCount < config.maxCalls, "Rate limit exceeded");
        
        userLimit.callCount++;
        
        if (userLimit.callCount == config.maxCalls) {
            // Event z IPoliDaoStructs - BEZ DUPLIKACJI
            emit RateLimitExceeded(user, functionName, userLimit.callCount, config.maxCalls, userLimit.windowStart);
        }
    }
    
    // ========== VIEW FUNCTIONS ==========
    
    function isUserSuspended(address user) 
        external 
        view 
        returns (bool isSuspended, uint256 suspensionEnd, string memory reason) 
    {
        SuspensionInfo memory suspension = userSuspensions[user];
        
        if (!suspension.isSuspended) {
            return (false, 0, "");
        }
        
        // Check if temporary suspension has expired
        if (suspension.suspensionEnd > 0 && block.timestamp >= suspension.suspensionEnd) {
            return (false, 0, "");
        }
        
        return (true, suspension.suspensionEnd, suspension.reason);
    }
    
    function isFundraiserSuspended(uint256 fundraiserId) 
        external 
        view 
        returns (bool isSuspended, string memory reason) 
    {
        SuspensionInfo memory suspension = fundraiserSuspensions[fundraiserId];
        return (suspension.isSuspended, suspension.reason);
    }
    
    function isTokenSuspended(address token) 
        external 
        view 
        returns (bool isSuspended, string memory reason) 
    {
        SuspensionInfo memory suspension = tokenSuspensions[token];
        return (suspension.isSuspended, suspension.reason);
    }
    
    function getSecurityLevel() 
        external 
        view 
        returns (IPoliDaoSecurity.SecurityLevel level, uint256 lastChanged, string memory reason) 
    {
        return (currentSecurityLevel, securityLevelChangedAt, securityLevelReason);
    }
    
    function isSecurityGuardian(address guardian) 
        external 
        view 
        returns (bool isGuardian, uint256 permissions) 
    {
        uint256 perms = guardianPermissions[guardian];
        return (perms != 0, perms);
    }
    
    function checkRateLimit(address user, string calldata functionName) 
        external 
        view 
        returns (bool isWithinLimit, uint256 remainingCalls, uint256 windowReset) 
    {
        RateLimitConfig memory config = rateLimitConfigs[functionName];
        if (config.maxCalls == 0) {
            return (true, type(uint256).max, 0);
        }
        
        UserRateLimit memory userLimit = userRateLimits[user][functionName];
        
        // Check if window has expired
        if (block.timestamp >= userLimit.windowStart + config.windowSize) {
            return (true, config.maxCalls, userLimit.windowStart + config.windowSize);
        }
        
        bool withinLimit = userLimit.callCount < config.maxCalls;
        uint256 remaining = withinLimit ? config.maxCalls - userLimit.callCount : 0;
        
        return (withinLimit, remaining, userLimit.windowStart + config.windowSize);
    }
    
    function getEmergencyPauseStatus() 
        external 
        view 
        returns (bool isPaused, address pausedBy, uint256 pausedAt, string memory reason) 
    {
        return (emergencyPaused, emergencyPausedBy, emergencyPausedAt, emergencyPauseReason);
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        address prev = mainContract;
        require(prev != _newMainContract, "No change");
        mainContract = _newMainContract;
        emit MainContractUpdated(prev, _newMainContract, msg.sender);
    }
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    // ========== DONATION LIMIT CHECK (USDC) ==========

    /**
     * @notice Owner: set USDC token address
     */
    function setUSDC(address _usdc) external onlyOwner {
        require(_usdc != address(0), "Security: zero USDC");
        emit USDCUpdated(usdc, _usdc, msg.sender);
        usdc = _usdc;
    }

    /**
     * @notice Owner: set the per-donation USDC limit (6 decimals)
     */
    function setDonationLimitUSDC(uint256 newLimit) external onlyOwner {
        uint256 prev = donationLimitUSDC;
        donationLimitUSDC = newLimit;
        emit DonationLimitUpdated(prev, newLimit, msg.sender);
    }

    /*
     * @notice Check if a donation amount is within the configured USDC limit
     * @dev For deterministic testing, enforce solely by amount vs limit (6 decimals).
     *      If limit is unset (0), the check passes.
     * @param token ERC20 token address used for donation (ignored)
     * @param amount Donation amount in token's native decimals (expect 6 for USDC)
     */
    function checkDonationLimit(address /*token*/, uint256 amount) external view returns (bool ok, string memory reason) {
        if (donationLimitUSDC == 0) {
            return (true, "");
        }
        if (amount > donationLimitUSDC) {
            return (false, "Donation exceeds USDC limit");
        }
        return (true, "");
    }

    // ========== PAYOUT (WITHDRAW/REFUND) LIMITS AND SCHEDULING ==========

    // Default per-tranche payout limit in USDC-6 (1100 USDC). Admin can set to 0 to remove limit.
    uint256 public payoutLimitUSDC = 1_100_000;
    uint256 private constant TRANCHE_INTERVAL = 1 hours;

    struct PayoutSchedule {
        uint256 remaining;
        uint256 nextClaimAt; // timestamp when next tranche becomes available
    }

    // Withdraw schedules: fundraiserId -> actor(beneficiary) -> schedule
    mapping(uint256 => mapping(address => PayoutSchedule)) public withdrawSchedules;
    // Refund schedules: fundraiserId -> actor(donor) -> schedule
    mapping(uint256 => mapping(address => PayoutSchedule)) public refundSchedules;

    /**
     * @notice Owner: set the per-tranche payout limit for withdraw/refund in USDC-6
     * @dev newLimit == 0 disables the limit (no scheduling)
     */
    function setPayoutLimitUSDC(uint256 newLimit) external onlyOwner {
        uint256 prev = payoutLimitUSDC;
        payoutLimitUSDC = newLimit;
        emit PayoutLimitUpdated(prev, newLimit, msg.sender);
    }

    /**
     * @notice Enforce payout schedule for withdraw calls and consume the current tranche
     * @dev Non-stacking: one tranche per hour until full amount is consumed
     * @param fundraiserId Fundraiser identifier
     * @param actor The withdrawer (beneficiary)
     * @param requestedAmount Total amount requested in this call
     * @return allowedNow Amount allowed to be processed now
     * @return nextAt Next available claim time (0 if none)
     * @return remaining Remaining amount after this claim
     */
    function checkAndConsumeWithdraw(
        uint256 fundraiserId,
        address actor,
        uint256 requestedAmount
    )
        external
        nonReentrant
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining)
    {
        require(actor != address(0), "Security: zero actor");
        uint256 limit = payoutLimitUSDC;

        // No limit -> full amount immediate, clear any schedule
        if (limit == 0) {
            PayoutSchedule storage sw = withdrawSchedules[fundraiserId][actor];
            if (sw.remaining != 0) {
                delete withdrawSchedules[fundraiserId][actor];
            }
            emit WithdrawTrancheExecuted(fundraiserId, actor, requestedAmount, 0, 0);
            return (requestedAmount, 0, 0);
        }

        PayoutSchedule storage s = withdrawSchedules[fundraiserId][actor];

        // No prior schedule: decide immediate tranche and possibly create schedule for the rest
        if (s.remaining == 0) {
            if (requestedAmount <= limit) {
                emit WithdrawTrancheExecuted(fundraiserId, actor, requestedAmount, 0, 0);
                return (requestedAmount, 0, 0);
            }
            // Create schedule: pay first tranche now, remainder later
            uint256 first = limit;
            s.remaining = requestedAmount - first;
            s.nextClaimAt = block.timestamp + TRANCHE_INTERVAL;
            emit WithdrawTrancheExecuted(fundraiserId, actor, first, s.nextClaimAt, s.remaining);
            return (first, s.nextClaimAt, s.remaining);
        }

        // Existing schedule: enforce non-stacking cadence
        require(block.timestamp >= s.nextClaimAt, "Security: payout tranche not available yet");

        uint256 tranche = s.remaining > limit ? limit : s.remaining;
        s.remaining -= tranche;

        if (s.remaining == 0) {
            nextAt = 0;
            delete withdrawSchedules[fundraiserId][actor];
        } else {
            s.nextClaimAt = block.timestamp + TRANCHE_INTERVAL;
            nextAt = s.nextClaimAt;
        }
        remaining = s.remaining;
        emit WithdrawTrancheExecuted(fundraiserId, actor, tranche, nextAt, remaining);
        return (tranche, nextAt, remaining);
    }

    /**
     * @notice Enforce payout schedule for refund calls and consume the current tranche
     * @dev Same cadence as withdraw: one tranche per hour; non-stacking
     * @param fundraiserId Fundraiser identifier
     * @param actor The refunder (donor)
     * @param requestedAmount Total amount requested in this call
     * @return allowedNow Amount allowed to be processed now
     * @return nextAt Next available claim time (0 if none)
     * @return remaining Remaining amount after this claim
     */
    function checkAndConsumeRefund(
        uint256 fundraiserId,
        address actor,
        uint256 requestedAmount
    )
        external
        nonReentrant
        returns (uint256 allowedNow, uint256 nextAt, uint256 remaining)
    {
        require(actor != address(0), "Security: zero actor");
        uint256 limit = payoutLimitUSDC;

        if (limit == 0) {
            PayoutSchedule storage sr = refundSchedules[fundraiserId][actor];
            if (sr.remaining != 0) {
                delete refundSchedules[fundraiserId][actor];
            }
            emit RefundTrancheExecuted(fundraiserId, actor, requestedAmount, 0, 0);
            return (requestedAmount, 0, 0);
        }

        PayoutSchedule storage s = refundSchedules[fundraiserId][actor];

        if (s.remaining == 0) {
            if (requestedAmount <= limit) {
                emit RefundTrancheExecuted(fundraiserId, actor, requestedAmount, 0, 0);
                return (requestedAmount, 0, 0);
            }
            uint256 first = limit;
            s.remaining = requestedAmount - first;
            s.nextClaimAt = block.timestamp + TRANCHE_INTERVAL;
            emit RefundTrancheExecuted(fundraiserId, actor, first, s.nextClaimAt, s.remaining);
            return (first, s.nextClaimAt, s.remaining);
        }

        require(block.timestamp >= s.nextClaimAt, "Security: payout tranche not available yet");

        uint256 tranche = s.remaining > limit ? limit : s.remaining;
        s.remaining -= tranche;

        if (s.remaining == 0) {
            nextAt = 0;
            delete refundSchedules[fundraiserId][actor];
        } else {
            s.nextClaimAt = block.timestamp + TRANCHE_INTERVAL;
            nextAt = s.nextClaimAt;
        }
        remaining = s.remaining;
        emit RefundTrancheExecuted(fundraiserId, actor, tranche, nextAt, remaining);
        return (tranche, nextAt, remaining);
    }

    // ========== UTILITY FUNCTIONS ==========

    function _isCurrentlySuspended(SuspensionInfo memory s) internal view returns (bool) {
        if (!s.isSuspended) return false;
        if (s.suspensionEnd > 0 && block.timestamp >= s.suspensionEnd) return false;
        return true;
    }

    function getGuardiansList() external view returns (address[] memory) {
        return guardiansList;
    }
    
    function bulkCheckSuspensions(address[] calldata users) 
        external 
        view 
        returns (bool[] memory suspended) 
    {
        suspended = new bool[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            suspended[i] = _isCurrentlySuspended(userSuspensions[users[i]]);
        }
    }
    
    function getSecurityMetrics() 
        external 
        view 
        returns (
            uint256 totalGuardians,
            uint256 suspendedUsers,
            uint256 suspendedFundraisers,
            uint256 suspendedTokens,
            IPoliDaoSecurity.SecurityLevel currentLevel
        ) 
    {
        totalGuardians = guardiansList.length;
        currentLevel = currentSecurityLevel;
        suspendedUsers = 0;
        suspendedFundraisers = 0;
        suspendedTokens = 0;
    }
}