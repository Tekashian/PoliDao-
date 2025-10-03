// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMockStorageView {
    function fundraiserTokens(uint256 id) external view returns (address);
}

contract MockCore {
    address private _storage;
    bool private _paused;

    event DonateForwarded(address indexed donor, uint256 indexed fundraiserId, uint256 amount);
    event BatchDonateForwarded(address indexed donor, uint256[] fundraiserIds, uint256[] amounts);

    constructor(address storageAddress) {
        _storage = storageAddress;
        _paused = false;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function storageContract() external view returns (IMockStorageView) {
        return IMockStorageView(_storage);
    }

    // Router forwards here if checks pass
    function donateFrom(uint256 fundraiserId, address donor, uint256 amount) external {
        emit DonateForwarded(donor, fundraiserId, amount);
    }

    function batchDonateFrom(address donor, uint256[] calldata fundraiserIds, uint256[] calldata amounts) external {
        require(fundraiserIds.length == amounts.length, "len mismatch");
        emit BatchDonateForwarded(donor, fundraiserIds, amounts);
    }

    // Stubs to satisfy router compile if ever called
    function getFundraiserCount() external pure returns (uint256) { return 0; }
    function createFundraiserFor(address, bytes calldata) external pure returns (uint256) { return 0; }
}
