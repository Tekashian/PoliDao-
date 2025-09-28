const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

describe("Withdraw flow", function () {
  it("transfers funds from Storage to creator on withdraw", async function () {
    const { core, storage, alice, bob } = await loadFixture(deploySystemFixture);
    const [creator, donor] = [alice, bob];

    const Token = await ethers.getContractFactory("MockToken");
    const token = await Token.deploy("Mock", "MOCK", 18);
    await token.waitForDeployment();

    const amount = ethers.parseUnits("1000", 18);
    await (await storage.setFundraiserTokenWhitelist(await token.getAddress(), true)).wait();
    if (core.allowToken) {
      await (await core.allowToken(await token.getAddress(), true)).wait();
    }

    await (await token.mint(donor.address, amount)).wait();
    await (await token.connect(donor).approve(await core.getAddress(), amount)).wait();

    const endDate = (await time.latest()) + 7 * 24 * 60 * 60;

    const tx = await core.connect(creator).createFundraiser(
      await token.getAddress(), amount, endDate, "Test", "Desc"
    );
    const rc = await tx.wait();
    const ev = rc.logs.map(l => { try { return core.interface.parseLog(l); } catch { return null; } })
      .find(x => x && /FundraiserCreated/i.test(x.name));
    const fundraiserId = ev ? (ev.args.fundraiserId ?? ev.args.id ?? ev.args[0]) : 1n;

    // ethers v6: dla przeciążonych funkcji użyj podpisu
    // donate (signaturą, bo są 2 overloady)
    await (await core.connect(donor)["donate(uint256,address,uint256)"](fundraiserId, await token.getAddress(), amount)).wait();

    await time.increaseTo(endDate + 1);

    const balCreatorBefore = await token.balanceOf(creator.address);
    const balStorageBefore = await token.balanceOf(await storage.getAddress());

    await (await core.connect(creator).withdrawFunds(fundraiserId, await token.getAddress())).wait();

    const balCreatorAfter = await token.balanceOf(creator.address);
    const balStorageAfter = await token.balanceOf(await storage.getAddress());

    expect(balCreatorAfter).to.be.gt(balCreatorBefore);
    expect(balStorageAfter).to.be.lt(balStorageBefore);
  });
});