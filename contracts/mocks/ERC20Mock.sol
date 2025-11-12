// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ERC20Mock
/// @notice Minimal ERC20 mock used in tests. Matches constructor used by tests.
contract ERC20Mock is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_,
        address initialAccount,
        uint256 initialBalance
    ) ERC20(name_, symbol_) {
        _mint(initialAccount, initialBalance);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
