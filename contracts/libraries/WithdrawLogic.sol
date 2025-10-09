// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoSecurity.sol";

library WithdrawLogic {
    error FundraiserNotFound();
    error AlreadyWithdrawn();
    error FundraiserNotEnded();
    error TokenNotSet();
    error NothingToWithdraw();
    error NotAuthorized();

    function withdrawWithFee(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address requester,
        address ownerAddr,
        address feeRecipient,
        uint16 withdrawFeeBps
    ) internal returns (
        address creator,
        address token,
        uint256 paidNet,
        uint256 paidGross,
        bool goalReached,
        bool timeEnded,
        bool isWithGoal
    ) {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();
        if (f.fundsWithdrawn) revert AlreadyWithdrawn();

        timeEnded = (f.endDate != 0 && block.timestamp > f.endDate);
        isWithGoal = (f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        goalReached = (isWithGoal && f.goalAmount > 0 && f.raisedAmount >= f.goalAmount);

        // WITH_GOAL: goalReached || (timeEnded && !goalReached)
        // NO_GOAL:   tylko przed endDate
        bool canWithdraw = isWithGoal ? (goalReached || (timeEnded && !goalReached)) : (!timeEnded);
        if (!canWithdraw) revert FundraiserNotEnded();

        creator = s.fundraiserCreators(fundraiserId);
        bool authorized = (requester == creator) || (requester == ownerAddr);
        if (!authorized) revert NotAuthorized();

        token = s.fundraiserTokens(fundraiserId);
        if (token == address(0)) revert TokenNotSet();

        uint256 requested = uint256(f.raisedAmount);
        if (requested == 0) revert NothingToWithdraw();

        // Security tranching
        uint256 allowedNow = requested;
        uint256 remaining = 0;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, remaining) =
                IPoliDaoSecurity(security).checkAndConsumeWithdraw(fundraiserId, creator, requested);
        }
        if (allowedNow == 0) revert NothingToWithdraw();

        // Fee
        uint256 fee = 0;
        if (feeRecipient != address(0) && withdrawFeeBps > 0) {
            fee = (allowedNow * withdrawFeeBps) / 10_000;
            if (fee > 0) s.releaseFunds(token, feeRecipient, fee);
        }

        uint256 net = allowedNow - fee;
        s.releaseFunds(token, creator, net);

        // Zamknięcie kampanii z celem po pełnej wypłacie sukcesu
        if (isWithGoal && goalReached && remaining == 0) {
            f.fundsWithdrawn = true;
            s.updateFundraiser(fundraiserId, f);
        }

        paidGross = allowedNow;
        paidNet = net;
    }
}

