// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPoliDaoStructs.sol";

contract MockStorageForAccounting {
    mapping(uint256 => IPoliDaoStructs.PackedFundraiserData) private _fundraisers;
    mapping(bytes32 => address) public moduleMap;

    function setFundraiser(uint256 id, uint256 raisedAmount) external {
        IPoliDaoStructs.PackedFundraiserData memory f;
        // rzutowania do typów używanych w PackedFundraiserData
        f.id = uint32(id);
        f.raisedAmount = uint128(raisedAmount);
        _fundraisers[id] = f;
    }

    function setModule(bytes32 key, address addr) external {
        moduleMap[key] = addr;
    }

    function fundraisers(uint256 fundraiserId) external view returns (IPoliDaoStructs.PackedFundraiserData memory) {
        return _fundraisers[fundraiserId];
    }

    function modules(bytes32 key) external view returns (address) {
        return moduleMap[key];
    }
}