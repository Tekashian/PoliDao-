const { expect } = require("chai");
const { ethers } = require("hardhat");

// Helpers for canonical auth calls
async function authorize(storage, addr) {
  const ownerAddr = await storage.owner();
  const ownerSigner = await ethers.getSigner(ownerAddr);
  await storage.connect(ownerSigner).authorizeContract(addr);
}
async function deauthorize(storage, addr) {
  const ownerAddr = await storage.owner();
  const ownerSigner = await ethers.getSigner(ownerAddr);
  await storage.connect(ownerSigner).deauthorizeContract(addr);
}

describe("Security - Comprehensive", function () {
  let storage;
  let someContractAddress;

  before(async function () {
    // If this suite already had a fixture, reuse it; otherwise fetch from existing fixtures
    const { deploySystemFixture } = require("../fixtures/deploySystemFixture");
    const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
    const fx = await loadFixture(deploySystemFixture);
    storage = fx.storage;

    // Deploy a dummy contract to act as “some contract”
    const Mock = await ethers.getContractFactory("ReentrancyAttackMock");
    const mock = await Mock.deploy();
    await mock.waitForDeployment();
    someContractAddress = mock.target || mock.address;
  });

  it("prevents unauthorized access to critical functions", async function () {
    // ...existing setup...

    // Use canonical functions (no bool overload)
    await authorize(storage, someContractAddress);
    // ... run protected calls that require authorization ...
    await deauthorize(storage, someContractAddress);

    // ...existing assertions...
  });

  // Replace any other occurrences in this file:
  // - storage.authorizeContract(addr, true)  -> await authorize(storage, addr)
  // - storage.authorizeContract(addr, false) -> await deauthorize(storage, addr)
});