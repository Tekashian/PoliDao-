// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../storage/PoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DonationLogic
 * @notice Library containing business logic for donation operations
 * @dev Used by PoliDaoCore to handle donation processing
 * @author PoliDAO Team
 * @custom:version 1.0.0-UNIFIED
 */
library DonationLogic {
    using SafeERC20 for IERC20;
    
    // ========== EVENTS ==========
    
    /// @notice Emitted when a donation is made
    event DonationMade(
        uint256 indexed fundraiserId,
        address indexed donor,
        address indexed token,
        uint256 amount,
        uint256 netAmount
    );
    
    // ========== ERRORS ==========
    
    error FundraiserNotFound();
    error InvalidAmount();
    error AmountTooLarge();
    error FundraiserNotActive();
    error FundraiserEnded();
    error FundraiserSuspended();
    error RaisedAmountOverflow();
    error NoDonationFound();
    
    // ========== CORE FUNCTIONS ==========
    
    /**
     * @notice Processes a donation with validation and token transfer
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID to donate to
     * @param donor The donor address
     * @param amount The donation amount
     */
    function processDonationLogic(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address donor,
        uint256 amount
    ) external {
        
        // ========== VALIDATION ==========
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        // Check fundraiser exists
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        // Check amount validity
        if (amount == 0) revert InvalidAmount();
        if (amount > type(uint128).max) revert AmountTooLarge();
        
        // Check fundraiser status
        if (fundraiser.status != uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE)) revert FundraiserNotActive();
        if (block.timestamp > fundraiser.endDate) revert FundraiserEnded();
        if (fundraiser.isSuspended) revert FundraiserSuspended();
        
        // Check for overflow protection
        uint256 currentRaised = fundraiser.raisedAmount;
        if (currentRaised > type(uint128).max - amount) revert RaisedAmountOverflow();
        
        // ========== PROCESS DONATION ==========
        
        // Add donation to storage
        store.addDonation(fundraiserId, donor, amount);
        
        // Transfer tokens from donor to this contract
        address token = store.fundraiserTokens(fundraiserId);
        IERC20(token).safeTransferFrom(donor, address(this), amount);
        
        // ========== EMIT EVENT ==========
        
        emit DonationMade(fundraiserId, donor, token, amount, amount);
    }
    
    /**
     * @notice Gets donation amount for a specific donor
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return amount Donation amount
     */
    function getDonationAmount(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address donor
    ) external view returns (uint256 amount) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        return store.donations(fundraiserId, donor);
    }
    
    /**
     * @notice Gets all donors for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return donors Array of donor addresses
     */
    function getFundraiserDonors(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (address[] memory donors) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        return store.getFundraiserDonors(fundraiserId);
    }
    
    /**
     * @notice Gets donor count for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return count Number of unique donors
     */
    function getDonorCount(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (uint256 count) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        return store.getFundraiserDonors(fundraiserId).length;
    }
    
    /**
     * @notice Validates donation parameters before processing
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param amount The donation amount
     * @return isValid Whether donation is valid
     * @return reason Reason if invalid
     */
    function validateDonation(
        PoliDaoStorage store,
        uint256 fundraiserId,
        uint256 amount
    ) external view returns (bool isValid, string memory reason) {
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        if (fundraiser.id == 0) {
            return (false, "Fundraiser not found");
        }
        
        if (amount == 0) {
            return (false, "Amount must be greater than 0");
        }
        
        if (amount > type(uint128).max) {
            return (false, "Amount too large");
        }
        
        if (fundraiser.status != uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE)) {
            return (false, "Fundraiser not active");
        }
        
        if (block.timestamp > fundraiser.endDate) {
            return (false, "Fundraiser ended");
        }
        
        if (fundraiser.isSuspended) {
            return (false, "Fundraiser suspended");
        }
        
        uint256 currentRaised = fundraiser.raisedAmount;
        if (currentRaised > type(uint128).max - amount) {
            return (false, "Would cause overflow");
        }
        
        return (true, "Valid donation");
    }
    
    /**
     * @notice Gets donation statistics for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @return totalRaised Total amount raised
     * @return donorCount Number of unique donors
     * @return averageDonation Average donation amount
     * @return goalAmount Goal amount
     * @return progressPercentage Progress percentage (in basis points)
     */
    function getDonationStats(
        PoliDaoStorage store,
        uint256 fundraiserId
    ) external view returns (
        uint256 totalRaised,
        uint256 donorCount,
        uint256 averageDonation,
        uint256 goalAmount,
        uint256 progressPercentage
    ) {
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        totalRaised = fundraiser.raisedAmount;
        donorCount = store.getFundraiserDonors(fundraiserId).length;
        averageDonation = donorCount > 0 ? totalRaised / donorCount : 0;
        goalAmount = fundraiser.goalAmount;
        
        if (goalAmount > 0) {
            progressPercentage = (totalRaised * 10000) / goalAmount; // Basis points
        } else {
            progressPercentage = 0;
        }
        
        return (totalRaised, donorCount, averageDonation, goalAmount, progressPercentage);
    }
    
    /**
     * @notice Checks if a donor has donated to a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
    * @return donated Whether the donor has donated
    * @return amount Amount donated
     */
    function hasDonated(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address donor
    ) external view returns (bool donated, uint256 amount) {
    if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();

    amount = store.donations(fundraiserId, donor);
    donated = amount > 0;

    return (donated, amount);
    }
    
    /**
     * @notice Gets top donors for a fundraiser
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param limit Maximum number of donors to return
     * @return donors Array of donor addresses
     * @return amounts Array of donation amounts
     */
    function getTopDonors(
        PoliDaoStorage store,
        uint256 fundraiserId,
        uint256 limit
    ) external view returns (address[] memory donors, uint256[] memory amounts) {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        
        address[] memory allDonors = store.getFundraiserDonors(fundraiserId);
        uint256 donorCount = allDonors.length;
        
        if (donorCount == 0) {
            return (new address[](0), new uint256[](0));
        }
        
        // Limit to actual donor count
        uint256 returnCount = limit > donorCount ? donorCount : limit;
        
        // Create arrays for sorting
        address[] memory sortedDonors = new address[](donorCount);
        uint256[] memory sortedAmounts = new uint256[](donorCount);
        
        // Fill arrays
        for (uint256 i = 0; i < donorCount; i++) {
            sortedDonors[i] = allDonors[i];
            sortedAmounts[i] = store.donations(fundraiserId, allDonors[i]);
        }
        
        // Simple bubble sort (for small arrays)
        for (uint256 i = 0; i < donorCount - 1; i++) {
            for (uint256 j = 0; j < donorCount - i - 1; j++) {
                if (sortedAmounts[j] < sortedAmounts[j + 1]) {
                    // Swap amounts
                    uint256 tempAmount = sortedAmounts[j];
                    sortedAmounts[j] = sortedAmounts[j + 1];
                    sortedAmounts[j + 1] = tempAmount;
                    
                    // Swap donors
                    address tempDonor = sortedDonors[j];
                    sortedDonors[j] = sortedDonors[j + 1];
                    sortedDonors[j + 1] = tempDonor;
                }
            }
        }
        
        // Return top donors
        donors = new address[](returnCount);
        amounts = new uint256[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            donors[i] = sortedDonors[i];
            amounts[i] = sortedAmounts[i];
        }
        
        return (donors, amounts);
    }
    
    /**
     * @notice Updates donation amount (used by refund logic)
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param newAmount New donation amount
     */
    function updateDonationAmount(
        PoliDaoStorage store,
        uint256 fundraiserId,
        address donor,
        uint256 newAmount
    ) external {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        store.updateDonationAmount(fundraiserId, donor, newAmount);
    }
}