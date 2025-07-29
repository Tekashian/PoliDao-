// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoStorage
 * @notice Interface for PoliDAO unified storage contract
 * @dev Defines all storage operations for the unified architecture
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 */
interface IPoliDaoStorage is IPoliDaoStructs {
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a fundraiser is created in storage
    event FundraiserCreatedInStorage(uint256 indexed fundraiserId, address indexed creator);
    
    /// @notice Emitted when a donation is added to storage
    event DonationAddedToStorage(uint256 indexed fundraiserId, address indexed donor, uint256 amount);
    
    /// @notice Emitted when a contract is authorized
    event ContractAuthorized(address indexed contractAddress);
    
    /// @notice Emitted when a contract is deauthorized
    event ContractDeauthorized(address indexed contractAddress);
    
    /// @notice Emitted when ownership is transferred
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
    // ========== CORE CRUD FUNCTIONS ==========
    
    /**
     * @notice Creates a new fundraiser in storage
     * @param data Packed fundraiser data
     * @param title Fundraiser title
     * @param description Fundraiser description
     * @param location Fundraiser location
     * @param creator Creator address
     * @param token Token address
     * @return fundraiserId The newly created fundraiser ID
     */
    function createFundraiser(
        PackedFundraiserData memory data,
        string memory title,
        string memory description,
        string memory location,
        address creator,
        address token
    ) external returns (uint256 fundraiserId);
    
    /**
     * @notice Adds a donation to storage
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param amount The donation amount
     */
    function addDonation(uint256 fundraiserId, address donor, uint256 amount) external;
    
    /**
     * @notice Updates fundraiser data
     * @param fundraiserId The fundraiser ID
     * @param data New packed fundraiser data
     */
    function updateFundraiser(uint256 fundraiserId, PackedFundraiserData memory data) external;
    
    /**
     * @notice Updates fundraiser location
     * @param fundraiserId The fundraiser ID
     * @param newLocation New location
     */
    function updateFundraiserLocation(uint256 fundraiserId, string memory newLocation) external;
    
