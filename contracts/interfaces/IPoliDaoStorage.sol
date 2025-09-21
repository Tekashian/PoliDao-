// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoStorage
 * @notice Interface for PoliDAO unified storage contract
 */
interface IPoliDaoStorage {
    // Gettery stanu zbiórek
    function fundraisers(uint256 fundraiserId) external view returns (IPoliDaoStructs.PackedFundraiserData memory);

    function fundraiserCreators(uint256 fundraiserId) external view returns (address);

    function fundraiserTokens(uint256 fundraiserId) external view returns (address);

    function fundraiserTitles(uint256 fundraiserId) external view returns (string memory);

    function fundraiserDescriptions(uint256 fundraiserId) external view returns (string memory);

    function fundraiserLocations(uint256 fundraiserId) external view returns (string memory);

    function donations(uint256 fundraiserId, address donor) external view returns (uint256);

    function getFundraiserDonors(uint256 fundraiserId) external view returns (address[] memory);

    function fundraiserCounter() external view returns (uint256);

    // Mutacje dot. zbiórek
    function updateFundraiser(uint256 fundraiserId, IPoliDaoStructs.PackedFundraiserData calldata data) external;

    function updateFundraiserLocation(uint256 fundraiserId, string calldata newLocation) external;

    // Donacje
    function addDonation(uint256 fundraiserId, address donor, uint256 amount) external;

    function batchAddDonations(
        address donor,
        address expectedToken,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external;

    function updateDonationAmount(uint256 fundraiserId, address donor, uint256 newAmount) external;

    // Whitelist
    function isTokenWhitelisted(address token) external view returns (bool);

    function addWhitelistedToken(address token) external;

    function removeWhitelistedToken(address token) external;

    function getWhitelistedTokens() external view returns (address[] memory);

    // Moduły / autoryzacje
    function modules(bytes32 key) external view returns (address);

    function setModule(bytes32 moduleKey, address moduleAddr) external;

    function authorizeContract(address contractAddress) external;

    function deauthorizeContract(address contractAddress) external;

    function isContractAuthorized(address contractAddress) external view returns (bool);

    // Transfer środków wykonywany przez Storage
    function releaseFunds(address token, address to, uint256 amount) external;
}