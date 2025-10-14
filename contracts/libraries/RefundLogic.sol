// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
// import "../interfaces/IPoliDaoAccounting.sol";
import "../interfaces/IPoliDaoSecurity.sol";
import "../storage/PoliDaoStorage.sol"; // ADDED

library RefundLogic {
    error FundraiserNotFound();
    error RefundNotEligible();
    error AlreadyRefunded();
    error GoalReachedNoRefund();
    error RefundTooEarly();

    // Zapisz sumy refundów w Storage (netto + prowizja) – bez modułu Accounting
    function recordRefund(IPoliDaoStorage s, uint256 fundraiserId, uint256 netAmount, uint256 commission) internal {
        try PoliDaoStorage(address(s)).recordRefundTotals(fundraiserId, netAmount, commission) {} catch {}
    }

    // New: enter refund period (idempotent) – status flip only
    function enterRefundPeriod(IPoliDaoStorage s, uint256 fundraiserId) internal {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        bool isWithGoal = f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL);
        bool timeEnded = (f.endDate != 0 && block.timestamp > f.endDate);
        bool goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        if (!isWithGoal) revert RefundNotEligible();
        if (!timeEnded) revert RefundTooEarly();
        if (goalReached) revert GoalReachedNoRefund();

        if (f.status != uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD)) {
            // mutate local copy then persist via full update (interface supports updateFundraiser)
            f.status = uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD);
            s.updateFundraiser(fundraiserId, f);
        }
    }

    // New: claim refund (returns net + commission + token)
    function claimRefund(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor
    ) internal returns (uint256 netAmount, uint256 commission, address token) {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        // Must already be in refund period (caller can ensure via enterRefundPeriod first)
        if (f.status != uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD)) {
            // attempt auto-enter if valid
            enterRefundPeriod(s, fundraiserId);
            // re-load status (not strictly necessary)
            f = s.fundraisers(fundraiserId);
            if (f.status != uint8(IPoliDaoStructs.FundraiserStatus.REFUND_PERIOD)) {
                revert RefundNotEligible();
            }
        }

        uint256 donated = s.donations(fundraiserId, donor);
        if (donated == 0) revert AlreadyRefunded();

        token = s.fundraiserTokens(fundraiserId);
        address wallet = PoliDaoStorage(address(s)).commissionWallet(); // CHANGED
        uint256 rate = PoliDaoStorage(address(s)).refundCommission(); // CHANGED

        commission = rate == 0 ? 0 : (donated * rate) / 10_000;
        netAmount = donated - commission;

        // Zero out donor amount & adjust raised via existing helper
        s.updateDonationAmount(fundraiserId, donor, 0);

        if (commission > 0 && wallet != address(0)) {
            s.releaseFunds(token, wallet, commission);
        }
        s.releaseFunds(token, donor, netAmount);

        // Zapisz sumy refundów w Storage (netto + prowizja)
        recordRefund(s, fundraiserId, netAmount, commission);
    }

    // Backward-compatible (old core call) – now delegates or no-op if module path required
    function startRefundPeriodStrict(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address /* refundsModule (unused) */
    ) internal {
        enterRefundPeriod(s, fundraiserId);
    }
}

