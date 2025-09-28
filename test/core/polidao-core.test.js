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
    await expect(core.connect(owner).createFundraiser(await token.getAddress(), 0, endDate, "T", "D")).to.not.be.reverted;
  });

  it("✅ should handle core donation processing", async function () {
    const { core, storage, owner } = await loadFixture(deployBasicFixtures);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const endDate = (await time.latest()) + 3600;
    const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, endDate, "T", "D");
    const rc = await tx.wait();
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    await (await token.mint(owner.address, 1000n)).wait();
    await (await token.connect(owner).approve(await core.getAddress(), 1000n)).wait();
    await expect(core.connect(owner)["donate(uint256,address,uint256)"](fundraiserId, await token.getAddress(), 100n)).to.not.be.reverted;
  });

  it("✅ should handle core withdrawal operations", async function () {
    const { core, storage, owner } = await loadFixture(deployBasicFixtures);

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) await (await core.allowToken(await token.getAddress(), true)).wait();

    const endDate = (await time.latest()) + 3600;
    const tx = await core.connect(owner).createFundraiser(await token.getAddress(), 0, endDate, "T", "D");
    const rc = await tx.wait();
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    await (await token.mint(owner.address, 1000n)).wait();
    await (await token.connect(owner).approve(await core.getAddress(), 1000n)).wait();
    await (await core.connect(owner)["donate(uint256,address,uint256)"](fundraiserId, await token.getAddress(), 100n)).wait();

    await time.increaseTo(endDate + 1);
    await expect(core.connect(owner).withdrawFunds(fundraiserId, await token.getAddress())).to.not.be.reverted;
  });
});