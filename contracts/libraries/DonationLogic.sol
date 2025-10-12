// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPoliDaoStorage.sol";

library DonationLogic {
    using SafeERC20 for IERC20;

    function donateWithFee(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        uint256 amount,
        address feeRecipient,
        uint16 donationFeeBps
    ) public returns (uint256 receivedNet) {
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
}