// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPoliDaoRefunds.sol";
import "../interfaces/IPoliDaoStorage.sol";

// [FIX] Security interface – zgodna z użyciem (fundraiserId, actor, requestedAmount)
interface ISecurityRefunds {
    function checkAndConsumeRefund(
        uint256 fundraiserId,
        address actor,
        uint256 requestedAmount
    ) external returns (uint256 allowedNow, uint256 nextAt, uint256 remaining);
}

// [ADD] Minimalny widok na Core (storage + kwota darczyńcy)
interface ICoreView {
    function storageContract() external view returns (IPoliDaoStorage);
    function getDonationAmount(uint256 fundraiserId, address donor) external view returns (uint256);
    function feeRecipient() external view returns (address);
}

/**
 * @title PoliDaoRefunds
 * @notice Refunds management module (minimal, PoC)
 * @dev Keeps refund logic outside core; mainContract is the PoliDao core/router
 */
contract PoliDaoRefunds is Ownable, Pausable, ReentrancyGuard, IPoliDaoRefunds {
    // ========== CONSTANTS ==========
    uint256 public constant RECLAIM_PERIOD = 14 days;
    uint256 public constant MAX_REFUND_COMMISSION = 500; // 5% in bps

    // ========== STORAGE ==========
    address public mainContract;
    uint256 public refundCommission = 100; // 1% default
    address public commissionWallet;

    // Core binding (ACL)
    address public core;
    bool public coreFrozen;
    modifier onlyCore() {
        require(msg.sender == core, "Refunds: only Core");
        _;
    }
    function setCore(address _core) external onlyOwner {
        require(!coreFrozen, "Refunds: core frozen");
        require(_core != address(0), "Refunds: zero core");
        core = _core;
    }
    function freezeCore() external onlyOwner {
        require(core != address(0), "Refunds: core not set");
        coreFrozen = true;
    }

    // DODANE: event aktualizacji mainContract
    event MainContractUpdated(address indexed previous, address indexed current, address indexed caller);

    mapping(uint256 => mapping(address => bool)) public hasRefunded;
    mapping(uint256 => mapping(address => uint256)) public refundAmounts;
    mapping(uint256 => bool) public closureInitiated;
    mapping(uint256 => uint256) public reclaimDeadline;
    mapping(uint256 => bool) public isFlexibleFundraiser;
    mapping(uint256 => uint256) public totalWithdrawnByCreator;
    mapping(uint256 => bool) public isRefundsPaused;

    // Konfiguracja i stan okna refundów per użytkownik
    uint32 public refundWindowSeconds = 7 days;
    uint16 public refundRepeatFeeBps = 100; // 1% domyślnie
    mapping(uint256 => mapping(address => uint32)) public lastRefundAt;      // fundraiserId => donor => ts
    mapping(uint256 => mapping(address => uint8))  public refundsInWindow;   // fundraiserId => donor => count

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
        address prev = mainContract;
        require(prev != _newMainContract, "No change");
        mainContract = _newMainContract;
        emit MainContractUpdated(prev, _newMainContract, msg.sender);
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

    function setRefundFeeConfig(uint16 bps, uint32 windowSecs) external onlyOwner {
        require(bps <= 10_000, "bps too high");
        refundRepeatFeeBps = bps;
        refundWindowSeconds = windowSecs;
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
        uint256 amount,
        address token,
        uint8 mode,
        uint256 proof,
        bool waiveCommission
    )
        external
        nonReentrant
    {
        require(!hasRefunded[fundraiserId][donor], "Already refunded");
        require(amount > 0, "No donation to refund");

        _validateRefundConditionsInternal(fundraiserId, mode, proof, waiveCommission);

        hasRefunded[fundraiserId][donor] = true;
        refundAmounts[fundraiserId][donor] = amount;

        uint256 refundAmount = waiveCommission ? amount : (amount * (10000 - refundCommission)) / 10000;
        uint256 commission = amount - refundAmount;

        // Use storage as custodian: ask mainContract for storage address via getContractStatus()
        bytes memory statusData = abi.encodeWithSignature("getContractStatus()");
        (bool ok, bytes memory statusRes) = mainContract.staticcall(statusData);
    require(ok && statusRes.length >= 32, "Failed to lookup storage address");
    (address storageAddress, , , ) = abi.decode(statusRes, (address, address, address, bool));
    IPoliDaoStorage(storageAddress).releaseFunds(token, commissionWallet, commission);
    IPoliDaoStorage(storageAddress).releaseFunds(token, donor, refundAmount);

        // Emit BEFORE external interactions
        emit RefundProcessed(fundraiserId, donor, refundAmount, commission);
    }

    function initiateClosure(uint256 fundraiserId, address creator, uint256 endDate) external onlyCore {
        require(!isFlexibleFundraiser[fundraiserId], "Flexible fundraisers cannot initiate closure");
        require(block.timestamp > endDate, "Fundraiser still active");
        require(!closureInitiated[fundraiserId], "Closure already initiated");

        closureInitiated[fundraiserId] = true;
        reclaimDeadline[fundraiserId] = block.timestamp + RECLAIM_PERIOD;

        emit ClosureInitiated(fundraiserId, reclaimDeadline[fundraiserId], creator);
    }

    function processFlexibleWithdrawal(
        uint256 fundraiserId,
        address creator,
        uint256 withdrawAmount,
        address token
    )
        external
        nonReentrant
    {
        require(isFlexibleFundraiser[fundraiserId], "Not a flexible fundraiser");
        require(withdrawAmount > 0, "Nothing to withdraw");

        totalWithdrawnByCreator[fundraiserId] += withdrawAmount;
        // Use storage to release funds
        bytes memory statusData2 = abi.encodeWithSignature("getContractStatus()");
        (bool ok2, bytes memory statusRes2) = mainContract.staticcall(statusData2);
    require(ok2 && statusRes2.length >= 32, "Failed to lookup storage address");
    (address storageAddress, , , ) = abi.decode(statusRes2, (address, address, address, bool));
    IPoliDaoStorage(storageAddress).releaseFunds(token, creator, withdrawAmount);

        // Emit BEFORE external interactions
        emit FlexibleWithdrawal(fundraiserId, creator, withdrawAmount, totalWithdrawnByCreator[fundraiserId]);
    }

    function claimRefund(uint256 fundraiserId, address donor) external nonReentrant onlyCore {
        IPoliDaoStorage s = ICoreView(core).storageContract();
        address token = s.fundraiserTokens(fundraiserId);

        uint256 amount = _calculateRefundAmount(fundraiserId, donor);
        require(amount > 0, "Nothing to refund");

        uint256 allowedNow = amount;
        address security = s.modules(keccak256("SECURITY"));
        if (security != address(0)) {
            (allowedNow, /*nextAt*/, /*remaining*/) =
                ISecurityRefunds(security).checkAndConsumeRefund(fundraiserId, donor, amount);
        }
        require(allowedNow > 0, "Nothing to refund now");

        uint256 fee = 0;
        uint32 nowTs = uint32(block.timestamp);
        uint32 lastTs = lastRefundAt[fundraiserId][donor];
        uint8 count = refundsInWindow[fundraiserId][donor];

        if (lastTs == 0 || nowTs > lastTs + refundWindowSeconds) {
            lastRefundAt[fundraiserId][donor] = nowTs;
            refundsInWindow[fundraiserId][donor] = 1;
        } else {
            count += 1;
            refundsInWindow[fundraiserId][donor] = count;
            lastRefundAt[fundraiserId][donor] = nowTs;
            if (count >= 2 && refundRepeatFeeBps > 0) {
                fee = (allowedNow * refundRepeatFeeBps) / 10_000;
            }
        }

        if (fee > 0) s.releaseFunds(token, commissionWallet, fee);
        uint256 net = allowedNow - fee;
        s.releaseFunds(token, donor, net);

        // TODO: emit event (np. RefundClaimed)
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

    // [ADD] lokalny helper – wylicza kwotę refundu z Core/Storage
    function _calculateRefundAmount(uint256 fundraiserId, address donor) internal view returns (uint256) {
        // zakładamy, że Core implementuje getDonationAmount(...)
        uint256 amt = ICoreView(core).getDonationAmount(fundraiserId, donor);
        return amt;
    }
}