// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1967Proxy as OZERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Thin wrapper to expose OpenZeppelin ERC1967Proxy artifact for Hardhat
contract ERC1967Proxy is OZERC1967Proxy {
    constructor(address _logic, bytes memory _data) OZERC1967Proxy(_logic, _data) {}
}
