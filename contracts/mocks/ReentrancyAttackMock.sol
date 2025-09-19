// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract ReentrancyAttackMock {
    address public target;
    bool public attackExecuted;
    
    // Remove constructor parameters if they're causing issues
    constructor() {
        attackExecuted = false;
    }
    
    function setTarget(address _target) external {
        require(_target != address(0), "ReentrancyAttackMock: zero target"); // added
        target = _target;
    }
    
    function attack() external {
        attackExecuted = true;
        // Basic attack logic placeholder
    }
    
    // Fallback function for reentrancy attempts
    receive() external payable {
        if (target != address(0)) {
            // Attempt reentrancy
            attackExecuted = true;
        }
    }
}