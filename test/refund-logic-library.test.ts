import { expect } from "chai";
import { ethers } from "hardhat";

enum FundraiserType {
  WITH_GOAL,
  NO_GOAL
}

async function increaseTime(seconds: number) {
  await ethers.provider.send("evm_increaseTime", [seconds]);
  await ethers.provider.send("evm_mine", []);
}

describe("RefundLogic Library (direct harness tests)", () => {
  let owner: any;
  let creator: any;
  let donor: any;
  let commissionWallet: any;

  let token: any;
  let storage: any;
  let core: any;
  let harness: any;

  const GOAL = ethers.parseEther("100");
  const DONATION = ethers.parseEther("10");
  const REFUND_COMMISSION_BPS = 500; // 5%

  async function createWithGoalFundraiser(endDeltaSec: number, goal = GOAL, fType = FundraiserType.WITH_GOAL) {
    const now = (await ethers.provider.getBlock("latest"))!.timestamp;
    const endDate = now + endDeltaSec;
    const createData = {
      title: "Test Fundraiser",
      description: "Desc",
      location: "Loc",
      endDate,
      goalAmount: goal,
      token: token.target as string,
      fundraiserType: fType,
      isFlexible: false
    };
    // Core validation requires fundraiserType & goal; adapt structure to expected FundraiserCreationData.
    await expect(
      core.connect(creator).createFundraiser(createData)
    ).to.emit(core, "FundraiserCreated");
    // Fundraiser IDs start at 1 in storage
    return 1;
  }

  async function donate(fundraiserId: number, amt = DONATION, donorSigner = donor) {
    await token.connect(donorSigner).approve(await storage.getAddress(), amt);
    await core.connect(donorSigner).donate(fundraiserId, amt);
  }

  beforeEach(async () => {
    [owner, creator, donor, commissionWallet] = await ethers.getSigners();

    // Deploy ERC20 test token
    const ERC20Mock = await ethers.getContractFactory("MockToken");
    token = await ERC20Mock.deploy("MockToken", "MKT", 18);
    await token.waitForDeployment();

    // Deploy Storage
    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.waitForDeployment();

    // Whitelist token
    await storage.connect(owner).addWhitelistedToken(token.target);

    // Set commission wallet & refund commission
    await storage.connect(owner).setCommissionWallet(commissionWallet.address);
    await storage.connect(owner).setCommissions(REFUND_COMMISSION_BPS);

    // Deploy Core (router param can be owner for tests)
    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(await storage.getAddress(), owner.address);
    await core.waitForDeployment();

    // Bind core in storage
    await storage.connect(owner).setCore(await core.getAddress());

    // Deploy harness
    const Harness = await ethers.getContractFactory("RefundLogicHarness");
    harness = await Harness.deploy();
    await harness.waitForDeployment();

    // Fund donor
    await token.mint(donor.address, ethers.parseEther("1000"));
  });

  it("enters refund period after end (WITH_GOAL & goal not reached)", async () => {
    const fid = await createWithGoalFundraiser(3600);
    await donate(fid);

    await increaseTime(3600 + 10);

    await expect(
      harness.enterRefundPeriod(storage.getAddress(), fid)
    ).to.not.be.reverted;

    const packed = await storage.fundraisers(fid);
    // status should now be REFUND_PERIOD (enum value 3 if ordering: ACTIVE=0, ...)
    expect(packed.status).to.equal(3, "Status should be REFUND_PERIOD");
  });

  it("reverts entering refund period too early", async () => {
    const fid = await createWithGoalFundraiser(3600);
    await donate(fid);
    await expect(
      harness.enterRefundPeriod(storage.getAddress(), fid)
    ).to.be.revertedWithCustomError(harness, "RefundTooEarly");
  });

  it("reverts entering refund period for NO_GOAL fundraiser", async () => {
    const fid = await createWithGoalFundraiser(3600, 0n, FundraiserType.NO_GOAL);
    await donate(fid, ethers.parseEther("1"));
    await increaseTime(4000);
    await expect(
      harness.enterRefundPeriod(storage.getAddress(), fid)
    ).to.be.revertedWithCustomError(harness, "RefundNotEligible");
  });

  it("reverts entering refund period when goal reached", async () => {
    const fid = await createWithGoalFundraiser(3600, ethers.parseEther("10"));
    await donate(fid, ethers.parseEther("10")); // reach goal
    await increaseTime(4000);
    await expect(
      harness.enterRefundPeriod(storage.getAddress(), fid)
    ).to.be.revertedWithCustomError(harness, "GoalReachedNoRefund");
  });

  it("claims refund (auto-enter) and distributes commission", async () => {
    const fid = await createWithGoalFundraiser(60); // short end
    await donate(fid, DONATION);
    await increaseTime(600); // after end

    const donorBefore = await token.balanceOf(donor.address);
    const commissionBefore = await token.balanceOf(commissionWallet.address);

    const tx = await harness.claimRefund(storage.getAddress(), fid, donor.address);
    const receipt = await tx.wait();
    // Parse returned values via callStatic for clarity
    const callStatic = await harness.callStatic.claimRefund(storage.getAddress(), fid, donor.address).catch(()=>null);
    // Since we already claimed in tx above, callStatic will revert (AlreadyRefunded); so derive expected manually
    const commission = (DONATION * BigInt(REFUND_COMMISSION_BPS)) / 10_000n;
    const expectedNet = DONATION - commission;

    const donorAfter = await token.balanceOf(donor.address);
    const commissionAfter = await token.balanceOf(commissionWallet.address);

    expect(donorAfter - donorBefore).to.equal(expectedNet);
    expect(commissionAfter - commissionBefore).to.equal(commission);
  });

  it("prevents double claim (AlreadyRefunded)", async () => {
    const fid = await createWithGoalFundraiser(60);
    await donate(fid);
    await increaseTime(600);
    await harness.claimRefund(storage.getAddress(), fid, donor.address);
    await expect(
      harness.claimRefund(storage.getAddress(), fid, donor.address)
    ).to.be.revertedWithCustomError(harness, "AlreadyRefunded");
  });
});
