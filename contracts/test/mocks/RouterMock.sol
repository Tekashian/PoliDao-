// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPoliDaoCore {
    function refundFor(uint256 fundraiserId, address donor) external;
}

contract RouterMock {
    function callRefundFor(address core, uint256 fundraiserId, address donor) external {
        IPoliDaoCore(core).refundFor(fundraiserId, donor);
    }
}