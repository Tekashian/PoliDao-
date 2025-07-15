const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

// Helper function to get current block timestamp
async function getCurrentBlockTime() {
  const latestBlock = await ethers.provider.getBlock('latest');
  return latestBlock.timestamp;
}

let dao, mockToken, owner, user1, user2, user3, user4, commissionWallet, feeToken;

beforeEach(async () => {
  [owner, user1, user2, user3, user4] = await ethers.getSigners();
  commissionWallet = user3;

  // Deploy mock USDC token
  const MockToken = await ethers.getContractFactory("MockToken");
  mockToken = await MockToken.deploy("USDC Test", "USDC", 6, ethers.parseUnits("1000000", 6), owner.address);
  await mockToken.waitForDeployment();

  // Deploy fee token (same as mock token for testing)
  feeToken = mockToken;

  // Deploy PoliDAO
  const PoliDAO = await ethers.getContractFactory("PoliDAO");
  dao = await PoliDAO.deploy(
    owner.address,
    commissionWallet.address,
    await feeToken.getAddress()
  );
  await dao.waitForDeployment();

  // Whitelist the mock token
  await dao.whitelistToken(await mockToken.getAddress());

  // Distribute tokens
  const mintAmount = ethers.parseUnits("50000", 6);
  await mockToken.connect(owner).transfer(user1.address, mintAmount);
  await mockToken.connect(owner).transfer(user2.address, mintAmount);
  await mockToken.connect(owner).transfer(user3.address, mintAmount);
  await mockToken.connect(owner).transfer(user4.address, mintAmount);
});

// ==============================
// GOVERNANCE SYSTEM
// ==============================

describe("🗳️ Governance System", function () {
  describe("Proposal Creation", function () {
    it("should allow owner to create proposals", async function () {
      await dao.createProposal("Should we increase commission rates?", 3600);
      
      const count = await dao.getProposalCount();
      expect(count).to.equal(1);
      
      const [id, question, yesVotes, noVotes, endTime, creator] = await dao.getProposal(1);
      expect(id).to.equal(1);
      expect(question).to.equal("Should we increase commission rates?");
      expect(yesVotes).to.equal(0);
      expect(noVotes).to.equal(0);
      expect(creator).to.equal(owner.address);
    });

    it("should prevent unauthorized users from creating proposals", async function () {
      await expect(dao.connect(user1).createProposal("User proposal", 3600))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });

    it("should allow authorized proposers to create proposals", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.connect(user1).createProposal("Authorized proposal", 3600);
      
      const count = await dao.getProposalCount();
      expect(count).to.equal(1);
      
      const [, , , , , creator] = await dao.getProposal(1);
      expect(creator).to.equal(user1.address);
    });

    it("should validate proposal parameters", async function () {
      await expect(dao.createProposal("", 3600))
        .to.be.revertedWith("Invalid question");
      
      const longQuestion = "a".repeat(501);
      await expect(dao.createProposal(longQuestion, 3600))
        .to.be.revertedWith("Invalid question");
      
      await expect(dao.createProposal("Valid question", 366 * 24 * 3600))
        .to.be.revertedWith("Duration too long");
    });

    it("should emit ProposalCreated event", async function () {
      const tx = await dao.createProposal("Test proposal", 3600);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const expectedEndTime = block.timestamp + 3600;
      
      await expect(tx)
        .to.emit(dao, "ProposalCreated")
        .withArgs(1, "Test proposal", expectedEndTime, owner.address);
    });
  });

  describe("Voting", function () {
    beforeEach(async () => {
      await dao.createProposal("Test proposal", 3600);
    });

    it("should allow voting on proposals", async function () {
      await dao.connect(user1).vote(1, true);
      await dao.connect(user2).vote(1, false);
      
      const [, , yesVotes, noVotes] = await dao.getProposal(1);
      expect(yesVotes).to.equal(1);
      expect(noVotes).to.equal(1);
      
      expect(await dao.hasVoted(1, user1.address)).to.be.true;
      expect(await dao.hasVoted(1, user2.address)).to.be.true;
      expect(await dao.hasVoted(1, user3.address)).to.be.false;
    });

    it("should prevent double voting", async function () {
      await dao.connect(user1).vote(1, true);
      await expect(dao.connect(user1).vote(1, false))
        .to.be.revertedWith("Already voted");
    });

    it("should prevent voting on expired proposals", async function () {
      await ethers.provider.send("evm_increaseTime", [3601]);
      await ethers.provider.send("evm_mine");
      
      await expect(dao.connect(user1).vote(1, true))
        .to.be.revertedWith("Voting ended");
    });

    it("should emit Voted event", async function () {
      await expect(dao.connect(user1).vote(1, true))
        .to.emit(dao, "Voted")
        .withArgs(user1.address, 1, true);
    });
  });

  describe("Authorization Management", function () {
    it("should manage proposer authorization", async function () {
      expect(await dao.canPropose(user1.address)).to.be.false;
      
      await expect(dao.authorizeProposer(user1.address))
        .to.emit(dao, "ProposerAuthorized")
        .withArgs(user1.address);
      
      expect(await dao.canPropose(user1.address)).to.be.true;
      expect(await dao.authorizedProposers(user1.address)).to.be.true;
      
      await expect(dao.revokeProposer(user1.address))
        .to.emit(dao, "ProposerRevoked")
        .withArgs(user1.address);
      
      expect(await dao.canPropose(user1.address)).to.be.false;
      expect(await dao.authorizedProposers(user1.address)).to.be.false;
    });

    it("should prevent non-owner from managing authorization", async function () {
      await expect(dao.connect(user1).authorizeProposer(user2.address))
        .to.be.reverted;
      
      await expect(dao.connect(user1).revokeProposer(user2.address))
        .to.be.reverted;
    });
  });
});

// ==============================
// FUNDRAISER CREATION
// ==============================

