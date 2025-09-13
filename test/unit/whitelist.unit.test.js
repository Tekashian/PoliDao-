const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Whitelist enforcement - creation and donations", function () {
  let storage, mockToken, owner, user1;

  beforeEach(async function () {
    [owner, user1] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockToken");
    mockToken = await MockToken.deploy("Whitelist Token", "WLT", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();

    const PoliDaoStorage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await PoliDaoStorage.deploy();
    await storage.waitForDeployment();
  });

  it("rejects fundraiser creation with non-whitelisted token", async function () {
    const now = Math.floor(Date.now() / 1000);
    const packedData = {
      goalAmount: ethers.parseEther("100"),
      raisedAmount: 0,
      endDate: now + 86400,
      originalEndDate: now + 86400,
      id: 0,
      suspensionTime: 0,
      extensionCount: 0,
      fundraiserType: 0,
      status: 0,
      isSuspended: false,
      fundsWithdrawn: false,
      isFlexible: false
    };

    await expect(
      storage.createFundraiser(
        packedData,
        "T1",
        "Desc",
        "Loc",
        owner.address,
        await mockToken.getAddress()
      )
    ).to.be.revertedWith("Token not whitelisted");
  });

  it("allows fundraiser creation after whitelisting and blocks donations after removal", async function () {
    await storage.addWhitelistedToken(await mockToken.getAddress());

    const now = Math.floor(Date.now() / 1000);
    const packedData = {
      goalAmount: ethers.parseEther("100"),
      raisedAmount: 0,
      endDate: now + 86400,
      originalEndDate: now + 86400,
      id: 0,
      suspensionTime: 0,
      extensionCount: 0,
      fundraiserType: 0,
      status: 0,
      isSuspended: false,
      fundsWithdrawn: false,
      isFlexible: false
    };

    const tx = await storage.createFundraiser(
      packedData,
      "T2",
      "Desc",
      "Loc",
      owner.address,
      await mockToken.getAddress()
    );
    await tx.wait();
    const fundraiserId = 1n;

    await mockToken.transfer(user1.address, ethers.parseEther("10"));
    await mockToken.connect(user1).approve(await storage.getAddress(), ethers.parseEther("10"));

    await storage.addDonation(fundraiserId, user1.address, ethers.parseEther("5"));

    await storage.removeWhitelistedToken(await mockToken.getAddress());

    await expect(
      storage.addDonation(fundraiserId, user1.address, ethers.parseEther("1"))
    ).to.be.revertedWith("Token not whitelisted");
  });

  it("only owner can add and remove tokens from whitelist", async function () {
    // Non-owner cannot add
    await expect(
      storage.connect(user1).addWhitelistedToken(await mockToken.getAddress())
    ).to.be.reverted;

    // Owner can add
    await storage.addWhitelistedToken(await mockToken.getAddress());

    // Non-owner cannot remove
    await expect(
      storage.connect(user1).removeWhitelistedToken(await mockToken.getAddress())
    ).to.be.reverted;

    // Owner can remove
    await storage.removeWhitelistedToken(await mockToken.getAddress());
  });

  it("blocks new fundraiser creation after token is removed from whitelist", async function () {
    await storage.addWhitelistedToken(await mockToken.getAddress());

    const now = Math.floor(Date.now() / 1000);
    const basePacked = {
      goalAmount: ethers.parseEther("50"),
      raisedAmount: 0,
      endDate: now + 86400,
      originalEndDate: now + 86400,
      id: 0,
      suspensionTime: 0,
      extensionCount: 0,
      fundraiserType: 0,
      status: 0,
      isSuspended: false,
      fundsWithdrawn: false,
      isFlexible: false
    };

    // First fundraiser succeeds while whitelisted
    await (await storage.createFundraiser(
      basePacked,
      "T3",
      "Desc",
      "Loc",
      owner.address,
      await mockToken.getAddress()
    )).wait();

    // Remove token from whitelist
    await storage.removeWhitelistedToken(await mockToken.getAddress());

    // New fundraiser with the same token should fail now
    await expect(
      storage.createFundraiser(
        basePacked,
        "T3b",
        "Desc",
        "Loc",
        owner.address,
        await mockToken.getAddress()
      )
    ).to.be.revertedWith("Token not whitelisted");
  });

  it("handles multiple tokens; donations follow current whitelist state", async function () {
    const MockToken = await ethers.getContractFactory("MockToken");
    const tokenA = mockToken; // already deployed in beforeEach
    const tokenB = await MockToken.deploy("Whitelist Token B", "WLTB", ethers.parseEther("1000000"));
    await tokenB.waitForDeployment();

    await storage.addWhitelistedToken(await tokenA.getAddress());
    await storage.addWhitelistedToken(await tokenB.getAddress());

    const now = Math.floor(Date.now() / 1000);
    const packed = {
      goalAmount: ethers.parseEther("200"),
      raisedAmount: 0,
      endDate: now + 86400,
      originalEndDate: now + 86400,
      id: 0,
      suspensionTime: 0,
      extensionCount: 0,
      fundraiserType: 0,
      status: 0,
      isSuspended: false,
      fundsWithdrawn: false,
      isFlexible: false
    };

    // Create two fundraisers with different tokens
    await (await storage.createFundraiser(
      packed,
      "FA",
      "DescA",
      "LocA",
      owner.address,
      await tokenA.getAddress()
    )).wait(); // id 1
    await (await storage.createFundraiser(
      packed,
      "FB",
      "DescB",
      "LocB",
      owner.address,
      await tokenB.getAddress()
    )).wait(); // id 2

    const fA = 1n;
    const fB = 2n;

    // Fund user and approve both tokens
    await tokenA.transfer(user1.address, ethers.parseEther("20"));
    await tokenB.transfer(user1.address, ethers.parseEther("20"));
    await tokenA.connect(user1).approve(await storage.getAddress(), ethers.parseEther("20"));
    await tokenB.connect(user1).approve(await storage.getAddress(), ethers.parseEther("20"));

    // Donations succeed while whitelisted
    await storage.addDonation(fA, user1.address, ethers.parseEther("2"));
    await storage.addDonation(fB, user1.address, ethers.parseEther("3"));

    // Remove tokenB from whitelist
    await storage.removeWhitelistedToken(await tokenB.getAddress());

    // Donation for B now blocked
    await expect(
      storage.addDonation(fB, user1.address, ethers.parseEther("1"))
    ).to.be.revertedWith("Token not whitelisted");

    // Donation for A still allowed
    await storage.addDonation(fA, user1.address, ethers.parseEther("1"));
  });

  it("whitelisting is per-token; creating with non-whitelisted token fails until whitelisted", async function () {
    const MockToken = await ethers.getContractFactory("MockToken");
    const tokenA = mockToken; // from beforeEach
    const tokenB = await MockToken.deploy("Another Token", "ANT", ethers.parseEther("1000000"));
    await tokenB.waitForDeployment();

    // Only A is whitelisted
    await storage.addWhitelistedToken(await tokenA.getAddress());

    const now = Math.floor(Date.now() / 1000);
    const packed = {
      goalAmount: ethers.parseEther("120"),
      raisedAmount: 0,
      endDate: now + 86400,
      originalEndDate: now + 86400,
      id: 0,
      suspensionTime: 0,
      extensionCount: 0,
      fundraiserType: 0,
      status: 0,
      isSuspended: false,
      fundsWithdrawn: false,
      isFlexible: false
    };

    // Fundraiser with A succeeds
    await (await storage.createFundraiser(
      packed,
      "OnlyA",
      "Desc",
      "Loc",
      owner.address,
      await tokenA.getAddress()
    )).wait();

    // Fundraiser with B fails (not whitelisted)
    await expect(
      storage.createFundraiser(
        packed,
        "OnlyB",
        "Desc",
        "Loc",
        owner.address,
        await tokenB.getAddress()
      )
    ).to.be.revertedWith("Token not whitelisted");

    // After whitelisting B, it succeeds
    await storage.addWhitelistedToken(await tokenB.getAddress());
    await (await storage.createFundraiser(
      packed,
      "NowB",
      "Desc",
      "Loc",
      owner.address,
      await tokenB.getAddress()
    )).wait();
  });
});