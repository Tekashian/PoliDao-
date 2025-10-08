// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoSecurity.sol"; // [ADD] Security interface

library WithdrawLogic {
    error FundraiserNotFound();
    error AlreadyWithdrawn();
    error FundraiserNotEnded();
    error TokenNotSet();
    error NothingToWithdraw();
    error NotAuthorized();

    // authorized przekazuje Core (mniej zależności od interfejsu Storage)
    function withdraw(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address requester,
        address ownerAddr
    ) public returns (address creator, address token, uint256 amount) {
        IPoliDaoStructs.PackedFundraiserData memory f = s.fundraisers(fundraiserId);
        if (f.id == 0) revert FundraiserNotFound();
        if (f.fundsWithdrawn) revert AlreadyWithdrawn();

        // [ADD] Dopuszczamy natychmiastową wypłatę po osiągnięciu celu (WITH_GOAL)
        bool ended = (f.endDate == 0 || block.timestamp > f.endDate || f.isFlexible);
        bool goalReached = (
            f.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL) &&
            f.goalAmount > 0 &&
            f.raisedAmount >= f.goalAmount
        );

        // Stara reguła: tylko po endDate; Nowa: także, gdy osiągnięto cel
        if (!(ended || goalReached)) revert FundraiserNotEnded();

        creator = s.fundraiserCreators(fundraiserId);
        bool authorized = (requester == creator) || (requester == ownerAddr);
        if (!authorized) revert NotAuthorized();

        token = s.fundraiserTokens(fundraiserId);
        uint256 requested = uint256(f.raisedAmount);
        if (token == address(0)) revert TokenNotSet();
        if (requested == 0) revert NothingToWithdraw();

        // [ADD] Tranching przez Security module (jeśli ustawiony w Storage.modules["SECURITY"])
        uint256 allowedNow = requested;
        uint256 remaining = 0;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, remaining) = IPoliDaoSecurity(security).checkAndConsumeWithdraw(
                fundraiserId,
                creator,
                requested
            );
        }
        if (allowedNow == 0) revert NothingToWithdraw();

        // Transfer tylko bieżącej transzy
        s.releaseFunds(token, creator, allowedNow);

        // [CHANGE] Ustaw fundsWithdrawn tylko gdy:
        // - kampania faktycznie się skończyła (stary warunek), albo
        // - w ścieżce "goal reached" Security wyczerpał bieżący harmonogram (remaining == 0)
        //   dzięki czemu ta “pula” (requested) została w pełni wypłacona.
        if (ended || (goalReached && remaining == 0)) {
            f.fundsWithdrawn = true;
            s.updateFundraiser(fundraiserId, f);
        }

        // Zwracamy faktycznie wypłaconą transzę
        amount = allowedNow;
        return (creator, token, amount);
    }
}