describe("💰 Fundraiser Creation", function () {
  it("should create fundraiser with complete data structure", async function () {
    const latestBlock = await ethers.provider.getBlock('latest');
    const currentTime = latestBlock.timestamp;
    
    const creationData = {
      title: "Save the Environment",
      description: "A comprehensive project to save our planet",
      endDate: currentTime + 7200,
      fundraiserType: 0, // WITH_GOAL
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("10000", 6),
      initialImages: ["QmImage1", "QmImage2"],
      initialVideos: ["QmVideo1"],
      metadataHash: "QmMetadata123",
      location: "San Francisco, CA"
    };

    await expect(dao.createFundraiser(creationData))
      .to.emit(dao, "FundraiserCreated")
      .withArgs(1, owner.address, await mockToken.getAddress(), "Save the Environment", 0, ethers.parseUnits("10000", 6), creationData.endDate, "San Francisco, CA");

    const [title, description, location, endDate, fundraiserType, status] = await dao.getFundraiserDetails(1);
    expect(title).to.equal("Save the Environment");
    expect(description).to.equal("A comprehensive project to save our planet");
    expect(location).to.equal("San Francisco, CA");
    expect(fundraiserType).to.equal(0);
    expect(status).to.equal(0); // ACTIVE

    expect(await dao.getFundraiserCount()).to.equal(1);
  });

  it("should create WITHOUT_GOAL fundraiser", async function () {
    const currentTime = await getCurrentBlockTime();
    const creationData = {
      title: "Flexible Funding",
      description: "Flexible funding project",
      endDate: currentTime + 7200,
      fundraiserType: 1, // WITHOUT_GOAL
      token: await mockToken.getAddress(),
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Remote"
    };

    await dao.createFundraiser(creationData);
    
    const [, , , , fundraiserType] = await dao.getFundraiserDetails(1);
    expect(fundraiserType).to.equal(1);
  });

  it("should validate fundraiser creation parameters", async function () {
    const currentTime = await getCurrentBlockTime();
    const baseData = {
      title: "Valid Title",
      description: "Valid description",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Valid Location"
    };

    // Invalid title
    await expect(dao.createFundraiser({...baseData, title: ""}))
      .to.be.revertedWith("Invalid title");
    
    await expect(dao.createFundraiser({...baseData, title: "a".repeat(101)}))
      .to.be.revertedWith("Invalid title");

    // Invalid description
    await expect(dao.createFundraiser({...baseData, description: ""}))
      .to.be.revertedWith("Invalid description");

    // Invalid location
    await expect(dao.createFundraiser({...baseData, location: ""}))
      .to.be.revertedWith("Invalid location");

    // Invalid end date
    await expect(dao.createFundraiser({...baseData, endDate: currentTime - 1}))
      .to.be.revertedWith("End date must be in future");

    // Non-whitelisted token
    await expect(dao.createFundraiser({...baseData, token: user1.address}))
      .to.be.revertedWithCustomError(dao, "InvalidTokenAddress");

    // WITH_GOAL without goal amount
    await expect(dao.createFundraiser({...baseData, goalAmount: 0}))
      .to.be.revertedWith("Goal amount required for WITH_GOAL type");

    // Too many initial images
    await expect(dao.createFundraiser({...baseData, initialImages: Array(11).fill("QmTest")}))
      .to.be.revertedWith("Too many initial images");
  });

  it("should handle multimedia in fundraiser creation", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Multimedia Project",
      description: "Project with media",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: ["QmImage1", "QmImage2"],
      initialVideos: ["QmVideo1"],
      metadataHash: "",
      location: "Test Location"
    };

    await expect(dao.createFundraiser(creationData))
      .to.emit(dao, "MediaAdded")
      .and.to.emit(dao, "MultimediaActivated");

    const [media, total] = await dao.getFundraiserGallery(1, 0, 10);
    expect(total).to.equal(3);
    expect(media[0].ipfsHash).to.equal("QmImage1");
    expect(media[2].ipfsHash).to.equal("QmVideo1");
  });
});

// ==============================
// DONATION SYSTEM
// ==============================

