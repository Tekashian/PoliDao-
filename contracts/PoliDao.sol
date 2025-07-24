// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPoliDao.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PoliDao - GŁÓWNY KONTRAKT
 * @notice Main implementation of PoliDAO platform
 * @dev Core contract implementing all fundraising functionality
 */
contract PoliDao is IPoliDao, Ownable, Pausable, ReentrancyGuard {
    
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
        returns (uint256 fundraiserId) 
    {
        require(bytes(data.title).length > 0, "Title required");
        require(data.endDate > block.timestamp, "Invalid end date");
        require(isTokenWhitelisted[data.token], "Token not whitelisted");
        
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
    
    // ========== STUB IMPLEMENTATIONS (dla interfejsu) ==========
    
    function withdrawFunds(uint256) external pure override { revert("Not implemented"); }
    function refund(uint256) external pure override { revert("Not implemented"); }
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
            address(0), // TODO: get token from storage
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
    
    // ========== MODULE MANAGEMENT ==========
    
    function setModule(bytes32 moduleKey, address moduleAddress) external override onlyOwner {
        modules[moduleKey] = moduleAddress;
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
    function canRefund(uint256, address) external pure override returns (bool, string memory) { revert("Use refunds module"); }
    function getWhitelistedTokens() external view override returns (address[] memory) { return whitelistedTokens; }
    function getFeeInfo() external view override returns (uint256, uint256, uint256, uint256, address, address) { 
        return (donationCommission, successCommission, refundCommission, extensionFee, feeToken, commissionWallet);
    }
    function getFundraiserBasicInfo(uint256) external pure override returns (string memory, address, address, uint256, uint256, uint256, uint8, bool) { revert("Not implemented"); }
    function removeWhitelistToken(address) external pure override { revert("Not implemented"); }
    function setCommissions(uint256, uint256, uint256) external pure override { revert("Not implemented"); }
    function setFeeToken(address) external pure override { revert("Not implemented"); }
    function setModules(address, address, address, address, address, address, address) external pure override { revert("Not implemented"); }
    function getFundraiserData(uint256) external pure override returns (address, address, uint256, uint256, uint256, uint8, bool) { revert("Not implemented"); }
    function updateFundraiserState(uint256, uint256, uint8) external pure override { revert("Not implemented"); }
    function updateDonationAmount(uint256, address, uint256) external pure override { revert("Not implemented"); }
    function emergencyWithdraw(address, address, uint256) external pure override { revert("Not implemented"); }
}