// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoSecurity.sol";
import "../storage/PoliDaoStorage.sol";

library RefundLogic {
    error FundraiserNotFound();
    error RefundNotEligible();
    error AlreadyRefunded();
    error GoalReachedNoRefund();
    error WithdrawalsStarted(); // refund blocked if withdrawals have started

    // Sumy refundów do Storage (netto + prowizja)
    function recordRefund(IPoliDaoStorage s, uint256 fundraiserId, uint256 netAmount, uint256 commission) internal {
        try PoliDaoStorage(address(s)).recordRefundTotals(fundraiserId, netAmount, commission) {} catch {}
    }

    // Deprecated: brak "refund period" – zachowane dla kompatybilności
    function enterRefundPeriod(IPoliDaoStorage s, uint256 fundraiserId) internal view {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();
        bool isWithGoal = f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL);
        if (!isWithGoal) revert RefundNotEligible();
        // Brak ograniczeń czasowych (zawsze dozwolone warunkowo na stanach poniżej)
    }

    // Refund "zawsze", ale tylko: WITH_GOAL && !goalReached && !withdrawalsStarted && !fundsWithdrawn
    function claimRefund(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        bool withdrawalsStartedFlag
    ) internal returns (uint256 netAmount, uint256 commission, address token) {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        // 1) Tylko zbiórki z celem
        bool isWithGoal = f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL);
        if (!isWithGoal) revert RefundNotEligible();

        // 2) Cel nie może być osiągnięty
        bool goalReached = (f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);
        if (goalReached) revert GoalReachedNoRefund();

        // 3) Wypłaty nie mogą być rozpoczęte / środki nie mogą być wypłacone
        if (withdrawalsStartedFlag) revert WithdrawalsStarted();
        if (f.fundsWithdrawn) revert RefundNotEligible();

        // 4) Darczyńca musi mieć saldo i nie refundował wcześniej
        uint256 donated = s.donations(fundraiserId, donor);
        if (donated == 0) revert AlreadyRefunded();

        token = s.fundraiserTokens(fundraiserId);

        // 5) Tranching przez moduł Security (opcjonalnie)
        uint256 allowedNow = donated;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, /*remaining*/) =
                IPoliDaoSecurity(security).checkAndConsumeRefund(fundraiserId, donor, donated);
            if (allowedNow == 0) revert("Security: payout tranche not available yet");
        }

        // 6) Prowizja od refundów (jeśli skonfigurowana w Storage)
        address wallet = PoliDaoStorage(address(s)).commissionWallet();
        uint256 rate = PoliDaoStorage(address(s)).refundCommission();

        commission = rate == 0 ? 0 : (allowedNow * rate) / 10_000;
        netAmount = allowedNow - commission;

        // Zmniejsz zapisane saldo darczyńcy o zrefundowaną transzę
        s.updateDonationAmount(fundraiserId, donor, donated - allowedNow);

        if (commission > 0 && wallet != address(0)) {
            s.releaseFunds(token, wallet, commission);
        }
        s.releaseFunds(token, donor, netAmount);

        // Akumulacja statystyk
        recordRefund(s, fundraiserId, netAmount, commission);
    }

    // Backward-compat
    function claimRefund(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor
    ) internal returns (uint256 netAmount, uint256 commission, address token) {
        return claimRefund(s, fundraiserId, donor, false);
    }

    // Backward-compat (startRefundPeriod nie ma znaczenia – pozostaje view/no-op)
    function startRefundPeriodStrict(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address /* refundsModule (unused) */
    ) internal view {
        enterRefundPeriod(s, fundraiserId);
    }
}

