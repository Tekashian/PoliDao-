// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IPoliDaoStructs.sol";
import "./interfaces/IPoliDaoWeb3.sol";
import "./interfaces/IPoliDaoAnalytics.sol";
import "./interfaces/IPoliDaoSecurity.sol";
import "./interfaces/IPoliDaoRefunds.sol";

interface IPoliDaoCore {
    function delegateCall(bytes32 moduleKey, bytes calldata data) external returns (bytes memory);
    function staticCall(bytes32 moduleKey, bytes calldata data) external view returns (bytes memory);
    function getModule(bytes32 moduleKey) external view returns (address);
    
    function GOVERNANCE_MODULE() external pure returns (bytes32);
    function MEDIA_MODULE() external pure returns (bytes32);
    function UPDATES_MODULE() external pure returns (bytes32);
    function REFUNDS_MODULE() external pure returns (bytes32);
    function SECURITY_MODULE() external pure returns (bytes32);
    function WEB3_MODULE() external pure returns (bytes32);
    function ANALYTICS_MODULE() external pure returns (bytes32);
    
    // Core contract functions for extension and location
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external;
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external;
    function canExtendFundraiser(uint256 fundraiserId) external view returns (bool canExtend, uint256 timeLeft, string memory reason);
    function getFundraiserLocation(uint256 fundraiserId) external view returns (string memory location);
    function getExtensionInfo(uint256 fundraiserId) external view returns (uint256 extensionCount, uint256 originalEndDate, uint256 currentEndDate);
}

/**
 * @title PoliDaoRouter - ROUTER FOR ALL MODULE FUNCTIONS
 * @notice Wrapper contract providing user-friendly access to all module functions
 * @dev Reduces main contract size by moving wrapper functions here
 */
