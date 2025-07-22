// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoWeb3
 * @notice Interface for PoliDAO Web3 features module
 * @dev Defines all Web3-related functions including permits, meta-transactions, and batch operations
 */
interface IPoliDaoWeb3 is IPoliDaoStructs {
    
    // ========== EVENTS (USUNIETO DUPLIKATY) ==========
    // DonationMadeWithPermit i DonationMadeWithMetaTx są w IPoliDaoStructs
    
    event RelayerAuthorized(
        address indexed relayer, 
        uint256 gasLimit
    );
    
    event RelayerRevoked(
        address indexed relayer
    );
    
    event MetaTxRateLimitUpdated(
        uint256 oldLimit, 
        uint256 newLimit
    );
    
    event PermitSupportDetected(
        address indexed token, 
        bool supported
    );
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Donate with EIP-2612 permit
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     * @param deadline Permit deadline
     * @param v Permit signature v
     * @param r Permit signature r
     * @param s Permit signature s
     */
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    
    /**
     * @notice Execute donation via meta-transaction
     * @param donor The actual donor address
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     * @param deadline Transaction deadline
     * @param signature EIP-712 signature
     */
    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external;
    
    /**
     * @notice Batch donate to multiple fundraisers
     * @param fundraiserIds Array of fundraiser IDs
     * @param amounts Array of donation amounts
     */
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external;
    
    /**
     * @notice Batch donate with permits
     * @param fundraiserIds Array of fundraiser IDs
     * @param amounts Array of donation amounts
     * @param deadlines Array of permit deadlines
     * @param vs Array of permit signature v values
     * @param rs Array of permit signature r values
     * @param ss Array of permit signature s values
     */
    function batchDonateWithPermits(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external;
    
    // ========== UTILITY FUNCTIONS ==========
    
    /**
     * @notice Check if token supports EIP-2612 permits
     * @param token Token address to check
     * @return supported Whether token supports permits
     */
    function supportsPermit(address token) external view returns (bool supported);
    
    /**
     * @notice Get user's current nonce for meta-transactions
     * @param user User address
     * @return nonce Current nonce
     */
    function getNonce(address user) external view returns (uint256 nonce);
    
    /**
     * @notice Verify donation signature for meta-transaction
     * @param donor Donor address
     * @param fundraiserId Fundraiser ID
     * @param amount Donation amount
     * @param deadline Transaction deadline
     * @param signature EIP-712 signature
     * @return valid Whether signature is valid
     */
    function verifyDonationSignature(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (bool valid);
    
    /**
     * @notice Get meta-transaction count for user in specific hour
     * @param user User address
     * @param hour Hour timestamp (block.timestamp / 1 hours)
     * @return count Number of meta-transactions
     */
    function getMetaTxCount(address user, uint256 hour) external view returns (uint256 count);
    
    /**
     * @notice Check if user can execute meta-transaction (rate limit)
     * @param user User address
     * @return canExecute Whether user can execute meta-tx
     */
    function canExecuteMetaTx(address user) external view returns (bool canExecute);
    
    /**
     * @notice Check if batch was already executed
     * @param batchId Batch identifier
     * @return executed Whether batch was executed
     */
    function isBatchExecuted(bytes32 batchId) external view returns (bool executed);
    
    /**
     * @notice Calculate batch ID for given parameters
     * @param donor Donor address
     * @param fundraiserIds Array of fundraiser IDs
     * @param amounts Array of amounts
     * @return batchId Calculated batch identifier
     */
    function calculateBatchId(
        address donor,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external view returns (bytes32 batchId);
    
    // ========== ADMIN FUNCTIONS ==========
    
    /**
     * @notice Set main contract address
     * @param newMainContract New main contract address
     */
    function setMainContract(address newMainContract) external;
    
    /**
     * @notice Authorize relayer for meta-transactions
     * @param relayer Relayer address
     * @param gasLimit Gas limit for relayer
     */
    function authorizeRelayer(address relayer, uint256 gasLimit) external;
    
    /**
     * @notice Revoke relayer authorization
     * @param relayer Relayer address to revoke
     */
    function revokeRelayer(address relayer) external;
    
    /**
     * @notice Set meta-transaction rate limit
     * @param newLimit New rate limit (transactions per hour)
     */
    function setMetaTxRateLimit(uint256 newLimit) external;
    
    /**
     * @notice Emergency withdraw tokens
     * @param token Token address (address(0) for ETH)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
    
    /**
     * @notice Invalidate user's nonce (emergency)
     * @param user User address
     */
    function invalidateNonce(address user) external;
    
    /**
     * @notice Clear batch execution status (emergency)
     * @param batchId Batch identifier
     */
    function clearBatch(bytes32 batchId) external;
    
    /**
     * @notice Pause the contract
     */
    function pause() external;
    
    /**
     * @notice Unpause the contract
     */
    function unpause() external;
    
    // ========== VIEW FUNCTIONS ==========
    
    /**
     * @notice Get main contract address
     * @return contractAddress Main contract address
     */
    function mainContract() external view returns (address contractAddress);
    
    /**
     * @notice Check if relayer is authorized
     * @param relayer Relayer address
     * @return authorized Whether relayer is authorized
     */
    function authorizedRelayers(address relayer) external view returns (bool authorized);
    
    /**
     * @notice Get relayer gas limit
     * @param relayer Relayer address
     * @return gasLimit Gas limit for relayer
     */
    function relayerGasLimits(address relayer) external view returns (uint256 gasLimit);
    
    /**
     * @notice Get current meta-transaction rate limit
     * @return rateLimit Current rate limit (transactions per hour)
     */
    function maxMetaTxPerHour() external view returns (uint256 rateLimit);
    
    /**
     * @notice Get batch size limit
     * @return batchLimit Maximum batch size
     */
    function MAX_BATCH_SIZE() external view returns (uint256 batchLimit);
    
    /**
     * @notice Get meta-transaction delay limit
     * @return delayLimit Maximum delay for meta-transactions
     */
    function MAX_META_TX_DELAY() external view returns (uint256 delayLimit);
}