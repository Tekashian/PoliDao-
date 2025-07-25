// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPoliDao.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PoliDao - GŁÓWNY KONTRAKT - ZAKTUALIZOWANY
 * @notice Main implementation of PoliDAO platform
 * @dev Core contract implementing all fundraising functionality
 */
contract PoliDao is IPoliDao, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ========== CONSTANTS ==========
    uint256 public constant MIN_EXTENSION_NOTICE = 7 days;
    uint256 public constant MAX_EXTENSION_DAYS = 90;
    uint256 public constant MAX_LOCATION_LENGTH = 200;
    
    // ========== STORAGE ==========
    uint256 public fundraiserCounter;
    mapping(uint256 => PackedFundraiserData) public fundraisers;
    mapping(uint256 => string) public fundraiserTitles;
    mapping(uint256 => string) public fundraiserDescriptions;
    mapping(uint256 => string) public fundraiserLocations;
    mapping(uint256 => address) public fundraiserCreators;
    mapping(uint256 => address) public fundraiserTokens;  // DODANE
    
    // Donations mapping: fundraiserId => donor => amount
    mapping(uint256 => mapping(address => uint256)) public donations;
    mapping(uint256 => address[]) public fundraiserDonors;
    
    // Commissions and fees
    uint256 public donationCommission = 250; // 2.5%
    uint256 public successCommission = 500;  // 5%
    uint256 public refundCommission = 100;   // 1%
    uint256 public extensionFee = 1000e18;   // 1000 tokens
    address public feeToken;
    address public commissionWallet;
    
    // Module addresses
    mapping(bytes32 => address) public modules;
    
    // Whitelisted tokens
    address[] public whitelistedTokens;
    mapping(address => bool) public isTokenWhitelisted;
    
    // ========== MODULE KEYS ==========
    bytes32 public constant GOVERNANCE_MODULE = keccak256("GOVERNANCE_MODULE");
    bytes32 public constant MEDIA_MODULE = keccak256("MEDIA_MODULE");
    bytes32 public constant UPDATES_MODULE = keccak256("UPDATES_MODULE");
    bytes32 public constant REFUNDS_MODULE = keccak256("REFUNDS_MODULE");
    bytes32 public constant SECURITY_MODULE = keccak256("SECURITY_MODULE");
    bytes32 public constant WEB3_MODULE = keccak256("WEB3_MODULE");
    bytes32 public constant ANALYTICS_MODULE = keccak256("ANALYTICS_MODULE");
    
    // ========== CONSTRUCTOR ==========
    constructor(
        address _commissionWallet,
        address _feeToken,
        address _initialToken
    ) Ownable(msg.sender) {
        require(_commissionWallet != address(0), "Invalid commission wallet");
        require(_feeToken != address(0), "Invalid fee token");
        require(_initialToken != address(0), "Invalid initial token");
        
        commissionWallet = _commissionWallet;
        feeToken = _feeToken;
        
        // Whitelist initial token
        whitelistedTokens.push(_initialToken);
        isTokenWhitelisted[_initialToken] = true;
        
        emit TokenWhitelisted(_initialToken);
    }
    
    // ========== FUNDRAISER MANAGEMENT ==========
    
    function createFundraiser(FundraiserCreationData calldata data) 
        external 
        override 
        whenNotPaused
        nonReentrant  // DODANE
        returns (uint256 fundraiserId) 
    {
        require(bytes(data.title).length > 0, "Title required");
        require(data.endDate > block.timestamp, "Invalid end date");
        require(isTokenWhitelisted[data.token], "Token not whitelisted");
        require(bytes(data.location).length <= MAX_LOCATION_LENGTH, "Location too long");  // DODANE
        
        fundraiserCounter++;
        fundraiserId = fundraiserCounter;
        
        // Store packed data
        fundraisers[fundraiserId] = PackedFundraiserData({
            goalAmount: uint128(data.goalAmount),
            raisedAmount: 0,
            endDate: uint64(data.endDate),
            originalEndDate: uint64(data.endDate),
            id: uint32(fundraiserId),
            suspensionTime: 0,
            extensionCount: 0,
            fundraiserType: uint8(data.fundraiserType),
            status: uint8(FundraiserStatus.ACTIVE),
            isSuspended: false,
            fundsWithdrawn: false,
            isFlexible: data.isFlexible
        });
        
        // Store additional data
        fundraiserTitles[fundraiserId] = data.title;
        fundraiserDescriptions[fundraiserId] = data.description;
        fundraiserLocations[fundraiserId] = data.location;
        fundraiserCreators[fundraiserId] = msg.sender;
        fundraiserTokens[fundraiserId] = data.token;  // DODANE
        
        // DODANE - rejestracja w Refunds module
        address refundsModule = modules[REFUNDS_MODULE];
        if (refundsModule != address(0)) {
            bytes memory registerData = abi.encodeWithSignature(
                "registerFundraiser(uint256,bool)",
                fundraiserId,
                data.isFlexible
            );
            (bool success,) = refundsModule.call(registerData);
            require(success, "Refunds registration failed");
        }
        
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
    }
    
    function donate(uint256 fundraiserId, uint256 amount) 
        external 
        override 
        whenNotPaused 
        nonReentrant 
    {
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        require(amount > 0, "Amount must be greater than 0");
        require(fundraisers[fundraiserId].status == uint8(FundraiserStatus.ACTIVE), "Fundraiser not active");
        require(block.timestamp <= fundraisers[fundraiserId].endDate, "Fundraiser ended");
        
        // Add to donors list if first donation
        if (donations[fundraiserId][msg.sender] == 0) {
            fundraiserDonors[fundraiserId].push(msg.sender);
        }
        
        // Update donation
        donations[fundraiserId][msg.sender] += amount;
        fundraisers[fundraiserId].raisedAmount += uint128(amount);
        
        // TODO: Transfer tokens (simplified for interface)
        
        emit DonationMade(fundraiserId, msg.sender, address(0), amount, amount);
    }
    
    // ========== NEW EXTENSION FUNCTIONS ==========
    
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) 
        external 
        override 
        whenNotPaused 
    {
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        require(fundraiserCreators[fundraiserId] == msg.sender, "Only creator");
        require(additionalDays > 0 && additionalDays <= MAX_EXTENSION_DAYS, "Invalid days");
        require(fundraisers[fundraiserId].extensionCount < 3, "Max extensions reached");
        
        uint256 timeLeft = fundraisers[fundraiserId].endDate > block.timestamp ? 
            fundraisers[fundraiserId].endDate - block.timestamp : 0;
        require(timeLeft >= MIN_EXTENSION_NOTICE, "Too close to end");
        
        // TODO: Charge extension fee
        
        fundraisers[fundraiserId].endDate += uint64(additionalDays * 1 days);
        fundraisers[fundraiserId].extensionCount++;
        
        emit FundraiserExtended(fundraiserId, fundraisers[fundraiserId].endDate, additionalDays, extensionFee);
    }
    
    function canExtendFundraiser(uint256 fundraiserId) 
        external 
        view 
        override 
        returns (bool canExtend, uint256 timeLeft, string memory reason) 
    {
        if (fundraisers[fundraiserId].id == 0) {
            return (false, 0, "Fundraiser not found");
        }
        
        if (fundraiserCreators[fundraiserId] != msg.sender) {
            return (false, 0, "Only creator can extend");
        }
        
        if (fundraisers[fundraiserId].extensionCount >= 3) {
            return (false, 0, "Maximum extensions reached");
        }
        
        timeLeft = fundraisers[fundraiserId].endDate > block.timestamp ? 
            fundraisers[fundraiserId].endDate - block.timestamp : 0;
            
        if (timeLeft < MIN_EXTENSION_NOTICE) {
            return (false, timeLeft, "Too close to deadline");
        }
        
        return (true, timeLeft, "Can extend");
    }
    
    // ========== NEW LOCATION FUNCTIONS ==========
    
    function updateLocation(uint256 fundraiserId, string calldata newLocation) 
        external 
        override 
        whenNotPaused 
    {
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        require(fundraiserCreators[fundraiserId] == msg.sender, "Only creator");
        require(bytes(newLocation).length <= MAX_LOCATION_LENGTH, "Location too long");
        
        string memory oldLocation = fundraiserLocations[fundraiserId];
        fundraiserLocations[fundraiserId] = newLocation;
        
        emit LocationUpdated(fundraiserId, oldLocation, newLocation);
    }
    
    function getFundraiserLocation(uint256 fundraiserId) 
        external 
        view 
        override 
        returns (string memory location) 
    {
        return fundraiserLocations[fundraiserId];
    }
    
    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        override 
        returns (
            uint256 extensionCount,
            uint256 originalEndDate,
            uint256 currentEndDate
        ) 
    {
        PackedFundraiserData memory data = fundraisers[fundraiserId];
        return (data.extensionCount, data.originalEndDate, data.endDate);
    }
    
    // ========== REFUND FUNCTIONS - ZAKTUALIZOWANE ==========
    
    function refund(uint256 fundraiserId) external override whenNotPaused nonReentrant {
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        require(donations[fundraiserId][msg.sender] > 0, "No donation found");
        
        address refundsModule = modules[REFUNDS_MODULE];
        require(refundsModule != address(0), "Refunds module not set");
        
        PackedFundraiserData memory fundraiser = fundraisers[fundraiserId];
        address token = fundraiserTokens[fundraiserId];
        uint256 donationAmount = donations[fundraiserId][msg.sender];
        bool goalReached = fundraiser.raisedAmount >= fundraiser.goalAmount;
        
        // Clear donation before external call (reentrancy protection)
        donations[fundraiserId][msg.sender] = 0;
        fundraisers[fundraiserId].raisedAmount -= uint128(donationAmount);
        
        // Process refund through module
        bytes memory refundData = abi.encodeWithSignature(
            "processRefund(uint256,address,uint256,address,uint8,uint256,bool)",
            fundraiserId,
            msg.sender,
            donationAmount,
            token,
            fundraiser.status,
            fundraiser.endDate,
            goalReached
        );
        
        (bool success,) = refundsModule.call(refundData);
        require(success, "Refund processing failed");
    }
    
    function canRefund(uint256 fundraiserId, address donor) 
        external 
        view 
        override
        returns (bool canRefundResult, string memory reason) 
    {
        address refundsModule = modules[REFUNDS_MODULE];
        if (refundsModule == address(0)) {
            return (false, "Refunds module not set");
        }
        
        if (fundraisers[fundraiserId].id == 0) {
            return (false, "Fundraiser not found");
        }
        
        PackedFundraiserData memory fundraiser = fundraisers[fundraiserId];
        uint256 donationAmount = donations[fundraiserId][donor];
        bool goalReached = fundraiser.raisedAmount >= fundraiser.goalAmount;
        
        // Call refunds module
        bytes memory data = abi.encodeWithSignature(
            "canRefund(uint256,address,uint256,uint8,uint256,bool)",
            fundraiserId,
            donor,
            donationAmount,
            fundraiser.status,
            fundraiser.endDate,
            goalReached
        );
        
        (bool success, bytes memory result) = refundsModule.staticcall(data);
        if (!success) {
            return (false, "Module call failed");
        }
        
        return abi.decode(result, (bool, string));
    }
    
    // ========== HELPER FUNCTIONS FOR MODULES - ZAKTUALIZOWANE ==========
    
    function getFundraiserData(uint256 fundraiserId) 
        external 
        view 
        override
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
        PackedFundraiserData memory data = fundraisers[fundraiserId];
        require(data.id != 0, "Fundraiser not found");
        
        return (
            fundraiserCreators[fundraiserId],
            fundraiserTokens[fundraiserId],
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status,
            data.isFlexible
        );
    }
    
    function updateFundraiserState(
        uint256 fundraiserId, 
        uint256 newRaisedAmount, 
        uint8 newStatus
    ) external override {
        require(msg.sender == modules[REFUNDS_MODULE], "Only refunds module");
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        
        fundraisers[fundraiserId].raisedAmount = uint128(newRaisedAmount);
        fundraisers[fundraiserId].status = newStatus;
    }
    
    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) 
        external override {
        require(msg.sender == modules[REFUNDS_MODULE], "Only refunds module");
        require(fundraisers[fundraiserId].id != 0, "Fundraiser not found");
        
        donations[fundraiserId][donor] = newAmount;
    }
    
    function getFundraiserBasicInfo(uint256 id) 
        external 
        view 
        override
        returns (
            string memory title,
            address creator,
            address token,
            uint256 raised,
            uint256 goal,
            uint256 endDate,
            uint8 status,
            bool isFlexible
        ) 
    {
        PackedFundraiserData memory data = fundraisers[id];
        require(data.id != 0, "Fundraiser not found");
        
        return (
            fundraiserTitles[id],
            fundraiserCreators[id],
            fundraiserTokens[id],
            data.raisedAmount,
            data.goalAmount,
            data.endDate,
            data.status,
            data.isFlexible
        );
    }
    
    // ========== STUB IMPLEMENTATIONS (dla interfejsu) ==========
    
    function withdrawFunds(uint256) external pure override { revert("Not implemented"); }
    function suspendFundraiser(uint256, string calldata) external pure override { revert("Not implemented"); }
    function unsuspendFundraiser(uint256) external pure override { revert("Not implemented"); }
    function createProposal(string calldata, uint256) external pure override { revert("Not implemented"); }
    function vote(uint256, bool) external pure override { revert("Not implemented"); }
    function authorizeProposer(address) external pure override { revert("Not implemented"); }
    function revokeProposer(address) external pure override { revert("Not implemented"); }
    function addMediaToFundraiser(uint256, MediaItem[] calldata) external pure override { revert("Not implemented"); }
    function removeMediaFromFundraiser(uint256, uint256) external pure override { revert("Not implemented"); }
    function authorizeMediaManager(uint256, address) external pure override { revert("Not implemented"); }
    function revokeMediaManager(uint256, address) external pure override { revert("Not implemented"); }
    function postUpdate(uint256, string calldata) external pure override { revert("Not implemented"); }
    function postUpdateWithMedia(uint256, string calldata, uint8, uint256[] calldata) external pure override { revert("Not implemented"); }
    function pinUpdate(uint256) external pure override { revert("Not implemented"); }
    function unpinUpdate(uint256) external pure override { revert("Not implemented"); }
    function authorizeUpdater(uint256, address) external pure override { revert("Not implemented"); }
    function revokeUpdater(uint256, address) external pure override { revert("Not implemented"); }
    
    // ========== VIEW FUNCTIONS ==========
    
    function getFundraiserDetails(uint256 fundraiserId) 
        external 
        view 
        override 
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
        PackedFundraiserData memory data = fundraisers[fundraiserId];
        return (
            fundraiserTitles[fundraiserId],
            fundraiserDescriptions[fundraiserId],
            fundraiserLocations[fundraiserId],
            data.endDate,
            data.fundraiserType,
            data.status,
            fundraiserTokens[fundraiserId],  // ZAKTUALIZOWANE: zamiast address(0)
            data.goalAmount,
            data.raisedAmount,
            fundraiserCreators[fundraiserId],
            data.extensionCount,
            data.isSuspended,
            "" // TODO: suspension reason
        );
    }
    
    function getFundraiserCount() external view override returns (uint256) {
        return fundraiserCounter;
    }
    
    function getFundraiserCreator(uint256 fundraiserId) external view override returns (address) {
        return fundraiserCreators[fundraiserId];
    }
    
    function donationOf(uint256 fundraiserId, address donor) external view override returns (uint256) {
        return donations[fundraiserId][donor];
    }
    
    function getDonationAmount(uint256 fundraiserId, address donor) external view override returns (uint256) {
        return donations[fundraiserId][donor];
    }
    
    function getFundraiserDonors(uint256 fundraiserId) external view override returns (address[] memory) {
        return fundraiserDonors[fundraiserId];
    }
    
    function getDonorCount(uint256 fundraiserId) external view override returns (uint256) {
        return fundraiserDonors[fundraiserId].length;
    }
    
    // ========== ADMIN FUNCTIONS ==========
    
    function whitelistToken(address token) external override onlyOwner {
        require(token != address(0), "Invalid token");
        require(!isTokenWhitelisted[token], "Already whitelisted");
        
        whitelistedTokens.push(token);
        isTokenWhitelisted[token] = true;
        
        emit TokenWhitelisted(token);
    }
    
    function setExtensionFee(uint256 _extensionFee) external override onlyOwner {
        uint256 oldFee = extensionFee;
        extensionFee = _extensionFee;
        emit ExtensionFeeSet(oldFee, _extensionFee);
    }
    
    function setCommissionWallet(address newWallet) external override onlyOwner {
        require(newWallet != address(0), "Invalid wallet");
        address oldWallet = commissionWallet;
        commissionWallet = newWallet;
        emit CommissionWalletChanged(oldWallet, newWallet);
    }
    
    function pause() external override onlyOwner { _pause(); }
    function unpause() external override onlyOwner { _unpause(); }
    
    // ========== MODULE MANAGEMENT - ZAKTUALIZOWANE ==========
    
    function setModule(bytes32 moduleKey, address moduleAddress) external override onlyOwner {
        modules[moduleKey] = moduleAddress;
    }
    
    function setModules(
        address governance, 
        address media, 
        address updates, 
        address refunds,
        address security,
        address web3,
        address analytics
    ) external override onlyOwner {
        modules[GOVERNANCE_MODULE] = governance;
        modules[MEDIA_MODULE] = media;
        modules[UPDATES_MODULE] = updates;
        modules[REFUNDS_MODULE] = refunds;
        modules[SECURITY_MODULE] = security;
        modules[WEB3_MODULE] = web3;
        modules[ANALYTICS_MODULE] = analytics;
        
        emit ModulesInitialized(governance, media, updates, refunds);
    }
    
    function getModule(bytes32 moduleKey) external view override returns (address) {
        return modules[moduleKey];
    }
    
    function delegateCall(bytes32 moduleKey, bytes calldata data) 
        external 
        override 
        returns (bytes memory result) 
    {
        address module = modules[moduleKey];
        require(module != address(0), "Module not set");
        
        (bool success, bytes memory returnData) = module.delegatecall(data);
        require(success, "Module call failed");
        
        return returnData;
    }
    
    function staticCall(bytes32 moduleKey, bytes calldata data) 
        external 
        view 
        override 
        returns (bytes memory result) 
    {
        address module = modules[moduleKey];
        require(module != address(0), "Module not set");
        
        (bool success, bytes memory returnData) = module.staticcall(data);
        require(success, "Module call failed");
        
        return returnData;
    }
    
    // ========== POZOSTAŁE FUNKCJE (stub implementations) ==========
    
    function donateWithPermit(uint256, uint256, uint256, uint8, bytes32, bytes32) external pure override { revert("Use router"); }
    function batchDonate(uint256[] calldata, uint256[] calldata) external pure override { revert("Use router"); }
    function getFundraiserProgress(uint256) external pure override returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) { revert("Not implemented"); }
    function getDonors(uint256, uint256, uint256) external pure override returns (address[] memory, uint256[] memory, uint256) { revert("Use analytics module"); }
    function getFundraisersByStatus(uint8, uint256, uint256) external pure override returns (uint256[] memory, uint256) { revert("Use analytics module"); }
    function getFundraisersByCreator(address, uint256, uint256) external pure override returns (uint256[] memory, uint256) { revert("Use analytics module"); }
    function getWhitelistedTokens() external view override returns (address[] memory) { return whitelistedTokens; }
    function getFeeInfo() external view override returns (uint256, uint256, uint256, uint256, address, address) { 
        return (donationCommission, successCommission, refundCommission, extensionFee, feeToken, commissionWallet);
    }
    function removeWhitelistToken(address) external pure override { revert("Not implemented"); }
    function setCommissions(uint256, uint256, uint256) external pure override { revert("Not implemented"); }
    function setFeeToken(address) external pure override { revert("Not implemented"); }
    function emergencyWithdraw(address, address, uint256) external pure override { revert("Not implemented"); }
}