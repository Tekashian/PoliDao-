import { expect } from "chai";
import { ethers } from "hardhat";

// Keep local enum aligned with IPoliDaoStructs.FundraiserType
enum FundraiserType {
  WITH_GOAL,
  NO_GOAL
}

describe("Fundraiser endDate limit (MAX_FUTURE_DATE)", () => {
  let owner: any;
  let creator: any;
  let token: any;
  let storage: any;
  let core: any;

  beforeEach(async () => {
    [owner, creator] = await ethers.getSigners();

    // ERC20 mock
    const ERC20Mock = await ethers.getContractFactory("MockToken");
    token = await ERC20Mock.deploy("MockToken", "MKT", 18);
    await token.waitForDeployment();

    // Storage
    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.waitForDeployment();

    // Whitelist token for fundraisers
    await storage.connect(owner).addWhitelistedToken(token.target);

    // Core (router param can be owner for tests)
    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(await storage.getAddress(), owner.address);
    await core.waitForDeployment();

    // Bind storage -> core
    await storage.connect(owner).setCore(await core.getAddress());
  });

  it("allows endDate up to 3 years + 1 day (1096 days)", async () => {
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const days = 24 * 60 * 60;
    const limit = 1096 * days; // 3 years + 1 day

    const createData = {
      title: "Long Campaign",
      description: "Desc",
      location: "Loc",
      endDate: now + limit,
      goalAmount: ethers.parseEther("1"),
      token: token.target as string,
      fundraiserType: FundraiserType.WITH_GOAL,
      isFlexible: false
    };

    await expect(core.connect(creator).createFundraiser(createData)).to.emit(core, "FundraiserCreated");
  });

  it("reverts when endDate exceeds 3 years + 1 day by 1 second", async () => {
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const days = 24 * 60 * 60;
    const over = 1096 * days + 1; // limit + 1 second

    const createData = {
      title: "Too Long Campaign",
      description: "Desc",
      location: "Loc",
      endDate: now + over,
      goalAmount: ethers.parseEther("1"),
      token: token.target as string,
      fundraiserType: FundraiserType.WITH_GOAL,
      isFlexible: false
    };

    // Custom error originates in FundraiserLogic; assert generic revert to avoid ABI coupling
    await expect(core.connect(creator).createFundraiser(createData)).to.be.reverted;
  });
});
