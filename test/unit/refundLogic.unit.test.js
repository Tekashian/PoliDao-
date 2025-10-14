const { ethers } = require("hardhat");
const { expect } = require("chai");

async function increaseTime(sec) {
  await ethers.provider.send("evm_increaseTime", [sec]);
  await ethers.provider.send("evm_mine", []);
}

// Build struct data helper
async function buildCreateData(tokenAddr, overrides = {}) {
  const now = (await ethers.provider.getBlock("latest")).timestamp;
  return {
    title: "FR",
    description: "Desc",
    location: "LOC",
    endDate: now + 3600,
    goalAmount: ethers.parseEther("100"),
    token: tokenAddr,
    fundraiserType: 0, // WITH_GOAL
    isFlexible: false,
    initialImages: [],
    initialVideos: [],
    metadataHash: "",
    ...overrides
  };
}

describe("RefundLogic (library) – direct harness scenarios", function () {
  let owner, creator, donor, wallet;
  let token, storage, core, harness;

  async function deployEnv() {
    [owner, creator, donor, wallet] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockToken");
    token = await Token.deploy("Mock", "MCK", 18);
    await token.waitForDeployment();

    const Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.waitForDeployment();

    const Core = await ethers.getContractFactory("PoliDaoCore");
    core = await Core.deploy(await storage.getAddress(), owner.address);
    await core.waitForDeployment();
    await (await storage.setCore(await core.getAddress())).wait();

    const Harness = await ethers.getContractFactory("RefundLogicHarness");
    harness = await Harness.deploy();
    await harness.waitForDeployment();

    await (await storage.addWhitelistedToken(await token.getAddress())).wait();
    await (await storage.setCommissionWallet(wallet.address)).wait();
    // Autoryzuj harness aby RefundLogic mógł wywoływać update w Storage (onlyCore rozszerzone)
    await (await storage.authorizeContract(await harness.getAddress())).wait();
  }

  beforeEach(async () => {
    await deployEnv();
  });

  it("enterRefundPeriod: goal not reached after end -> status REFUND_PERIOD", async () => {
    const data = await buildCreateData(await token.getAddress(), { goalAmount: ethers.parseEther("100"), endDate: (await ethers.provider.getBlock("latest")).timestamp + 300 });
    await expect(core.connect(creator).createFundraiser(data)).to.emit(core, "FundraiserCreated");

    await token.mint(donor.address, ethers.parseEther("10"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("10"));
    await core.connect(donor).donate(1, ethers.parseEther("10"));

    await increaseTime(600);
    await expect(harness.enterRefundPeriod(await storage.getAddress(), 1)).to.not.be.reverted;

    const packed = await storage.fundraisers(1);
    expect(packed.status).to.equal(3);
  });

  it("enterRefundPeriod reverts RefundTooEarly before endDate", async () => {
    const data = await buildCreateData(await token.getAddress(), { endDate: (await ethers.provider.getBlock("latest")).timestamp + 3600 });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("5"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("5"));
    await core.connect(donor).donate(1, ethers.parseEther("5"));
    await expect(harness.enterRefundPeriod(await storage.getAddress(), 1))
      .to.be.revertedWithCustomError(harness, "RefundTooEarly");
  });

  it("claimRefund transfers net & commission, then second claim -> AlreadyRefunded", async () => {
    await (await storage.setCommissions(500)).wait(); // 5%
    const data = await buildCreateData(await token.getAddress(), { goalAmount: ethers.parseEther("50"), endDate: (await ethers.provider.getBlock("latest")).timestamp + 100 });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("20"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("20"));
    await core.connect(donor).donate(1, ethers.parseEther("20"));
    // Raised before refund should equal donated amount (no donation fee in this test)
    const packedBefore = await storage.fundraisers(1);
    expect(packedBefore.raisedAmount).to.equal(ethers.parseEther("20"));
    await increaseTime(400);

    const balDonorBefore = await token.balanceOf(donor.address);
    const balWalletBefore = await token.balanceOf(wallet.address);

    await harness.claimRefund(await storage.getAddress(), 1, donor.address);

    const balDonorAfter = await token.balanceOf(donor.address);
    const balWalletAfter = await token.balanceOf(wallet.address);
    const commission = ethers.parseEther("20") * 500n / 10000n;
    const net = ethers.parseEther("20") - commission;

    expect(balDonorAfter - balDonorBefore).to.equal(net);
    expect(balWalletAfter - balWalletBefore).to.equal(commission);
    // Raised should decrease by full donor recorded amount (set to 0 for this donor)
    const packedAfter = await storage.fundraisers(1);
    expect(packedAfter.raisedAmount).to.equal(0n);
    // Storage financial totals should be updated
    const totalRefunded = await storage.totalRefunded(1);
    const totalRefundCommission = await storage.totalRefundCommission(1);
    expect(totalRefunded).to.equal(net);
    expect(totalRefundCommission).to.equal(commission);

    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWithCustomError(harness, "AlreadyRefunded");
  });

  it("claimRefund reverts GoalReachedNoRefund when goal met", async () => {
    const data = await buildCreateData(await token.getAddress(), { goalAmount: ethers.parseEther("10"), endDate: (await ethers.provider.getBlock("latest")).timestamp + 120 });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("10"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("10"));
    await core.connect(donor).donate(1, ethers.parseEther("10"));
    await increaseTime(400);
    await expect(
      harness.claimRefund(await storage.getAddress(), 1, donor.address)
    ).to.be.revertedWithCustomError(harness, "GoalReachedNoRefund");
  });

  it("NO_GOAL fundraiser -> RefundNotEligible", async () => {
    const data = await buildCreateData(await token.getAddress(), {
      fundraiserType: 1, // NO_GOAL
      goalAmount: 0,
      endDate: (await ethers.provider.getBlock("latest")).timestamp + 200
    });
    await core.connect(creator).createFundraiser(data);
    await token.mint(donor.address, ethers.parseEther("5"));
    await token.connect(donor).approve(await core.getAddress(), ethers.parseEther("5"));
    await core.connect(donor).donate(1, ethers.parseEther("5"));
    await increaseTime(500);
    await expect(
      harness.enterRefundPeriod(await storage.getAddress(), 1)
    ).to.be.revertedWithCustomError(harness, "RefundNotEligible");
  });
});