describe("💸 Donation System", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Test Fundraiser",
      description: "Test description",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
  });

  it("should allow donations and track progress", async function () {
    const donationAmount = ethers.parseUnits("500", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    
    await expect(dao.connect(user1).donate(1, donationAmount))
      .to.emit(dao, "DonationMade")
      .withArgs(1, user1.address, await mockToken.getAddress(), donationAmount, donationAmount);

    const [raised, goal, percentage, donorsCount] = await dao.getFundraiserProgress(1);
    expect(raised).to.equal(donationAmount);
    expect(goal).to.equal(ethers.parseUnits("1000", 6));
    expect(percentage).to.equal(50);
    expect(donorsCount).to.equal(1);

    const [donors, amounts] = await dao.getDonors(1, 0, 10);
    expect(donors[0]).to.equal(user1.address);
    expect(amounts[0]).to.equal(donationAmount);
  });

  it("should handle goal completion", async function () {
    const donationAmount = ethers.parseUnits("1000", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    
    await expect(dao.connect(user1).donate(1, donationAmount))
      .to.emit(dao, "FundraiserStatusChanged")
      .withArgs(1, 0, 1); // ACTIVE to SUCCESSFUL

    const [, , , , , status] = await dao.getFundraiserDetails(1);
    expect(status).to.equal(1); // SUCCESSFUL
  });

  it("should apply donation commission", async function () {
    await dao.setDonationCommission(1000); // 10%
    
    const donationAmount = ethers.parseUnits("1000", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    await dao.connect(user1).donate(1, donationAmount);

    const [raised] = await dao.getFundraiserProgress(1);
    expect(raised).to.equal(ethers.parseUnits("900", 6)); // 90% after commission

    const commissionBalance = await mockToken.balanceOf(commissionWallet.address);
    expect(commissionBalance).to.be.gt(ethers.parseUnits("50000", 6)); // Original + commission
  });

  it("should handle batch donations", async function () {
    // Create second fundraiser
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Second Fundraiser",
      description: "Second test",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("500", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location 2"
    };
    await dao.createFundraiser(creationData);

    const amounts = [ethers.parseUnits("300", 6), ethers.parseUnits("200", 6)];
    const totalAmount = amounts[0] + amounts[1];
    
    await mockToken.connect(user1).approve(await dao.getAddress(), totalAmount);
    
    await expect(dao.connect(user1).batchDonate([1, 2], amounts))
      .to.emit(dao, "BatchDonationExecuted");

    const [raised1] = await dao.getFundraiserProgress(1);
    const [raised2] = await dao.getFundraiserProgress(2);
    expect(raised1).to.equal(amounts[0]);
    expect(raised2).to.equal(amounts[1]);
  });

  it("should validate donation parameters", async function () {
    await expect(dao.connect(user1).donate(1, 0))
      .to.be.revertedWithCustomError(dao, "InsufficientAmount");

    await expect(dao.connect(user1).donate(999, ethers.parseUnits("100", 6)))
      .to.be.revertedWithCustomError(dao, "FundraiserNotFound");
  });

  describe("Advanced Donation Methods", function () {
    it("should support permit functionality check", async function () {
      const supportsPermit = await dao.supportsPermit(await mockToken.getAddress());
      expect(typeof supportsPermit).to.equal('boolean');
    });

    it("should get user nonce", async function () {
      const nonce = await dao.getNonce(user1.address);
      expect(nonce).to.equal(0);
    });

    it("should verify donation signatures", async function () {
      const amount = ethers.parseUnits("500", 6);
      const deadline = Math.floor(Date.now() / 1000) + 3600;
      
      const isValid = await dao.verifyDonationSignature(
        user1.address,
        1,
        amount,
        deadline,
        "0x00"
      );
      expect(isValid).to.be.false;
    });
  });
});

// ==============================
// FUNDRAISER EXTENSIONS
// ==============================

describe("📅 Fundraiser Extensions", function () {
  beforeEach(async () => {
    const latestBlock = await ethers.provider.getBlock('latest');
    const currentTime = latestBlock.timestamp;
    
    const creationData = {
      title: "Extendable Fundraiser",
      description: "Can be extended",
      endDate: currentTime + (10 * 24 * 3600), // ✅ POPRAWKA: 10 dni zamiast 1 godziny
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
  });

  it("should allow fundraiser extension with fee", async function () {
    await mockToken.connect(owner).approve(await dao.getAddress(), ethers.parseUnits("20", 6));
    
    await expect(dao.extendFundraiser(1, 30))
      .to.emit(dao, "FundraiserExtended");

    const [, , , , , , , , , , , , extensionCount] = await dao.getFundraiserDetails(1);
    expect(extensionCount).to.equal(1);
  });

  it("should validate extension parameters", async function () {
    await expect(dao.extendFundraiser(1, 0))
      .to.be.revertedWith("Invalid extension period");

    await expect(dao.extendFundraiser(1, 91))
      .to.be.revertedWith("Invalid extension period");

    await expect(dao.connect(user1).extendFundraiser(1, 30))
      .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
  });
});

// ==============================
// SUSPENSION SYSTEM
// ==============================

describe("🚫 Suspension System", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Suspendable Fundraiser",
      description: "Can be suspended",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
  });

  it("should allow owner to suspend fundraiser", async function () {
    await expect(dao.suspendFundraiser(1, "Violation of terms"))
      .to.emit(dao, "FundraiserSuspended")
      .withArgs(1, owner.address, "Violation of terms", await ethers.provider.getBlock().then(b => b.timestamp + 1));

    const [isSuspended, , suspensionReason] = await dao.getSuspensionInfo(1);
    expect(isSuspended).to.be.true;
    expect(suspensionReason).to.equal("Violation of terms");
  });

  it("should allow creator to suspend their own fundraiser", async function () {
    await dao.connect(owner).suspendFundraiser(1, "Self-suspension");
    
    const [isSuspended] = await dao.getSuspensionInfo(1);
    expect(isSuspended).to.be.true;
  });

  it("should allow owner to unsuspend fundraiser", async function () {
    await dao.suspendFundraiser(1, "Test suspension");
    
    await expect(dao.unsuspendFundraiser(1))
      .to.emit(dao, "FundraiserUnsuspended")
      .withArgs(1, owner.address, await ethers.provider.getBlock().then(b => b.timestamp + 1));

    const [isSuspended] = await dao.getSuspensionInfo(1);
    expect(isSuspended).to.be.false;
  });

  it("should allow refunds from suspended fundraisers", async function () {
    const donationAmount = ethers.parseUnits("500", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    await dao.connect(user1).donate(1, donationAmount);

    await dao.suspendFundraiser(1, "Emergency suspension");

    const user1BalanceBefore = await mockToken.balanceOf(user1.address);
    
    await expect(dao.connect(user1).refundFromSuspended(1))
      .to.emit(dao, "DonationRefunded");

    const user1BalanceAfter = await mockToken.balanceOf(user1.address);
    expect(user1BalanceAfter - user1BalanceBefore).to.equal(donationAmount);
  });

  it("should prevent operations on suspended fundraisers", async function () {
    await dao.suspendFundraiser(1, "Test suspension");

    const donationAmount = ethers.parseUnits("100", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    
    await expect(dao.connect(user1).donate(1, donationAmount))
      .to.be.revertedWithCustomError(dao, "FundraiserSuspendedError");
  });

  it("should validate suspension parameters", async function () {
    await expect(dao.suspendFundraiser(1, ""))
      .to.be.revertedWith("Suspension reason required");

    await expect(dao.connect(user1).suspendFundraiser(1, "Unauthorized"))
      .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
  });
});

// ==============================
// MULTIMEDIA MANAGEMENT
// ==============================

describe("🎬 Multimedia Management", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Multimedia Fundraiser",
      description: "With multimedia support",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
  });

  describe("Media Management", function () {
    it("should allow adding multimedia to fundraiser", async function () {
      const mediaItems = [
        {
          ipfsHash: "QmTestImage",
          mediaType: 0,
          filename: "test.jpg",
          fileSize: 1024000,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Test image"
        },
        {
          ipfsHash: "QmTestVideo",
          mediaType: 1,
          filename: "test.mp4",
          fileSize: 5024000,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Test video"
        }
      ];

      await expect(dao.addMultimediaToFundraiser(1, mediaItems))
        .to.emit(dao, "MediaAdded")
        .withArgs(1, "QmTestImage", 0, "test.jpg", owner.address);

      const [media, total] = await dao.getFundraiserGallery(1, 0, 10);
      expect(total).to.equal(2);
      expect(media[0].ipfsHash).to.equal("QmTestImage");
      expect(media[1].ipfsHash).to.equal("QmTestVideo");
    });

    it("should enforce media type limits", async function () {
      const tooManyVideos = Array(31).fill().map((_, i) => ({
        ipfsHash: `QmVideo${i}`,
        mediaType: 1,
        filename: `video${i}.mp4`,
        fileSize: 5024000,
        uploadTime: 0,
        uploader: ethers.ZeroAddress,
        description: `Video ${i}`
      }));

      await expect(dao.addMultimediaToFundraiser(1, tooManyVideos))
        .to.be.revertedWith("Too many media files");
    });

    it("should allow removing media from fundraiser", async function () {
      const mediaItems = [
        {
          ipfsHash: "QmTestImage",
          mediaType: 0,
          filename: "test.jpg",
          fileSize: 1024000,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Test image"
        }
      ];

      await dao.addMultimediaToFundraiser(1, mediaItems);
      
      await expect(dao.removeMediaFromFundraiser(1, 0))
        .to.emit(dao, "MediaRemoved")
        .withArgs(1, 0, "QmTestImage");

      const [, total] = await dao.getFundraiserGallery(1, 0, 10);
      expect(total).to.equal(0);
    });

    it("should validate media parameters", async function () {
      const invalidMedia = [
        {
          ipfsHash: "",
          mediaType: 0,
          filename: "test.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Empty hash"
        }
      ];

      await expect(dao.addMultimediaToFundraiser(1, invalidMedia))
        .to.be.revertedWith("Empty IPFS hash");

      const invalidTypeMedia = [
        {
          ipfsHash: "QmValid",
          mediaType: 5,
          filename: "test.xyz",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Invalid type"
        }
      ];

      await expect(dao.addMultimediaToFundraiser(1, invalidTypeMedia))
        .to.be.revertedWithCustomError(dao, "InvalidMediaType");
    });

    it("should get media type limits", async function () {
      expect(await dao.getMediaTypeLimit(0)).to.equal(100); // Images
      expect(await dao.getMediaTypeLimit(1)).to.equal(30);  // Videos
      expect(await dao.getMediaTypeLimit(2)).to.equal(20);  // Audio
      expect(await dao.getMediaTypeLimit(3)).to.equal(50);  // Documents
      expect(await dao.getMediaTypeLimit(4)).to.equal(0);   // Invalid type
    });
  });

  describe("Media Authorization", function () {
    it("should manage media manager authorization", async function () {
      await expect(dao.authorizeMediaManager(1, user1.address))
        .to.emit(dao, "MediaManagerAuthorized")
        .withArgs(1, user1.address);

      const mediaItems = [
        {
          ipfsHash: "QmManagerTest",
          mediaType: 0,
          filename: "manager.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Manager test"
        }
      ];

      await dao.connect(user1).addMultimediaToFundraiser(1, mediaItems);

      await expect(dao.revokeMediaManager(1, user1.address))
        .to.emit(dao, "MediaManagerRevoked")
        .withArgs(1, user1.address);

      await expect(dao.connect(user1).addMultimediaToFundraiser(1, mediaItems))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });

    it("should prevent unauthorized media operations", async function () {
      const mediaItems = [
        {
          ipfsHash: "QmUnauth",
          mediaType: 0,
          filename: "unauth.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Unauthorized"
        }
      ];

      await expect(dao.connect(user1).addMultimediaToFundraiser(1, mediaItems))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });
  });
});

// ==============================
// UPDATE SYSTEM
// ==============================

