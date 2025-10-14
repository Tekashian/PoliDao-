// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol"; // added for enum / struct access

library DonationLogic {
    using SafeERC20 for IERC20;

    function donateWithFee(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        uint256 amount,
        address feeRecipient,
        uint16 donationFeeBps
    ) internal returns (uint256 receivedNet) {
        require(amount > 0, "Donation: zero amount");
        address token = s.fundraiserTokens(fundraiserId);
        require(token != address(0), "Donation: invalid fundraiser");

        uint256 balBefore = IERC20(token).balanceOf(address(s));
        IERC20(token).safeTransferFrom(donor, address(s), amount);
        uint256 balAfter = IERC20(token).balanceOf(address(s));

        uint256 receivedGross = balAfter - balBefore;
        require(receivedGross > 0, "Donation: nothing received");

        uint256 fee = 0;
        if (feeRecipient != address(0) && donationFeeBps > 0) {
            fee = (receivedGross * donationFeeBps) / 10_000;
            if (fee > 0) {
                s.releaseFunds(token, feeRecipient, fee);
            }
        }

        receivedNet = receivedGross - fee;
        require(receivedNet > 0, "Donation: net is zero");

        // Księgowanie przeniesione do Core (Storage.addDonation)
        return receivedNet;
    }

    // NEW: unified donation processor (used by Core.donate / donateFrom / batchDonateFrom)
    function processDonation(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        uint256 amount,
        address feeRecipient,
        uint16 donationFeeBps
    ) internal returns (uint256 receivedNet, address token, uint256 newRaised) {
        if (amount == 0) revert("Donation: zero amount");

        IPoliDaoStructs.PackedFundraiserData memory fPrev = s.fundraisers(fundraiserId);
        if (fPrev.id == 0) revert("Donation: fundraiser not found");

        bool timeEnded = (fPrev.endDate != 0 && block.timestamp > fPrev.endDate);
        bool isWithGoal = (fPrev.fundraiserType == uint8(IPoliDaoStructs.FundraiserType.WITH_GOAL));
        bool goalReached = (isWithGoal && fPrev.goalAmount > 0 && fPrev.raisedAmount >= fPrev.goalAmount);

        if (fPrev.fundsWithdrawn) revert("Donation: closed");
        if (!isWithGoal && timeEnded) revert("Donation: ended");
        if (isWithGoal && timeEnded && !goalReached) revert("Donation: ended");

        token = s.fundraiserTokens(fundraiserId);
        if (token == address(0)) revert("Donation: token unset");

        uint256 received = donateWithFee(
            s,
            fundraiserId,
            donor,
            amount,
            feeRecipient,
            donationFeeBps
        );

        // Record donation (Core context => msg.sender = Core, passes onlyCore)
        s.addDonation(fundraiserId, donor, received);

        newRaised = uint256(fPrev.raisedAmount) + received;
        receivedNet = received;
    }
}