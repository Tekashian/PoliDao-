// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "../interfaces/IPoliDaoAccounting.sol";

contract PoliDaoAccounting is Ownable, IPoliDaoAccounting {
    address public core;
    IPoliDaoStorage public storageContract;

    mapping(uint256 => uint256) private _withdrawn;
    mapping(uint256 => uint256) private _refunded;

    event WithdrawalRecorded(uint256 indexed fundraiserId, uint256 amount);
    event RefundRecorded(uint256 indexed fundraiserId, uint256 amount);

    modifier onlyCore() {
        require(msg.sender == core, "Accounting: only Core");
        _;
    }

    constructor(address storageAddr, address initialOwner) Ownable(initialOwner) {
        require(storageAddr != address(0), "Accounting: storage=0");
        storageContract = IPoliDaoStorage(storageAddr);
    }

    function setCore(address _core) external override onlyOwner {
        require(_core != address(0), "Accounting: core=0");
        core = _core;
    }

    function setStorage(address storageAddr) external override onlyOwner {
        require(storageAddr != address(0), "Accounting: storage=0");
        storageContract = IPoliDaoStorage(storageAddr);
    }

    function recordWithdrawal(uint256 fundraiserId, uint256 grossAmount) external override onlyCore {
        if (grossAmount == 0) return;
        _withdrawn[fundraiserId] += grossAmount;
        emit WithdrawalRecorded(fundraiserId, grossAmount);
    }

    function recordRefund(uint256 fundraiserId, uint256 amount) external override onlyCore {
        if (amount == 0) return;
        _refunded[fundraiserId] += amount;
        emit RefundRecorded(fundraiserId, amount);
    }

    function withdrawnAmount(uint256 fundraiserId) external view override returns (uint256) {
        return _withdrawn[fundraiserId];
    }

    function refundedAmount(uint256 fundraiserId) external view override returns (uint256) {
        return _refunded[fundraiserId];
    }

    function currentBalance(uint256 fundraiserId) external view override returns (uint256) {
        IPoliDaoStructs.PackedFundraiserData memory f = storageContract.fundraisers(fundraiserId);
        uint256 used = _withdrawn[fundraiserId] + _refunded[fundraiserId];
        return f.raisedAmount > used ? (f.raisedAmount - used) : 0;
    }
}