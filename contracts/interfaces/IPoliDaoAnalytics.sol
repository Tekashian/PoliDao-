// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoliDaoStructs.sol";

/**
 * @title IPoliDaoAnalytics - POPRAWIONA WERSJA
 * @notice Interface for PoliDAO analytics and statistics module
 * @dev Defines all analytics-related functions for platform metrics, fundraiser stats, and performance tracking
 */
interface IPoliDaoAnalytics is IPoliDaoStructs {
    
    // ========== STRUCTURES ==========
    
    struct PlatformStats {
        uint256 totalFundraisers;
        uint256 totalProposals;
        uint256 totalUpdates;
        uint256 activeFundraisers;
        uint256 successfulFundraisers;
        uint256 suspendedFundraisers;
        uint256 totalWhitelistedTokens;
        uint256 timestamp;
    }
    
    struct FundraiserAnalytics {
        uint256 totalDonations;
        uint256 averageDonation;
        uint256 donorsCount;
        uint256 refundsCount;
        uint256 mediaItemsCount;
        uint256 updatesCount;
        uint256 daysActive;
        uint256 goalProgress; // In basis points
        uint256 velocity; // Donations per day
        bool hasReachedGoal;
    }
    
    struct MarketTrends {
        uint256[] dailyVolume;
        uint256[] dailyFundraisers;
        uint256[] successRate;
    }
    
    struct TokenAnalytics {
        address[] tokens;
        uint256[] volumes;
        uint256[] fundraiserCounts;
        uint256[] averageAmounts;
    }
    
    struct PerformanceMetrics {
        uint256 totalQueries;
        uint256 todayQueries;
        uint256 cacheHitRate;
        uint256 averageResponseTime;
    }
    
    struct RecentActivity {
        uint256 newFundraisers;
        uint256 totalDonations;
        uint256 uniqueDonors;
        uint256 newProposals;
        uint256 newUpdates;
    }
    
    // ========== EVENTS ==========
    
    event AnalyticsQueried(
        string indexed queryType, 
        address indexed user, 
        uint256 timestamp
    );
    
    event CacheUpdated(uint256 timestamp);
    
    event ModulesUpdated(
        address indexed governance, 
        address indexed media, 
        address indexed updates, 
        address refunds
    );
    
    event QueryCountersReset(
        address indexed resetBy, 
        uint256 timestamp
    );
    
    event CacheCleared(
        address indexed clearedBy, 
        uint256 timestamp
    );
    
    // ========== CORE ANALYTICS FUNCTIONS (VIEW ONLY) ==========
    
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
        );
    
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
        );
    
    function getTopFundraisers(uint256 limit) 
        external 
        view 
        returns (
            uint256[] memory fundraiserIds,
            uint256[] memory amounts,
            string[] memory titles
        );
    
    function getRecentActivity(uint256 timeHours) 
        external 
        view 
        returns (
            uint256 newFundraisers,
            uint256 totalDonations,
            uint256 uniqueDonors,
            uint256 newProposals,
            uint256 newUpdates
        );
    
    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total);
    
    function getMarketTrends(uint256 timeDays) 
        external 
        view 
        returns (
            uint256[] memory dailyVolume,
            uint256[] memory dailyFundraisers,
            uint256[] memory successRate
        );
    
    function getTokenAnalytics() 
        external 
        view 
        returns (
            address[] memory tokens,
            uint256[] memory volumes,
            uint256[] memory fundraiserCounts,
            uint256[] memory averageAmounts
        );
    
    // ========== TRACKING FUNCTIONS (WITH STATE MODIFICATION) ==========
    // POPRAWKA: Usunięto nieużywane parametry z interfejsu
    
    function getPlatformStatsWithTracking() external;
    
    function getFundraiserStatsWithTracking() external;
    
    function getTopFundraisersWithTracking() external;
    
    function getRecentActivityWithTracking() external;
    
    function getFundraisersByStatusWithTracking() external;
    
    function getFundraisersByCreatorWithTracking() external;
    
    function getMarketTrendsWithTracking() external;
    
    function getTokenAnalyticsWithTracking() external;
    
    // ========== PERFORMANCE & USAGE ANALYTICS ==========
    
    function getPerformanceMetrics() 
        external 
        view 
        returns (
            uint256 totalQueries,
            uint256 todayQueries,
            uint256 cacheHitRate,
            uint256 averageResponseTime
        );
    
    function getAnalyticsUsage(address user) 
        external 
        view 
        returns (
            uint256 userQueries,
            uint256 lastQuery,
            bool isActiveUser
        );
    
    // ========== CACHE MANAGEMENT ==========
    
    function updatePlatformStatsCache() external;
    
    function clearCache() external;
    
    function resetQueryCounters() external;
    
    // ========== MODULE CONFIGURATION ==========
    
    function setMainContract(address newMainContract) external;
    
    function setModules(
        address governance,
        address media,
        address updates,
        address refunds
    ) external;
    
    // ========== ADMIN FUNCTIONS ==========
    
    function pause() external;
    
    function unpause() external;
    
    function emergencyPause() external;
    
    // ========== VIEW FUNCTIONS ==========
    
    function mainContract() external view returns (address contractAddress);
    
    function governanceModule() external view returns (address moduleAddress);
    
    function mediaModule() external view returns (address moduleAddress);
    
    function updatesModule() external view returns (address moduleAddress);
    
    function refundsModule() external view returns (address moduleAddress);
    
    function CACHE_DURATION() external view returns (uint256 duration);
    
    function MAX_TOP_RESULTS() external view returns (uint256 maxResults);
    
    function queryCount(uint256 day) external view returns (uint256 count);
    
    function userQueryCount(address user) external view returns (uint256 count);
}