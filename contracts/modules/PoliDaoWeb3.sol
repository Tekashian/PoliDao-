// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoWeb3 - POPRAWIONA WERSJA
 * @notice Modern Web3 features module for PoliDAO
 * @dev Handles EIP-2612 permits, meta-transactions, batch operations, and multicall
 * @dev USUNIĘTO DUPLIKOWANE EVENTY - używamy tylko z IPoliDaoStructs
 */
contract PoliDaoWeb3 is Ownable, Pausable, ReentrancyGuard, EIP712, Multicall, IPoliDaoStructs {
    using ECDSA for bytes32;

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

    // ========== EVENTS - USUNIĘTO DUPLIKATY ==========
    // DonationMadeWithPermit i DonationMadeWithMetaTx są już w IPoliDaoStructs
    
    event RelayerAuthorized(address indexed relayer, uint256 gasLimit);
    event RelayerRevoked(address indexed relayer);
    event MetaTxRateLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event PermitSupportDetected(address indexed token, bool supported);

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
    
    constructor(address _mainContract) 
        Ownable(msg.sender) 
        EIP712("PoliDAO", "1") 
    {
        require(_mainContract != address(0), "Invalid main contract");
        mainContract = _mainContract;
    }

    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    
    function setMainContract(address _newMainContract) external onlyOwner {
        require(_newMainContract != address(0), "Invalid address");
        mainContract = _newMainContract;
    }
    
    function authorizeRelayer(address relayer, uint256 gasLimit) external onlyOwner {
        require(relayer != address(0), "Invalid relayer");
        authorizedRelayers[relayer] = true;
        relayerGasLimits[relayer] = gasLimit;
        emit RelayerAuthorized(relayer, gasLimit);
    }
    
    function revokeRelayer(address relayer) external onlyOwner {
        authorizedRelayers[relayer] = false;
        delete relayerGasLimits[relayer];
        emit RelayerRevoked(relayer);
    }
    
    function setMetaTxRateLimit(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = maxMetaTxPerHour;
        maxMetaTxPerHour = newLimit;
        emit MetaTxRateLimitUpdated(oldLimit, newLimit);
    }

    // ========== EIP-2612 PERMIT DONATIONS ==========
    
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) 
        external 
        whenNotPaused 
        nonReentrant
    {
        // Get fundraiser token from main contract
        address token = _getFundraiserToken(fundraiserId);
        
        // Execute permit
        IERC20Permit(token).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            v,
            r,
            s
        );
        
        // Execute donation through main contract
        IERC20(token).transferFrom(msg.sender, mainContract, amount);
        
        // Call main contract donation logic
        bytes memory data = abi.encodeWithSignature(
            "donate(uint256,uint256)",
            fundraiserId,
            amount
        );
        (bool success, ) = mainContract.call(data);
        require(success, "Donation failed");
        
        emit DonationMadeWithPermit(fundraiserId, msg.sender, token, amount);
    }

    // ========== META-TRANSACTIONS ==========
    
    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) 
        external 
        whenNotPaused 
        onlyAuthorizedRelayer
        metaTxRateLimit(donor)
        nonReentrant
    {
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
        
        // Execute donation
        IERC20(token).transferFrom(donor, mainContract, amount);
        
        // Call main contract donation logic
        bytes memory data = abi.encodeWithSignature(
            "donate(uint256,uint256)",
            fundraiserId,
            amount
        );
        (bool success, ) = mainContract.call(data);
        require(success, "Donation failed");
        
        emit DonationMadeWithMetaTx(fundraiserId, donor, msg.sender, amount);
    }

    // ========== BATCH OPERATIONS ==========
    
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) 
        external 
        whenNotPaused 
        validBatchSize(fundraiserIds.length)
        nonReentrant
    {
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
            IERC20(token).transferFrom(msg.sender, mainContract, amounts[i]);
            
            // Call main contract donation logic
            bytes memory data = abi.encodeWithSignature(
                "donate(uint256,uint256)",
                fundraiserIds[i],
                amounts[i]
            );
            (bool success, ) = mainContract.call(data);
            require(success, "Donation failed");
            
            totalAmount += amounts[i];
        }
        
        emit BatchDonationExecuted(batchId, msg.sender, totalAmount);
    }
    
    function batchDonateWithPermits(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) 
        external 
        whenNotPaused 
        validBatchSize(fundraiserIds.length)
        nonReentrant
    {
        require(
            fundraiserIds.length == amounts.length &&
            amounts.length == deadlines.length &&
            deadlines.length == vs.length &&
            vs.length == rs.length &&
            rs.length == ss.length,
            "Array length mismatch"
        );
        
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
        
        // Execute permits and donations
        for (uint256 i = 0; i < fundraiserIds.length; i++) {
            require(amounts[i] > 0, "Zero amount");
            
            // Get fundraiser token
            address token = _getFundraiserToken(fundraiserIds[i]);
            
            // Execute permit
            IERC20Permit(token).permit(
                msg.sender,
                address(this),
                amounts[i],
                deadlines[i],
                vs[i],
                rs[i],
                ss[i]
            );
            
            // Transfer tokens to main contract
            IERC20(token).transferFrom(msg.sender, mainContract, amounts[i]);
            
            // Call main contract donation logic
            bytes memory data = abi.encodeWithSignature(
                "donate(uint256,uint256)",
                fundraiserIds[i],
                amounts[i]
            );
            (bool success, ) = mainContract.call(data);
            require(success, "Donation failed");
            
            totalAmount += amounts[i];
        }
        
        emit BatchDonationExecuted(batchId, msg.sender, totalAmount);
    }

    // ========== UTILITY FUNCTIONS ==========
    
    function supportsPermit(address token) external view returns (bool) {
        try IERC20Permit(token).DOMAIN_SEPARATOR() returns (bytes32) {
            return true;
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
        bytes memory data = abi.encodeWithSignature(
            "getFundraiserData(uint256)",
            fundraiserId
        );
        (bool success, bytes memory result) = mainContract.staticcall(data);
        require(success, "Failed to get fundraiser data");
        
        (, address token, , , , , ) = abi.decode(
            result,
            (address, address, uint256, uint256, uint256, uint8, bool)
        );
        return token;
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        
        if (token == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(to, amount), "Token transfer failed");
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