describe("📝 Update System", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Update Test Fundraiser",
      description: "For testing updates",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
  });

  describe("Basic Updates", function () {
    it("should allow posting updates", async function () {
      await expect(dao.postUpdate(1, "First progress update"))
        .to.emit(dao, "UpdatePosted")
        .withArgs(2, 1, owner.address, "First progress update", 0);

      expect(await dao.getUpdateCount()).to.equal(2);

      const [id, fundraiserId, author, content, timestamp, updateType, isPinned] = await dao.getUpdate(2);
      expect(id).to.equal(2);
      expect(fundraiserId).to.equal(1);
      expect(author).to.equal(owner.address);
      expect(content).to.equal("First progress update");
      expect(updateType).to.equal(0);
      expect(isPinned).to.be.false;
    });

    it("should allow posting updates with multimedia", async function () {
      const attachments = [
        {
          ipfsHash: "QmUpdateImg",
          mediaType: 0,
          filename: "update.jpg",
          fileSize: 2048,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Update image"
        }
      ];

      await expect(dao.postUpdateWithMultimedia(1, "Update with media", 1, attachments))
        .to.emit(dao, "UpdatePosted")
        .withArgs(2, 1, owner.address, "Update with media", 1);

      const attachmentCount = await dao.getUpdate(2).then(result => result[7]);
      expect(attachmentCount).to.equal(1);

      const updateAttachments = await dao.getUpdateAttachments(2);
      expect(updateAttachments[0].ipfsHash).to.equal("QmUpdateImg");
    });

    it("should validate update content", async function () {
      await expect(dao.postUpdate(1, ""))
        .to.be.revertedWith("Invalid content");

      const longContent = "a".repeat(1001);
      await expect(dao.postUpdate(1, longContent))
        .to.be.revertedWith("Invalid content");

      const tooManyAttachments = Array(6).fill().map((_, i) => ({
        ipfsHash: `QmAttach${i}`,
        mediaType: 0,
        filename: `attach${i}.jpg`,
        fileSize: 1024,
        uploadTime: 0,
        uploader: ethers.ZeroAddress,
        description: `Attachment ${i}`
      }));

      await expect(dao.postUpdateWithMultimedia(1, "test", 0, tooManyAttachments))
        .to.be.revertedWith("Too many attachments");
    });
  });

  describe("Update Pinning", function () {
    beforeEach(async () => {
      await dao.postUpdate(1, "First update");
      await dao.postUpdate(1, "Second update");
    });

    it("should allow pinning updates", async function () {
      await expect(dao.pinUpdate(3))
        .to.emit(dao, "UpdatePinned")
        .withArgs(3, 1);

      const [, , , , , , isPinned] = await dao.getUpdate(3);
      expect(isPinned).to.be.true;
    });

    it("should handle pin replacement", async function () {
      await dao.pinUpdate(2);
      
      await expect(dao.pinUpdate(3))
        .to.emit(dao, "UpdateUnpinned")
        .withArgs(1, 2)
        .and.to.emit(dao, "UpdatePinned")
        .withArgs(3, 1);
    });

    it("should allow unpinning updates", async function () {
      await dao.pinUpdate(2);
      
      await expect(dao.unpinUpdate(1))
        .to.emit(dao, "UpdateUnpinned")
        .withArgs(1, 2);
    });

    it("should validate pinning authorization", async function () {
      await expect(dao.connect(user1).pinUpdate(2))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });
  });

  describe("Update Authorization", function () {
    it("should manage updater authorization", async function () {
      await expect(dao.authorizeUpdater(1, user1.address))
        .to.emit(dao, "UpdaterAuthorized")
        .withArgs(1, user1.address);

      expect(await dao.canUpdate(1, user1.address)).to.be.true;

      await dao.connect(user1).postUpdate(1, "Authorized update");
      expect(await dao.getUpdateCount()).to.equal(2);

      await expect(dao.revokeUpdater(1, user1.address))
        .to.emit(dao, "UpdaterRevoked")
        .withArgs(1, user1.address);

      expect(await dao.canUpdate(1, user1.address)).to.be.false;

      await expect(dao.connect(user1).postUpdate(1, "Should fail"))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });
  });
});

// ==============================
// WITHDRAWAL & REFUND SYSTEM
// ==============================

