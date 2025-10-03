// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockStorage {
    mapping(uint256 => address) public fundraiserTokens;

    function setFundraiserToken(uint256 fundraiserId, address token) external {
        fundraiserTokens[fundraiserId] = token;
    }
}
