// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStorage.sol";
import "./IPoliDaoStructs.sol";

interface IPoliDaoAccounting {
    // wiring
    function setCore(address core) external;
    function setStorage(address storageAddr) external;

    // mutations (wywołuje Core/Refunds)
    function recordWithdrawal(uint256 fundraiserId, uint256 grossAmount) external;
    function recordRefund(uint256 fundraiserId, uint256 amount) external;

    // views
    function withdrawnAmount(uint256 fundraiserId) external view returns (uint256);
    function refundedAmount(uint256 fundraiserId) external view returns (uint256);
    function currentBalance(uint256 fundraiserId) external view returns (uint256);
}