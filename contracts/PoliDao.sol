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
 * @title PoliDao - CORE CONTRACT OPTIMIZED FOR SIZE
 * @notice Core fundraising functionality with module delegation
 * @dev Size-optimized version with minimal wrapper functions
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
    
    // Modules - packed into single mapping for gas optimization
    mapping(bytes32 => address) public modules;
    
    // Module keys
    bytes32 public constant GOVERNANCE_MODULE = keccak256("GOVERNANCE");
    bytes32 public constant MEDIA_MODULE = keccak256("MEDIA");
    bytes32 public constant UPDATES_MODULE = keccak256("UPDATES");
    bytes32 public constant REFUNDS_MODULE = keccak256("REFUNDS");
    bytes32 public constant SECURITY_MODULE = keccak256("SECURITY");
    bytes32 public constant WEB3_MODULE = keccak256("WEB3");
    bytes32 public constant ANALYTICS_MODULE = keccak256("ANALYTICS");

    // ========== MODIFIERS ==========
    modifier validFundraiserId(uint256 id) {
        require(id > 0 && id <= fundraiserCount, "Invalid fundraiser");
        _;
    }

    modifier onlyModule(bytes32 moduleKey) {
        require(msg.sender == modules[moduleKey], "Only authorized module");
        _;
    }

    modifier securityCheck(string memory functionName) {
        address security = modules[SECURITY_MODULE];
        if (security != address(0)) {
            (bool success, bytes memory result) = security.staticcall(
                abi.encodeWithSignature("performSecurityCheck(address,string)", msg.sender, functionName)
            );
            require(success && abi.decode(result, (bool)), "Security check failed");
        }
        _;
    }

    modifier tokenSecurityCheck(address token) {
        address security = modules[SECURITY_MODULE];
        if (security != address(0)) {
            (bool success, bytes memory result) = security.staticcall(
                abi.encodeWithSignature("isTokenSuspended(address)", token)
            );
            if (success) {
                (bool isSuspended,) = abi.decode(result, (bool, string));
                require(!isSuspended, "Token suspended");
            }
        }
        _;
    }

    // ========== CONSTRUCTOR ==========
    constructor(address _commissionWallet) Ownable(msg.sender) {
        require(_commissionWallet != address(0), "Invalid wallet");
        commissionWallet = _commissionWallet;
    }

    // ========== MODULE MANAGEMENT ==========
    function setModule(bytes32 moduleKey, address moduleAddress) external onlyOwner {
        address oldModule = modules[moduleKey];
        modules[moduleKey] = moduleAddress;
        emit ModuleSet(moduleKey, oldModule, moduleAddress);
    }

    function setModules(
        address _governance, 
        address _media, 
        address _updates, 
        address _refunds,
        address _security,
        address _web3,
        address _analytics
    ) external onlyOwner {
        modules[GOVERNANCE_MODULE] = _governance;
        modules[MEDIA_MODULE] = _media;
        modules[UPDATES_MODULE] = _updates;
        modules[REFUNDS_MODULE] = _refunds;
        modules[SECURITY_MODULE] = _security;
        modules[WEB3_MODULE] = _web3;
        modules[ANALYTICS_MODULE] = _analytics;
        
        emit ModulesInitialized(_governance, _media, _updates, _refunds);
        emit SecurityModuleSet(address(0), _security);
        emit Web3ModuleSet(address(0), _web3);
        emit AnalyticsModuleSet(address(0), _analytics);
    }

    // ========== CORE FUNDRAISING ==========
    
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
        
        // Register in refunds module
        address refunds = modules[REFUNDS_MODULE];
        if (refunds != address(0)) {
            IPoliDaoRefunds(refunds).registerFundraiser(id, data.isFlexible);
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
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(f.packed.status == uint8(FundraiserStatus.ACTIVE), "Not active");
        require(block.timestamp <= f.packed.endDate, "Ended");
        require(!f.packed.isSuspended, "Suspended");
        require(amount > 0, "Zero amount");
        
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
    {
        Fundraiser storage f = fundraisers[fundraiserId];
        require(msg.sender == f.creator, "Not creator");
        require(!f.packed.fundsWithdrawn, "Already withdrawn");
        require(f.packed.raisedAmount > 0, "No funds");
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

    // ========== UNIVERSAL DELEGATION ==========
    
    /**
     * @notice Universal delegation function for all modules
     * @param moduleKey Module identifier
     * @param data Function call data
     * @return result Return data from delegated call
     */
    function delegateCall(bytes32 moduleKey, bytes calldata data) 
        external 
        returns (bytes memory result) 
    {
        address module = modules[moduleKey];
        require(module != address(0), "Module not set");
        
        // Security check for critical functions
        if (moduleKey == SECURITY_MODULE) {
            require(
                msg.sender == owner() || 
                msg.sender == modules[SECURITY_MODULE], 
                "Not authorized for security"
            );
        }
        
        bool success;
        (success, result) = module.delegatecall(data);
        require(success, "Delegate call failed");
    }

    /**
     * @notice Static call to module (view functions)
     * @param moduleKey Module identifier  
     * @param data Function call data
     * @return result Return data from static call
     */
    function staticCall(bytes32 moduleKey, bytes calldata data) 
        external 
        view 
        returns (bytes memory result) 
    {
        address module = modules[moduleKey];
        require(module != address(0), "Module not set");
        
        bool success;
        (success, result) = module.staticcall(data);
        require(success, "Static call failed");
    }

    // ========== HELPER FUNCTIONS FOR MODULES ==========
    
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
        onlyModule(REFUNDS_MODULE)
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
        onlyModule(REFUNDS_MODULE)
        validFundraiserId(fundraiserId) 
    {
        fundraisers[fundraiserId].donations[donor] = newAmount;
    }

    // ========== TOKEN MANAGEMENT ==========
    
    function whitelistToken(address token) external onlyOwner tokenSecurityCheck(token) {
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

    function getModule(bytes32 moduleKey) external view returns (address) {
        return modules[moduleKey];
    }

    // ========== ADMIN FUNCTIONS ==========
    
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

    // ========== EVENTS ==========
    
    event ModuleSet(bytes32 indexed moduleKey, address indexed oldModule, address indexed newModule);
    event Web3ModuleSet(address indexed oldModule, address indexed newModule);
    event AnalyticsModuleSet(address indexed oldModule, address indexed newModule);

    receive() external payable {}
}