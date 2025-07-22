// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoSecurity - POPRAWIONA WERSJA
 * @notice Interface for PoliDAO security management module
 * @dev Defines all security-related functions including circuit breakers, emergency controls, and admin suspension
 */
interface IPoliDaoSecurity is IPoliDaoStructs {
    
    // ========== ENUMS ==========
    
    enum SecurityLevel {
        NORMAL,      // Normal operations
        ELEVATED,    // Enhanced monitoring
        CRITICAL,    // Limited operations
        EMERGENCY    // Emergency mode - most functions disabled
    }
    
    enum SuspensionType {
        USER_SUSPENSION,
        FUNDRAISER_SUSPENSION,
        TOKEN_SUSPENSION,
        GLOBAL_SUSPENSION
    }
    
    // ========== EVENTS - USUNIĘTO DUPLIKATY ==========
    // Wszystkie security eventy są już zdefiniowane w IPoliDaoStructs
    
    event SuspiciousActivityDetected(
        address indexed user,
        string activityType,
        uint256 severity,
        bytes32 indexed alertId
    );
    
    // ========== CORE SECURITY FUNCTIONS ==========
    
    /**
     * @notice Activate emergency pause
     * @param reason Reason for emergency pause
     */
    function activateEmergencyPause(string calldata reason) external;
    
    /**
     * @notice Deactivate emergency pause
     */
    function deactivateEmergencyPause() external;
    
    /**
     * @notice Change security level
     * @param newLevel New security level
     * @param reason Reason for change
     */
    function setSecurityLevel(SecurityLevel newLevel, string calldata reason) external;
    
    /**
     * @notice Suspend user temporarily or permanently
     * @param user User address to suspend
     * @param duration Duration in seconds (0 = permanent)
     * @param reason Reason for suspension
     */
    function suspendUser(address user, uint256 duration, string calldata reason) external;
    
    /**
     * @notice Unsuspend user
     * @param user User address to unsuspend
     */
    function unsuspendUser(address user) external;
    
    /**
     * @notice Suspend fundraiser
     * @param fundraiserId Fundraiser ID to suspend
     * @param reason Reason for suspension
     */
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external;
    
    /**
     * @notice Unsuspend fundraiser
     * @param fundraiserId Fundraiser ID to unsuspend
     */
    function unsuspendFundraiser(uint256 fundraiserId) external;
    
    /**
     * @notice Suspend token operations
     * @param token Token address to suspend
     * @param reason Reason for suspension
     */
    function suspendToken(address token, string calldata reason) external;
    
    /**
     * @notice Unsuspend token operations
     * @param token Token address to unsuspend
     */
    function unsuspendToken(address token) external;
    
    // ========== GUARDIAN MANAGEMENT ==========
    
    /**
     * @notice Add security guardian
     * @param guardian Guardian address
     * @param permissions Permission level
     */
    function addSecurityGuardian(address guardian, uint256 permissions) external;
    
    /**
     * @notice Remove security guardian
     * @param guardian Guardian address
     */
    function removeSecurityGuardian(address guardian) external;
    
    // ========== CIRCUIT BREAKER FUNCTIONS ==========
    
    /**
     * @notice Set gas limit threshold for circuit breaker
     * @param functionName Function name
     * @param gasThreshold Gas threshold
     */
    function setGasThreshold(string calldata functionName, uint256 gasThreshold) external;
    
    /**
     * @notice Set rate limit for function calls
     * @param functionName Function name
     * @param maxCalls Maximum calls per window
     * @param windowSize Window size in seconds
     */
    function setRateLimit(
        string calldata functionName,
        uint256 maxCalls,
        uint256 windowSize
    ) external;
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Check if user is suspended
     * @param user User address
     * @return isSuspended Whether user is suspended
     * @return suspensionEnd When suspension ends (0 if permanent)
     * @return reason Suspension reason
     */
    function isUserSuspended(address user) 
        external 
        view 
        returns (bool isSuspended, uint256 suspensionEnd, string memory reason);
    
    /**
     * @notice Check if fundraiser is suspended
     * @param fundraiserId Fundraiser ID
     * @return isSuspended Whether fundraiser is suspended
     * @return reason Suspension reason
     */
    function isFundraiserSuspended(uint256 fundraiserId) 
        external 
        view 
        returns (bool isSuspended, string memory reason);
    
    /**
     * @notice Check if token is suspended
     * @param token Token address
     * @return isSuspended Whether token is suspended
     * @return reason Suspension reason
     */
    function isTokenSuspended(address token) 
        external 
        view 
        returns (bool isSuspended, string memory reason);
    
    /**
     * @notice Get current security level
     * @return level Current security level
     * @return lastChanged When level was last changed
     * @return reason Reason for current level
     */
    function getSecurityLevel() 
        external 
        view 
        returns (SecurityLevel level, uint256 lastChanged, string memory reason);
    
    /**
     * @notice Check if address is security guardian
     * @param guardian Address to check
     * @return isGuardian Whether address is guardian
     * @return permissions Permission level
     */
    function isSecurityGuardian(address guardian) 
        external 
        view 
        returns (bool isGuardian, uint256 permissions);
    
    /**
     * @notice Check rate limit status
     * @param user User address
     * @param functionName Function name
     * @return isWithinLimit Whether user is within rate limit
     * @return remainingCalls Remaining calls in current window
     * @return windowReset When current window resets
     */
    function checkRateLimit(address user, string calldata functionName) 
        external 
        view 
        returns (bool isWithinLimit, uint256 remainingCalls, uint256 windowReset);
    
    /**
     * @notice Get emergency pause status
     * @return isPaused Whether emergency pause is active
     * @return pausedBy Who activated the pause
     * @return pausedAt When pause was activated
     * @return reason Reason for pause
     */
    function getEmergencyPauseStatus() 
        external 
        view 
        returns (bool isPaused, address pausedBy, uint256 pausedAt, string memory reason);
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
    /**
     * @notice Pause the security module
     */
    function pause() external;
    
    /**
     * @notice Unpause the security module
     */
    function unpause() external;
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
}