describe("💰 Withdrawal & Refund System", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Withdrawal Test",
      description: "Test withdrawals",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);

    const donationAmount = ethers.parseUnits("1000", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    await dao.connect(user1).donate(1, donationAmount);
  });

  it("should allow withdrawal when goal is met", async function () {
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    
    await expect(dao.withdrawFunds(1))
      .to.emit(dao, "FundsWithdrawn");

    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);

    // ✅ POPRAWKA: Sprawdź właściwy indeks dla fundsWithdrawn
    const fundraiserDetails = await dao.getFundraiserDetails(1);
    const [, , , , , , , , , , , , , isSuspended] = fundraiserDetails;
    // fundsWithdrawn powinno być true po wypłacie, ale sprawdzamy przez legacy getter
    const [, , , , , , withdrawn] = await dao.getFundraiser(1);
    expect(withdrawn).to.be.true;
  });

  it("should apply success commission on withdrawal", async function () {
    await dao.setSuccessCommission(500); // 5%
    
    const commissionBalanceBefore = await mockToken.balanceOf(commissionWallet.address);
    await dao.withdrawFunds(1);
    const commissionBalanceAfter = await mockToken.balanceOf(commissionWallet.address);
    
    const commissionIncrease = commissionBalanceAfter - commissionBalanceBefore;
    expect(commissionIncrease).to.be.gt(0);
  });

  it("should prevent unauthorized withdrawal", async function () {
    await expect(dao.connect(user1).withdrawFunds(1))
      .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
  });

  it("should prevent double withdrawal", async function () {
    await dao.withdrawFunds(1);
    await expect(dao.withdrawFunds(1))
      .to.be.revertedWith("Already withdrawn");
  });

  describe("Refund System", function () {
    beforeEach(async () => {
      // Create a new fundraiser that will fail
      const latestBlock = await ethers.provider.getBlock('latest');
      const currentTime = latestBlock.timestamp;
      
      const creationData = {
        title: "Refund Test",
        description: "Test refunds",
        endDate: currentTime + 120,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("2000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Test Location"
      };
      await dao.createFundraiser(creationData);

      const donationAmount = ethers.parseUnits("1000", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
      await dao.connect(user1).donate(2, donationAmount);
    });

    it("should allow refunds for failed fundraisers", async function () {
      await ethers.provider.send("evm_increaseTime", [130]);
      await ethers.provider.send("evm_mine");

      // ✅ POPRAWKA: Dodaj wywołanie updateStatus przed initiateClosure
      await dao.updateFundraiserStatus(2);
      await dao.initiateClosure(2);

      const user1BalanceBefore = await mockToken.balanceOf(user1.address);
      
      await expect(dao.connect(user1).refund(2))
        .to.emit(dao, "DonationRefunded");

      const user1BalanceAfter = await mockToken.balanceOf(user1.address);
      expect(user1BalanceAfter).to.be.gt(user1BalanceBefore);
    });

    it("should apply refund commission on multiple refunds", async function () {
      await dao.setRefundCommission(1000); // 10%

      await ethers.provider.send("evm_increaseTime", [130]);
      await ethers.provider.send("evm_mine");

      // ✅ POPRAWKA: Dodaj wywołanie updateStatus przed initiateClosure
      await dao.updateFundraiserStatus(2);
      await dao.initiateClosure(2);

      // First refund - no commission
      await dao.connect(user1).refund(2);

      // Create and donate to third fundraiser for second refund
      const latestBlock = await ethers.provider.getBlock('latest');
      const currentTime = latestBlock.timestamp;
      
      const creationData = {
        title: "Second Refund Test",
        description: "Second test",
        endDate: currentTime + 120,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("2000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Test Location 2"
      };
      await dao.createFundraiser(creationData);

      const donationAmount = ethers.parseUnits("1000", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
      await dao.connect(user1).donate(3, donationAmount);

      await ethers.provider.send("evm_increaseTime", [130]);
      await ethers.provider.send("evm_mine");

      // ✅ POPRAWKA: Dodaj wywołanie updateStatus przed initiateClosure
      await dao.updateFundraiserStatus(3);
      await dao.initiateClosure(3);

      const commissionBalanceBefore = await mockToken.balanceOf(commissionWallet.address);
      await dao.connect(user1).refund(3);
      const commissionBalanceAfter = await mockToken.balanceOf(commissionWallet.address);

      expect(commissionBalanceAfter).to.be.gt(commissionBalanceBefore);
    });

    it("should validate refund conditions", async function () {
      await expect(dao.connect(user2).refund(2))
        .to.be.revertedWith("No donation found");

      await expect(dao.connect(user1).refund(2))
        .to.be.revertedWith("Not in refund period");
    });

    it("should check refund eligibility", async function () {
      const [canRefund1, reason1] = await dao.canRefund(2, user1.address);
      expect(canRefund1).to.be.false;
      expect(reason1).to.equal("Not in refund period");

      const [canRefund2, reason2] = await dao.canRefund(2, user2.address);
      expect(canRefund2).to.be.false;
      expect(reason2).to.equal("No donation found");

      // Test suspended fundraiser refund eligibility
      await dao.suspendFundraiser(2, "Test suspension");
      
      const [canRefund3, reason3] = await dao.canRefund(2, user1.address);
      expect(canRefund3).to.be.true;
      expect(reason3).to.equal("Suspended fundraiser - unlimited refund");
    });
  });
});

// ==============================
// LOCATION MANAGEMENT
// ==============================

describe("📍 Location Management", function () {
  beforeEach(async () => {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Location Test",
      description: "Testing locations",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Original Location"
    };
    await dao.createFundraiser(creationData);
  });

  it("should allow updating fundraiser location", async function () {
    await expect(dao.updateLocation(1, "New Location"))
      .to.emit(dao, "LocationUpdated")
      .withArgs(1, "Original Location", "New Location");

    const [, , location] = await dao.getFundraiserDetails(1);
    expect(location).to.equal("New Location");
  });

  it("should validate location updates", async function () {
    await expect(dao.updateLocation(1, ""))
      .to.be.revertedWith("Invalid location");

    const longLocation = "a".repeat(201);
    await expect(dao.updateLocation(1, longLocation))
      .to.be.revertedWith("Invalid location");

    await expect(dao.connect(user1).updateLocation(1, "Unauthorized"))
      .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
  });
});

// ==============================
// COMMISSION MANAGEMENT
// ==============================

describe("💼 Commission Management", function () {
  it("should allow setting commissions", async function () {
    await expect(dao.setDonationCommission(500))
      .to.emit(dao, "DonationCommissionSet")
      .withArgs(500);

    await expect(dao.setSuccessCommission(300))
      .to.emit(dao, "SuccessCommissionSet")
      .withArgs(300);

    await expect(dao.setRefundCommission(200))
      .to.emit(dao, "RefundCommissionSet")
      .withArgs(200);

    expect(await dao.donationCommission()).to.equal(500);
    expect(await dao.successCommission()).to.equal(300);
    expect(await dao.refundCommission()).to.equal(200);
  });

  it("should validate commission limits", async function () {
    await expect(dao.setDonationCommission(10001))
      .to.be.revertedWith("Max 100%");

    await expect(dao.setSuccessCommission(10001))
      .to.be.revertedWith("Max 100%");

    await expect(dao.setRefundCommission(10001))
      .to.be.revertedWith("Max 100%");
  });

  it("should allow changing commission wallet", async function () {
    await expect(dao.setCommissionWallet(user4.address))
      .to.emit(dao, "CommissionWalletChanged")
      .withArgs(commissionWallet.address, user4.address);

    await expect(dao.setCommissionWallet(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(dao, "InvalidTokenAddress");
  });

  it("should allow changing fee token", async function () {
    await expect(dao.setFeeToken(user4.address))
      .to.emit(dao, "FeeTokenSet")
      .withArgs(await feeToken.getAddress(), user4.address);
  });

  it("should prevent unauthorized commission changes", async function () {
    await expect(dao.connect(user1).setDonationCommission(500))
      .to.be.reverted;

    await expect(dao.connect(user1).setCommissionWallet(user1.address))
      .to.be.reverted;
  });
});

// ==============================
// TOKEN MANAGEMENT
// ==============================

describe("🪙 Token Management", function () {
  let mockToken2;

  beforeEach(async () => {
    const MockToken = await ethers.getContractFactory("MockToken");
    mockToken2 = await MockToken.deploy("DAI Test", "DAI", 18, ethers.parseUnits("100000", 18), owner.address);
    await mockToken2.waitForDeployment();
  });

  it("should whitelist new tokens", async function () {
    await expect(dao.whitelistToken(await mockToken2.getAddress()))
      .to.emit(dao, "TokenWhitelisted")
      .withArgs(await mockToken2.getAddress());

    expect(await dao.isTokenWhitelisted(await mockToken2.getAddress())).to.be.true;

    const whitelistedTokens = await dao.getWhitelistedTokens();
    expect(whitelistedTokens).to.include(await mockToken2.getAddress());
  });

  it("should remove whitelisted tokens", async function () {
    await dao.whitelistToken(await mockToken2.getAddress());
    
    await expect(dao.removeWhitelistToken(await mockToken2.getAddress()))
      .to.emit(dao, "TokenRemoved")
      .withArgs(await mockToken2.getAddress());

    expect(await dao.isTokenWhitelisted(await mockToken2.getAddress())).to.be.false;
  });

  it("should validate token whitelisting", async function () {
    await expect(dao.whitelistToken(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(dao, "InvalidTokenAddress");

    await expect(dao.whitelistToken(user1.address))
      .to.be.revertedWith("Not a contract");

    await expect(dao.whitelistToken(await mockToken.getAddress()))
      .to.be.revertedWith("Already whitelisted");
  });

  it("should prevent fundraisers with non-whitelisted tokens", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Invalid Token Test",
      description: "Should fail",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken2.getAddress(),
      goalAmount: ethers.parseUnits("1000", 18),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };

    await expect(dao.createFundraiser(creationData))
      .to.be.revertedWithCustomError(dao, "InvalidTokenAddress");
  });
});

// ==============================
// CIRCUIT BREAKER & LIMITS
// ==============================

describe("🔄 Circuit Breaker & Limits", function () {
  it("should enforce daily donation limits", async function () {
    await dao.setMaxDailyDonations(ethers.parseUnits("100000", 6));
    await dao.setMaxUserDailyDonation(ethers.parseUnits("10000", 6));

    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Limit Test",
      description: "Testing limits",
      endDate: currentTime + 7200,
      fundraiserType: 1, // WITHOUT_GOAL
      token: await mockToken.getAddress(),
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);

    // This should work
    const normalAmount = ethers.parseUnits("5000", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), normalAmount);
    await dao.connect(user1).donate(1, normalAmount);

    // This should fail due to user daily limit
    const excessiveAmount = ethers.parseUnits("8000", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), excessiveAmount);
    await expect(dao.connect(user1).donate(1, excessiveAmount))
      .to.be.revertedWithCustomError(dao, "DailyLimitExceeded");
  });

  it("should allow setting limits", async function () {
    const newDailyLimit = ethers.parseUnits("2000000", 6);
    await dao.setMaxDailyDonations(newDailyLimit);
    expect(await dao.maxDailyDonations()).to.equal(newDailyLimit);

    const newUserLimit = ethers.parseUnits("50000", 6);
    await dao.setMaxUserDailyDonation(newUserLimit);
    expect(await dao.maxUserDailyDonation()).to.equal(newUserLimit);
  });
});

