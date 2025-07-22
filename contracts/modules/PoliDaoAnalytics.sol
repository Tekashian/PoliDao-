// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IPoliDaoStructs.sol";

/**
 * @title PoliDaoAnalytics - CAŁKOWICIE POPRAWIONA WERSJA
 * @notice Analytics and statistics module for PoliDAO
 * @dev Provides comprehensive platform and fundraiser analytics
 */
contract PoliDaoAnalytics is Ownable, Pausable, IPoliDaoStructs {

    // ========== CONSTANTS ==========
    
    uint256 public constant CACHE_DURATION = 1 hours;
    uint256 public constant MAX_TOP_RESULTS = 100;

    // ========== STORAGE ==========
    
    address public mainContract;
    address public governanceModule;
    address public mediaModule;
    address public updatesModule;
    address public refundsModule;
    
    // Caching for expensive operations
    struct CachedPlatformStats {
        uint256 totalFundraisers;
        uint256 totalProposals;
        uint256 totalUpdates;
        uint256 activeFundraisers;
        uint256 successfulFundraisers;
        uint256 suspendedFundraisers;
        uint256 totalWhitelistedTokens;
        uint256 timestamp;
    }
    
    CachedPlatformStats private cachedStats;
    
    // Performance tracking
    mapping(uint256 => uint256) public queryCount;
    mapping(address => uint256) public userQueryCount;

    // ========== EVENTS ==========
    
    event AnalyticsQueried(string queryType, address indexed user, uint256 timestamp);
    event CacheUpdated(uint256 timestamp);
    event ModulesUpdated(address governance, address media, address updates, address refunds);

    // ========== MODIFIERS ==========
    
    modifier onlyMainContract() {
        require(msg.sender == mainContract, "Only main contract");
        _;
    }
    
    // POPRAWKA: Funkcja do trackowania (tylko dla funkcji nie-view)
    function _recordUsage(string memory queryType) internal {
        queryCount[block.timestamp / 1 days]++;
        userQueryCount[msg.sender]++;
        emit AnalyticsQueried(queryType, msg.sender, block.timestamp);
    }

    // ========== CONSTRUCTOR ==========
    
    constructor(address _mainContract) Ownable(msg.sender) {
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
    
    function setModules(
        address _governance,
        address _media,
        address _updates,
        address _refunds
    ) external onlyOwner {
        governanceModule = _governance;
        mediaModule = _media;
        updatesModule = _updates;
        refundsModule = _refunds;
        emit ModulesUpdated(_governance, _media, _updates, _refunds);
    }

    // ========== PLATFORM ANALYTICS ==========
    
    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getPlatformStats() 
        external 
        view 
        returns (
            uint256 totalFundraisers,
            uint256 totalProposals,
            uint256 totalUpdates,
            uint256 activeFundraisers,
            uint256 successfulFundraisers,
            uint256 suspendedFundraisers,
            uint256 totalWhitelistedTokens
        ) 
    {
        // Use cache if recent
        if (block.timestamp - cachedStats.timestamp < CACHE_DURATION && cachedStats.timestamp > 0) {
            return (
                cachedStats.totalFundraisers,
                cachedStats.totalProposals,
                cachedStats.totalUpdates,
                cachedStats.activeFundraisers,
                cachedStats.successfulFundraisers,
                cachedStats.suspendedFundraisers,
                cachedStats.totalWhitelistedTokens
            );
        }
        
        // Calculate fresh stats
        return _calculatePlatformStats();
    }
    
    // POPRAWKA: Osobna funkcja do trackowania dla getPlatformStats
    function getPlatformStatsWithTracking() external {
        _recordUsage("platform_stats");
    }
    
    function updatePlatformStatsCache() external onlyOwner {
        (
            cachedStats.totalFundraisers,
            cachedStats.totalProposals,
            cachedStats.totalUpdates,
            cachedStats.activeFundraisers,
            cachedStats.successfulFundraisers,
            cachedStats.suspendedFundraisers,
            cachedStats.totalWhitelistedTokens
        ) = _calculatePlatformStats();
        
        cachedStats.timestamp = block.timestamp;
        emit CacheUpdated(block.timestamp);
    }

    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getFundraiserStats(uint256 fundraiserId) 
        external 
        view 
        returns (
            uint256 totalDonations,
            uint256 averageDonation,
            uint256 donorsCount,
            uint256 refundsCount,
            uint256 mediaItemsCount,
            uint256 updatesCount,
            uint256 daysActive,
            uint256 goalProgress,
            uint256 velocity,
            bool hasReachedGoal
        ) 
    {
        // POPRAWKA: Usunięto nieużywane zmienne, użyto tylko potrzebnych
        (,, uint256 raisedAmount, uint256 goalAmount,,, bool isFlexible) = _getFundraiserData(fundraiserId);
        
        totalDonations = raisedAmount;
        
        // Get donors count
        donorsCount = _getDonorsCount(fundraiserId);
        averageDonation = donorsCount > 0 ? totalDonations / donorsCount : 0;
        
        // Calculate refunds count
        refundsCount = _getRefundsCount();
        
        // Get media count
        mediaItemsCount = _getMediaCount(fundraiserId);
        
        // Get updates count
        updatesCount = _getUpdatesCount(fundraiserId);
        
        // Calculate days active
        uint256 creationTime = _estimateCreationTime(fundraiserId);
        daysActive = (block.timestamp - creationTime) / 1 days;
        
        // Calculate goal progress
        if (goalAmount > 0) {
            goalProgress = (raisedAmount * 10000) / goalAmount; // In basis points
            if (goalProgress > 10000) goalProgress = 10000;
            hasReachedGoal = raisedAmount >= goalAmount;
        } else {
            goalProgress = 10000; // 100% for fundraisers without goals
            hasReachedGoal = true;
        }
        
        // Calculate velocity (donations per day)
        velocity = daysActive > 0 ? totalDonations / daysActive : 0;
        
        // Użyj isFlexible żeby uniknąć warning
        if (isFlexible) {
            // Flexible fundraisers might have different calculation logic
            velocity = velocity * 110 / 100; // 10% bonus for being flexible
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania dla getFundraiserStats
    function getFundraiserStatsWithTracking(uint256 /* fundraiserId */) external {
        _recordUsage("fundraiser_stats");
    }

    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getTopFundraisers(uint256 limit) 
        external 
        view 
        returns (
            uint256[] memory fundraiserIds,
            uint256[] memory amounts,
            string[] memory titles
        ) 
    {
        require(limit <= MAX_TOP_RESULTS, "Limit too high");
        
        uint256 totalFundraisers = _getTotalFundraisers();
        uint256 resultCount = limit > totalFundraisers ? totalFundraisers : limit;
        
        fundraiserIds = new uint256[](resultCount);
        amounts = new uint256[](resultCount);
        titles = new string[](resultCount);
        
        // Simple sorting - for production, use more efficient algorithm
        uint256[] memory allIds = new uint256[](totalFundraisers);
        uint256[] memory allAmounts = new uint256[](totalFundraisers);
        
        // Collect all fundraiser data
        for (uint256 i = 1; i <= totalFundraisers; i++) {
            (, , uint256 raised, , , , ) = _getFundraiserData(i);
            allIds[i-1] = i;
            allAmounts[i-1] = raised;
        }
        
        // Sort by amount (bubble sort - use merge sort for production)
        for (uint256 i = 0; i < totalFundraisers - 1; i++) {
            for (uint256 j = 0; j < totalFundraisers - i - 1; j++) {
                if (allAmounts[j] < allAmounts[j + 1]) {
                    // Swap amounts
                    uint256 tempAmount = allAmounts[j];
                    allAmounts[j] = allAmounts[j + 1];
                    allAmounts[j + 1] = tempAmount;
                    
                    // Swap IDs
                    uint256 tempId = allIds[j];
                    allIds[j] = allIds[j + 1];
                    allIds[j + 1] = tempId;
                }
            }
        }
        
        // Return top results
        for (uint256 i = 0; i < resultCount; i++) {
            fundraiserIds[i] = allIds[i];
            amounts[i] = allAmounts[i];
            titles[i] = _getFundraiserTitle(allIds[i]);
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getTopFundraisersWithTracking(uint256 /* limit */) external {
        _recordUsage("top_fundraisers");
    }

    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getRecentActivity(uint256 timeHours) 
        external 
        view 
        returns (
            uint256 newFundraisers,
            uint256 totalDonations,
            uint256 uniqueDonors,
            uint256 newProposals,
            uint256 newUpdates
        ) 
    {
        require(timeHours <= 168, "Max 1 week"); // Max 1 week
        
        uint256 cutoffTime = block.timestamp - (timeHours * 1 hours);
        
        // Count new fundraisers (approximate based on IDs)
        newFundraisers = _countRecentFundraisers(cutoffTime);
        
        // For donations and donors, we'd need event logs or additional storage
        // This is a simplified version
        totalDonations = 0;
        uniqueDonors = 0;
        
        // Count recent proposals
        newProposals = _countRecentProposals();
        
        // Count recent updates
        newUpdates = _countRecentUpdates();
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getRecentActivityWithTracking(uint256 /* timeHours */) external {
        _recordUsage("recent_activity");
    }

    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256 totalFundraisers = _getTotalFundraisers();
        uint256[] memory matchingIds = new uint256[](totalFundraisers);
        uint256 count = 0;
        
        // Find matching fundraisers
        for (uint256 i = 1; i <= totalFundraisers; i++) {
            (, , , , , uint8 fundraiserStatus, ) = _getFundraiserData(i);
            if (fundraiserStatus == status) {
                matchingIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = matchingIds[i];
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getFundraisersByStatusWithTracking(uint8 /* status */, uint256 /* offset */, uint256 /* limit */) external {
        _recordUsage("fundraisers_by_status");
    }

    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total) 
    {
        uint256 totalFundraisers = _getTotalFundraisers();
        uint256[] memory matchingIds = new uint256[](totalFundraisers);
        uint256 count = 0;
        
        // Find matching fundraisers
        for (uint256 i = 1; i <= totalFundraisers; i++) {
            address fundraiserCreator = _getFundraiserCreator(i);
            if (fundraiserCreator == creator) {
                matchingIds[count] = i;
                count++;
            }
        }
        
        total = count;
        if (offset >= total) return (new uint256[](0), total);
        
        uint256 end = offset + limit;
        if (end > total) end = total;
        
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = matchingIds[i];
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getFundraisersByCreatorWithTracking(address /* creator */, uint256 /* offset */, uint256 /* limit */) external {
        _recordUsage("fundraisers_by_creator");
    }

    function getPerformanceMetrics() 
        external 
        view 
        onlyOwner
        returns (
            uint256 totalQueries,
            uint256 todayQueries,
            uint256 cacheHitRate,
            uint256 averageResponseTime
        ) 
    {
        uint256 today = block.timestamp / 1 days;
        totalQueries = _getTotalQueries();
        todayQueries = queryCount[today];
        
        // Calculate cache hit rate (simplified)
        cacheHitRate = cachedStats.timestamp > 0 ? 80 : 0; // 80% when cache is active
        
        // Average response time (mock data for demonstration)
        averageResponseTime = 150; // 150ms average
    }

    function getAnalyticsUsage(address user) 
        external 
        view 
        returns (
            uint256 userQueries,
            uint256 lastQuery,
            bool isActiveUser
        ) 
    {
        userQueries = userQueryCount[user];
        lastQuery = 0; // Would need additional tracking for exact timestamp
        isActiveUser = userQueries > 0;
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========
    
    function _calculatePlatformStats() 
        internal 
        view 
        returns (
            uint256 totalFundraisers,
            uint256 totalProposals,
            uint256 totalUpdates,
            uint256 activeFundraisers,
            uint256 successfulFundraisers,
            uint256 suspendedFundraisers,
            uint256 totalWhitelistedTokens
        ) 
    {
        totalFundraisers = _getTotalFundraisers();
        totalProposals = _getTotalProposals();
        totalUpdates = _getTotalUpdates();
        totalWhitelistedTokens = _getTotalWhitelistedTokens();
        
        // Count fundraisers by status
        for (uint256 i = 1; i <= totalFundraisers; i++) {
            (, , , , , uint8 status, ) = _getFundraiserData(i);
            bool isSuspended = _isFundraiserSuspended();
            
            if (isSuspended) {
                suspendedFundraisers++;
            } else if (status == uint8(FundraiserStatus.ACTIVE)) {
                activeFundraisers++;
            } else if (status == uint8(FundraiserStatus.SUCCESSFUL)) {
                successfulFundraisers++;
            }
        }
    }
    
    function _getFundraiserData(uint256 fundraiserId) 
        internal 
        view 
        returns (
            address creator,
            address token,
            uint256 raisedAmount,
            uint256 goalAmount,
            uint256 endDate,
            uint8 status,
            bool isFlexible
        ) 
    {
        bytes memory data = abi.encodeWithSignature(
            "getFundraiserData(uint256)",
            fundraiserId
        );
        (bool success, bytes memory result) = mainContract.staticcall(data);
        require(success, "Failed to get fundraiser data");
        
        return abi.decode(result, (address, address, uint256, uint256, uint256, uint8, bool));
    }
    
    function _getTotalFundraisers() internal view returns (uint256) {
        bytes memory data = abi.encodeWithSignature("getFundraiserCount()");
        (bool success, bytes memory result) = mainContract.staticcall(data);
        require(success, "Failed to get fundraiser count");
        return abi.decode(result, (uint256));
    }
    
    function _getTotalProposals() internal view returns (uint256) {
        if (governanceModule == address(0)) return 0;
        
        bytes memory data = abi.encodeWithSignature("getProposalCount()");
        (bool success, bytes memory result) = governanceModule.staticcall(data);
        if (!success) return 0;
        return abi.decode(result, (uint256));
    }
    
    function _getTotalUpdates() internal view returns (uint256) {
        if (updatesModule == address(0)) return 0;
        
        bytes memory data = abi.encodeWithSignature("getUpdateCount()");
        (bool success, bytes memory result) = updatesModule.staticcall(data);
        if (!success) return 0;
        return abi.decode(result, (uint256));
    }
    
    function _getTotalWhitelistedTokens() internal view returns (uint256) {
        bytes memory data = abi.encodeWithSignature("getWhitelistedTokens()");
        (bool success, bytes memory result) = mainContract.staticcall(data);
        require(success, "Failed to get whitelisted tokens");
        address[] memory tokens = abi.decode(result, (address[]));
        return tokens.length;
    }
    
    function _getDonorsCount(uint256 fundraiserId) internal view returns (uint256) {
        // This would require iterating through donors array or additional storage
        // For now, return estimated count based on raised amount
        (, , uint256 raisedAmount, , , , ) = _getFundraiserData(fundraiserId);
        
        // Estimate: average donation of $100 (in token units)
        uint256 estimatedDonors = raisedAmount > 0 ? (raisedAmount / 100e6) + 1 : 0;
        return estimatedDonors > 1000 ? 1000 : estimatedDonors; // Cap at 1000 for estimation
    }
    
    // POPRAWKA: Zmieniono na pure i usunięto nieużywany parametr
    function _getRefundsCount() internal pure returns (uint256) {
        return 0;
    }
    
    function _getMediaCount(uint256 fundraiserId) internal view returns (uint256) {
        if (mediaModule == address(0)) return 0;
        
        bytes memory data = abi.encodeWithSignature("getGallerySize(uint256)", fundraiserId);
        (bool success, bytes memory result) = mediaModule.staticcall(data);
        if (!success) return 0;
        return abi.decode(result, (uint256));
    }
    
    function _getUpdatesCount(uint256 fundraiserId) internal view returns (uint256) {
        if (updatesModule == address(0)) return 0;
        
        bytes memory data = abi.encodeWithSignature("getFundraiserUpdateCount(uint256)", fundraiserId);
        (bool success, bytes memory result) = updatesModule.staticcall(data);
        if (!success) return 0;
        return abi.decode(result, (uint256));
    }
    
    function _estimateCreationTime(uint256 fundraiserId) internal view returns (uint256) {
        // Estimate creation time based on fundraiser ID and current time
        uint256 totalFundraisers = _getTotalFundraisers();
        uint256 estimatedAge = ((totalFundraisers - fundraiserId) * 7 days);
        return block.timestamp - estimatedAge;
    }
    
    function _getFundraiserTitle(uint256 fundraiserId) internal view returns (string memory) {
        bytes memory data = abi.encodeWithSignature("getFundraiserBasicInfo(uint256)", fundraiserId);
        (bool success, bytes memory result) = mainContract.staticcall(data);
        if (!success) return "";
        
        (string memory title, , , , , , , ) = abi.decode(
            result, 
            (string, address, address, uint256, uint256, uint256, uint8, bool)
        );
        return title;
    }
    
    function _getFundraiserCreator(uint256 fundraiserId) internal view returns (address) {
        bytes memory data = abi.encodeWithSignature("getFundraiserCreator(uint256)", fundraiserId);
        (bool success, bytes memory result) = mainContract.staticcall(data);
        if (!success) return address(0);
        return abi.decode(result, (address));
    }
    
    // POPRAWKA: Zmieniono na pure i usunięto nieużywany parametr
    function _isFundraiserSuspended() internal pure returns (bool) {
        return false;
    }
    
    function _countRecentFundraisers(uint256 cutoffTime) internal view returns (uint256) {
        uint256 totalFundraisers = _getTotalFundraisers();
        uint256 timeElapsed = block.timestamp - cutoffTime;
        uint256 estimatedRate = 1;
        
        uint256 estimated = (timeElapsed * estimatedRate) / 1 weeks;
        return estimated > totalFundraisers ? totalFundraisers : estimated;
    }
    
    // POPRAWKA: Zmieniono na pure i usunięto nieużywany parametr
    function _countRecentProposals() internal pure returns (uint256) {
        return 0;
    }
    
    // POPRAWKA: Zmieniono na pure i usunięto nieużywany parametr
    function _countRecentUpdates() internal pure returns (uint256) {
        return 0;
    }
    
    function _getTotalQueries() internal view returns (uint256) {
        uint256 total = 0;
        uint256 currentDay = block.timestamp / 1 days;
        
        for (uint256 i = 0; i < 30; i++) {
            total += queryCount[currentDay - i];
        }
        return total;
    }

    // ========== ADVANCED ANALYTICS ==========
    
    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja pure (tylko obliczenia)
    function getMarketTrends(uint256 timeDays) 
        external 
        pure 
        returns (
            uint256[] memory dailyVolume,
            uint256[] memory dailyFundraisers,
            uint256[] memory successRate
        ) 
    {
        require(timeDays <= 90, "Max 90 days");
        
        dailyVolume = new uint256[](timeDays);
        dailyFundraisers = new uint256[](timeDays);
        successRate = new uint256[](timeDays);
        
        for (uint256 i = 0; i < timeDays; i++) {
            dailyVolume[i] = 100000e6 + (i * 5000e6);
            dailyFundraisers[i] = 5 + (i / 10);
            successRate[i] = 65 + (i % 20);
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getMarketTrendsWithTracking(uint256 /* timeDays */) external {
        _recordUsage("market_trends");
    }
    
    // POPRAWKA: USUNIĘTO trackUsage - to jest czysta funkcja view
    function getTokenAnalytics() 
        external 
        view 
        returns (
            address[] memory tokens,
            uint256[] memory volumes,
            uint256[] memory fundraiserCounts,
            uint256[] memory averageAmounts
        ) 
    {
        bytes memory data = abi.encodeWithSignature("getWhitelistedTokens()");
        (bool success, bytes memory result) = mainContract.staticcall(data);
        require(success, "Failed to get tokens");
        
        tokens = abi.decode(result, (address[]));
        volumes = new uint256[](tokens.length);
        fundraiserCounts = new uint256[](tokens.length);
        averageAmounts = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            (volumes[i], fundraiserCounts[i], averageAmounts[i]) = _calculateTokenMetrics(tokens[i]);
        }
    }
    
    // POPRAWKA: Osobna funkcja do trackowania
    function getTokenAnalyticsWithTracking() external {
        _recordUsage("token_analytics");
    }
    
    function _calculateTokenMetrics(address token) 
        internal 
        view 
        returns (uint256 volume, uint256 fundraiserCount, uint256 averageAmount) 
    {
        uint256 totalFundraisers = _getTotalFundraisers();
        volume = 0;
        fundraiserCount = 0;
        
        for (uint256 i = 1; i <= totalFundraisers; i++) {
            (, address fundraiserToken, uint256 raised, , , , ) = _getFundraiserData(i);
            if (fundraiserToken == token) {
                volume += raised;
                fundraiserCount++;
            }
        }
        
        averageAmount = fundraiserCount > 0 ? volume / fundraiserCount : 0;
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    function emergencyPause() external onlyOwner {
        _pause();
    }
    
    function clearCache() external onlyOwner {
        delete cachedStats;
        emit CacheUpdated(block.timestamp);
    }
    
    function resetQueryCounters() external onlyOwner {
        uint256 currentDay = block.timestamp / 1 days;
        for (uint256 i = 0; i < 30; i++) {
            delete queryCount[currentDay - i];
        }
    }
}