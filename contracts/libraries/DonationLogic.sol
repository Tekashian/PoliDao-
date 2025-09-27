// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPoliDaoStorage.sol";

library DonationLogic {
    using SafeERC20 for IERC20;

    // Transferuje token do Storage, obsługuje fee-on-transfer; zwraca realnie otrzymaną kwotę
    function donate(
        IPoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        uint256 amount
    ) public returns (uint256 received) {
        require(amount > 0, "Donation: zero amount");
        address token = s.fundraiserTokens(fundraiserId);
        require(token != address(0), "Donation: invalid fundraiser");

        uint256 balBefore = IERC20(token).balanceOf(address(s));
        IERC20(token).safeTransferFrom(donor, address(s), amount);
        uint256 balAfter = IERC20(token).balanceOf(address(s));

        received = balAfter - balBefore;
        require(received > 0, "Donation: nothing received");

        s.addDonation(fundraiserId, donor, received);
        return received;
    }
}