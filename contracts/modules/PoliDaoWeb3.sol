// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../interfaces/IPoliDao.sol";
import "../interfaces/IPoliDaoWeb3.sol";

contract PoliDaoWeb3
is IPoliDaoWeb3
, Ownable
, Pausable
, ReentrancyGuard
, EIP712
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ========== EVENTS (ADDED) ==========
    // Slither: missing event for setMainContract
    event MainContractUpdated(address indexed previous, address indexed current, address indexed caller);
    // (MetaTxRateLimitUpdated already declared in interface and will now be emitted)

    // ========== CONSTANTS ==========
    
    bytes32 private constant DONATION_TYPEHASH = keccak256(
        "Donation(address donor,uint256 fundraiserId,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    
    uint256 public constant MAX_BATCH_SIZE = 20;
    uint256 public constant MAX_META_TX_DELAY = 1 hours;

    // ========== STORAGE ==========
    
    address public mainContract;
    
    // Meta-transaction support
    mapping(address => uint256) public nonces;
    
    // Batch operations tracking
    mapping(bytes32 => bool) public executedBatches;
    
    // Relayer management
    mapping(address => bool) public authorizedRelayers;
    mapping(address => uint256) public relayerGasLimits;
    
    // Rate limiting for meta-transactions
    mapping(address => mapping(uint256 => uint256)) public hourlyMetaTxCount;
    uint256 public maxMetaTxPerHour = 10;

    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    modifier onlyAuthorizedRelayer() {
        require(authorizedRelayers[msg.sender], "Not authorized relayer");
        _;
    }
    
    modifier validBatchSize(uint256 size) {
        require(size > 0 && size <= MAX_BATCH_SIZE, "Invalid batch size");
        _;
    }
    
    modifier metaTxRateLimit(address user) {
        uint256 currentHour = block.timestamp / 1 hours;
        require(
            hourlyMetaTxCount[user][currentHour] < maxMetaTxPerHour,
            "Meta-tx rate limit exceeded"
        );
        hourlyMetaTxCount[user][currentHour]++;
        _;
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(
        // ...existing params...
    )
        Ownable(msg.sender)
        EIP712("PoliDaoWeb3", "1")
    {
        // ...existing code...
    }

    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        // ADDED: zero address + no-change guards + event
        require(_newMainContract != address(0), "Invalid address");
        address prev = mainContract;
        require(prev != _newMainContract, "No change");
        mainContract = _newMainContract;
        emit MainContractUpdated(prev, _newMainContract, msg.sender);
    }
    
    function authorizeRelayer(address relayer, uint256 gasLimit) external onlyOwner {
        require(relayer != address(0), "Invalid relayer");
        authorizedRelayers[relayer] = true;
        relayerGasLimits[relayer] = gasLimit;
        // emit RelayerAuthorized(relayer, gasLimit);
    }
    
    function revokeRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = false;
        delete relayerGasLimits[relayer];
        // emit RelayerRevoked(relayer);
    }
    
    function setMetaTxRateLimit(uint256 newLimit) external onlyOwner {
        // ADDED: validation + no-change + event emission
        require(newLimit > 0, "Invalid limit");
        uint256 prev = maxMetaTxPerHour;
        require(prev != newLimit, "No change");
        maxMetaTxPerHour = newLimit;
        emit MetaTxRateLimitUpdated(prev, newLimit);
    }

    // ========== EIP-2612 PERMIT DONATIONS ==========
    
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // Get fundraiser token from main contract
        address token = _getFundraiserToken(fundraiserId);

        IERC20Permit(token).permit(msg.sender, address(this), amount, deadline, v, r, s);
        IERC20(token).safeTransferFrom(msg.sender, mainContract, amount);

        // Call main contract donation logic (bez low-level call)
        IPoliDao(mainContract).donate(fundraiserId, amount);
        
        emit DonationMadeWithPermit(fundraiserId, msg.sender, token, amount);
    }

    // ========== META-TRANSACTIONS ==========
    
    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant metaTxRateLimit(donor) {
        require(block.timestamp <= deadline, "Meta-tx expired");
        require(deadline <= block.timestamp + MAX_META_TX_DELAY, "Deadline too far");
        
        // Verify signature
        bytes32 structHash = keccak256(
            abi.encode(
                DONATION_TYPEHASH,
                donor,
                fundraiserId,
                amount,
                nonces[donor]++,
                deadline
            )
        );
        
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);
        require(signer == donor, "Invalid signature");
        
        // Get fundraiser token
        address token = _getFundraiserToken(fundraiserId);

        // Kluczowa zmiana: zawsze from = msg.sender
        IERC20(token).safeTransferFrom(msg.sender, mainContract, amount);

        // Call main contract donation logic (bez low-level call)
        IPoliDao(mainContract).donate(fundraiserId, amount);
        
        emit DonationMadeWithMetaTx(fundraiserId, donor, msg.sender, amount);
    }

    // ========== BATCH OPERATIONS ==========
    
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external nonReentrant validBatchSize(fundraiserIds.length) {
        require(fundraiserIds.length == amounts.length, "Array length mismatch");
        
        // Generate unique batch ID
        bytes32 batchId = keccak256(
            abi.encode(
                msg.sender,
                block.timestamp,
                fundraiserIds,
                amounts,
                nonces[msg.sender]++
            )
        );
        require(!executedBatches[batchId], "Batch already executed");
        executedBatches[batchId] = true;
        
        uint256 totalAmount = 0;
        
        // Execute each donation
        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            require(amounts[i] > 0, "Zero amount");
            
            // Get fundraiser token
            address token = _getFundraiserToken(fundraiserIds[i]);
            
            // Transfer tokens to main contract
            IERC20(token).safeTransferFrom(msg.sender, mainContract, amounts[i]);
            
            // Call main contract donation logic (bez low-level call)
            IPoliDao(mainContract).donate(fundraiserIds[i], amounts[i]);
            
            totalAmount += amounts[i];
        }
        
        emit BatchDonationExecuted(batchId, msg.sender, totalAmount);
    }
    
    // Pomocnicza: wylicza wspólny token i sumę kwot; weryfikuje zgodność długości i tokenów
    function _aggregateTokenAndTotal(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) internal view returns (address token, uint256 totalAmount) {
        uint256 len = fundraiserIds.length;
        require(len == amounts.length, "Web3: length mismatch");

        token = _getFundraiserToken(fundraiserIds[0]);
        for (uint256 i = 0; i < len; ) {
            require(_getFundraiserToken(fundraiserIds[i]) == token, "Web3: mixed tokens");
            totalAmount += amounts[i];
            unchecked { ++i; }
        }
    }

    // Pomocnicza: wykonuje serię permitów (zmniejsza presję na stos)
    function _applyPermits(
        address token,
        address tokenOwner,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) internal {
        uint256 len = amounts.length;
        require(
            len == deadlines.length &&
            len == vs.length &&
            len == rs.length &&
            len == ss.length,
            "Web3: permit arrays mismatch"
        );

        for (uint256 i = 0; i < len; ) {
            IERC20Permit(token).permit(
                tokenOwner,
                address(this),
                amounts[i],
                deadlines[i],
                vs[i],
                rs[i],
                ss[i]
            );
            unchecked { ++i; }
        }
    }

    function batchDonateWithPermits(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external nonReentrant validBatchSize(fundraiserIds.length) {
        // 1) Wylicz token i sumę
        (address token, uint256 totalAmount) = _aggregateTokenAndTotal(fundraiserIds, amounts);

        // 2) Permity (każda pozycja osobno – zachowujemy dotychczasową semantykę)
        _applyPermits(token, msg.sender, amounts, deadlines, vs, rs, ss);

        // 3) Jeden transfer za całość (tak jak wcześniej)
        IERC20(token).safeTransferFrom(msg.sender, mainContract, totalAmount);

        // 4) Wołanie logiki głównej (bez low-level call)
        IPoliDao(mainContract).donate(fundraiserIds[0], totalAmount);
        
        emit BatchDonationExecuted(
            keccak256(abi.encode(msg.sender, block.timestamp, fundraiserIds, amounts, nonces[msg.sender])),
            msg.sender,
            totalAmount
        );
    }

    // ========== UTILITY FUNCTIONS ==========
    
    function supportsPermit(address token) external view returns (bool) {
        try IERC20Permit(token).DOMAIN_SEPARATOR() returns (bytes32 ds) {
            return ds != bytes32(0);
        } catch {
            return false;
        }
    }
    
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }
    
    function verifyDonationSignature(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (bool) {
        if (block.timestamp > deadline) return false;
        
        bytes32 structHash = keccak256(
            abi.encode(
                DONATION_TYPEHASH,
                donor,
                fundraiserId,
                amount,
                nonces[donor],
                deadline
            )
        );
        
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = hash.recover(signature);
        return signer == donor;
    }
    
    function getMetaTxCount(address user, uint256 hour) external view returns (uint256) {
        return hourlyMetaTxCount[user][hour];
    }
    
    function canExecuteMetaTx(address user) external view returns (bool) {
        uint256 currentHour = block.timestamp / 1 hours;
        return hourlyMetaTxCount[user][currentHour] < maxMetaTxPerHour;
    }
    
    function isBatchExecuted(bytes32 batchId) external view returns (bool) {
        return executedBatches[batchId];
    }
    
    function calculateBatchId(
        address donor,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                donor,
                block.timestamp,
                fundraiserIds,
                amounts,
                nonces[donor]
            )
        );
    }

    // ========== INTERNAL FUNCTIONS ==========
    
    function _getFundraiserToken(uint256 fundraiserId) internal view returns (address) {
        (, address token, , , , ,) = IPoliDao(mainContract).getFundraiserData(fundraiserId);
        return token;
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        
        if (token == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
    
    function invalidateNonce(address user) external onlyOwner {
        nonces[user]++;
    }
    
    function clearBatch(bytes32 batchId) external onlyOwner {
        delete executedBatches[batchId];
    }

    // ========== ETH HANDLING ==========
    
    /**
     * @notice Handle direct ETH transfers - reject them as we only work with ERC20 tokens
     */
    receive() external payable {
        revert("Direct ETH transfers not supported");
    }
    
    /**
     * @notice Handle calls to non-existent functions
     */
    fallback() external payable {
        revert("Function not found");
    }
}