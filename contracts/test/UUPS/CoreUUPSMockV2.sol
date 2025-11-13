// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CoreUUPSMockV1} from "./CoreUUPSMockV1.sol";

/// @title CoreUUPSMockV2
/// @notice Wersja V2 kompatybilna pamięciowo – rozszerza funkcjonalność i zmienia version()
contract CoreUUPSMockV2 is CoreUUPSMockV1 {
    function version() external pure override returns (string memory) {
        return "V2";
    }

    function double(uint256 x) external pure returns (uint256) {
        return x * 2;
    }
}