    /**
     * @notice Updates donation amount for a specific donor
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param newAmount New donation amount
     */
    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) external;
    
    /**
     * @notice Updates raised amount for a fundraiser
     * @param fundraiserId The fundraiser ID
     * @param newAmount New raised amount
     */
    function updateRaisedAmount(uint256 fundraiserId, uint256 newAmount) external;
    
    /**
     * @notice Updates fundraiser status
     * @param fundraiserId The fundraiser ID
     * @param newStatus New status
     */
    function updateFundraiserStatus(uint256 fundraiserId, uint8 newStatus) external;
    
    // ========== TOKEN WHITELIST MANAGEMENT ==========
    
    /**
     * @notice Adds a token to the whitelist
     * @param token The token address to whitelist
     */
    function addWhitelistedToken(address token) external;
    
    /**
     * @notice Removes a token from the whitelist
     * @param token The token address to remove
     */
    function removeWhitelistedToken(address token) external;
    
    // ========== CONFIGURATION MANAGEMENT ==========
    
    /**
     * @notice Sets commission rates
     * @param _donationCommission New donation commission
     * @param _successCommission New success commission
     * @param _refundCommission New refund commission
     */
    function setCommissions(
        uint256 _donationCommission,
        uint256 _successCommission,
        uint256 _refundCommission
    ) external;
    
    /**
     * @notice Sets extension fee
     * @param _extensionFee New extension fee
     */
    function setExtensionFee(uint256 _extensionFee) external;
    
    /**
     * @notice Sets commission wallet
     * @param _commissionWallet New commission wallet
     */
    function setCommissionWallet(address _commissionWallet) external;
    
    /**
     * @notice Sets fee token
     * @param _feeToken New fee token
     */
    function setFeeToken(address _feeToken) external;
    
    // ========== MODULE MANAGEMENT ==========
    
    /**
     * @notice Sets a module address
     * @param moduleKey The module key
     * @param moduleAddress The module address
     */
    function setModule(bytes32 moduleKey, address moduleAddress) external;
    
    /**
     * @notice Sets the authorized router
     * @param _router The router address
     */
    function setAuthorizedRouter(address _router) external;
    
    // ========== ACCESS CONTROL ==========
    
    /**
     * @notice Authorizes a contract to access storage
     * @param contractAddress The contract address to authorize
     */
    function authorizeContract(address contractAddress) external;
    
    /**
     * @notice Deauthorizes a contract from accessing storage
     * @param contractAddress The contract address to deauthorize
     */
    function deauthorizeContract(address contractAddress) external;
    
    /**
     * @notice Transfers ownership of the storage contract
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external;
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Gets fundraiser donors array
     * @param fundraiserId The fundraiser ID
     * @return donors Array of donor addresses
     */
    function getFundraiserDonors(uint256 fundraiserId) external view returns (address[] memory donors);
    
    /**
     * @notice Gets all whitelisted tokens
     * @return tokens Array of whitelisted token addresses
     */
    function getWhitelistedTokens() external view returns (address[] memory);
    
    /**
     * @notice Gets fee and commission information
     * @return donationCommissionRate Donation commission in basis points
     * @return successCommissionRate Success commission in basis points
     * @return refundCommissionRate Refund commission in basis points
     * @return extensionFeeAmount Extension fee amount
     * @return feeTokenAddress Fee token address
     * @return commissionWalletAddress Commission wallet address
     */
    function getFeeInfo() external view returns (
        uint256 donationCommissionRate, 
        uint256 successCommissionRate, 
        uint256 refundCommissionRate, 
        uint256 extensionFeeAmount, 
        address feeTokenAddress, 
        address commissionWalletAddress
    );
    
    /**
     * @notice Checks if a contract is authorized
     * @param contractAddress The contract address to check
     * @return isAuthorized Whether the contract is authorized
     */
    function isContractAuthorized(address contractAddress) external view returns (bool);
    
    // ========== STORAGE ACCESS FUNCTIONS ==========
    
    /**
     * @notice Gets fundraiser counter
     * @return counter Current fundraiser counter
     */
    function fundraiserCounter() external view returns (uint256);
    
    /**
     * @notice Gets fundraiser data
     * @param fundraiserId The fundraiser ID
     * @return data Packed fundraiser data
     */
    function fundraisers(uint256 fundraiserId) external view returns (PackedFundraiserData memory);
    
    /**
     * @notice Gets fundraiser title
     * @param fundraiserId The fundraiser ID
     * @return title Fundraiser title
     */
    function fundraiserTitles(uint256 fundraiserId) external view returns (string memory);
    
    /**
     * @notice Gets fundraiser description
     * @param fundraiserId The fundraiser ID
     * @return description Fundraiser description
     */
    function fundraiserDescriptions(uint256 fundraiserId) external view returns (string memory);
    
    /**
     * @notice Gets fundraiser location
     * @param fundraiserId The fundraiser ID
     * @return location Fundraiser location
     */
    function fundraiserLocations(uint256 fundraiserId) external view returns (string memory);
    
    /**
     * @notice Gets fundraiser creator
     * @param fundraiserId The fundraiser ID
     * @return creator Creator address
     */
    function fundraiserCreators(uint256 fundraiserId) external view returns (address);
    
    /**
     * @notice Gets fundraiser token
     * @param fundraiserId The fundraiser ID
     * @return token Token address
     */
    function fundraiserTokens(uint256 fundraiserId) external view returns (address);
    
    /**
     * @notice Gets donation amount
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return amount Donation amount
     */
    function donations(uint256 fundraiserId, address donor) external view returns (uint256);
    
    /**
     * @notice Checks if token is whitelisted
     * @param token The token address
     * @return isWhitelisted Whether token is whitelisted
     */
    function isTokenWhitelisted(address token) external view returns (bool);
    
    /**
     * @notice Gets module address
     * @param moduleKey The module key
     * @return moduleAddress Module address
     */
    function modules(bytes32 moduleKey) external view returns (address);
    
    /**
     * @notice Gets authorized router
     * @return router Authorized router address
     */
    function authorizedRouter() external view returns (address);
    
    /**
     * @notice Gets storage owner
     * @return owner Owner address
     */
    function owner() external view returns (address);
    
    /**
     * @notice Gets donation commission
     * @return commission Donation commission in basis points
     */
    function donationCommission() external view returns (uint256);
    
    /**
     * @notice Gets success commission
     * @return commission Success commission in basis points
     */
    function successCommission() external view returns (uint256);
    
    /**
     * @notice Gets refund commission
     * @return commission Refund commission in basis points
     */
    function refundCommission() external view returns (uint256);
    
    /**
     * @notice Gets extension fee
     * @return fee Extension fee amount
     */
    function extensionFee() external view returns (uint256);
    
    /**
     * @notice Gets fee token
     * @return token Fee token address
     */
    function feeToken() external view returns (address);
    
    /**
     * @notice Gets commission wallet
     * @return wallet Commission wallet address
     */
    function commissionWallet() external view returns (address);
    
    // ========== CONSTANTS ==========
    
    /**
     * @notice Gets maximum extension fee constant
     * @return maxFee Maximum extension fee
     */
    function MAX_EXTENSION_FEE() external view returns (uint256);
    
    /**
     * @notice Gets maximum commission rate constant
     * @return maxRate Maximum commission rate
     */
    function MAX_COMMISSION_RATE() external view returns (uint256);
    
    /**
     * @notice Gets maximum location length constant
     * @return maxLength Maximum location length
     */
    function MAX_LOCATION_LENGTH() external view returns (uint256);
    
    /**
     * @notice Gets maximum title length constant
     * @return maxLength Maximum title length
     */
    function MAX_TITLE_LENGTH() external view returns (uint256);
    
    /**
     * @notice Gets maximum description length constant
     * @return maxLength Maximum description length
     */
    function MAX_DESCRIPTION_LENGTH() external view returns (uint256);
    
    /**
     * @notice Gets maximum future date constant
     * @return maxDate Maximum future date
     */
    function MAX_FUTURE_DATE() external view returns (uint256);
    
    /**
     * @notice Gets maximum extensions constant
     * @return maxExtensions Maximum extensions
     */
    function MAX_EXTENSIONS() external view returns (uint256);
    
    /**
     * @notice Gets minimum extension notice constant
     * @return minNotice Minimum extension notice
     */
    function MIN_EXTENSION_NOTICE() external view returns (uint256);
    
    /**
     * @notice Gets maximum extension days constant
     * @return maxDays Maximum extension days
     */
    function MAX_EXTENSION_DAYS() external view returns (uint256);
}