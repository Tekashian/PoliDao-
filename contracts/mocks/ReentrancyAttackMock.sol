// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../PoliDao.sol";
import "../modules/PoliDaoGovernance.sol";
import "../modules/PoliDaoMedia.sol";
import "../modules/PoliDaoUpdates.sol";
import "../interfaces/IPoliDaoStructs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReentrancyAttackMock
 * @notice Kontrakt testowy do symulacji ataku reentrancy na modularną architekturę PoliDAO
 * @dev ZAKTUALIZOWANY dla nowej architektury bez wrapper functions
 */
contract ReentrancyAttackMock is IPoliDaoStructs {
    
    // ========== STORAGE ==========
    
    PoliDao public immutable mainContract;
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
    
    // ========== ENUMS ==========
    
    enum AttackType {
        DONATION,
        WITHDRAW,
        GOVERNANCE_VOTE,
        MEDIA_UPLOAD,
        UPDATE_POST,
        DELEGATE_CALL
    }
    
    // ========== EVENTS ==========
    
    event AttackInitiated(AttackType attackType, uint256 targetId);
    event ReentrancyAttempted(AttackType attackType, bool success);
    event AttackCompleted(AttackType attackType, uint256 attempts);
    
    // ========== CONSTRUCTOR ==========
    
    constructor(
        address payable _mainContract,
        address _governanceModule,
        address _mediaModule,
        address _updatesModule,
        address _token
    ) {
        require(_mainContract != address(0), "Invalid main contract");
        require(_governanceModule != address(0), "Invalid governance module");
        require(_mediaModule != address(0), "Invalid media module");
        require(_updatesModule != address(0), "Invalid updates module");
        require(_token != address(0), "Invalid token");
        
        mainContract = PoliDao(_mainContract);
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
        
        // Approve main contract
        require(
            IERC20(token).approve(address(mainContract), _amount),
            "Approval failed"
        );
        
        // Make initial donation for refund attacks
        mainContract.donate(_fundraiserId, _amount);
        
        targetFundraiser = _fundraiserId;
    }
    
    /**
     * @notice Przygotowuje propozycję dla ataku governance - BEZPOŚREDNIO PRZEZ MODUŁ
     */
    function setupGovernanceAttack(string calldata _question, uint256 _duration) external {
        require(msg.sender == attacker, "Only attacker");
        
        // Create proposal DIRECTLY through governance module
        governanceModule.createProposal(_question, _duration);
        targetProposal = governanceModule.getProposalCount();
    }
    
    // ========== ATTACK FUNCTIONS ==========
    
    /**
     * @notice Atakuje funkcję donate
     */
    function attackDonation(uint256 _fundraiserId, uint256 _amount) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.DONATION;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.DONATION, _fundraiserId);
        
        // Attack main contract donation
        mainContract.donate(_fundraiserId, _amount);
        
        emit AttackCompleted(AttackType.DONATION, attackCount);
    }
    
    /**
     * @notice Atakuje funkcję withdraw
     */
    function attackWithdraw(uint256 _fundraiserId) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.WITHDRAW;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.WITHDRAW, _fundraiserId);
        
        try mainContract.withdrawFunds(_fundraiserId) {
            // Withdrawal succeeded
        } catch {
            // Withdrawal failed (expected if not creator)
        }
        
        emit AttackCompleted(AttackType.WITHDRAW, attackCount);
    }
    
    /**
     * @notice Atakuje system governance - BEZPOŚREDNIO
     */
    function attackGovernance(uint256 _proposalId, bool _support) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.GOVERNANCE_VOTE;
        targetProposal = _proposalId;
        
        emit AttackInitiated(AttackType.GOVERNANCE_VOTE, _proposalId);
        
        try governanceModule.vote(_proposalId, _support) {
            // Vote succeeded
        } catch {
            // Vote failed
        }
        
        emit AttackCompleted(AttackType.GOVERNANCE_VOTE, attackCount);
    }
    
    /**
     * @notice Atakuje system media - BEZPOŚREDNIO
     */
    function attackMedia(uint256 _fundraiserId) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.MEDIA_UPLOAD;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.MEDIA_UPLOAD, _fundraiserId);
        
        // Prepare media item
        MediaItem[] memory mediaItems = new MediaItem[](1);
        mediaItems[0] = MediaItem({
            ipfsHash: "QmTestHash123",
            mediaType: 0,
            filename: "attack.jpg",
            uploadTime: block.timestamp,
            uploader: address(this),
            description: "Attack test"
        });
        
        try mediaModule.addMediaToFundraiser(_fundraiserId, mediaItems) {
            // Media upload succeeded
        } catch {
            // Media upload failed (expected - not creator)
        }
        
        emit AttackCompleted(AttackType.MEDIA_UPLOAD, attackCount);
    }
    
    /**
     * @notice Atakuje system updates - BEZPOŚREDNIO
     */
    function attackUpdates(uint256 _fundraiserId, string calldata _content) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.UPDATE_POST;
        targetFundraiser = _fundraiserId;
        
        emit AttackInitiated(AttackType.UPDATE_POST, _fundraiserId);
        
        try updatesModule.postUpdate(_fundraiserId, _content, address(this)) {
            // Update succeeded
        } catch {
            // Update failed (expected - not creator)
        }
        
        emit AttackCompleted(AttackType.UPDATE_POST, attackCount);
    }
    
    /**
     * @notice Atakuje delegatecall system
     */
    function attackDelegateCall(bytes calldata _data) external {
        require(msg.sender == attacker, "Only attacker");
        
        _resetAttackState();
        currentAttackType = AttackType.DELEGATE_CALL;
        
        emit AttackInitiated(AttackType.DELEGATE_CALL, 0);
        
        try mainContract.delegateToGovernance(_data) {
            // Delegate call succeeded
        } catch {
            // Delegate call failed
        }
        
        emit AttackCompleted(AttackType.DELEGATE_CALL, attackCount);
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
     * @notice Wykonuje właściwą logikę reentrancy - ZAKTUALIZOWANE
     */
    function executeReentrancy() external {
        require(msg.sender == address(this), "Internal call only");
        
        if (currentAttackType == AttackType.DONATION) {
            mainContract.donate(targetFundraiser, 1000);
        } else if (currentAttackType == AttackType.WITHDRAW) {
            mainContract.withdrawFunds(targetFundraiser);
        } else if (currentAttackType == AttackType.GOVERNANCE_VOTE) {
            // Attack governance module directly
            governanceModule.vote(targetProposal, true);
        } else if (currentAttackType == AttackType.MEDIA_UPLOAD) {
            // Attack media module directly
            MediaItem[] memory items = new MediaItem[](1);
            items[0] = MediaItem("QmTest", 0, "test", block.timestamp, address(this), "test");
            mediaModule.addMediaToFundraiser(targetFundraiser, items);
        } else if (currentAttackType == AttackType.UPDATE_POST) {
            // Attack updates module directly
            updatesModule.postUpdate(targetFundraiser, "Reentrancy attack", address(this));
        }
    }
    
    // ========== UTILITY FUNCTIONS ==========
    
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
        currentAttackType = AttackType.DONATION;
    }
    
    /**
     * @notice Test delegate call encoding
     */
    function testDelegateCallEncoding(string calldata question, uint256 duration) external view returns (bytes memory) {
        return abi.encodeWithSignature("createProposal(string,uint256)", question, duration);
    }
}