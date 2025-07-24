// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ========== POPRAWIONE IMPORTY ==========
import "../interfaces/IPoliDao.sol";          // ZMIANA: Interface zamiast implementacji
import "../PoliDaoRouter.sol";
import "../modules/PoliDaoGovernance.sol";
import "../modules/PoliDaoMedia.sol";
import "../modules/PoliDaoUpdates.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReentrancyAttackMock - ZAKTUALIZOWANY DLA ROUTER ARCHITEKTURY
 * @notice Kontrakt testowy do symulacji ataku reentrancy na modularną architekturę PoliDAO
 * @dev NOWA WERSJA dla architektury Core + Router + Modules
 */
contract ReentrancyAttackMock is IPoliDaoStructs {
    
    // ========== STORAGE ==========
    
    IPoliDao public immutable coreContract;             // POPRAWIONE: Interface zamiast konkretnej implementacji
    PoliDaoRouter public immutable routerContract;      // NOWE: Router do wrapper'ów
    PoliDaoGovernance public immutable governanceModule;
    PoliDaoMedia public immutable mediaModule;
    PoliDaoUpdates public immutable updatesModule;
    
    address public immutable token;
    address public immutable attacker;
    
    uint256 public targetFundraiser;
    uint256 public targetProposal;
    AttackType public currentAttackType;
    bool public hasAttacked;
    uint256 public attackCount;
    
    // ========== CONSTANTS ==========
    uint256 constant MIN_EXTENSION_NOTICE = 7 days;
    uint256 constant MAX_EXTENSION_DAYS = 90;
    uint256 constant MAX_LOCATION_LENGTH = 200;
    
    // ========== ENUMS ==========
    
    enum AttackType {
        DONATION_CORE,          // Atak na podstawową donację (Core)
        DONATION_ROUTER,        // Atak na donację przez Router
        WITHDRAW_CORE,          // Atak na wypłatę (Core)
        GOVERNANCE_ROUTER,      // Atak na governance przez Router
        MEDIA_ROUTER,           // Atak na media przez Router
        UPDATE_ROUTER,          // Atak na updates przez Router
        DELEGATE_CALL_CORE,     // Atak na delegateCall (Core)
        BATCH_DONATION_ROUTER,  // NOWE: Atak na batch donation
        PERMIT_DONATION_ROUTER, // NOWE: Atak na permit donation
        SECURITY_ROUTER         // NOWE: Atak na security funkcje
    }
    
    // ========== EVENTS ==========
    
    event AttackInitiated(AttackType attackType, uint256 targetId);
    event ReentrancyAttempted(AttackType attackType, bool success);
    event AttackCompleted(AttackType attackType, uint256 attempts);
    event RouterAttackAttempted(string functionName, bool success);
    
    // ========== CONSTRUCTOR ==========
    
    constructor(
        address _coreContract,                // ZMIANA: Core jako interface
        address _routerContract,              // NOWE: Router
        address _governanceModule,
        address _mediaModule,
        address _updatesModule,
        address _token
    ) {
        require(_coreContract != address(0), "Invalid core contract");
        require(_routerContract != address(0), "Invalid router contract");
        require(_governanceModule != address(0), "Invalid governance module");
        require(_mediaModule != address(0), "Invalid media module");
        require(_updatesModule != address(0), "Invalid updates module");
        require(_token != address(0), "Invalid token");
        
        coreContract = IPoliDao(_coreContract);             // POPRAWIONE: Interface cast
        routerContract = PoliDaoRouter(_routerContract);
        governanceModule = PoliDaoGovernance(_governanceModule);
        mediaModule = PoliDaoMedia(_mediaModule);
        updatesModule = PoliDaoUpdates(_updatesModule);
        
        token = _token;
        attacker = msg.sender;
    }
    
    // ========== SETUP FUNCTIONS ==========
    
    /**
     * @notice Przygotowuje kontrakt do ataku
     */
    function setupForAttack(uint256 _fundraiserId, uint256 _amount) external {
        require(msg.sender == attacker, "Only attacker");
        
        // Transfer tokens from attacker
        require(
            IERC20(token).transferFrom(msg.sender, address(this), _amount),
            "Transfer from failed"
        );
        
        // Approve both core and router contracts
        require(
            IERC20(token).approve(address(coreContract), _amount),
            "Core approval failed"
        );
        require(
            IERC20(token).approve(address(routerContract), _amount),
            "Router approval failed"
        );
        
        // Make initial donation for refund attacks (through core)
        coreContract.donate(_fundraiserId, _amount);
        
        targetFundraiser = _fundraiserId;
    }
    
    /**
     * @notice Przygotowuje propozycję dla ataku governance - PRZEZ ROUTER
     */
    function setupGovernanceAttack(string calldata _question, uint256 _duration) external {
        require(msg.sender == attacker, "Only attacker");
        
        // Create proposal through Router (nowa architektura)
        try routerContract.createProposal(_question, "", _duration) returns (uint256 proposalId) {
            targetProposal = proposalId;
        } catch {
            // Fallback: estimate proposal ID
            targetProposal = 1; // Simplified fallback
        }
    }
    
    // ========== CORE ATTACKS ==========
    
    /**
     * @notice Atakuje podstawową funkcję donate (Core)
     */
    function attackCoreDonation(uint256 _fundraiserId, uint256 _amount) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.DONATION_CORE;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.DONATION_CORE, _fundraiserId);
        
        // Attack core contract donation
        coreContract.donate(_fundraiserId, _amount);
        
        emit AttackCompleted(AttackType.DONATION_CORE, attackCount);
    }
    
    /**
     * @notice Atakuje funkcję withdraw (Core)
     */
    function attackCoreWithdraw(uint256 _fundraiserId) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.WITHDRAW_CORE;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.WITHDRAW_CORE, _fundraiserId);
        
        try coreContract.withdrawFunds(_fundraiserId) {
            // Withdrawal succeeded
        } catch {
            // Withdrawal failed (expected if not creator)
        }
        
        emit AttackCompleted(AttackType.WITHDRAW_CORE, attackCount);
    }
    
    /**
     * @notice Atakuje delegateCall (Core)
     */
    function attackDelegateCall(bytes calldata _data) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.DELEGATE_CALL_CORE;
        
        emit AttackInitiated(AttackType.DELEGATE_CALL_CORE, 0);
        
        try coreContract.delegateCall(coreContract.GOVERNANCE_MODULE(), _data) {
            // Delegate call succeeded
        } catch {
            // Delegate call failed
        }
        
        emit AttackCompleted(AttackType.DELEGATE_CALL_CORE, attackCount);
    }
    
    // ========== ROUTER ATTACKS ==========
    
    /**
     * @notice Atakuje donację przez Router
     */
    function attackRouterDonation(uint256 _fundraiserId, uint256 _amount) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.DONATION_ROUTER;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.DONATION_ROUTER, _fundraiserId);
        
        // Attack through router (should delegate to core)
        try routerContract.batchDonate(_toArray(_fundraiserId), _toArray(_amount)) {
            emit RouterAttackAttempted("batchDonate", true);
        } catch {
            emit RouterAttackAttempted("batchDonate", false);
        }
        
        emit AttackCompleted(AttackType.DONATION_ROUTER, attackCount);
    }
    
    /**
     * @notice Atakuje batch donation przez Router
     */
    function attackBatchDonation(uint256[] calldata _fundraiserIds, uint256[] calldata _amounts) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.BATCH_DONATION_ROUTER;
        
        emit AttackInitiated(AttackType.BATCH_DONATION_ROUTER, _fundraiserIds.length);
        
        try routerContract.batchDonate(_fundraiserIds, _amounts) {
            emit RouterAttackAttempted("batchDonate", true);
        } catch {
            emit RouterAttackAttempted("batchDonate", false);
        }
        
        emit AttackCompleted(AttackType.BATCH_DONATION_ROUTER, attackCount);
    }
    
    /**
     * @notice Atakuje permit donation przez Router  
     */
    function attackPermitDonation(
        uint256 _fundraiserId,
        uint256 _amount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.PERMIT_DONATION_ROUTER;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.PERMIT_DONATION_ROUTER, _fundraiserId);
        
        try routerContract.donateWithPermit(_fundraiserId, _amount, _deadline, _v, _r, _s) {
            emit RouterAttackAttempted("donateWithPermit", true);
        } catch {
            emit RouterAttackAttempted("donateWithPermit", false);
        }
        
        emit AttackCompleted(AttackType.PERMIT_DONATION_ROUTER, attackCount);
    }
    
    /**
     * @notice Atakuje governance przez Router
     */
    function attackRouterGovernance(uint256 _proposalId, bool _support) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.GOVERNANCE_ROUTER;
        targetProposal = _proposalId;
        
        emit AttackInitiated(AttackType.GOVERNANCE_ROUTER, _proposalId);
        
        try routerContract.vote(_proposalId, _support) {
            emit RouterAttackAttempted("vote", true);
        } catch {
            emit RouterAttackAttempted("vote", false);
        }
        
        emit AttackCompleted(AttackType.GOVERNANCE_ROUTER, attackCount);
    }
    
    /**
     * @notice Atakuje security functions przez Router
     */
    function attackRouterSecurity(uint256 _fundraiserId, string calldata _reason) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.SECURITY_ROUTER;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.SECURITY_ROUTER, _fundraiserId);
        
        try routerContract.suspendFundraiser(_fundraiserId, _reason) {
            emit RouterAttackAttempted("suspendFundraiser", true);
        } catch {
            emit RouterAttackAttempted("suspendFundraiser", false);
        }
        
        emit AttackCompleted(AttackType.SECURITY_ROUTER, attackCount);
    }
    
    /**
     * @notice Atakuje analytics przez Router
     */
    function attackRouterAnalytics() external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        
        emit AttackInitiated(AttackType.SECURITY_ROUTER, 0); // Reuse enum
        
        try routerContract.getPlatformStats() {
            emit RouterAttackAttempted("getPlatformStats", true);
        } catch {
            emit RouterAttackAttempted("getPlatformStats", false);
        }
        
        try routerContract.getTopFundraisers(10) {
            emit RouterAttackAttempted("getTopFundraisers", true);
        } catch {
            emit RouterAttackAttempted("getTopFundraisers", false);
        }
        
        emit AttackCompleted(AttackType.SECURITY_ROUTER, attackCount);
    }
    
    // ========== REENTRANCY CALLBACKS ==========
    
    /**
     * @notice Fallback function - główny punkt reentrancy
     */
    fallback() external payable {
        _attemptReentrancy();
    }
    
    /**
     * @notice Receive function - alternatywny punkt reentrancy
     */
    receive() external payable {
        _attemptReentrancy();
    }
    
    /**
     * @notice Token transfer callback (jeśli token obsługuje)
     */
    function onTokenTransfer(address, uint256, bytes calldata) external returns (bool) {
        _attemptReentrancy();
        return true;
    }
    
    /**
     * @notice Wykonuje próbę reentrancy na podstawie typu ataku
     */
    function _attemptReentrancy() internal {
        if (hasAttacked || attackCount >= 3) return; // Prevent infinite loops
        
        hasAttacked = true;
        attackCount++;
        
        emit ReentrancyAttempted(currentAttackType, false);
        
        try this.executeReentrancy() {
            emit ReentrancyAttempted(currentAttackType, true);
        } catch {
            emit ReentrancyAttempted(currentAttackType, false);
        }
        
        hasAttacked = false; // Allow multiple attempts
    }
    
    /**
     * @notice Wykonuje właściwą logikę reentrancy - ZAKTUALIZOWANE DLA ROUTER
     */
    function executeReentrancy() external {
        require(msg.sender == address(this), "Internal call only");
        
        if (currentAttackType == AttackType.DONATION_CORE) {
            coreContract.donate(targetFundraiser, 1000);
        } else if (currentAttackType == AttackType.DONATION_ROUTER) {
            routerContract.batchDonate(_toArray(targetFundraiser), _toArray(1000));
        } else if (currentAttackType == AttackType.WITHDRAW_CORE) {
            coreContract.withdrawFunds(targetFundraiser);
        } else if (currentAttackType == AttackType.GOVERNANCE_ROUTER) {
            routerContract.vote(targetProposal, true);
        } else if (currentAttackType == AttackType.BATCH_DONATION_ROUTER) {
            routerContract.batchDonate(_toArray(targetFundraiser), _toArray(500));
        } else if (currentAttackType == AttackType.SECURITY_ROUTER) {
            routerContract.suspendFundraiser(targetFundraiser, "Reentrancy attack");
        }
    }
    
    // ========== UTILITY FUNCTIONS ==========
    
    /**
     * @notice Konwertuje uint256 na array (helper)
     */
    function _toArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = value;
        return array;
    }
    
    /**
     * @notice Resetuje stan ataku
     */
    function _resetAttackState() internal {
        hasAttacked = false;
        attackCount = 0;
    }
    
    /**
     * @notice Sprawdza balanse kontraktu
     */
    function getBalances() external view returns (uint256 tokenBalance, uint256 ethBalance) {
        tokenBalance = IERC20(token).balanceOf(address(this));
        ethBalance = address(this).balance;
    }
    
    /**
     * @notice Sprawdza status ataku
     */
    function getAttackStatus() external view returns (
        AttackType attackType,
        uint256 attempts,
        bool attacked,
        uint256 target
    ) {
        return (currentAttackType, attackCount, hasAttacked, targetFundraiser);
    }
    
    /**
     * @notice Sprawdza adresy kontraktów
     */
    function getContractAddresses() external view returns (
        address core,
        address router,
        address governance,
        address media,
        address updates
    ) {
        return (
            address(coreContract),
            address(routerContract), 
            address(governanceModule),
            address(mediaModule),
            address(updatesModule)
        );
    }
    
    /**
     * @notice Test wszystkich Router functions
     * @dev POPRAWIONE: usunięto nieużywany parametr _fundraiserId
     */
    function testRouterFunctions() external view returns (
        bool supportsPermit,
        uint256 nonce,
        bool isModuleActive
    ) {
        try routerContract.supportsPermit(token) returns (bool result) {
            supportsPermit = result;
        } catch {
            supportsPermit = false;
        }
        
        try routerContract.getNonce(address(this)) returns (uint256 result) {
            nonce = result;
        } catch {
            nonce = 0;
        }
        
        try routerContract.isModuleActive(coreContract.WEB3_MODULE()) returns (bool result) {
            isModuleActive = result;
        } catch {
            isModuleActive = false;
        }
    }
    
    /**
     * @notice Emergency cleanup
     */
    function emergencyWithdraw() external {
        require(msg.sender == attacker, "Only attacker");
        
        // Withdraw tokens
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(token).transfer(attacker, tokenBalance);
        }
        
        // Withdraw ETH
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            payable(attacker).transfer(ethBalance);
        }
    }
    
    /**
     * @notice Reset all attack parameters
     */
    function resetAll() external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        targetFundraiser = 0;
        targetProposal = 0;
        currentAttackType = AttackType.DONATION_CORE;
    }
    
    /**
     * @notice Test delegate call encoding for new architecture
     */
    function testDelegateCallEncoding(string calldata question, uint256 duration) external pure returns (bytes memory) {
        return abi.encodeWithSignature("createProposal(string,uint256)", question, duration);
    }
    
    /**
     * @notice Test Router delegate call encoding
     */
    function testRouterCallEncoding(uint256 fundraiserId, uint256 amount) external pure returns (bytes memory) {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = fundraiserId;
        amounts[0] = amount;
        return abi.encodeWithSignature("batchDonate(uint256[],uint256[])", ids, amounts);
    }
}