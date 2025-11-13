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

    // whitelist and basic fundraiser setup
    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const data = {
      title: "X",
      description: "Y",
      endDate: now + 3600,
      fundraiserType: 0,
      token: await token.getAddress(),
      goalAmount: 1n,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "",
      isFlexible: false
    };
    const tx = await core.connect(owner).createFundraiser(data);
    const rc = await tx.wait();
    const ev = rc.logs.find(l => l.fragment && l.fragment.name === "FundraiserCreated");
    const fundraiserId = ev.args.fundraiserId;

    // donate to have something to withdraw
    await (await token.mint(owner.address, 1000n)).wait();
    await (await token.connect(owner).approve(await core.getAddress(), 500n)).wait();
    await (await core.connect(owner).donate(fundraiserId, 200n)).wait();

    // withdraw via core path triggers storage.releaseFunds internally
    await expect(core.connect(owner).withdrawFunds(fundraiserId)).to.not.be.reverted;
  });
});
