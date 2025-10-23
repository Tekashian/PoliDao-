// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoStorage
 * @notice Interface for PoliDAO unified storage contract
 */
interface IPoliDaoStorage {
    // ======== Views: fundraisers and mappings ========
    function fundraiserCounter() external view returns (uint256);

    function fundraisers(uint256 fundraiserId) external view returns (IPoliDaoStructs.PackedFundraiserData memory);

    function fundraiserCreators(uint256 fundraiserId) external view returns (address);

    function fundraiserTokens(uint256 fundraiserId) external view returns (address);

    function fundraiserTitles(uint256 fundraiserId) external view returns (string memory);

    function fundraiserDescriptions(uint256 fundraiserId) external view returns (string memory);

    function fundraiserLocations(uint256 fundraiserId) external view returns (string memory);

    function donations(uint256 fundraiserId, address donor) external view returns (uint256);

    function totalWithdrawn(uint256 fundraiserId) external view returns (uint256);

    function totalRefunded(uint256 fundraiserId) external view returns (uint256);

    function modules(bytes32 key) external view returns (address);

    function isTokenWhitelisted(address token) external view returns (bool);

    function getWhitelistedTokens() external view returns (address[] memory);

    function getFundraiserDonors(uint256 fundraiserId) external view returns (address[] memory);

    // ======== Views: metadata helpers ========
    function getFundraiserMetadata(uint256 fundraiserId) external view returns (string memory);

    function getFundraiserInitialImage(uint256 fundraiserId) external view returns (string memory);

    // ======== Core-only mutators ========
    function createFundraiser(
        IPoliDaoStructs.PackedFundraiserData memory data,
        string memory title,
        string memory description,
        string memory location,
        address creator,
        address token
    ) external returns (uint256 fundraiserId);

    function addDonation(uint256 fundraiserId, address donor, uint256 amount) external;

    function updateFundraiser(uint256 fundraiserId, IPoliDaoStructs.PackedFundraiserData calldata data) external;

    function updateFundraiserStatus(uint256 fundraiserId, uint8 newStatus) external;

    function updateRaisedAmount(uint256 fundraiserId, uint256 newAmount) external;

    function batchAddDonations(
        address donor,
        address expectedToken,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external;

    function releaseFunds(address token, address to, uint256 amount) external;

    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) external;

    // ======== Ownership/ACL helpers used by Core ========
    function setModule(bytes32 key, address moduleAddr) external;

    function isContractAuthorized(address a) external view returns (bool);

    function authorizeContract(address contractAddress) external;

    // ======== Analytics helpers ========
    function recordWithdrawal(uint256 fundraiserId, uint256 amount) external;

    function recordRefundTotals(uint256 fundraiserId, uint256 netAmount, uint256 commission) external;
}