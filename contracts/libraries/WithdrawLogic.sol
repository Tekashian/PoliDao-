// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoSecurity.sol";
import "../interfaces/IPoliDaoAccounting.sol";

library WithdrawLogic {
    error FundraiserNotFound();
    error AlreadyWithdrawn();
    error FundraiserNotEnded();
    error NotAuthorized();
    error TokenNotSet();
    error NothingToWithdraw();

    function withdrawWithFee(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address requester,
        address ownerAddr,
        address feeRecipient,
        uint16 withdrawFeeBps
    )
        internal
        returns (
            address creator,
            address token,
            uint256 paidNet,
            uint256 paidGross,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();
        if (f.fundsWithdrawn) revert AlreadyWithdrawn();

        timeEnded = (f.endDate != 0 && block.timestamp > f.endDate);
        isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        bool canWithdraw = isWithGoal ? (goalReached || (timeEnded && !goalReached)) : (!timeEnded);
        if (!canWithdraw) revert FundraiserNotEnded();

        creator = s.fundraiserCreators(fundraiserId);
        bool authorized = (requester == creator) || (requester == ownerAddr);
        if (!authorized) revert NotAuthorized();

        token = s.fundraiserTokens(fundraiserId);
        if (token == address(0)) revert TokenNotSet();

        // Compute available funds = raised - withdrawn - refunded (saturating at zero)
        uint256 withdrawnSoFar = s.totalWithdrawn(fundraiserId);
        uint256 refundedSoFar = s.totalRefunded(fundraiserId);
        uint256 accounted = withdrawnSoFar + refundedSoFar;
        uint256 available;
        if (accounted >= f.raisedAmount) {
            available = 0;
        } else {
            available = uint256(f.raisedAmount) - accounted;
        }
        if (available == 0) revert NothingToWithdraw();

        // Security tranching (limit to 'available')
        uint256 allowedNow = available;
        uint256 remaining = 0;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, remaining) =
                IPoliDaoSecurity(security).checkAndConsumeWithdraw(fundraiserId, creator, available);
            if (allowedNow == 0) revert("Security: payout tranche not available yet");
        }
        if (allowedNow == 0) revert NothingToWithdraw();

        // Fee on allowedNow (gross)
        uint256 fee = 0;
        if (feeRecipient != address(0) && withdrawFeeBps > 0) {
            fee = (allowedNow * withdrawFeeBps) / 10_000;
            if (fee > 0) s.releaseFunds(token, feeRecipient, fee);
        }
        paidNet = allowedNow - fee;
        s.releaseFunds(token, creator, paidNet);

        paidGross = allowedNow;

        // Atomically record gross withdrawal in storage (prevents re-withdraw)
        s.recordWithdrawal(fundraiserId, paidGross);

        // Księgowanie w module ACCOUNTING (bez dotykania Storage)
        address accounting = s.modules(keccak256("ACCOUNTING"));
        if (accounting != address(0)) {
            IPoliDaoAccounting(accounting).recordWithdrawal(fundraiserId, paidGross);
        }

        // Mark fully withdrawn if no further funds or tranches remain
        // Important nuance:
        // - For WITH_GOAL: mark fundsWithdrawn and set status to COMPLETED when all available funds are withdrawn
        //   (either goal reached or time ended path).
        // - For NO_GOAL (flex): do NOT permanently lock with fundsWithdrawn flag; new donations may arrive later.
        if (remaining == 0 && allowedNow == available) {
            if (isWithGoal || timeEnded) {
                f.fundsWithdrawn = true;
                // Best-effort status refresh similar to post-refund/donate state changes
                // Prefer COMPLETED when funds are fully drained for WITH_GOAL or after end.
                f.status = uint8(IPoliDaoStructs.FundraiserStatus.COMPLETED);
                s.updateFundraiser(fundraiserId, f);
            }
        }
    }

    // NEW: wrapper selecting proper fee tier and delegating to withdrawWithFee
    function executeWithdraw(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address requester,
        address ownerAddr,
        address feeRecipient,
        uint16 successWithdrawFeeBps,
        uint16 flexibleWithdrawFeeBps
    )
        internal
        returns (
            address creator,
            address token,
            uint256 paidNet,
            bool goalReached,
            bool timeEnded,
            bool isWithGoal
        )
    {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();

        timeEnded = (f.endDate != 0 && block.timestamp > f.endDate);
        isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        uint16 wFee = (isWithGoal && goalReached) ? successWithdrawFeeBps : flexibleWithdrawFeeBps;

        (creator, token, paidNet, /*gross*/, /*goalReachedAgain*/, /*timeEndedAgain*/, /*isWithGoalAgain*/) =
            withdrawWithFee(
                s,
                fundraiserId,
                requester,
                ownerAddr,
                feeRecipient,
                wFee
            );
    }
}

