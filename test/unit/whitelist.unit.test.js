const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

describe("Whitelist enforcement - creation and donations", function () {
  it("rejects fundraiser creation with non-whitelisted token", async function () {
    const { core } = await loadFixture(deploySystemFixture);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    const endDate = (await time.latest()) + 3600;

    await expect(
      core.createFundraiser(await token.getAddress(), 0, endDate, "T", "D")
    ).to.be.reverted;
  });

  it("allows fundraiser creation after whitelisting and blocks donations after removal", async function () {
    const { storage, core, owner } = await loadFixture(deploySystemFixture);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) {
      await (await core.allowToken(await token.getAddress(), true)).wait();
    }

    const endDate = (await time.latest()) + 3600;
    await expect(
      core.connect(owner).createFundraiser(await token.getAddress(), 0, endDate, "T", "D")
    ).to.not.be.reverted;

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), false)).wait();
    if (core.allowToken) {
      await (await core.allowToken(await token.getAddress(), false)).wait();
    }

    await expect(
      core.connect(owner).createFundraiser(await token.getAddress(), 0, endDate, "T2", "D2")
    ).to.be.reverted;
  });
});