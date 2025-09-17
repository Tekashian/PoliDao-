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
interface IPoliDaoStorage {
    // ==== FUNDRAISERS ====

    /// @notice Full creation path
    function createFundraiser(
        IPoliDaoStructs.PackedFundraiserData memory data,
        string memory title,
        string memory description,
        string memory location,
        address creator,
        address token
    ) external returns (uint256 fundraiserId);

    /// @notice Minimal variant
    function createFundraiser(address token) external returns (uint256 fundraiserId);

    function fundraisers(uint256 fundraiserId) external view returns (IPoliDaoStructs.PackedFundraiserData memory);
    function updateFundraiser(uint256 fundraiserId, IPoliDaoStructs.PackedFundraiserData memory data) external;
    function updateFundraiserStatus(uint256 fundraiserId, uint8 newStatus) external;
    function updateRaisedAmount(uint256 fundraiserId, uint256 newAmount) external;

    function updateFundraiserLocation(uint256 fundraiserId, string memory newLocation) external;
    function setFundraiserTitle(uint256 fundraiserId, string memory newTitle) external;
    function setFundraiserDescription(uint256 fundraiserId, string memory newDescription) external;

    function addDonation(uint256 fundraiserId, address donor, uint256 amount) external;

    function fundraiserCreators(uint256 fundraiserId) external view returns (address);
    function fundraiserTokens(uint256 fundraiserId) external view returns (address);
    function fundraiserTitles(uint256 fundraiserId) external view returns (string memory);
    function fundraiserDescriptions(uint256 fundraiserId) external view returns (string memory);
    function fundraiserLocations(uint256 fundraiserId) external view returns (string memory);
    function fundraiserCounter() external view returns (uint256);
    function donations(uint256 fundraiserId, address donor) external view returns (uint256);
    function getFundraiserDonors(uint256 fundraiserId) external view returns (address[] memory);

    // ==== AUTH / ROUTER ====
    function authorizeContract(address contractAddress) external;
    function deauthorizeContract(address contractAddress) external;
    function isContractAuthorized(address contractAddress) external view returns (bool);
    function setAuthorizedRouter(address router) external;
    function authorizedRouter() external view returns (address);

    // ==== WHITELIST ====
    function isTokenWhitelisted(address token) external view returns (bool);
    function addWhitelistedToken(address token) external;
    function removeWhitelistedToken(address token) external;
    function getWhitelistedTokens() external view returns (address[] memory);

    // ==== FEES / COMMISSIONS ====
    function setCommissions(uint256 _refundCommission) external;
    function setCommissions(uint256 _donationCommission, uint256 _successCommission, uint256 _refundCommission) external;
    function setExtensionFee(uint256 _extensionFee) external;
    function setCommissionWallet(address _commissionWallet) external;
    function setFeeToken(address _feeToken) external;
    function getFeeInfo() external view returns (
        uint256 donationCommissionRate,
        uint256 successCommissionRate,
        uint256 refundCommissionRate,
        uint256 extensionFeeAmount,
        address feeTokenAddress,
        address commissionWalletAddress
    );

    // ==== MODULE REGISTRY ====
    function modules(bytes32 key) external view returns (address);
    function setModule(bytes32 moduleKey, address moduleAddr) external;
    function setModules(
        address governance,
        address media,
        address updates,
        address refunds,
        address security,
        address web3,
        address analytics
    ) external;

    // ==== FUNDS ====
    function releaseFunds(address token, address to, uint256 amount) external;

    // ==== CONSTANT GETTERS (matched to public constants) ====
    function MAX_EXTENSION_DAYS() external view returns (uint256);
    function MAX_EXTENSIONS() external view returns (uint256);
    function MIN_EXTENSION_NOTICE() external view returns (uint256);
    function MAX_LOCATION_LENGTH() external view returns (uint256);
    function MAX_TITLE_LENGTH() external view returns (uint256);
    function MAX_DESCRIPTION_LENGTH() external view returns (uint256);
    function MAX_COMMISSION_RATE() external view returns (uint256);
    function MAX_EXTENSION_FEE() external view returns (uint256);

    // ==== OWNERSHIP ====
    function owner() external view returns (address);
}