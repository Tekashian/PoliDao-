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
 * @title PoliDaoRouter - FIXED ROUTER FOR ALL MODULE FUNCTIONS
 * @notice Wrapper contract providing user-friendly access to all module functions
 * @dev SECURITY FIXES: Enhanced error handling, proper validation, consistent module calling
 */
contract PoliDaoRouter is IPoliDaoStructs {
    
    IPoliDaoCore public immutable core;
    
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
    
    event ModuleCallFailed(
        bytes32 indexed moduleKey,
        string functionName,
        address indexed caller,
        string reason
    );
    
    // ========== MODIFIERS ==========
    
    modifier moduleExists(bytes32 moduleKey) {
        require(core.getModule(moduleKey) != address(0), "Module not available");
        _;
    }
    
    modifier validBatchSize(uint256 size) {
        require(size > 0 && size <= 50, "Invalid batch size");
        _;
    }
    
    // ========== CONSTRUCTOR ==========
    
    constructor(address _core) {
        require(_core != address(0), "Invalid core address");
        core = IPoliDaoCore(_core);
    }

    // ========== WEB3 MODULE WRAPPERS - FIXED ==========
    
    function donateWithPermit(
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 moduleKey = core.WEB3_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "donateWithPermit(uint256,uint256,uint256,uint8,bytes32,bytes32)",
                fundraiserId, amount, deadline, v, r, s
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "donateWithPermit", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "donateWithPermit", msg.sender, reason);
            revert(string(abi.encodePacked("Permit donation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "donateWithPermit", msg.sender, "Unknown error");
            revert("Permit donation failed: Unknown error");
        }
    }
    
    function donateWithMetaTransaction(
        address donor,
        uint256 fundraiserId,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        bytes32 moduleKey = core.WEB3_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "donateWithMetaTransaction(address,uint256,uint256,uint256,bytes)",
                donor, fundraiserId, amount, deadline, signature
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "donateWithMetaTransaction", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "donateWithMetaTransaction", msg.sender, reason);
            revert(string(abi.encodePacked("Meta donation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "donateWithMetaTransaction", msg.sender, "Unknown error");
            revert("Meta donation failed: Unknown error");
        }
    }
    
    function batchDonate(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts
    ) external validBatchSize(fundraiserIds.length) {
        require(fundraiserIds.length == amounts.length, "Array length mismatch");
        
        bytes32 moduleKey = core.WEB3_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "batchDonate(uint256[],uint256[])",
                fundraiserIds, amounts
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "batchDonate", msg.sender, block.timestamp);
            emit BatchOperationExecuted(fundraiserIds.length, msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "batchDonate", msg.sender, reason);
            revert(string(abi.encodePacked("Batch donation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "batchDonate", msg.sender, "Unknown error");
            revert("Batch donation failed: Unknown error");
        }
    }
    
    function batchDonateWithPermits(
        uint256[] calldata fundraiserIds,
        uint256[] calldata amounts,
        uint256[] calldata deadlines,
        uint8[] calldata vs,
        bytes32[] calldata rs,
        bytes32[] calldata ss
    ) external validBatchSize(fundraiserIds.length) {
        require(
            fundraiserIds.length == amounts.length &&
            amounts.length == deadlines.length &&
            deadlines.length == vs.length &&
            vs.length == rs.length &&
            rs.length == ss.length,
            "Array length mismatch"
        );
        
        bytes32 moduleKey = core.WEB3_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "batchDonateWithPermits(uint256[],uint256[],uint256[],uint8[],bytes32[],bytes32[])",
                fundraiserIds, amounts, deadlines, vs, rs, ss
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "batchDonateWithPermits", msg.sender, block.timestamp);
            emit BatchOperationExecuted(fundraiserIds.length, msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "batchDonateWithPermits", msg.sender, reason);
            revert(string(abi.encodePacked("Batch permit donation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "batchDonateWithPermits", msg.sender, "Unknown error");
            revert("Batch permit donation failed: Unknown error");
        }
    }

    function supportsPermit(address token) external view returns (bool) {
        address web3Module = core.getModule(core.WEB3_MODULE());
        if (web3Module == address(0)) return false;
        
        try IPoliDaoWeb3(web3Module).supportsPermit(token) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    function getNonce(address user) external view returns (uint256) {
        address web3Module = core.getModule(core.WEB3_MODULE());
        if (web3Module == address(0)) return 0;
        
        try IPoliDaoWeb3(web3Module).getNonce(user) returns (uint256 result) {
            return result;
        } catch {
            return 0;
        }
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
        
        try IPoliDaoWeb3(web3Module).verifyDonationSignature(
            donor, fundraiserId, amount, deadline, signature
        ) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    // ========== ANALYTICS MODULE WRAPPERS - FIXED ==========
    
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
        
        try IPoliDaoAnalytics(analyticsModule).getPlatformStats() returns (
            uint256 _totalFundraisers,
            uint256 _totalProposals,
            uint256 _totalUpdates,
            uint256 _activeFundraisers,
            uint256 _successfulFundraisers,
            uint256 _suspendedFundraisers,
            uint256 _totalWhitelistedTokens
        ) {
            return (_totalFundraisers, _totalProposals, _totalUpdates, _activeFundraisers, _successfulFundraisers, _suspendedFundraisers, _totalWhitelistedTokens);
        } catch {
            return (0, 0, 0, 0, 0, 0, 0);
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getFundraiserStats(fundraiserId) returns (
            uint256 _totalDonations,
            uint256 _averageDonation,
            uint256 _donorsCount,
            uint256 _refundsCount,
            uint256 _mediaItemsCount,
            uint256 _updatesCount,
            uint256 _daysActive,
            uint256 _goalProgress,
            uint256 _velocity,
            bool _hasReachedGoal
        ) {
            return (_totalDonations, _averageDonation, _donorsCount, _refundsCount, _mediaItemsCount, _updatesCount, _daysActive, _goalProgress, _velocity, _hasReachedGoal);
        } catch {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, false);
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getTopFundraisers(limit) returns (
            uint256[] memory _fundraiserIds,
            uint256[] memory _amounts,
            string[] memory _titles
        ) {
            return (_fundraiserIds, _amounts, _titles);
        } catch {
            return (new uint256[](0), new uint256[](0), new string[](0));
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getRecentActivity(timeHours) returns (
            uint256 _newFundraisers,
            uint256 _totalDonations,
            uint256 _uniqueDonors,
            uint256 _newProposals,
            uint256 _newUpdates
        ) {
            return (_newFundraisers, _totalDonations, _uniqueDonors, _newProposals, _newUpdates);
        } catch {
            return (0, 0, 0, 0, 0);
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getFundraisersByStatus(status, offset, limit) returns (
            uint256[] memory _ids,
            uint256 _total
        ) {
            return (_ids, _total);
        } catch {
            return (new uint256[](0), 0);
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getFundraisersByCreator(creator, offset, limit) returns (
            uint256[] memory _ids,
            uint256 _total
        ) {
            return (_ids, _total);
        } catch {
            return (new uint256[](0), 0);
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getMarketTrends(timeDays) returns (
            uint256[] memory _dailyVolume,
            uint256[] memory _dailyFundraisers,
            uint256[] memory _successRate
        ) {
            return (_dailyVolume, _dailyFundraisers, _successRate);
        } catch {
            return (new uint256[](0), new uint256[](0), new uint256[](0));
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getTokenAnalytics() returns (
            address[] memory _tokens,
            uint256[] memory _volumes,
            uint256[] memory _fundraiserCounts,
            uint256[] memory _averageAmounts
        ) {
            return (_tokens, _volumes, _fundraiserCounts, _averageAmounts);
        } catch {
            return (new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        }
    }

    // ========== FIXED DONORS FUNCTIONS ==========
    
    function getDonors(uint256 fundraiserId, uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory donors, uint256[] memory amounts, uint256 total) 
    {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) {
            return (new address[](0), new uint256[](0), 0);
        }
        
        try IPoliDaoAnalytics(analyticsModule).getDonors(fundraiserId, offset, limit) returns (
            address[] memory _donors,
            uint256[] memory _amounts,
            uint256 _total
        ) {
            return (_donors, _amounts, _total);
        } catch {
            return (new address[](0), new uint256[](0), 0);
        }
    }

    function getDonorsCount(uint256 fundraiserId) external view returns (uint256) {
        address analyticsModule = core.getModule(core.ANALYTICS_MODULE());
        if (analyticsModule == address(0)) return 0;
        
        try IPoliDaoAnalytics(analyticsModule).getDonorsCount(fundraiserId) returns (uint256 count) {
            return count;
        } catch {
            return 0;
        }
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
        
        try IPoliDaoAnalytics(analyticsModule).getTopDonors(fundraiserId, limit) returns (
            address[] memory _topDonors,
            uint256[] memory _topAmounts
        ) {
            return (_topDonors, _topAmounts);
        } catch {
            return (new address[](0), new uint256[](0));
        }
    }

    // ========== EXTENSION FUNCTIONS - DIRECT CORE ACCESS ==========
    
    function extendFundraiser(uint256 fundraiserId, uint256 additionalDays) external {
        try core.extendFundraiser(fundraiserId, additionalDays) {
            emit RouterFunctionCalled(bytes32(0), "extendFundraiser", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(bytes32(0), "extendFundraiser", msg.sender, reason);
            revert(string(abi.encodePacked("Extension failed: ", reason)));
        } catch {
            emit ModuleCallFailed(bytes32(0), "extendFundraiser", msg.sender, "Unknown error");
            revert("Extension failed: Unknown error");
        }
    }

    function canExtendFundraiser(uint256 fundraiserId) 
        external 
        view 
        returns (bool canExtend, uint256 timeLeft, string memory reason) 
    {
        try core.canExtendFundraiser(fundraiserId) returns (
            bool _canExtend,
            uint256 _timeLeft,
            string memory _reason
        ) {
            return (_canExtend, _timeLeft, _reason);
        } catch {
            return (false, 0, "Error checking extension eligibility");
        }
    }

    function getExtensionInfo(uint256 fundraiserId) 
        external 
        view 
        returns (uint256 extensionCount, uint256 originalEndDate, uint256 currentEndDate) 
    {
        try core.getExtensionInfo(fundraiserId) returns (
            uint256 _extensionCount,
            uint256 _originalEndDate,
            uint256 _currentEndDate
        ) {
            return (_extensionCount, _originalEndDate, _currentEndDate);
        } catch {
            return (0, 0, 0);
        }
    }

    // ========== LOCATION FUNCTIONS - DIRECT CORE ACCESS ==========
    
    function updateLocation(uint256 fundraiserId, string calldata newLocation) external {
        try core.updateLocation(fundraiserId, newLocation) {
            emit RouterFunctionCalled(bytes32(0), "updateLocation", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(bytes32(0), "updateLocation", msg.sender, reason);
            revert(string(abi.encodePacked("Location update failed: ", reason)));
        } catch {
            emit ModuleCallFailed(bytes32(0), "updateLocation", msg.sender, "Unknown error");
            revert("Location update failed: Unknown error");
        }
    }

    function getFundraiserLocation(uint256 fundraiserId) external view returns (string memory) {
        try core.getFundraiserLocation(fundraiserId) returns (string memory location) {
            return location;
        } catch {
            return "";
        }
    }

    // ========== REFUNDS MODULE WRAPPERS - FIXED ==========
    
    function refund(uint256 fundraiserId) external {
        bytes32 moduleKey = core.REFUNDS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("refund(uint256)", fundraiserId)
        ) {
            emit RouterFunctionCalled(moduleKey, "refund", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "refund", msg.sender, reason);
            revert(string(abi.encodePacked("Refund failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "refund", msg.sender, "Unknown error");
            revert("Refund failed: Unknown error");
        }
    }
    
    function initiateClosure(uint256 fundraiserId) external {
        bytes32 moduleKey = core.REFUNDS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("initiateClosure(uint256)", fundraiserId)
        ) {
            emit RouterFunctionCalled(moduleKey, "initiateClosure", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "initiateClosure", msg.sender, reason);
            revert(string(abi.encodePacked("Closure initiation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "initiateClosure", msg.sender, "Unknown error");
            revert("Closure initiation failed: Unknown error");
        }
    }
    
    function canRefund(uint256 fundraiserId, address donor) external view returns (bool, string memory) {
        address refundsModule = core.getModule(core.REFUNDS_MODULE());
        if (refundsModule == address(0)) {
            return (false, "Refunds module not set");
        }
        
        try IPoliDaoRefunds(refundsModule).canRefund(
            fundraiserId, donor, 0, 0, 0, false
        ) returns (bool canRefundResult, string memory reason) {
            return (canRefundResult, reason);
        } catch {
            return (false, "Error checking refund eligibility");
        }
    }

    function withdrawFlexibleFunds(uint256 fundraiserId) external {
        bytes32 moduleKey = core.REFUNDS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("withdrawFlexible(uint256)", fundraiserId)
        ) {
            emit RouterFunctionCalled(moduleKey, "withdrawFlexible", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "withdrawFlexible", msg.sender, reason);
            revert(string(abi.encodePacked("Flexible withdrawal failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "withdrawFlexible", msg.sender, "Unknown error");
            revert("Flexible withdrawal failed: Unknown error");
        }
    }

    // ========== SECURITY MODULE WRAPPERS - FIXED ==========
    
    function suspendFundraiser(uint256 fundraiserId, string calldata reason) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("suspendFundraiser(uint256,string)", fundraiserId, reason)
        ) {
            emit RouterFunctionCalled(moduleKey, "suspendFundraiser", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "suspendFundraiser", msg.sender, errorReason);
            revert(string(abi.encodePacked("Suspension failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "suspendFundraiser", msg.sender, "Unknown error");
            revert("Suspension failed: Unknown error");
        }
    }

    function unsuspendFundraiser(uint256 fundraiserId) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("unsuspendFundraiser(uint256)", fundraiserId)
        ) {
            emit RouterFunctionCalled(moduleKey, "unsuspendFundraiser", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "unsuspendFundraiser", msg.sender, errorReason);
            revert(string(abi.encodePacked("Unsuspension failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "unsuspendFundraiser", msg.sender, "Unknown error");
            revert("Unsuspension failed: Unknown error");
        }
    }

    function activateEmergencyPause(string calldata reason) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("activateEmergencyPause(string)", reason)
        ) {
            emit RouterFunctionCalled(moduleKey, "activateEmergencyPause", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "activateEmergencyPause", msg.sender, errorReason);
            revert(string(abi.encodePacked("Emergency pause failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "activateEmergencyPause", msg.sender, "Unknown error");
            revert("Emergency pause failed: Unknown error");
        }
    }

    function suspendUser(address user, uint256 duration, string calldata reason) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("suspendUser(address,uint256,string)", user, duration, reason)
        ) {
            emit RouterFunctionCalled(moduleKey, "suspendUser", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "suspendUser", msg.sender, errorReason);
            revert(string(abi.encodePacked("User suspension failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "suspendUser", msg.sender, "Unknown error");
            revert("User suspension failed: Unknown error");
        }
    }

    function suspendToken(address token, string calldata reason) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("suspendToken(address,string)", token, reason)
        ) {
            emit RouterFunctionCalled(moduleKey, "suspendToken", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "suspendToken", msg.sender, errorReason);
            revert(string(abi.encodePacked("Token suspension failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "suspendToken", msg.sender, "Unknown error");
            revert("Token suspension failed: Unknown error");
        }
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
        
        try IPoliDaoSecurity(securityModule).getEmergencyPauseStatus() returns (
            bool isPaused,
            address, // pausedBy - not used
            uint256, // pausedAt - not used
            string memory reason
        ) {
            emergencyPaused = isPaused;
            emergencyReason = reason;
        } catch {
            emergencyPaused = false;
            emergencyReason = "";
        }
        
        try IPoliDaoSecurity(securityModule).getSecurityLevel() returns (
            IPoliDaoSecurity.SecurityLevel level,
            uint256, // lastChanged - not used
            string memory // reason - not used
        ) {
            securityLevel = level;
        } catch {
            securityLevel = IPoliDaoSecurity.SecurityLevel.NORMAL;
        }
        
        try IPoliDaoSecurity(securityModule).isUserSuspended(msg.sender) returns (
            bool isSuspended,
            uint256, // suspensionEnd - not used
            string memory // reason - not used
        ) {
            userSuspended = isSuspended;
        } catch {
            userSuspended = false;
        }
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
        
        try IPoliDaoSecurity(securityModule).isFundraiserSuspended(fundraiserId) returns (
            bool _isSuspended,
            string memory _reason
        ) {
            return (_isSuspended, _reason);
        } catch {
            return (false, "Error checking suspension status");
        }
    }

    // ========== GOVERNANCE MODULE WRAPPERS - FIXED ==========
    
    function createProposal(
        string calldata title,
        string calldata description,
        uint256 votingPeriod
    ) external returns (uint256) {
        bytes32 moduleKey = core.GOVERNANCE_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "createProposal(string,string,uint256)",
                title, description, votingPeriod
            )
        ) returns (bytes memory result) {
            emit RouterFunctionCalled(moduleKey, "createProposal", msg.sender, block.timestamp);
            return abi.decode(result, (uint256));
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "createProposal", msg.sender, reason);
            revert(string(abi.encodePacked("Proposal creation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "createProposal", msg.sender, "Unknown error");
            revert("Proposal creation failed: Unknown error");
        }
    }

    function vote(uint256 proposalId, bool support) external {
        bytes32 moduleKey = core.GOVERNANCE_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("vote(uint256,bool)", proposalId, support)
        ) {
            emit RouterFunctionCalled(moduleKey, "vote", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "vote", msg.sender, reason);
            revert(string(abi.encodePacked("Vote failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "vote", msg.sender, "Unknown error");
            revert("Vote failed: Unknown error");
        }
    }

    function executeProposal(uint256 proposalId) external {
        bytes32 moduleKey = core.GOVERNANCE_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("executeProposal(uint256)", proposalId)
        ) {
            emit RouterFunctionCalled(moduleKey, "executeProposal", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "executeProposal", msg.sender, reason);
            revert(string(abi.encodePacked("Proposal execution failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "executeProposal", msg.sender, "Unknown error");
            revert("Proposal execution failed: Unknown error");
        }
    }

    // ========== MEDIA MODULE WRAPPERS - FIXED ==========
    
    function uploadMedia(
        uint256 fundraiserId,
        string calldata mediaHash,
        string calldata mediaType,
        string calldata description
    ) external {
        bytes32 moduleKey = core.MEDIA_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "uploadMedia(uint256,string,string,string)",
                fundraiserId, mediaHash, mediaType, description
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "uploadMedia", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "uploadMedia", msg.sender, reason);
            revert(string(abi.encodePacked("Media upload failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "uploadMedia", msg.sender, "Unknown error");
            revert("Media upload failed: Unknown error");
        }
    }

    function removeMedia(uint256 fundraiserId, uint256 mediaId) external {
        bytes32 moduleKey = core.MEDIA_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("removeMedia(uint256,uint256)", fundraiserId, mediaId)
        ) {
            emit RouterFunctionCalled(moduleKey, "removeMedia", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "removeMedia", msg.sender, reason);
            revert(string(abi.encodePacked("Media removal failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "removeMedia", msg.sender, "Unknown error");
            revert("Media removal failed: Unknown error");
        }
    }

    // ========== UPDATES MODULE WRAPPERS - FIXED ==========
    
    function createUpdate(
        uint256 fundraiserId,
        string calldata title,
        string calldata content
    ) external returns (uint256) {
        bytes32 moduleKey = core.UPDATES_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "createUpdate(uint256,string,string)",
                fundraiserId, title, content
            )
        ) returns (bytes memory result) {
            emit RouterFunctionCalled(moduleKey, "createUpdate", msg.sender, block.timestamp);
            return abi.decode(result, (uint256));
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "createUpdate", msg.sender, reason);
            revert(string(abi.encodePacked("Update creation failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "createUpdate", msg.sender, "Unknown error");
            revert("Update creation failed: Unknown error");
        }
    }

    function editUpdate(
        uint256 updateId,
        string calldata newTitle,
        string calldata newContent
    ) external {
        bytes32 moduleKey = core.UPDATES_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature(
                "editUpdate(uint256,string,string)",
                updateId, newTitle, newContent
            )
        ) {
            emit RouterFunctionCalled(moduleKey, "editUpdate", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "editUpdate", msg.sender, reason);
            revert(string(abi.encodePacked("Update edit failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "editUpdate", msg.sender, "Unknown error");
            revert("Update edit failed: Unknown error");
        }
    }

    function deleteUpdate(uint256 updateId) external {
        bytes32 moduleKey = core.UPDATES_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("deleteUpdate(uint256)", updateId)
        ) {
            emit RouterFunctionCalled(moduleKey, "deleteUpdate", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "deleteUpdate", msg.sender, reason);
            revert(string(abi.encodePacked("Update deletion failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "deleteUpdate", msg.sender, "Unknown error");
            revert("Update deletion failed: Unknown error");
        }
    }

    // ========== TRACKING FUNCTIONS FOR ANALYTICS ==========
    
    function trackPlatformStatsQuery() external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getPlatformStatsWithTracking()")
        ) {
            emit RouterFunctionCalled(moduleKey, "trackPlatformStatsQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
    }

    function trackFundraiserStatsQuery(uint256 fundraiserId) external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getFundraiserStatsWithTracking(uint256)", fundraiserId)
        ) {
            emit RouterFunctionCalled(moduleKey, "trackFundraiserStatsQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
    }

    function trackTopFundraisersQuery(uint256 limit) external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getTopFundraisersWithTracking(uint256)", limit)
        ) {
            emit RouterFunctionCalled(moduleKey, "trackTopFundraisersQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
    }

    function trackRecentActivityQuery(uint256 timeHours) external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getRecentActivityWithTracking(uint256)", timeHours)
        ) {
            emit RouterFunctionCalled(moduleKey, "trackRecentActivityQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
    }

    function trackMarketTrendsQuery(uint256 timeDays) external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getMarketTrendsWithTracking(uint256)", timeDays)
        ) {
            emit RouterFunctionCalled(moduleKey, "trackMarketTrendsQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
    }

    function trackTokenAnalyticsQuery() external {
        bytes32 moduleKey = core.ANALYTICS_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("getTokenAnalyticsWithTracking()")
        ) {
            emit RouterFunctionCalled(moduleKey, "trackTokenAnalyticsQuery", msg.sender, block.timestamp);
        } catch {
            // Silent fail for tracking functions
        }
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

    // ========== ENHANCED BATCH OPERATIONS ==========
    
    function batchStaticCall(
        bytes32[] calldata moduleKeys,
        bytes[] calldata datas
    ) external view returns (bytes[] memory results) {
        require(moduleKeys.length == datas.length, "Array length mismatch");
        require(moduleKeys.length <= 10, "Too many operations");
        
        results = new bytes[](moduleKeys.length);
        
        for (uint256 i = 0; i < moduleKeys.length; i++) {
            try core.staticCall(moduleKeys[i], datas[i]) returns (bytes memory result) {
                results[i] = result;
            } catch {
                results[i] = new bytes(0); // Return empty bytes on error
            }
        }
    }

    function batchDelegateCall(
        bytes32[] calldata moduleKeys,
        bytes[] calldata datas
    ) external returns (bytes[] memory results) {
        require(moduleKeys.length == datas.length, "Array length mismatch");
        require(moduleKeys.length <= 10, "Too many operations");
        
        results = new bytes[](moduleKeys.length);
        
        for (uint256 i = 0; i < moduleKeys.length; i++) {
            try core.delegateCall(moduleKeys[i], datas[i]) returns (bytes memory result) {
                results[i] = result;
            } catch Error(string memory reason) {
                emit ModuleCallFailed(moduleKeys[i], "batchDelegateCall", msg.sender, reason);
                revert(string(abi.encodePacked("Batch operation failed at index ", _toString(i), ": ", reason)));
            } catch {
                emit ModuleCallFailed(moduleKeys[i], "batchDelegateCall", msg.sender, "Unknown error");
                revert(string(abi.encodePacked("Batch operation failed at index ", _toString(i), ": Unknown error")));
            }
        }
        
        emit BatchOperationExecuted(moduleKeys.length, msg.sender, block.timestamp);
    }

    // ========== EMERGENCY FUNCTIONS ==========
    
    function emergencyPause(string calldata reason) external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("activateEmergencyPause(string)", reason)
        ) {
            emit RouterFunctionCalled(moduleKey, "emergencyPause", msg.sender, block.timestamp);
        } catch Error(string memory errorReason) {
            emit ModuleCallFailed(moduleKey, "emergencyPause", msg.sender, errorReason);
            revert(string(abi.encodePacked("Emergency pause failed: ", errorReason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "emergencyPause", msg.sender, "Unknown error");
            revert("Emergency pause failed: Unknown error");
        }
    }

    function emergencyUnpause() external {
        bytes32 moduleKey = core.SECURITY_MODULE();
        
        try core.delegateCall(
            moduleKey,
            abi.encodeWithSignature("deactivateEmergencyPause()")
        ) {
            emit RouterFunctionCalled(moduleKey, "emergencyUnpause", msg.sender, block.timestamp);
        } catch Error(string memory reason) {
            emit ModuleCallFailed(moduleKey, "emergencyUnpause", msg.sender, reason);
            revert(string(abi.encodePacked("Emergency unpause failed: ", reason)));
        } catch {
            emit ModuleCallFailed(moduleKey, "emergencyUnpause", msg.sender, "Unknown error");
            revert("Emergency unpause failed: Unknown error");
        }
    }

    // ========== INTERNAL UTILITY FUNCTIONS ==========
    
    /**
     * @notice Convert uint256 to string
     * @param value The value to convert
     * @return String representation
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}