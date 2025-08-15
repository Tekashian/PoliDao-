// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IPoliDaoRefunds.sol";
import "../interfaces/IPoliDaoStorage.sol";

/**
 * @title PoliDaoRefunds
 * @notice Refunds management module (minimal, PoC)
 * @dev Keeps refund logic outside core; mainContract is the PoliDao core/router
 */
contract PoliDaoRefunds is Ownable, Pausable, IPoliDaoRefunds {
    // ========== CONSTANTS ==========
    uint256 public constant RECLAIM_PERIOD = 14 days;
    uint256 public constant MAX_REFUND_COMMISSION = 500; // 5% in bps

    // ========== STORAGE ==========
    address public mainContract;
    uint256 public refundCommission = 100; // 1% default
    address public commissionWallet;

    mapping(uint256 => mapping(address => bool)) public hasRefunded;
    mapping(uint256 => mapping(address => uint256)) public refundAmounts;
    mapping(uint256 => bool) public closureInitiated;
    mapping(uint256 => uint256) public reclaimDeadline;
    mapping(uint256 => bool) public isFlexibleFundraiser;
    mapping(uint256 => uint256) public totalWithdrawnByCreator;
    mapping(uint256 => bool) public isRefundsPaused;

    constructor(address _mainContract, address _commissionWallet) Ownable(msg.sender) {
        require(_mainContract != address(0), "Invalid main contract");
        require(_commissionWallet != address(0), "Invalid commission wallet");
        mainContract = _mainContract;
        commissionWallet = _commissionWallet;
    }

    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }

    // ========== ADMIN ==========
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        mainContract = _newMainContract;
    }

    function setRefundCommission(uint256 _commission) external onlyOwner {
        require(_commission <= MAX_REFUND_COMMISSION, "Commission too high");
        refundCommission = _commission;
        emit RefundCommissionSet(_commission);
    }

    function setCommissionWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid wallet");
        commissionWallet = _newWallet;
    }

    function pauseRefundsForFundraiser(uint256 fundraiserId) external onlyOwner {
        isRefundsPaused[fundraiserId] = true;
        emit RefundsPausedForFundraiser(fundraiserId);
    }

    function unpauseRefundsForFundraiser(uint256 fundraiserId) external onlyOwner {
        isRefundsPaused[fundraiserId] = false;
        emit RefundsUnpausedForFundraiser(fundraiserId);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ========== MAIN CONTRACT INTEGRATION ==========
    function registerFundraiser(uint256 fundraiserId, bool isFlexible) external onlyMainContract {
        isFlexibleFundraiser[fundraiserId] = isFlexible;
    }

    // ========== VALIDATION ==========
    function validateRefundConditions(
        uint256 fundraiserId,
        uint256 /* fundraiserStatus */,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external view {
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers don't allow refunds");
        require(!goalReached, "Goal reached - no refunds available");
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        if (closureInitiated[fundraiserId]) {
            require(block.timestamp <= reclaimDeadline[fundraiserId], "Reclaim period expired");
        }
    }

    function _validateRefundConditionsInternal(
        uint256 fundraiserId,
        uint256 /* fundraiserStatus */,
        uint256 fundraiserEndTime,
        bool goalReached
    ) internal view {
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers don't allow refunds");
        require(!goalReached, "Goal reached - no refunds available");
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        if (closureInitiated[fundraiserId]) {
            require(block.timestamp <= reclaimDeadline[fundraiserId], "Reclaim period expired");
        }
    }

    // ========== REFUND PROCESSING ==========
    function processRefund(
        uint256 fundraiserId,
        address donor,
        uint256 donationAmount,
        address token,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external whenNotPaused onlyMainContract {
        require(!hasRefunded[fundraiserId][donor], "Already refunded");
        require(donationAmount > 0, "No donation to refund");

        _validateRefundConditionsInternal(fundraiserId, fundraiserStatus, fundraiserEndTime, goalReached);

        hasRefunded[fundraiserId][donor] = true;
        refundAmounts[fundraiserId][donor] = donationAmount;

        uint256 commission = (donationAmount * refundCommission) / 10000;
        uint256 refundAmount = donationAmount - commission;

        // Use storage as custodian: ask mainContract for storage address via getContractStatus()
        bytes memory statusData = abi.encodeWithSignature("getContractStatus()");
        (bool ok, bytes memory statusRes) = mainContract.staticcall(statusData);
    require(ok && statusRes.length >= 32, "Failed to lookup storage address");
    (address storageAddress, , , ) = abi.decode(statusRes, (address, address, address, bool));
    IPoliDaoStorage(storageAddress).releaseFunds(token, commissionWallet, commission);
    IPoliDaoStorage(storageAddress).releaseFunds(token, donor, refundAmount);

        emit RefundProcessed(fundraiserId, donor, refundAmount, commission);
    }

    function initiateClosure(uint256 fundraiserId, address creator, uint256 fundraiserEndTime) external whenNotPaused onlyMainContract {
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers cannot initiate closure");
        require(block.timestamp > fundraiserEndTime, "Fundraiser still active");
        require(!closureInitiated[fundraiserId], "Closure already initiated");

        closureInitiated[fundraiserId] = true;
        reclaimDeadline[fundraiserId] = block.timestamp + RECLAIM_PERIOD;

        emit ClosureInitiated(fundraiserId, reclaimDeadline[fundraiserId], creator);
    }

    function processFlexibleWithdrawal(uint256 fundraiserId, address creator, uint256 withdrawAmount, address token) external whenNotPaused onlyMainContract {
        require(isFlexibleFundraiser[fundraiserId], "Not a flexible fundraiser");
        require(withdrawAmount > 0, "Nothing to withdraw");

        totalWithdrawnByCreator[fundraiserId] += withdrawAmount;
        // Use storage to release funds
        bytes memory statusData2 = abi.encodeWithSignature("getContractStatus()");
        (bool ok2, bytes memory statusRes2) = mainContract.staticcall(statusData2);
    require(ok2 && statusRes2.length >= 32, "Failed to lookup storage address");
    (address storageAddress, , , ) = abi.decode(statusRes2, (address, address, address, bool));
    IPoliDaoStorage(storageAddress).releaseFunds(token, creator, withdrawAmount);

        emit FlexibleWithdrawal(fundraiserId, creator, withdrawAmount, totalWithdrawnByCreator[fundraiserId]);
    }

    // ========== VIEWS ==========
    function canRefund(
        uint256 fundraiserId,
        address donor,
        uint256 donationAmount,
        uint8 fundraiserStatus,
        uint256 fundraiserEndTime,
        bool goalReached
    ) external view returns (bool canRefundResult, string memory reason) {
        if (hasRefunded[fundraiserId][donor]) return (false, "Already refunded");
        if (donationAmount == 0) return (false, "No donation found");
        if (isRefundsPaused[fundraiserId]) return (false, "Refunds paused");
        try this.validateRefundConditions(fundraiserId, fundraiserStatus, fundraiserEndTime, goalReached) {
            return (true, "Refund available");
        } catch {
            if (isFlexibleFundraiser[fundraiserId]) return (false, "Flexible fundraisers don't allow refunds");
            if (goalReached) return (false, "Goal reached - no refunds");
            if (block.timestamp <= fundraiserEndTime) return (false, "Fundraiser still active");
            if (closureInitiated[fundraiserId] && block.timestamp > reclaimDeadline[fundraiserId]) return (false, "Reclaim period expired");
            return (false, "Refund not available");
        }
    }

    function getRefundInfo(uint256 fundraiserId, address donor) external view returns (bool, uint256, bool, uint256, bool) {
        return (hasRefunded[fundraiserId][donor], refundAmounts[fundraiserId][donor], closureInitiated[fundraiserId], reclaimDeadline[fundraiserId], isFlexibleFundraiser[fundraiserId]);
    }

    function getFlexibleInfo(uint256 fundraiserId) external view returns (bool, uint256) {
        return (isFlexibleFundraiser[fundraiserId], totalWithdrawnByCreator[fundraiserId]);
    }
}