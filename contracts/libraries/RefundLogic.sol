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
    error WithdrawalsStarted(); // NEW: refund blocked if withdrawals have started

    // Zapisz sumy refundów w Storage (netto + prowizja) – bez modułu Accounting
    function recordRefund(IPoliDaoStorage s, uint256 fundraiserId, uint256 netAmount, uint256 commission) internal {
        try PoliDaoStorage(address(s)).recordRefundTotals(fundraiserId, netAmount, commission) {} catch {}
    }

    // DEPRECATED: refund period removed; keep as no-op for backward compatibility
    function enterRefundPeriod(IPoliDaoStorage s, uint256 fundraiserId) internal view {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();
        bool isWithGoal = f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL);
        if (!isWithGoal) revert RefundNotEligible();
        // No changes to status anymore
    }

    // New: claim refund without refund period; tranche via Security module
    function claimRefund(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        bool withdrawalsStartedFlag
    ) internal returns (uint256 netAmount, uint256 commission, address token) {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        bool isWithGoal = f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL);
        if (!isWithGoal) revert RefundNotEligible();

        // Goal must not be reached yet
        bool goalReached = (f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);
        if (goalReached) revert GoalReachedNoRefund();

        // Must not be paid out (no withdrawals started for fail/flexible path)
        if (withdrawalsStartedFlag) revert WithdrawalsStarted();
        if (f.fundsWithdrawn) revert RefundNotEligible();

        uint256 donated = s.donations(fundraiserId, donor);
        if (donated == 0) revert AlreadyRefunded();

        token = s.fundraiserTokens(fundraiserId);

        // Tranching via Security module (same as withdraw)
        uint256 allowedNow = donated;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, /*remaining*/) =
                IPoliDaoSecurity(security).checkAndConsumeRefund(fundraiserId, donor, donated);
            if (allowedNow == 0) revert("Security: payout tranche not available yet");
        }

        // Commission and payout only for the tranche
        address wallet = PoliDaoStorage(address(s)).commissionWallet();
        uint256 rate = PoliDaoStorage(address(s)).refundCommission();

        commission = rate == 0 ? 0 : (allowedNow * rate) / 10_000;
        netAmount = allowedNow - commission;

        // Decrease donor’s recorded donation by the tranche amount
        s.updateDonationAmount(fundraiserId, donor, donated - allowedNow);

        if (commission > 0 && wallet != address(0)) {
            s.releaseFunds(token, wallet, commission);
        }
        s.releaseFunds(token, donor, netAmount);

        // Accumulate totals for analytics
        recordRefund(s, fundraiserId, netAmount, commission);
    }

    // Backward-compat: old callers without withdrawalsStartedFlag
    function claimRefund(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor
    ) internal returns (uint256 netAmount, uint256 commission, address token) {
        return claimRefund(s, fundraiserId, donor, false);
    }

    // Backward-compatible (old core call) – no-op now
    function startRefundPeriodStrict(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address /* refundsModule (unused) */
    ) internal {
        enterRefundPeriod(s, fundraiserId);
    }
}

