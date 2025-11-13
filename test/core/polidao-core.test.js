const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployBasicFixtures } = require("../fixtures/deploySystemFixture");

describe("PoliDaoCore - Core System Functions", function () {
  it("✅ should deploy core contract successfully", async function () {
    const { core } = await loadFixture(deployBasicFixtures);
    expect(core).to.exist;
  });

  it("✅ should handle core fundraiser operations", async function () {
    const { core, storage, owner } = await loadFixture(deployBasicFixtures);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const endDate = (await time.latest()) + 3600;
    const data = {
      title: "T",
      description: "D",
      endDate,
      fundraiserType: 0, // WITH_GOAL
      token: await token.getAddress(),
      goalAmount: 1n,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "",
      isFlexible: false
    };
    await expect(core.connect(owner).createFundraiser(data)).to.not.be.reverted;
  });

  it("✅ should handle core donation processing", async function () {
    const { core, storage, owner } = await loadFixture(deployBasicFixtures);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const endDate = (await time.latest()) + 3600;
    const data = {
      title: "T",
      description: "D",
      endDate,
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
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    await (await token.mint(owner.address, 1000n)).wait();
  await (await token.connect(owner).approve(await core.getAddress(), 1000n)).wait();
  await expect(core.connect(owner).donate(fundraiserId, 100n)).to.not.be.reverted;
  });

  it("✅ should handle core withdrawal operations", async function () {
    const { core, storage, owner } = await loadFixture(deployBasicFixtures);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const endDate = (await time.latest()) + 3600;
    const data = {
      title: "T",
      description: "D",
      endDate,
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
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    await (await token.mint(owner.address, 1000n)).wait();
  await (await token.connect(owner).approve(await core.getAddress(), 1000n)).wait();
  await (await core.connect(owner).donate(fundraiserId, 100n)).wait();

    await time.increaseTo(endDate + 1);
  await expect(core.connect(owner).withdrawFunds(fundraiserId)).to.not.be.reverted;
  });
});