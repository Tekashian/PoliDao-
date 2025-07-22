// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IPoliDaoStructs.sol";
import "./interfaces/IPoliDaoRefunds.sol";
import "./interfaces/IPoliDaoSecurity.sol";

/**
 * @title PoliDao - GŁÓWNY KONTRAKT Z MODUŁEM SECURITY - POPRAWIONE EVENTY
 * @notice Podstawowy fundraising + delegacja do modułów + integracja Security
 * @dev Maksymalnie uproszczony - całą logikę refundów obsługuje moduł, security chroni system
 */
contract PoliDao is Ownable, Pausable, ReentrancyGuard, IPoliDaoStructs {
    
    // ========== CONSTANTS ========== 
    uint256 public constant MAX_DURATION = 365 days;
    uint256 public constant MAX_TITLE_LENGTH = 100;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 2000;
    uint256 private constant PRECISION = 10_000;
    uint256 private constant MAX_COMMISSION = 10_000;

    // ========== STORAGE ==========
    struct Fundraiser {
        PackedFundraiserData packed;
        address creator;
        address token;
        string title;
        string description;
        string location;
        mapping(address => uint256) donations;
        address[] donors;
    }

    uint256 public fundraiserCount;
    mapping(uint256 => Fundraiser) private fundraisers;
    
    // Token management
    mapping(address => bool) public isTokenWhitelisted;
    address[] public whitelistedTokens;
    
    // Commission system
    uint256 public donationCommission = 100;  // 1%
    uint256 public successCommission = 250;   // 2.5%
    address public commissionWallet;
    
    // Modules
    address public governanceModule;
    address public mediaModule;
    address public updatesModule;
    address public refundsModule;
    address public securityModule;

    // ========== MODIFIERS ==========
    modifier validFundraiserId(uint256 id) {
        require(id > 0 && id <= fundraiserCount, "Invalid fundraiser");
        _;
    }

    modifier onlyRefundsModule() {
        require(msg.sender == refundsModule, "Only refunds module");
        _;
    }

    // ========== SECURITY MODIFIERS ==========
    
    /**
     * @notice Główny modyfikator security sprawdzający wszystkie warunki bezpieczeństwa
     * @param functionName Nazwa funkcji dla rate limiting i circuit breaker
     */
    modifier securityCheck(string memory functionName) {
        if (securityModule != address(0)) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            
            // 1. Check emergency pause
            (bool isPaused, , , ) = security.getEmergencyPauseStatus();
            require(!isPaused, "System emergency paused");
            
            // 2. Check user suspension
            (bool isUserSuspended, , ) = security.isUserSuspended(msg.sender);
            require(!isUserSuspended, "User suspended");
            
            // 3. Check rate limiting - internal call w module
            (bool withinLimit, , ) = security.checkRateLimit(msg.sender, functionName);
            require(withinLimit, "Rate limit exceeded");
            
            // 4. Check security level for critical functions
            (IPoliDaoSecurity.SecurityLevel level, , ) = security.getSecurityLevel();
            if (keccak256(bytes(functionName)) == keccak256(bytes("withdrawFunds")) ||
                keccak256(bytes(functionName)) == keccak256(bytes("emergencyWithdraw"))) {
                require(level <= IPoliDaoSecurity.SecurityLevel.ELEVATED, "Security level too high for operation");
            }
        }
        _;
    }

    /**
     * @notice Sprawdza czy fundraiser nie jest zawieszony
     */
    modifier fundraiserSecurityCheck(uint256 fundraiserId) {
        if (securityModule != address(0)) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            (bool isSuspended, ) = security.isFundraiserSuspended(fundraiserId);
            require(!isSuspended, "Fundraiser suspended");
        }
        _;
    }

    /**
     * @notice Sprawdza czy token nie jest zawieszony
     */
    modifier tokenSecurityCheck(address token) {
        if (securityModule != address(0)) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            (bool isSuspended, ) = security.isTokenSuspended(token);
            require(!isSuspended, "Token suspended");
        }
        _;
    }

    /**
     * @notice Tylko dla security guardianów lub owner - używane w modifierach
     */
    modifier onlySecurityOrOwner() {
        bool isAuthorized = msg.sender == owner();
        
        if (securityModule != address(0) && !isAuthorized) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            (bool isGuardian, ) = security.isSecurityGuardian(msg.sender);
            isAuthorized = isGuardian;
        }
        
        require(isAuthorized, "Not authorized");
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(address _commissionWallet) Ownable(msg.sender) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
    }

    // ========== MODULE SETUP - POPRAWIONA WERSJA ==========
    function setModules(
        address _governance, 
        address _media, 
        address _updates, 
        address _refunds,
        address _security
    ) external onlyOwner {
        governanceModule = _governance;
        mediaModule = _media;
        updatesModule = _updates;
        refundsModule = _refunds;
        securityModule = _security;
        
        emit ModulesInitialized(_governance, _media, _updates, _refunds);
        emit SecurityModuleSet(address(0), _security);  // Event z IPoliDaoStructs
    }

    /**
     * @notice Ustawia tylko security module (dla flexibility)
     */
    function setSecurityModule(address _security) external onlyOwner {
        address oldModule = securityModule;
        securityModule = _security;
        emit SecurityModuleSet(oldModule, _security);  // Event z IPoliDaoStructs
    }

    // ========== PODSTAWOWY FUNDRAISING (z security) ==========
    
    function createFundraiser(FundraiserCreationData calldata data) 
        external 
        whenNotPaused 
        nonReentrant
        securityCheck("createFundraiser")
        tokenSecurityCheck(data.token)
        returns (uint256) 
    {
        require(bytes(data.title).length > 0 && bytes(data.title).length <= MAX_TITLE_LENGTH, "Invalid title");
        require(bytes(data.description).length > 0 && bytes(data.description).length <= MAX_DESCRIPTION_LENGTH, "Invalid description");
        require(data.endDate > block.timestamp && data.endDate <= block.timestamp + MAX_DURATION, "Invalid end date");
        require(isTokenWhitelisted[data.token], "Token not whitelisted");
        
        if (data.fundraiserType == FundraiserType.WITH_GOAL) {
            require(data.goalAmount > 0, "Goal required");
        }
        
        fundraiserCount++;
        uint256 id = fundraiserCount;
        
        Fundraiser storage f = fundraisers[id];
        f.packed = PackedFundraiserData({
            goalAmount: uint128(data.goalAmount),
            raisedAmount: 0,
            endDate: uint64(data.endDate),
            originalEndDate: uint64(data.endDate),
            id: uint32(id),
            suspensionTime: 0,
            extensionCount: 0,
            fundraiserType: uint8(data.fundraiserType),
            status: uint8(FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            isFlexible: data.isFlexible
        });
        
        f.creator = msg.sender;
        f.token = data.token;
        f.title = data.title;
        f.description = data.description;
        f.location = data.location;
        
        // Zarejestruj w module refunds
        if (refundsModule != address(0)) {
            IPoliDaoRefunds(refundsModule).registerFundraiser(id, data.isFlexible);
        }
        
        emit FundraiserCreated(id, msg.sender, data.token, data.title, uint8(data.fundraiserType), data.goalAmount, data.endDate, data.location);
        
        return id;
    }

    function donate(uint256 fundraiserId, uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant
        validFundraiserId(fundraiserId) 
        securityCheck("donate")
        fundraiserSecurityCheck(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(f.packed.status == uint8(FundraiserStatus.ACTIVE), "Not active");
        require(block.timestamp <= f.packed.endDate, "Ended");
        require(!f.packed.isSuspended, "Suspended");
        require(amount > 0, "Zero amount");
        
        // Additional token security check
        if (securityModule != address(0)) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            (bool isTokenSuspended, ) = security.isTokenSuspended(f.token);
            require(!isTokenSuspended, "Token suspended");
        }
        
        IERC20 token = IERC20(f.token);
        
        // Calculate commission
        uint256 commission = (amount * donationCommission) / PRECISION;
        uint256 netAmount = amount - commission;
        
        // Transfer tokens
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Send commission
        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission failed");
        }
        
        // Update donation tracking
        if (f.donations[msg.sender] == 0) {
            f.donors.push(msg.sender);
        }
        f.donations[msg.sender] += netAmount;
        f.packed.raisedAmount += uint128(netAmount);
        
        // Check if goal reached
        if (f.packed.fundraiserType == uint8(FundraiserType.WITH_GOAL) && 
            f.packed.raisedAmount >= f.packed.goalAmount) {
            f.packed.status = uint8(FundraiserStatus.SUCCESSFUL);
        }
        
        emit DonationMade(fundraiserId, msg.sender, f.token, amount, netAmount);
    }

    function withdrawFunds(uint256 fundraiserId) 
        external 
        whenNotPaused 
        nonReentrant
        validFundraiserId(fundraiserId) 
        securityCheck("withdrawFunds")
        fundraiserSecurityCheck(fundraiserId)
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        require(!f.packed.fundsWithdrawn, "Already withdrawn");
        require(f.packed.raisedAmount > 0, "No funds");
        
        // TYLKO dla zwykłych zbiórek - elastyczne obsługuje moduł refunds
        require(!f.packed.isFlexible, "Use refunds module for flexible");
        
        // Check withdrawal conditions
        bool canWithdraw = false;
        if (f.packed.fundraiserType == uint8(FundraiserType.WITHOUT_GOAL)) {
            canWithdraw = true;
        } else if (f.packed.status == uint8(FundraiserStatus.SUCCESSFUL)) {
            canWithdraw = true;
        }
        require(canWithdraw, "Cannot withdraw");
        
        uint256 amount = f.packed.raisedAmount;
        uint256 commission = (amount * successCommission) / PRECISION;
        uint256 netAmount = amount - commission;
        
        f.packed.fundsWithdrawn = true;
        f.packed.status = uint8(FundraiserStatus.COMPLETED);
        
        IERC20 token = IERC20(f.token);
        
        if (commission > 0) {
            require(token.transfer(commissionWallet, commission), "Commission failed");
        }
        require(token.transfer(f.creator, netAmount), "Withdrawal failed");
        
        emit FundsWithdrawn(fundraiserId, f.creator, netAmount);
    }

    // ========== REFUND FUNCTIONS - CZYSTE WRAPPER'Y (z security) ==========
    
    /**
     * @notice CZYSTA DELEGACJA - nie ma własnej logiki
     */
    function refund(uint256 fundraiserId) 
        external 
        nonReentrant
        securityCheck("refund")
        fundraiserSecurityCheck(fundraiserId)
    {
        require(refundsModule != address(0), "Refunds module not set");
        
        // Przekaż całkowicie do modułu
        bytes memory data = abi.encodeWithSignature("refund(uint256)", fundraiserId);
        (bool success, ) = refundsModule.delegatecall(data);
        require(success, "Refund delegate failed");
    }
    
    function initiateClosure(uint256 fundraiserId) 
        external 
        securityCheck("initiateClosure")
        fundraiserSecurityCheck(fundraiserId)
    {
        require(refundsModule != address(0), "Refunds module not set");
        
        bytes memory data = abi.encodeWithSignature("initiateClosure(uint256)", fundraiserId);
        (bool success, ) = refundsModule.delegatecall(data);
        require(success, "Closure delegate failed");
    }
    
    function canRefund(uint256 fundraiserId, address donor) external view returns (bool, string memory) {
        if (refundsModule == address(0)) {
            return (false, "Refunds module not set");
        }
        
        // Check fundraiser suspension
        if (securityModule != address(0)) {
            IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
            (bool isSuspended, ) = security.isFundraiserSuspended(fundraiserId);
            if (isSuspended) {
                return (false, "Fundraiser suspended");
            }
        }
        
        return IPoliDaoRefunds(refundsModule).canRefund(
            fundraiserId, donor, 0, 0, 0, false // Moduł sam pobierze dane
        );
    }

    function withdrawFlexibleFunds(uint256 fundraiserId) 
        external 
        securityCheck("withdrawFlexibleFunds")
        fundraiserSecurityCheck(fundraiserId)
    {
        require(refundsModule != address(0), "Refunds module not set");
        
        bytes memory data = abi.encodeWithSignature("withdrawFlexible(uint256)", fundraiserId);
        (bool success, ) = refundsModule.delegatecall(data);
        require(success, "Flexible withdrawal failed");
    }

    // ========== SECURITY DELEGATION - CZYSTE WRAPPER'Y ==========
    
    /**
     * @notice CZYSTA DELEGACJA do Security Module - suspendFundraiser
     */
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external {
        require(securityModule != address(0), "Security module not set");
        
        bytes memory data = abi.encodeWithSignature("suspendFundraiser(uint256,string)", fundraiserId, reason);
        (bool success, ) = securityModule.delegatecall(data);
        require(success, "Security delegate failed");
    }

    /**
     * @notice CZYSTA DELEGACJA do Security Module - unsuspendFundraiser
     */
    function unsuspendFundraiser(uint256 fundraiserId) external {
        require(securityModule != address(0), "Security module not set");
        
        bytes memory data = abi.encodeWithSignature("unsuspendFundraiser(uint256)", fundraiserId);
        (bool success, ) = securityModule.delegatecall(data);
        require(success, "Security delegate failed");
    }

    /**
     * @notice CZYSTA DELEGACJA do Security Module - activateEmergencyPause
     */
    function activateEmergencyPause(string calldata reason) external {
        require(securityModule != address(0), "Security module not set");
        
        bytes memory data = abi.encodeWithSignature("activateEmergencyPause(string)", reason);
        (bool success, ) = securityModule.delegatecall(data);
        require(success, "Security delegate failed");
    }

    /**
     * @notice CZYSTA DELEGACJA do Security Module - suspendUser
     */
    function suspendUser(address user, uint256 duration, string calldata reason) external {
        require(securityModule != address(0), "Security module not set");
        
        bytes memory data = abi.encodeWithSignature("suspendUser(address,uint256,string)", user, duration, reason);
        (bool success, ) = securityModule.delegatecall(data);
        require(success, "Security delegate failed");
    }

    /**
     * @notice CZYSTA DELEGACJA do Security Module - suspendToken
     */
    function suspendToken(address token, string calldata reason) external {
        require(securityModule != address(0), "Security module not set");
        
        bytes memory data = abi.encodeWithSignature("suspendToken(address,string)", token, reason);
        (bool success, ) = securityModule.delegatecall(data);
        require(success, "Security delegate failed");
    }

    /**
     * @notice VIEW ONLY - sprawdź status bezpieczeństwa przez Security Module
     */
    function getSecurityStatus() 
        external 
        view 
        returns (
            bool emergencyPaused,
            IPoliDaoSecurity.SecurityLevel securityLevel,
            bool userSuspended,
            string memory emergencyReason
        ) 
    {
        if (securityModule == address(0)) {
            return (false, IPoliDaoSecurity.SecurityLevel.NORMAL, false, "");
        }
        
        IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
        
        (emergencyPaused, , , emergencyReason) = security.getEmergencyPauseStatus();
        (securityLevel, , ) = security.getSecurityLevel();
        (userSuspended, , ) = security.isUserSuspended(msg.sender);
    }

    /**
     * @notice VIEW ONLY - sprawdź czy fundraiser jest zawieszony
     */
    function isFundraiserSuspended(uint256 fundraiserId) 
        external 
        view 
        returns (bool isSuspended, string memory reason) 
    {
        if (securityModule == address(0)) {
            return (false, "");
        }
        
        return IPoliDaoSecurity(securityModule).isFundraiserSuspended(fundraiserId);
    }

    // ========== FUNKCJE HELPER DLA MODUŁÓW ==========
    
    function getFundraiserData(uint256 fundraiserId) 
        external 
        view 
        validFundraiserId(fundraiserId) 
        returns (
            address creator,
            address token,
            uint256 raisedAmount,
            uint256 goalAmount,
            uint256 endDate,
            uint8 status,
            bool isFlexible
        ) 
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        return (
            f.creator,
            f.token,
            f.packed.raisedAmount,
            f.packed.goalAmount,
            f.packed.endDate,
            f.packed.status,
            f.packed.isFlexible
        );
    }

    function updateFundraiserState(
        uint256 fundraiserId, 
        uint256 newRaisedAmount, 
        uint8 newStatus
    ) 
        external 
        onlyRefundsModule 
        validFundraiserId(fundraiserId) 
    {
        fundraisers[fundraiserId].packed.raisedAmount = uint128(newRaisedAmount);
        fundraisers[fundraiserId].packed.status = newStatus;
    }

    function getDonationAmount(uint256 fundraiserId, address donor) 
        external 
        view 
        validFundraiserId(fundraiserId) 
        returns (uint256) 
    {
        return fundraisers[fundraiserId].donations[donor];
    }

    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) 
        external 
        onlyRefundsModule 
        validFundraiserId(fundraiserId) 
    {
        fundraisers[fundraiserId].donations[donor] = newAmount;
    }

    // ========== DELEGATION TO MODULES ==========
    
    function delegateToGovernance(bytes calldata data) external returns (bytes memory) {
        require(governanceModule != address(0), "Module not set");
        (bool success, bytes memory result) = governanceModule.delegatecall(data);
        require(success, "Delegate failed");
        return result;
    }
    
    function delegateToMedia(bytes calldata data) external returns (bytes memory) {
        require(mediaModule != address(0), "Module not set");
        (bool success, bytes memory result) = mediaModule.delegatecall(data);
        require(success, "Delegate failed");
        return result;
    }
    
    function delegateToUpdates(bytes calldata data) external returns (bytes memory) {
        require(updatesModule != address(0), "Module not set");
        (bool success, bytes memory result) = updatesModule.delegatecall(data);
        require(success, "Delegate failed");
        return result;
    }

    function delegateToRefunds(bytes calldata data) external returns (bytes memory) {
        require(refundsModule != address(0), "Module not set");
        (bool success, bytes memory result) = refundsModule.delegatecall(data);
        require(success, "Delegate failed");
        return result;
    }

    function delegateToSecurity(bytes calldata data) external onlySecurityOrOwner returns (bytes memory) {
        require(securityModule != address(0), "Module not set");
        (bool success, bytes memory result) = securityModule.delegatecall(data);
        require(success, "Delegate failed");
        return result;
    }

    // ========== TOKEN & COMMISSION MANAGEMENT (z security) ==========
    function whitelistToken(address token) 
        external 
        onlyOwner 
        tokenSecurityCheck(token)
    {
        require(token != address(0), "Invalid token");
        require(!isTokenWhitelisted[token], "Already whitelisted");
        
        isTokenWhitelisted[token] = true;
        whitelistedTokens.push(token);
        
        emit TokenWhitelisted(token);
    }

    function removeWhitelistToken(address token) external onlyOwner {
        require(isTokenWhitelisted[token], "Not whitelisted");
        
        isTokenWhitelisted[token] = false;
        
        for (uint256 i = 0; i < whitelistedTokens.length; i++) {
            if (whitelistedTokens[i] == token) {
                whitelistedTokens[i] = whitelistedTokens[whitelistedTokens.length - 1];
                whitelistedTokens.pop();
                break;
            }
        }
        
        emit TokenRemoved(token);
    }

    function setCommissions(uint256 _donation, uint256 _success) external onlyOwner {
        require(_donation <= MAX_COMMISSION && _success <= MAX_COMMISSION, "Too high");
        
        donationCommission = _donation;
        successCommission = _success;
        
        emit DonationCommissionSet(_donation);
        emit SuccessCommissionSet(_success);
    }

    function setCommissionWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0), "Invalid wallet");
        address oldWallet = commissionWallet;
        commissionWallet = newWallet;
        emit CommissionWalletChanged(oldWallet, newWallet);
    }

    // ========== VIEW FUNCTIONS ==========
    
    function getFundraiserBasicInfo(uint256 id) external view validFundraiserId(id) returns (
        string memory title,
        address creator,
        address token,
        uint256 raised,
        uint256 goal,
        uint256 endDate,
        uint8 status,
        bool isFlexible
    ) {
        Fundraiser storage f = fundraisers[id];
        return (
            f.title, 
            f.creator, 
            f.token, 
            f.packed.raisedAmount, 
            f.packed.goalAmount, 
            f.packed.endDate, 
            f.packed.status,
            f.packed.isFlexible
        );
    }
    
    function donationOf(uint256 fundraiserId, address donor) external view returns (uint256) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) return 0;
        return fundraisers[fundraiserId].donations[donor];
    }
    
    function getFundraiserCount() external view returns (uint256) {
        return fundraiserCount;
    }
    
    function getWhitelistedTokens() external view returns (address[] memory) {
        return whitelistedTokens;
    }
    
    function getFundraiserCreator(uint256 fundraiserId) external view returns (address) {
        if (fundraiserId == 0 || fundraiserId > fundraiserCount) return address(0);
        return fundraisers[fundraiserId].creator;
    }

    // ========== ADMIN FUNCTIONS (z security) ==========
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function emergencyWithdraw(address token, address to, uint256 amount) 
        external 
        onlyOwner 
        securityCheck("emergencyWithdraw")
    {
        require(to != address(0), "Invalid address");
        
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(to, amount), "Token transfer failed");
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }

    receive() external payable {}
}