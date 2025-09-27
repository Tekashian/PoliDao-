// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";

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
        if (!(f.endDate == 0 || block.timestamp > f.endDate || f.isFlexible)) revert FundraiserNotEnded();

        creator = s.fundraiserCreators(fundraiserId);
        bool authorized = (requester == creator) || (requester == ownerAddr);
        // Jeżeli potrzebujesz dodatkowych ról, sprawdzaj w Core i wywołuj tę bibliotekę tylko gdy authorized == true
        if (!authorized) revert NotAuthorized();

        token = s.fundraiserTokens(fundraiserId);
        amount = uint256(f.raisedAmount);
        if (token == address(0)) revert TokenNotSet();
        if (amount == 0) revert NothingToWithdraw();

        // Transfer + aktualizacja flagi withdrawn w Packed struct
        s.releaseFunds(token, creator, amount);
        f.fundsWithdrawn = true;
        s.updateFundraiser(fundraiserId, f);

        return (creator, token, amount);
    }
}

