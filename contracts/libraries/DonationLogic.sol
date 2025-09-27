// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../storage/PoliDaoStorage.sol";
import "../interfaces/IPoliDaoStorage.sol";
import "../interfaces/IPoliDaoStructs.sol";

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
        IPoliDaoStorage store,
        uint256 fundraiserId,
        address donor,
        uint256 amount
    )
        public
    {
        // SECURITY: prevent arbitrary-from
        require(
            msg.sender == donor || store.isContractAuthorized(msg.sender),
            "DonationLogic: unauthorized transferFrom(from)"
        );

        // ========== VALIDATION ==========
        
        IPoliDaoStructs.PackedFundraiserData memory fundraiser = store.fundraisers(fundraiserId);
        
        // Check fundraiser exists
        if (fundraiser.id == 0) revert FundraiserNotFound();
        
        // Check amount validity
        if (amount == 0) revert InvalidAmount();
        if (amount > type(uint128).max) revert AmountTooLarge();
        
        // Check fundraiser status
        if (fundraiser.status != uint8(IPoliDaoStructs.FundraiserStatus.ACTIVE)) revert FundraiserNotActive();
        if (fundraiser.endDate > 0 && block.timestamp > fundraiser.endDate) revert FundraiserEnded();
        if (fundraiser.isSuspended) revert FundraiserSuspended();
        
        // Check for overflow protection
        uint256 currentRaised = fundraiser.raisedAmount;
        if (currentRaised > type(uint128).max - amount) revert RaisedAmountOverflow();
        
        // ========== PROCESS DONATION ==========

        // Dodatkowa autoryzacja (opcjonalnie zachowaj)
        require(msg.sender == donor || store.isContractAuthorized(msg.sender), "DonationLogic: unauthorized");

        address token = store.fundraiserTokens(fundraiserId);
        IERC20(token).safeTransferFrom(msg.sender, address(store), amount);

        // Emit BEFORE external interaction (CEI)
        emit DonationMade(fundraiserId, donor, token, amount, amount);

        // External interaction to storage (state write)
        store.addDonation(fundraiserId, donor, amount);
    }
    
    /**
     * @notice Gets donation amount for a specific donor
     * @param store The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @return amount Donation amount
     */
    function getDonationAmount(
        IPoliDaoStorage store,
        uint256 fundraiserId,
        address donor
    ) public view returns (uint256 amount) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId
    ) public view returns (address[] memory donors) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId
    ) public view returns (uint256 count) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId,
        uint256 amount
    ) public view returns (bool isValid, string memory reason) {
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
        
        if (fundraiser.endDate > 0 && block.timestamp > fundraiser.endDate) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId
    ) public view returns (
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
        IPoliDaoStorage store,
        uint256 fundraiserId,
        address donor
    ) public view returns (bool donated, uint256 amount) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId,
        uint256 limit
    ) public view returns (address[] memory donors, uint256[] memory amounts) {
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
        IPoliDaoStorage store,
        uint256 fundraiserId,
        address donor,
        uint256 newAmount
    ) public {
        if (store.fundraisers(fundraiserId).id == 0) revert FundraiserNotFound();
        store.updateDonationAmount(fundraiserId, donor, newAmount);
    }

    // Delegacja donacji do storage (public – brak inline w Core)
    function processDonation(
        IPoliDaoStorage stor,
        uint256 fundraiserId,
        address donor,
        uint256 amount
    ) public {
        stor.addDonation(fundraiserId, donor, amount);
    }

    // Delegacja batch donacji do storage (public – brak inline w Core)
    function processBatchDonation(
        IPoliDaoStorage stor,
        address donor,
        address expectedToken,
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) public {
        stor.batchAddDonations(donor, expectedToken, fundraiserIds, amounts);
    }

    /**
     * @notice Donate to a fundraiser
     * @param s The storage contract instance
     * @param fundraiserId The fundraiser ID
     * @param donor The donor address
     * @param amount The donation amount
     */
    function donate(
        PoliDaoStorage s,
        uint256 fundraiserId,
        address donor,
        uint256 amount
    ) internal {
        require(amount > 0, "Donation: zero amount");

        // pobierz token przypisany do zbiorki
        address token = s.fundraiserTokens(fundraiserId);
        require(token != address(0), "Donation: invalid fundraiser");

        // przenies srodki od darczyncy do storage (spender = Core)
        IERC20(token).safeTransferFrom(donor, address(s), amount);

        // zarejestruj darowizne w storage
        s.addDonation(fundraiserId, donor, amount);
    }
}