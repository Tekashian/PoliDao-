const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

describe("PoliDaoStorage - unit tests (storage access & config)", function () {
  it("releaseFunds: only core can call; direct call reverts", async function () {
    const { storage, alice } = await loadFixture(deploySystemFixture);
    await expect(
      storage.connect(alice).releaseFunds(ethers.ZeroAddress, alice.address, 1)
    ).to.be.revertedWith("Storage: only Core");
  });

  it("releaseFunds: authorized via core path", async function () {
    const { storage, core, owner } = await loadFixture(deploySystemFixture);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    // zasil Storage w tokeny
    await (await token.mint(await storage.getAddress(), 1000n)).wait();

    // wywołaj jako core (CoreMock lub realny core)
    await expect(
      core.connect(owner).withdrawFunds(1, await token.getAddress())
    ).to.not.be.reverted;
  });
});
