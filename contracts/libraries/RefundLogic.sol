// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoRefunds.sol";

library RefundLogic {
    error FundraiserNotFound();
    error RefundsModuleNotSet();

    function startRefundPeriodStrict(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address refundsModule
    ) internal {
        if (refundsModule == address(0)) revert RefundsModuleNotSet();

        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        // Jeśli masz setter statusu w Storage – ustaw REFUND_PERIOD
        // s.setFundraiserStatus(fundraiserId, uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD));

        IPoliDaoRefunds(refundsModule).initiateClosure(
            fundraiserId,
            s.fundraiserCreators(fundraiserId),
            f.endDate
        );
    }
}

