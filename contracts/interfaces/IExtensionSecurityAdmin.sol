// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExtensionSecurityAdmin {
    function setSecurityModuleWhitelist(address module, bool allowed) external;
    function setSecurityModule(address module) external;
    function freezeSecurityModule() external;
}