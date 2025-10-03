const { ethers } = require("hardhat");

before(async function () {
  // Provide a default value for tests that reference this variable
  global.someContractAddress = ethers.ZeroAddress;
});
