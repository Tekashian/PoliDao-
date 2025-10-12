// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoRefunds.sol";
import "../interfaces/IPoliDaoAccounting.sol";
import "../interfaces/IPoliDaoSecurity.sol";

library RefundLogic {
    error FundraiserNotFound();
    error RefundsModuleNotSet();

    function recordRefund(IPoliDaoStorage s, uint256 fundraiserId, uint256 amount) internal {
        address accounting = s.modules(keccak256("ACCOUNTING"));
        if (accounting != address(0) && amount > 0) {
            IPoliDaoAccounting(accounting).recordRefund(fundraiserId, amount);
        }
    }

    // Opcjonalny strict start okresu refundów (jak miałeś wcześniej)
    function startRefundPeriodStrict(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address refundsModule
    ) internal {
        if (refundsModule == address(0)) revert RefundsModuleNotSet();

        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        address creator = s.fundraiserCreators(fundraiserId);
        // wymagane (fundraiserId, creator, endDate)
        IPoliDaoRefunds(refundsModule).initiateClosure(fundraiserId, creator, f.endDate);
    }
}

