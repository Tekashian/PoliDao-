const { expect } = require("chai");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { ethers } = require("hardhat");

describe("Withdraw flow", function () {
  async function deploySystem() {
    const { storage, core, token, deployer, creator, donor } =
      await loadFixture(require("../fixtures/deploySystemFixture").deploySystemFixture);
    return { storage, core, token, deployer, creator, donor };
  }

  it("transfers funds from Storage to creator on withdraw", async function () {
    let { storage, core, token, deployer, creator, donor } = await deploySystem();
    const signers = await ethers.getSigners();
    deployer = deployer ?? signers[0];
    creator  = creator  ?? signers[1];
    donor    = donor    ?? signers[2];

    const amount = ethers.parseUnits("1000", 18);

    if (!token) {
      const MockToken = await ethers.getContractFactory("MockToken");
      token = await MockToken.deploy("Mock", "MOCK", 18);
      await token.waitForDeployment();
      await token.mint(donor.address, amount);
    }

    // Whitelist token
    await storage.connect(deployer).addWhitelistedToken(await token.getAddress());

    // Approve Core (to wykonuje transferFrom)
    await token.connect(donor).approve(await core.getAddress(), amount);

    const endDate = (await time.latest()) + 7 * 24 * 60 * 60;
    const tx = await core.connect(creator).createFundraiser({
      title: "Test",
      description: "Desc",
      location: "Loc",
      endDate,
      fundraiserType: 0,
      isFlexible: false,
      goalAmount: amount,
      token: await token.getAddress(),
      initialImages: [],
      initialVideos: [],
      initialLinks: [],
      metadataHash: ""
    });
    const rc = await tx.wait();
    const created = rc.logs.find((l) => l.fragment && l.fragment.name === "FundraiserCreated");
    const fundraiserId = created.args.fundraiserId;

    await core.connect(donor).donate(fundraiserId, amount);
    await time.increaseTo(endDate + 1);

    const balCreatorBefore = await token.balanceOf(creator.address);
    const balStorageBefore = await token.balanceOf(await storage.getAddress());

    await expect(core.connect(creator).withdrawFunds(fundraiserId)).to.emit(core, "FundsWithdrawn");

    const balCreatorAfter = await token.balanceOf(creator.address);
    const balStorageAfter = await token.balanceOf(await storage.getAddress());

    expect(balCreatorAfter).to.be.gt(balCreatorBefore);
    expect(balStorageAfter).to.be.lt(balStorageBefore);
  });
});