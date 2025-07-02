// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../PoliDao.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ReentrancyAttackMock
 * @notice Kontrakt testowy do symulacji ataku reentrancy na kontrakt PoliDAO v3.1
 * @dev Używa payable address casting dla kompatybilności z receive() function
 */
contract ReentrancyAttackMock {
    PoliDAO public dao;
    uint256 public targetFundraiser;
    bool public attackWithdraw;
    address public token;
    bool public hasAttacked; // Zapobiega nieskończonym pętlom
    address public attacker;

    // Fix: Use payable address for compatibility with receive() function
    constructor(address payable _dao, address _token) {
        dao = PoliDAO(_dao);
        token = _token;
        attacker = msg.sender;
    }

    /**
     * @notice Inicjuje atak reentrancy
     * @param _fundraiserId ID zbiórki do ataku
     * @param _attackWithdraw True dla ataku na withdraw, false dla refund
     */
    function attack(uint256 _fundraiserId, bool _attackWithdraw) external {
        require(msg.sender == attacker, "Only attacker can initiate");
        
        targetFundraiser = _fundraiserId;
        attackWithdraw = _attackWithdraw;
        hasAttacked = false; // Reset attack flag

        if (_attackWithdraw) {
            dao.withdraw(_fundraiserId);
        } else {
            dao.refund(_fundraiserId);
        }
    }

    /**
     * @notice Dokonuje donacji do zbiórki (setup przed atakiem)
     * @param _fundraiserId ID zbiórki
     * @param amount Kwota donacji
     */
    function donateToFundraiser(uint256 _fundraiserId, uint256 amount) external {
        // Transfer tokens from caller to this contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Approve DAO contract to spend tokens
        IERC20(token).approve(address(dao), amount);
        
        // Donate to fundraiser
        dao.donate(_fundraiserId, amount);
    }

    /**
     * @notice Fallback function - wykonuje atak reentrancy
     * @dev Zostanie wywołana podczas transferu tokenów z DAO
     */
    fallback() external {
        // Prevent infinite recursion
        if (!hasAttacked) {
            hasAttacked = true;
            
            try this.executeReentrancy() {
                // Reentrancy attempt
            } catch {
                // Reentrancy failed (ReentrancyGuard worked)
            }
        }
    }

    /**
     * @notice Wykonuje właściwy atak reentrancy
     * @dev Wydzielone do osobnej funkcji dla lepszej kontroli
     */
    function executeReentrancy() external {
        require(msg.sender == address(this), "Internal call only");
        
        if (attackWithdraw) {
            dao.withdraw(targetFundraiser);
        } else {
            dao.refund(targetFundraiser);
        }
    }

    /**
     * @notice Receive function - alternatywny punkt wejścia dla ataku
     * @dev Może zostać wywołana jeśli kontrakt otrzyma ETH
     */
    receive() external payable {
        // Alternative reentrancy vector if contract receives ETH
        if (!hasAttacked && targetFundraiser > 0) {
            hasAttacked = true;
            
            try this.executeReentrancy() {
                // Reentrancy attempt via receive
            } catch {
                // Reentrancy failed
            }
        }
    }

    /**
     * @notice Sprawdza saldo tokenów kontraktu
     * @return Saldo tokenów
     */
    function getTokenBalance() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Sprawdza saldo ETH kontraktu
     * @return Saldo ETH
     */
    function getEthBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Emergency function to withdraw tokens (for cleanup)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawTokens(address to, uint256 amount) external {
        require(msg.sender == attacker, "Only attacker");
        IERC20(token).transfer(to, amount);
    }

    /**
     * @notice Emergency function to withdraw ETH (for cleanup)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawEth(address payable to, uint256 amount) external {
        require(msg.sender == attacker, "Only attacker");
        to.transfer(amount);
    }

    /**
     * @notice Reset attack state
     * @dev Useful for multiple test runs
     */
    function resetAttack() external {
        require(msg.sender == attacker, "Only attacker");
        hasAttacked = false;
        targetFundraiser = 0;
        attackWithdraw = false;
    }
}