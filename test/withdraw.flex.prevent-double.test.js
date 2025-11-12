const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Flexible fundraiser - single withdraw & refund block", () => {
  let token, storage, core, owner, creator, donor, feeRecipient, fid;

  beforeEach(async () => {
    [owner, creator, donor, feeRecipient] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    token = await ERC20Mock.deploy("FlexUSD", "FUSD", owner.address, ethers.parseUnits("500000", 18));

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.connect(owner).addWhitelistedToken(token.target);

    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(storage.target, owner.address);
    await storage.connect(owner).authorizeContract(core.target);

    await core.connect(owner).setFeeRecipient(feeRecipient.address);
    await core.connect(owner).setDonationFeeBps(0);
    await core.connect(owner).setWithdrawFeesBps(0, 0);

    const data = {
      title: "Flexible",
      description: "Desc",
      endDate: (await ethers.provider.getBlock()).timestamp + 30 * 24 * 3600,
      fundraiserType: 1, // NO_GOAL
      token: token.target,
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Loc",
      isFlexible: true
    };
    const tx = await core.connect(creator).createFundraiser(data);
    const rc = await tx.wait();
    const ev = rc.logs.find(l => l.fragment && l.fragment.name === "FundraiserCreated");
    fid = ev.args.fundraiserId;

    await token.connect(owner).transfer(donor.address, ethers.parseUnits("200", 18));
    await token.connect(donor).approve(core.target, ethers.parseUnits("200", 18));
    await core.connect(donor).donate(fid, ethers.parseUnits("100", 18));
  });

  it("allows single withdraw and blocks second + refunds", async () => {
    const raised = (await storage.fundraisers(fid)).raisedAmount;
    await expect(core.connect(creator).withdrawFunds(fid))
      .to.emit(core, "FundsWithdrawn")
      .withArgs(fid, creator.address, token.target, raised);

    expect(await storage.totalWithdrawn(fid)).to.equal(raised);
    expect(await core.withdrawalsStarted(fid)).to.equal(true);

    await expect(core.connect(creator).withdrawFunds(fid)).to.be.reverted;

    await expect(core.connect(owner).refundFor(fid, donor.address))
      .to.be.revertedWith("PoliDaoCore: withdrawals started");
  });
});