contract PoliDaoRouter is IPoliDaoStructs {
    
    IPoliDaoCore public immutable core;
    
    constructor(address _core) {
        require(_core != address(0), "Invalid core address");
        core = IPoliDaoCore(_core);
    }

    // ========== WEB3 MODULE WRAPPERS ==========
    
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "donateWithPermit(uint256,uint256,uint256,uint8,bytes32,bytes32)",
            fundraiserId, amount, deadline, v, r, s
        );
        core.delegateCall(core.WEB3_MODULE(), data);
    }
    
    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "donateWithMetaTransaction(address,uint256,uint256,uint256,bytes)",
            donor, fundraiserId, amount, deadline, signature
        );
        core.delegateCall(core.WEB3_MODULE(), data);
    }
    
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "batchDonate(uint256[],uint256[])",
            fundraiserIds, amounts
        );
        core.delegateCall(core.WEB3_MODULE(), data);
    }
    
    function batchDonateWithPermits(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "batchDonateWithPermits(uint256[],uint256[],uint256[],uint8[],bytes32[],bytes32[])",
            fundraiserIds, amounts, deadlines, vs, rs, ss
        );
        core.delegateCall(core.WEB3_MODULE(), data);
    }

    function supportsPermit(address token) external view returns (bool) {
        address web3Module = core.getModule(core.WEB3_MODULE());
        if (web3Module == address(0)) return false;
        return IPoliDaoWeb3(web3Module).supportsPermit(token);
    }
    
    function getNonce(address user) external view returns (uint256) {
        address web3Module = core.getModule(core.WEB3_MODULE());
        if (web3Module == address(0)) return 0;
        return IPoliDaoWeb3(web3Module).getNonce(user);
    }
    
    function verifyDonationSignature(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external view returns (bool) {
        address web3Module = core.getModule(core.WEB3_MODULE());
        if (web3Module == address(0)) return false;
        return IPoliDaoWeb3(web3Module).verifyDonationSignature(
            donor, fundraiserId, amount, deadline, signature
        );
    }

    // ========== ANALYTICS MODULE WRAPPERS ==========
    
    function getPlatformStats() external view returns (
        uint256 totalFundraisers,
        uint256 totalProposals,
        uint256 totalUpdates,
        uint256 activeFundraisers,
        uint256 successfulFundraisers,
        uint256 suspendedFundraisers,
        uint256 totalWhitelistedTokens
    ) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (0, 0, 0, 0, 0, 0, 0);
        }
        return IPoliDaoAnalytics(analyticsModule).getPlatformStats();
    }
    
    function getFundraiserStats(uint256 fundraiserId) external view returns (
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
    ) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, false);
        }
        return IPoliDaoAnalytics(analyticsModule).getFundraiserStats(fundraiserId);
    }
    
    function getTopFundraisers(uint256 limit) external view returns (
        uint256[] memory fundraiserIds,
        uint256[] memory amounts,
        string[] memory titles
    ) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new uint256[](0), new uint256[](0), new string[](0));
        }
        return IPoliDaoAnalytics(analyticsModule).getTopFundraisers(limit);
    }
    
    function getRecentActivity(uint256 timeHours) external view returns (
        uint256 newFundraisers,
        uint256 totalDonations,
        uint256 uniqueDonors,
        uint256 newProposals,
        uint256 newUpdates
    ) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (0, 0, 0, 0, 0);
        }
        return IPoliDaoAnalytics(analyticsModule).getRecentActivity(timeHours);
    }

    function getFundraisersByStatus(uint8 status, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new uint256[](0), 0);
        }
        return IPoliDaoAnalytics(analyticsModule).getFundraisersByStatus(status, offset, limit);
    }

    function getFundraisersByCreator(address creator, uint256 offset, uint256 limit) 
        external 
        view 
        returns (uint256[] memory ids, uint256 total) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new uint256[](0), 0);
        }
        return IPoliDaoAnalytics(analyticsModule).getFundraisersByCreator(creator, offset, limit);
    }

    function getMarketTrends(uint256 timeDays) 
        external 
        view 
        returns (
            uint256[] memory dailyVolume,
            uint256[] memory dailyFundraisers,
            uint256[] memory successRate
        ) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new uint256[](0), new uint256[](0), new uint256[](0));
        }
        return IPoliDaoAnalytics(analyticsModule).getMarketTrends(timeDays);
    }

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
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        }
        return IPoliDaoAnalytics(analyticsModule).getTokenAnalytics();
    }

    // ========== NEW DONORS FUNCTIONS ==========
    
    function getDonors(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory donors, uint256[] memory amounts, uint256 total) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new address[](0), new uint256[](0), 0);
        }
        return IPoliDaoAnalytics(analyticsModule).getDonors(fundraiserId, offset, limit);
    }

    function getDonorsCount(uint256 fundraiserId) external view returns (uint256) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) return 0;
        return IPoliDaoAnalytics(analyticsModule).getDonorsCount(fundraiserId);
    }

    function getTopDonors(uint256 fundraiserId, uint256 limit) 
        external 
        view 
        returns (address[] memory topDonors, uint256[] memory topAmounts) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new address[](0), new uint256[](0));
        }
        return IPoliDaoAnalytics(analyticsModule).getTopDonors(fundraiserId, limit);
    }

    // ========== NEW EXTENSION FUNCTIONS ==========
    
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external {
        core.extendFundraiser(fundraiserId, additionalDays);
    }

    function canExtendFundraiser(uint256 fundraiserId) 
        external 
        view 
        returns (bool canExtend, uint256 timeLeft, string memory reason) 
    {
        return core.canExtendFundraiser(fundraiserId);
    }

    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 extensionCount, uint256 originalEndDate, uint256 currentEndDate) 
    {
        return core.getExtensionInfo(fundraiserId);
    }

    // ========== NEW LOCATION FUNCTIONS ==========
    
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external {
        core.updateLocation(fundraiserId, newLocation);
    }

    function getFundraiserLocation(uint256 fundraiserId) external view returns (string memory) {
        return core.getFundraiserLocation(fundraiserId);
    }

    // ========== REFUNDS MODULE WRAPPERS ==========
    
    function refund(uint256 fundraiserId) external {
        bytes memory data = abi.encodeWithSignature("refund(uint256)", fundraiserId);
        core.delegateCall(core.REFUNDS_MODULE(), data);
    }
    
    function initiateClosure(uint256 fundraiserId) external {
        bytes memory data = abi.encodeWithSignature("initiateClosure(uint256)", fundraiserId);
        core.delegateCall(core.REFUNDS_MODULE(), data);
    }
    
    function canRefund(uint256 fundraiserId, address donor) external view returns (bool, string memory) {
        address refundsModule = core.getModule(core.REFUNDS_MODULE());
        if (refundsModule == address(0)) {
            return (false, "Refunds module not set");
        }
        return IPoliDaoRefunds(refundsModule).canRefund(
            fundraiserId, donor, 0, 0, 0, false
        );
    }

    function withdrawFlexibleFunds(uint256 fundraiserId) external {
        bytes memory data = abi.encodeWithSignature("withdrawFlexible(uint256)", fundraiserId);
        core.delegateCall(core.REFUNDS_MODULE(), data);
    }

    // ========== SECURITY MODULE WRAPPERS ==========
    
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external {
        bytes memory data = abi.encodeWithSignature("suspendFundraiser(uint256,string)", fundraiserId, reason);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function unsuspendFundraiser(uint256 fundraiserId) external {
        bytes memory data = abi.encodeWithSignature("unsuspendFundraiser(uint256)", fundraiserId);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function activateEmergencyPause(string calldata reason) external {
        bytes memory data = abi.encodeWithSignature("activateEmergencyPause(string)", reason);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function suspendUser(address user, uint256 duration, string calldata reason) external {
        bytes memory data = abi.encodeWithSignature("suspendUser(address,uint256,string)", user, duration, reason);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function suspendToken(address token, string calldata reason) external {
        bytes memory data = abi.encodeWithSignature("suspendToken(address,string)", token, reason);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function getSecurityStatus() 
        external 
        view 
        returns (
            bool emergencyPaused,
            IPoliDaoSecurity.SecurityLevel securityLevel,
            bool userSuspended,
            string memory emergencyReason
        ) 
    {
        address securityModule = core.getModule(core.SECURITY_MODULE());
        if (securityModule == address(0)) {
            return (false, IPoliDaoSecurity.SecurityLevel.NORMAL, false, "");
        }
        
        IPoliDaoSecurity security = IPoliDaoSecurity(securityModule);
        
        (emergencyPaused, , , emergencyReason) = security.getEmergencyPauseStatus();
        (securityLevel, , ) = security.getSecurityLevel();
        (userSuspended, , ) = security.isUserSuspended(msg.sender);
    }

    function isFundraiserSuspended(uint256 fundraiserId) 
        external 
        view 
        returns (bool isSuspended, string memory reason) 
    {
        address securityModule = core.getModule(core.SECURITY_MODULE());
        if (securityModule == address(0)) {
            return (false, "");
        }
        
        return IPoliDaoSecurity(securityModule).isFundraiserSuspended(fundraiserId);
    }

    // ========== GOVERNANCE MODULE WRAPPERS ==========
    
    function createProposal(
        string calldata title,
        string calldata description,
        uint256 votingPeriod
    ) external returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "createProposal(string,string,uint256)",
            title, description, votingPeriod
        );
        bytes memory result = core.delegateCall(core.GOVERNANCE_MODULE(), data);
        return abi.decode(result, (uint256));
    }

    function vote(uint256 proposalId, bool support) external {
        bytes memory data = abi.encodeWithSignature("vote(uint256,bool)", proposalId, support);
        core.delegateCall(core.GOVERNANCE_MODULE(), data);
    }

    function executeProposal(uint256 proposalId) external {
        bytes memory data = abi.encodeWithSignature("executeProposal(uint256)", proposalId);
        core.delegateCall(core.GOVERNANCE_MODULE(), data);
    }

    // ========== MEDIA MODULE WRAPPERS ==========
    
    function uploadMedia(
        uint256 fundraiserId,
        string calldata mediaHash,
        string calldata mediaType,
        string calldata description
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "uploadMedia(uint256,string,string,string)",
            fundraiserId, mediaHash, mediaType, description
        );
        core.delegateCall(core.MEDIA_MODULE(), data);
    }

    function removeMedia(uint256 fundraiserId, uint256 mediaId) external {
        bytes memory data = abi.encodeWithSignature("removeMedia(uint256,uint256)", fundraiserId, mediaId);
        core.delegateCall(core.MEDIA_MODULE(), data);
    }

    // ========== UPDATES MODULE WRAPPERS ==========
    
    function createUpdate(
        uint256 fundraiserId,
        string calldata title,
        string calldata content
    ) external returns (uint256) {
        bytes memory data = abi.encodeWithSignature(
            "createUpdate(uint256,string,string)",
            fundraiserId, title, content
        );
        bytes memory result = core.delegateCall(core.UPDATES_MODULE(), data);
        return abi.decode(result, (uint256));
    }

    function editUpdate(
        uint256 updateId,
        string calldata newTitle,
        string calldata newContent
    ) external {
        bytes memory data = abi.encodeWithSignature(
            "editUpdate(uint256,string,string)",
            updateId, newTitle, newContent
        );
        core.delegateCall(core.UPDATES_MODULE(), data);
    }

    function deleteUpdate(uint256 updateId) external {
        bytes memory data = abi.encodeWithSignature("deleteUpdate(uint256)", updateId);
        core.delegateCall(core.UPDATES_MODULE(), data);
    }

    // ========== TRACKING FUNCTIONS (NON-VIEW FOR ANALYTICS) ==========
    
    function trackPlatformStatsQuery() external {
        bytes memory data = abi.encodeWithSignature("getPlatformStatsWithTracking()");
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    function trackFundraiserStatsQuery(uint256 fundraiserId) external {
        bytes memory data = abi.encodeWithSignature("getFundraiserStatsWithTracking(uint256)", fundraiserId);
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    function trackTopFundraisersQuery(uint256 limit) external {
        bytes memory data = abi.encodeWithSignature("getTopFundraisersWithTracking(uint256)", limit);
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    function trackRecentActivityQuery(uint256 timeHours) external {
        bytes memory data = abi.encodeWithSignature("getRecentActivityWithTracking(uint256)", timeHours);
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    function trackMarketTrendsQuery(uint256 timeDays) external {
        bytes memory data = abi.encodeWithSignature("getMarketTrendsWithTracking(uint256)", timeDays);
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    function trackTokenAnalyticsQuery() external {
        bytes memory data = abi.encodeWithSignature("getTokenAnalyticsWithTracking()");
        core.delegateCall(core.ANALYTICS_MODULE(), data);
    }

    // ========== UTILITY FUNCTIONS ==========
    
    function getAllModules() external view returns (
        address governance,
        address media,
        address updates,
        address refunds,
        address security,
        address web3,
        address analytics
    ) {
        governance = core.getModule(core.GOVERNANCE_MODULE());
        media = core.getModule(core.MEDIA_MODULE());
        updates = core.getModule(core.UPDATES_MODULE());
        refunds = core.getModule(core.REFUNDS_MODULE());
        security = core.getModule(core.SECURITY_MODULE());
        web3 = core.getModule(core.WEB3_MODULE());
        analytics = core.getModule(core.ANALYTICS_MODULE());
    }

    function isModuleActive(bytes32 moduleKey) external view returns (bool) {
        return core.getModule(moduleKey) != address(0);
    }

    function getModuleAddress(bytes32 moduleKey) external view returns (address) {
        return core.getModule(moduleKey);
    }

    // ========== BATCH OPERATIONS ==========
    
    function batchStaticCall(
        bytes32[] calldata moduleKeys,
        bytes[] calldata datas
    ) external view returns (bytes[] memory results) {
        require(moduleKeys.length == datas.length, "Array length mismatch");
        
        results = new bytes[](moduleKeys.length);
        
        for (uint256 i = 0; i < moduleKeys.length; i++) {
            results[i] = core.staticCall(moduleKeys[i], datas[i]);
        }
    }

    function batchDelegateCall(
        bytes32[] calldata moduleKeys,
        bytes[] calldata datas
    ) external returns (bytes[] memory results) {
        require(moduleKeys.length == datas.length, "Array length mismatch");
        
        results = new bytes[](moduleKeys.length);
        
        for (uint256 i = 0; i < moduleKeys.length; i++) {
            results[i] = core.delegateCall(moduleKeys[i], datas[i]);
        }
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    function emergencyPause(string calldata reason) external {
        bytes memory data = abi.encodeWithSignature("activateEmergencyPause(string)", reason);
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    function emergencyUnpause() external {
        bytes memory data = abi.encodeWithSignature("deactivateEmergencyPause()");
        core.delegateCall(core.SECURITY_MODULE(), data);
    }

    // ========== EVENTS ==========
    
    event RouterFunctionCalled(
        bytes32 indexed moduleKey,
        string functionName,
        address indexed caller,
        uint256 timestamp
    );

    event BatchOperationExecuted(
        uint256 operationCount,
        address indexed executor,
        uint256 timestamp
    );
}