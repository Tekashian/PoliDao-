// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../libraries/RefundLogic.sol";

contract RefundLogicHarness {
    function enterRefundPeriod(IPoliDaoStorage s, uint256 fundraiserId) external {
        RefundLogic.enterRefundPeriod(s, fundraiserId);
    }

    function claimRefund(IPoliDaoStorage s, uint256 fundraiserId, address donor)
        external
        returns (uint256 netAmount, uint256 commission, address token)
    {
        return RefundLogic.claimRefund(s, fundraiserId, donor);
    }
}