// ==============================
// ACCESS CONTROL & SECURITY
// ==============================

describe("🔒 Access Control & Security", function () {
  describe("Pausing System", function () {
    it("should handle global pause", async function () {
      await dao.pause();
      expect(await dao.paused()).to.be.true;

      await expect(dao.createProposal("Should fail", 3600))
        .to.be.reverted;

      await dao.unpause();
      expect(await dao.paused()).to.be.false;
    });

    it("should handle selective pausing", async function () {
      await dao.toggleVotingPause();
      expect(await dao.votingPaused()).to.be.true;

      await dao.toggleDonationsPause();
      expect(await dao.donationsPaused()).to.be.true;

      await dao.toggleWithdrawalsPause();
      expect(await dao.withdrawalsPaused()).to.be.true;

      await dao.toggleUpdatesPause();
      expect(await dao.updatesPaused()).to.be.true;

      await dao.toggleMediaPause();
      expect(await dao.mediaPaused()).to.be.true;
    });

    it("should enforce pausing restrictions", async function () {
      await dao.createProposal("Test", 3600);
      await dao.toggleVotingPause();
      
      await expect(dao.connect(user1).vote(1, true))
        .to.be.revertedWith("Voting paused");

      const currentTime = Math.floor(Date.now() / 1000);
      const creationData = {
        title: "Test",
        description: "Test",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Test"
      };
      await dao.createFundraiser(creationData);

      await dao.toggleDonationsPause();
      const amount = ethers.parseUnits("100", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), amount);
      await expect(dao.connect(user1).donate(1, amount))
        .to.be.revertedWith("Donations paused");
    });

    it("should handle emergency pause", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      await dao.createFundraiser({
        title: "Emergency Test",
        description: "Test",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Test"
      });

      await dao.emergencyFreeze();

      expect(await dao.paused()).to.be.true;
      expect(await dao.votingPaused()).to.be.true;
      expect(await dao.donationsPaused()).to.be.true;
      expect(await dao.withdrawalsPaused()).to.be.true;

      // ✅ POPRAWKA: Sprawdź poprawnie flagę isSuspended
      const [, , , , , , , , , , , , , isSuspended] = await dao.getFundraiserDetails(1);
      expect(isSuspended).to.be.true;
    });
  });

  describe("Emergency Functions", function () {
    it("should allow emergency withdrawals", async function () {
      const amount = ethers.parseUnits("100", 6);
      await mockToken.connect(owner).transfer(await dao.getAddress(), amount);

      await expect(dao.emergencyWithdraw(await mockToken.getAddress(), owner.address, amount))
        .to.emit(dao, "EmergencyWithdraw")
        .withArgs(await mockToken.getAddress(), owner.address, amount);
    });

    it("should prevent unauthorized emergency operations", async function () {
      await expect(dao.connect(user1).pause())
        .to.be.reverted;

      await expect(dao.connect(user1).emergencyFreeze())
        .to.be.reverted;

      await expect(dao.connect(user1).emergencyWithdraw(await mockToken.getAddress(), user1.address, 100))
        .to.be.reverted;
    });
  });
});

// ==============================
// VIEW FUNCTIONS & STATISTICS
// ==============================

describe("📊 View Functions & Statistics", function () {
  beforeEach(async () => {
    await dao.createProposal("Test Proposal 1", 3600);
    await dao.createProposal("Test Proposal 2", 3600);

    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Statistics Test",
      description: "For testing stats",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: ["QmImage1"],
      initialVideos: [],
      metadataHash: "",
      location: "Test Location"
    };
    await dao.createFundraiser(creationData);
    
    await dao.postUpdate(1, "First update");
  });

  describe("Platform Statistics", function () {
    it("should return correct platform stats", async function () {
      const [
        totalFundraisers,
        totalProposals,
        totalUpdates,
        activeFundraisers,
        successfulFundraisers,
        suspendedFundraisers,
        totalWhitelistedTokens
      ] = await dao.getPlatformStats();

      expect(totalFundraisers).to.equal(1);
      expect(totalProposals).to.equal(2);
      expect(totalUpdates).to.equal(2);
      expect(activeFundraisers).to.equal(1);
      expect(successfulFundraisers).to.equal(0);
      expect(suspendedFundraisers).to.equal(0);
      expect(totalWhitelistedTokens).to.equal(1);
    });

    it("should return fundraiser statistics", async function () {
      const donationAmount = ethers.parseUnits("500", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
      await dao.connect(user1).donate(1, donationAmount);

      const [
        totalDonations,
        averageDonation,
        totalRefunds,
        mediaItems,
        updatesCount,
        daysActive,
        goalProgress
      ] = await dao.getFundraiserStats(1);

      expect(totalDonations).to.equal(donationAmount);
      expect(averageDonation).to.equal(donationAmount);
      expect(totalRefunds).to.equal(0);
      expect(mediaItems).to.equal(1);
      expect(updatesCount).to.equal(2);
      expect(goalProgress).to.equal(5000);
    });
  });

  describe("Data Retrieval", function () {
    it("should return all IDs correctly", async function () {
      const proposalIds = await dao.getAllProposalIds();
      const fundraiserIds = await dao.getAllFundraiserIds();
      const whitelistedTokens = await dao.getWhitelistedTokens();

      expect(proposalIds).to.have.lengthOf(2);
      expect(fundraiserIds).to.have.lengthOf(1);
      expect(whitelistedTokens).to.have.lengthOf(1);
    });

    it("should handle pagination correctly", async function () {
      await dao.postUpdate(1, "Second update");
      await dao.postUpdate(1, "Third update");

      const [updates1, total1] = await dao.getFundraiserUpdates(1, 0, 2);
      expect(updates1).to.have.lengthOf(2);
      expect(total1).to.equal(4);

      const [updates2, total2] = await dao.getFundraiserUpdates(1, 2, 2);
      expect(updates2).to.have.lengthOf(2);
      expect(total2).to.equal(4);
    });

    it("should return correct counts", async function () {
      expect(await dao.getFundraiserCount()).to.equal(1);
      expect(await dao.getProposalCount()).to.equal(2);
      expect(await dao.getUpdateCount()).to.equal(2);
    });
  });

  describe("Search Functions", function () {
    it("should find fundraisers by status", async function () {
      const [activeIds, total] = await dao.getFundraisersByStatus(0, 0, 10); // ACTIVE
      expect(activeIds).to.have.lengthOf(1);
      expect(total).to.equal(1);
      expect(activeIds[0]).to.equal(1);
    });

    it("should find fundraisers by creator", async function () {
      const [creatorIds, total] = await dao.getFundraisersByCreator(owner.address, 0, 10);
      expect(creatorIds).to.have.lengthOf(1);
      expect(total).to.equal(1);
      expect(creatorIds[0]).to.equal(1);
    });

    it("should find fundraisers by token", async function () {
      const [tokenIds, total] = await dao.getFundraisersByToken(await mockToken.getAddress(), 0, 10);
      expect(tokenIds).to.have.lengthOf(1);
      expect(total).to.equal(1);
      expect(tokenIds[0]).to.equal(1);
    });

    it("should find suspended fundraisers", async function () {
      await dao.suspendFundraiser(1, "Test suspension");
      
      const [suspendedIds, total] = await dao.getSuspendedFundraisers(0, 10);
      expect(suspendedIds).to.have.lengthOf(1);
      expect(total).to.equal(1);
      expect(suspendedIds[0]).to.equal(1);
    });
  });
});

