// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoliDaoSecurity.sol";

/**
 * @title PoliDaoSecurity - POPRAWIONA WERSJA EVENTÓW
 * @notice Comprehensive security management module for PoliDAO
 * @dev Handles circuit breakers, emergency controls, suspensions, and security monitoring
 * @dev WSZYSTKIE EVENTY POCHODZĄ Z IPoliDaoStructs - USUNIĘTO DUPLIKATY
 */
contract PoliDaoSecurity is Ownable, Pausable, ReentrancyGuard, IPoliDaoSecurity {
    
    // ========== CONSTANTS ==========
    
    uint256 public constant MAX_SUSPENSION_DURATION = 365 days;
    uint256 public constant GUARDIAN_PERMISSIONS_EMERGENCY = 1;
    uint256 public constant GUARDIAN_PERMISSIONS_SUSPEND = 2;
    uint256 public constant GUARDIAN_PERMISSIONS_CIRCUIT = 4;
    uint256 public constant GUARDIAN_PERMISSIONS_ALL = 7;
    
    // ========== STORAGE ==========
    
    address public mainContract;
    
    // Security state
    SecurityLevel public currentSecurityLevel = SecurityLevel.NORMAL;
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
    
    modifier securityLevelCheck(SecurityLevel minLevel) {
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
    }
    
    // ========== EMERGENCY FUNCTIONS ==========
    
    function activateEmergencyPause(string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_EMERGENCY)
        nonReentrant
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
    
    function setSecurityLevel(SecurityLevel newLevel, string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_EMERGENCY)
    {
        SecurityLevel oldLevel = currentSecurityLevel;
        currentSecurityLevel = newLevel;
        securityLevelChangedAt = block.timestamp;
        securityLevelReason = reason;
        
        // Event z IPoliDaoStructs - używamy uint8 dla kompatybilności
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
    
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(!fundraiserSuspensions[fundraiserId].isSuspended, "Already suspended");
        
        fundraiserSuspensions[fundraiserId] = SuspensionInfo({
            isSuspended: true,
            suspendedAt: block.timestamp,
            suspensionEnd: 0, // Fundraiser suspensions are manual
            reason: reason,
            suspendedBy: msg.sender
        });
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit FundraiserSuspended(fundraiserId, msg.sender, reason, block.timestamp);
    }
    
    function unsuspendFundraiser(uint256 fundraiserId) 
        external 
        onlyGuardianOrOwner(GUARDIAN_PERMISSIONS_SUSPEND)
        nonReentrant
    {
        require(fundraiserSuspensions[fundraiserId].isSuspended, "Not suspended");
        
        delete fundraiserSuspensions[fundraiserId];
        
        // Event z IPoliDaoStructs - BEZ DUPLIKACJI
        emit FundraiserUnsuspended(fundraiserId, msg.sender, block.timestamp);
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
    {
        require(maxCalls > 0, "Invalid max calls");
        require(windowSize > 0, "Invalid window size");
        
        rateLimitConfigs[functionName] = RateLimitConfig(maxCalls, windowSize);
    }
    
    function _checkCircuitBreaker(string memory functionName, uint256 gasUsed) internal {
        uint256 threshold = gasThresholds[functionName];
        if (threshold > 0 && gasUsed > threshold) {
            // Event z IPoliDaoStructs - BEZ DUPLIKACJI
            emit CircuitBreakerTriggered(functionName, msg.sender, gasUsed, threshold, block.timestamp);
            
            // Auto-elevate security level on repeated breaches
            if (currentSecurityLevel == SecurityLevel.NORMAL) {
                currentSecurityLevel = SecurityLevel.ELEVATED;
                emit SecurityLevelChanged(uint8(SecurityLevel.NORMAL), uint8(SecurityLevel.ELEVATED), address(this), "Circuit breaker triggered");
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
        returns (SecurityLevel level, uint256 lastChanged, string memory reason) 
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
        mainContract = _newMainContract;
    }
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    // ========== UTILITY FUNCTIONS ==========
    
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
            (bool isSuspended, , ) = this.isUserSuspended(users[i]);
            suspended[i] = isSuspended;
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
            SecurityLevel currentLevel
        ) 
    {
        totalGuardians = guardiansList.length;
        currentLevel = currentSecurityLevel;
        
        // Note: For gas efficiency, we don't count suspended items here
        // This would require iterating through all items
        suspendedUsers = 0;
        suspendedFundraisers = 0;
        suspendedTokens = 0;
    }
}