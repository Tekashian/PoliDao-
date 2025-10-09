// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract RefundsMock {
    event Registered(uint256 fundraiserId, bool isFlexible);
    event Initiated(uint256 fundraiserId, address creator, uint256 endDate);
    event Claimed(uint256 fundraiserId, address donor);

    function registerFundraiser(uint256 fundraiserId, bool isFlexible) external {
        emit Registered(fundraiserId, isFlexible);
    }

    function initiateClosure(uint256 fundraiserId, address creator, uint256 endDate) external {
        emit Initiated(fundraiserId, creator, endDate);
    }

    function claimRefund(uint256 fundraiserId, address donor) external {
        emit Claimed(fundraiserId, donor);
    }
}