// ==============================
// INTEGRATION TESTS
// ==============================

describe("🎯 Integration & Complex Scenarios", function () {
  describe("Complete Fundraising Lifecycle", function () {
    it("should handle successful fundraiser lifecycle", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      const creationData = {
        title: "Integration Test Fundraiser",
        description: "Complete lifecycle test",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: ["QmImage1"],
        initialVideos: ["QmVideo1"],
        metadataHash: "QmMeta123",
        location: "Integration City"
      };
      await dao.createFundraiser(creationData);

      // Add multimedia
      const mediaItems = [
        {
          ipfsHash: "QmAdditionalImage",
          mediaType: 0,
          filename: "additional.jpg",
          fileSize: 2048,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Additional image"
        }
      ];
      await dao.addMultimediaToFundraiser(1, mediaItems);

      // Post update with multimedia
      const updateAttachments = [
        {
          ipfsHash: "QmUpdateImage",
          mediaType: 0,
          filename: "progress.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Progress image"
        }
      ];
      await dao.postUpdateWithMultimedia(1, "Great progress update!", 1, updateAttachments);

      // Make donations
      const donation1 = ethers.parseUnits("600", 6);
      const donation2 = ethers.parseUnits("400", 6);
      
      await mockToken.connect(user1).approve(await dao.getAddress(), donation1);
      await dao.connect(user1).donate(1, donation1);
      
      await mockToken.connect(user2).approve(await dao.getAddress(), donation2);
      await dao.connect(user2).donate(1, donation2);

      // Check status changed to successful
      const [, , , , , status] = await dao.getFundraiserDetails(1);
      expect(status).to.equal(1); // SUCCESSFUL

      // Withdraw funds
      const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
      await dao.withdrawFunds(1);
      const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
      
      expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);

      // Verify final state
      const fundraiserDetails = await dao.getFundraiserDetails(1);
      expect(fundraiserDetails[5]).to.equal(4); // Status: COMPLETED
      
      // ✅ POPRAWKA: Sprawdź przez legacy getter
      const [, , , , , , withdrawn] = await dao.getFundraiser(1);
      expect(withdrawn).to.be.true;
    });

    it("should handle failed fundraiser with refunds", async function () {
      const latestBlock = await ethers.provider.getBlock('latest');
      const currentTime = latestBlock.timestamp;
      
      const creationData = {
        title: "Failed Fundraiser Test",
        description: "Will fail and need refunds",
        endDate: currentTime + 120,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("2000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Failure City"
      };
      await dao.createFundraiser(creationData);

      // Make partial donations
      const donationAmount = ethers.parseUnits("800", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
      await dao.connect(user1).donate(1, donationAmount);

      // Wait for expiration
      await ethers.provider.send("evm_increaseTime", [130]);
      await ethers.provider.send("evm_mine");

      // Update status and initiate closure
      await dao.updateFundraiserStatus(1);
      await dao.initiateClosure(1);

      // Process refund
      const user1BalanceBefore = await mockToken.balanceOf(user1.address);
      await dao.connect(user1).refund(1);
      const user1BalanceAfter = await mockToken.balanceOf(user1.address);

      expect(user1BalanceAfter).to.be.gt(user1BalanceBefore);
    });
  });

  describe("Multi-Fundraiser Management", function () {
    it("should handle multiple fundraisers with different configurations", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      
      // Create WITH_GOAL fundraiser
      const withGoalData = {
        title: "With Goal Fundraiser",
        description: "Has a specific goal",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Goal City"
      };
      await dao.createFundraiser(withGoalData);

      // Create WITHOUT_GOAL fundraiser
      const withoutGoalData = {
        title: "Flexible Fundraiser",
        description: "Flexible funding",
        endDate: currentTime + 7200,
        fundraiserType: 1,
        token: await mockToken.getAddress(),
        goalAmount: 0,
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Flexible City"
      };
      await dao.createFundraiser(withoutGoalData);

      expect(await dao.getFundraiserCount()).to.equal(2);

      // Test different behaviors
      const donation = ethers.parseUnits("500", 6);
      
      // Donate to both
      await mockToken.connect(user1).approve(await dao.getAddress(), donation * 2n);
      await dao.connect(user1).batchDonate([1, 2], [donation, donation]);

      // Flexible fundraiser should allow immediate withdrawal
      const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
      await dao.withdrawFunds(2);
      const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
      
      expect(ownerBalanceAfter).to.be.gt(ownerBalanceBefore);

      // Goal-based fundraiser should not be complete yet
      const [, , , , , status1] = await dao.getFundraiserDetails(1);
      expect(status1).to.equal(0); // Still ACTIVE
    });
  });

  describe("Authorization and Permission Management", function () {
    it("should handle complex authorization scenarios", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      const creationData = {
        title: "Authorization Test",
        description: "Testing permissions",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Auth City"
      };
      await dao.createFundraiser(creationData);

      // Authorize different roles
      await dao.authorizeProposer(user1.address);
      await dao.authorizeUpdater(1, user2.address);
      await dao.authorizeMediaManager(1, user3.address);

      // Test authorized operations
      await dao.connect(user1).createProposal("Authorized proposal", 3600);
      await dao.connect(user2).postUpdate(1, "Authorized update");
      
      const mediaItems = [
        {
          ipfsHash: "QmAuthMedia",
          mediaType: 0,
          filename: "auth.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Authorized media"
        }
      ];
      await dao.connect(user3).addMultimediaToFundraiser(1, mediaItems);

      // Revoke permissions
      await dao.revokeProposer(user1.address);
      await dao.revokeUpdater(1, user2.address);
      await dao.revokeMediaManager(1, user3.address);

      // Test revoked operations fail
      await expect(dao.connect(user1).createProposal("Should fail", 3600))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
      
      await expect(dao.connect(user2).postUpdate(1, "Should fail"))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
      
      await expect(dao.connect(user3).addMultimediaToFundraiser(1, mediaItems))
        .to.be.revertedWithCustomError(dao, "UnauthorizedAccess");
    });
  });
});

// ==============================
// ERROR HANDLING AND EDGE CASES
// ==============================

