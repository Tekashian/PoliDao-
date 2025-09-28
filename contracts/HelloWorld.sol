// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract HelloWorld {
    function greet() external pure returns (string memory) {
        return "Hello, World!";
    }
}