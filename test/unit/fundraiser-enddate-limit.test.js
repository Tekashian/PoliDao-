const { expect } = require("chai");
const { ethers } = require("hardhat");

// FundraiserType enum mapping
const FundraiserType = { WITH_GOAL: 0, NO_GOAL: 1 };

describe("Fundraiser endDate limit (MAX_FUTURE_DATE)", function () {
  let owner, creator;
  let token, storage, core;

  beforeEach(async function () {
    [owner, creator] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("MockToken");
    token = await ERC20Mock.deploy("MockToken", "MKT", 18);
    await token.waitForDeployment();

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.waitForDeployment();

    await storage.connect(owner).addWhitelistedToken(token.target);

    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(await storage.getAddress(), owner.address);
    await core.waitForDeployment();

    await storage.connect(owner).setCore(await core.getAddress());
  });

  it("allows endDate up to 3 years + 1 day (1096 days)", async function () {
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    const days = 24 * 60 * 60;
    const limit = 1096 * days;

    const createData = {
      title: "Long Campaign",
      description: "Desc",
      endDate: now + limit,
      fundraiserType: FundraiserType.WITH_GOAL,
      token: token.target,
      goalAmount: ethers.parseEther("1"),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Loc",
      isFlexible: false
    };

    await expect(core.connect(creator).createFundraiser(createData)).to.emit(core, "FundraiserCreated");
  });

  it("reverts when endDate exceeds 3 years + 1 day by 1 second", async function () {
    const now = (await ethers.provider.getBlock("latest")).timestamp;
  const days = 24 * 60 * 60;
  const over = 1096 * days + 120; // exceed by 2 minutes to avoid miner timestamp drift

    const createData = {
      title: "Too Long Campaign",
      description: "Desc",
      endDate: now + over,
      fundraiserType: FundraiserType.WITH_GOAL,
      token: token.target,
      goalAmount: ethers.parseEther("1"),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Loc",
      isFlexible: false
    };

    await expect(core.connect(creator).createFundraiser(createData)).to.be.reverted;
  });
});
