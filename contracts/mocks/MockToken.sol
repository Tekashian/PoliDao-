// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    // POPRAWKA: Dodano immutable dla zmiennej która nie zmienia się po deployment
    uint8 private immutable _customDecimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply,
        address initialOwner
    ) ERC20(name, symbol) {
        // POPRAWKA: Dodano walidację zero-address
        require(initialOwner != address(0), "Invalid owner address");
        require(decimals_ > 0 && decimals_ <= 18, "Invalid decimals"); // Dodatkowa walidacja
        require(initialSupply > 0, "Initial supply must be greater than 0"); // Dodatkowa walidacja
        
        _customDecimals = decimals_;
        _mint(initialOwner, initialSupply * (10 ** decimals_));
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    /**
     * @notice Dodatkowa funkcja dla testów - mint więcej tokenów
     * @param to Adres otrzymujący tokeny
     * @param amount Ilość tokenów do mint
     */
    function mint(address to, uint256 amount) external {
        require(to != address(0), "Cannot mint to zero address");
        _mint(to, amount);
    }

    /**
     * @notice Dodatkowa funkcja dla testów - burn tokeny
     * @param amount Ilość tokenów do burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}