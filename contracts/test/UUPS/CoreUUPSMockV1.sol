// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title CoreUUPSMockV1
/// @notice Minimalny przykład kontraktu w stylu UUPS (upgrade'owalny)
/// @dev Trzyma referencję do Storage i prosty stan (greeting), aby pokazać zachowanie po upgrade.
contract CoreUUPSMockV1 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address public storageContract; // referencja do "szafy" z danymi
    string public greeting;

    /// @dev UUPS wymaga initializer zamiast konstruktora
    function initialize(address _storage, string memory _greeting) public initializer {
        require(_storage != address(0), "zero storage");
        __Ownable_init(msg.sender); // OZ v5: przekazujemy initial owner
        __UUPSUpgradeable_init();
        storageContract = _storage;
        greeting = _greeting;
    }

    function setGreeting(string calldata g) external onlyOwner {
        greeting = g;
    }

    function version() external pure virtual returns (string memory) {
        return "V1";
    }

    /// @dev W UUPS ochrona upgrade trafia tutaj
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