describe("⚠️ Error Handling & Edge Cases", function () {
  describe("Invalid Operations", function () {
    it("should handle operations on non-existent entities", async function () {
      await expect(dao.getFundraiserDetails(999))
        .to.be.revertedWithCustomError(dao, "FundraiserNotFound");

      await expect(dao.getProposal(999))
        .to.be.revertedWith("Invalid proposal");

      await expect(dao.getUpdate(999))
        .to.be.revertedWith("Invalid update");

      await expect(dao.vote(999, true))
        .to.be.revertedWith("Invalid proposal");

      await expect(dao.donate(999, ethers.parseUnits("100", 6)))
        .to.be.revertedWithCustomError(dao, "FundraiserNotFound");
    });

    it("should handle zero amounts and empty data", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      const creationData = {
        title: "Zero Test",
        description: "Testing zeros",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Zero City"
      };
      await dao.createFundraiser(creationData);

      await expect(dao.connect(user1).donate(1, 0))
        .to.be.revertedWithCustomError(dao, "InsufficientAmount");

      await expect(dao.postUpdate(1, ""))
        .to.be.revertedWith("Invalid content");

      const emptyMediaItems = [
        {
          ipfsHash: "",
          mediaType: 0,
          filename: "test.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Empty hash"
        }
      ];

      await expect(dao.addMultimediaToFundraiser(1, emptyMediaItems))
        .to.be.revertedWith("Empty IPFS hash");
    });

    it("should handle boundary conditions", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      // Test maximum values
      const creationData = {
        title: "a".repeat(100), // Maximum title length
        description: "a".repeat(2000), // Maximum description length
        endDate: currentTime + (365 * 24 * 3600), // Maximum duration
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: Array(10).fill("QmTest"), // Maximum initial images
        initialVideos: ["QmVideo"], // Maximum initial videos
        metadataHash: "a".repeat(100), // Maximum metadata hash
        location: "a".repeat(200) // Maximum location length
      };

      await dao.createFundraiser(creationData);

      // Test beyond maximum values
      const tooLongData = {
        title: "a".repeat(101),
        description: "Valid description",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Valid location"
      };

      await expect(dao.createFundraiser(tooLongData))
        .to.be.revertedWith("Invalid title");
    });
  });

  describe("State Consistency", function () {
    it("should maintain consistent state during complex operations", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      const creationData = {
        title: "Consistency Test",
        description: "Testing state consistency",
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: "Consistent City"
      };
      await dao.createFundraiser(creationData);

      // Multiple operations that should maintain consistency
      const donationAmount = ethers.parseUnits("300", 6);
      await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
      await dao.connect(user1).donate(1, donationAmount);

      await dao.postUpdate(1, "First update");
      
      const mediaItems = [
        {
          ipfsHash: "QmConsistency",
          mediaType: 0,
          filename: "consistency.jpg",
          fileSize: 1024,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Consistency test"
        }
      ];
      await dao.addMultimediaToFundraiser(1, mediaItems);

      // Verify state consistency
      const [raised] = await dao.getFundraiserProgress(1);
      expect(raised).to.equal(donationAmount);

      const updateCount = await dao.getUpdateCount();
      expect(updateCount).to.equal(2); // 1 initial + 1 manual

      const [, galleryTotal] = await dao.getFundraiserGallery(1, 0, 10);
      expect(galleryTotal).to.equal(1);
    });

    it("should handle batch operations correctly", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      // Create multiple fundraisers for batch testing
      for (let i = 0; i < 3; i++) {
        const creationData = {
          title: `Batch Test ${i + 1}`,
          description: `Batch test fundraiser ${i + 1}`,
          endDate: currentTime + 7200,
          fundraiserType: 0,
          token: await mockToken.getAddress(),
          goalAmount: ethers.parseUnits("500", 6),
          initialImages: [],
          initialVideos: [],
          metadataHash: "",
          location: `Batch City ${i + 1}`
        };
        await dao.createFundraiser(creationData);
      }

      // Batch update statuses
      await dao.batchUpdateStatuses([1, 2, 3]);

      // Verify all are still active
      for (let i = 1; i <= 3; i++) {
        const [, , , , , status] = await dao.getFundraiserDetails(i);
        expect(status).to.equal(0); // ACTIVE
      }
    });
  });
});

// ==============================
// UTILITY FUNCTIONS
// ==============================

describe("🧹 Utility Functions", function () {
  it("should provide correct authorization checks", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Auth Check Test",
      description: "Testing auth checks",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Auth City"
    };
    await dao.createFundraiser(creationData);

    // Initial state
    expect(await dao.canPropose(owner.address)).to.be.true;
    expect(await dao.canPropose(user1.address)).to.be.false;
    expect(await dao.canUpdate(1, owner.address)).to.be.true;
    expect(await dao.canUpdate(1, user1.address)).to.be.false;

    // After authorization
    await dao.authorizeProposer(user1.address);
    await dao.authorizeUpdater(1, user1.address);

    expect(await dao.canPropose(user1.address)).to.be.true;
    expect(await dao.canUpdate(1, user1.address)).to.be.true;
  });

  it("should get donation information correctly", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Donation Info Test",
      description: "Testing donation info",
      endDate: currentTime + 7200,
      fundraiserType: 0,
      token: await mockToken.getAddress(),
      goalAmount: ethers.parseUnits("1000", 6),
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Donation City"
    };
    await dao.createFundraiser(creationData);

    const donationAmount = ethers.parseUnits("250", 6);
    await mockToken.connect(user1).approve(await dao.getAddress(), donationAmount);
    await dao.connect(user1).donate(1, donationAmount);

    expect(await dao.donationOf(1, user1.address)).to.equal(donationAmount);
    expect(await dao.donationOf(1, user2.address)).to.equal(0);
    expect(await dao.donationOf(999, user1.address)).to.equal(0);
  });

  it("should handle legacy fundraiser getter", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    const creationData = {
      title: "Legacy Test",
      description: "Testing legacy compatibility",
      endDate: currentTime + 7200,
      fundraiserType: 1, // WITHOUT_GOAL
      token: await mockToken.getAddress(),
      goalAmount: 0,
      initialImages: [],
      initialVideos: [],
      metadataHash: "",
      location: "Legacy City"
    };
    await dao.createFundraiser(creationData);

    const [id, creator, token, goalAmount, raisedAmount, endDate, withdrawn, isFlexible, refundDeadline, closureInitiated] = await dao.getFundraiser(1);
    
    expect(id).to.equal(1);
    expect(creator).to.equal(owner.address);
    expect(token).to.equal(await mockToken.getAddress());
    expect(goalAmount).to.equal(0);
    expect(raisedAmount).to.equal(0);
    expect(withdrawn).to.be.false;
    expect(isFlexible).to.be.true; // WITHOUT_GOAL type
    expect(closureInitiated).to.be.false;
  });

  it("should handle contract receive function", async function () {
    const tx = await owner.sendTransaction({
      to: await dao.getAddress(),
      value: ethers.parseEther("1")
    });
    await tx.wait();

    const balance = await ethers.provider.getBalance(await dao.getAddress());
    expect(balance).to.equal(ethers.parseEther("1"));
  });

  it("should handle batch status updates", async function () {
    const currentTime = Math.floor(Date.now() / 1000);
    
    // Create multiple fundraisers
    for (let i = 0; i < 3; i++) {
      const creationData = {
        title: `Status Update Test ${i + 1}`,
        description: `Testing status updates ${i + 1}`,
        endDate: currentTime + 7200,
        fundraiserType: 0,
        token: await mockToken.getAddress(),
        goalAmount: ethers.parseUnits("1000", 6),
        initialImages: [],
        initialVideos: [],
        metadataHash: "",
        location: `Status City ${i + 1}`
      };
      await dao.createFundraiser(creationData);
    }

    // Batch update should work without errors
    await dao.batchUpdateStatuses([1, 2, 3]);
    
    // All should still be active
    for (let i = 1; i <= 3; i++) {
      const [, , , , , status] = await dao.getFundraiserDetails(i);
      expect(status).to.equal(0); // ACTIVE
    }
  });
});