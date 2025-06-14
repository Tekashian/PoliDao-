// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../PoliDao.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReentrancyAttackMock
 * @notice Kontrakt testowy do symulacji ataku reentrancy na kontrakt PoliDAO
 */
contract ReentrancyAttackMock {
    PoliDAO public dao;
    uint256 public targetFundraiser;
    bool public attackWithdraw;
    address public token;

    constructor(address _dao, address _token) {
        dao = PoliDAO(_dao);
        token = _token;
    }

    function attack(uint256 _fundraiserId, bool _attackWithdraw) external {
        targetFundraiser = _fundraiserId;
        attackWithdraw = _attackWithdraw;

        uint256 amount = 100 ether;

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(address(dao), amount);

        dao.donate(_fundraiserId, amount);

        if (_attackWithdraw) {
            dao.withdraw(_fundraiserId);
        } else {
            dao.refund(_fundraiserId);
        }
    }

    fallback() external {
        if (attackWithdraw) {
            dao.withdraw(targetFundraiser);
        } else {
            dao.refund(targetFundraiser);
        }
    }
}
