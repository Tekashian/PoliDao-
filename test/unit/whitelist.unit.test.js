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
    // Packed data minimal valid
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
    // Whitelist token
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

    // Create fundraiser
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

    // Prepare donation
    await mockToken.transfer(user1.address, ethers.parseEther("10"));
    await mockToken.connect(user1).approve(await storage.getAddress(), ethers.parseEther("10"));

    // Donation ok while whitelisted
    await storage.addDonation(fundraiserId, user1.address, ethers.parseEther("5"));

    // Remove from whitelist
    await storage.removeWhitelistedToken(await mockToken.getAddress());

    // Donation now blocked
    await expect(
      storage.addDonation(fundraiserId, user1.address, ethers.parseEther("1"))
    ).to.be.revertedWith("Token not whitelisted");
  });
});