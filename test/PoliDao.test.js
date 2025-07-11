const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

let dao, mockToken, owner, user1, user2, user3, user4;

beforeEach(async () => {
  [owner, user1, user2, user3, user4] = await ethers.getSigners();

  const MockToken = await ethers.getContractFactory("MockToken");
  mockToken = await MockToken.deploy("USDC Test", "USDC", 18, ethers.parseUnits("1000000", 18), owner.address);
  await mockToken.waitForDeployment();

  const PoliDAO = await ethers.getContractFactory("PoliDAO");
  dao = await PoliDAO.deploy(owner.address, user3.address);
  await dao.waitForDeployment();

  await dao.whitelistToken(await mockToken.getAddress());

  const mintAmount = ethers.parseUnits("5000", 18);
  await mockToken.connect(owner).transfer(user1.address, mintAmount);
  await mockToken.connect(owner).transfer(user2.address, mintAmount);
  await mockToken.connect(owner).transfer(user3.address, mintAmount);
  await mockToken.connect(owner).transfer(user4.address, mintAmount);
});

// ==============================
// AUTHORIZATION-ONLY ACCESS CONTROL
// ==============================

describe("🔐 Authorization-Only Access Control", function () {
  describe("Default Authorization Model", function () {
    it("should allow owner to create proposals", async function () {
      await dao.createProposal("Owner proposal", 3600);
      
      const count = await dao.getProposalCount();
      expect(count).to.equal(1);
      
      const [id, question, yesVotes, noVotes] = await dao.getProposal(1);
      expect(id).to.equal(1);
      expect(question).to.equal("Owner proposal");
      expect(yesVotes).to.equal(0);
      expect(noVotes).to.equal(0);
      
      const creator = await dao.getProposalCreator(1);
      expect(creator).to.equal(owner.address);
    });

    it("should prevent unauthorized users from creating proposals", async function () {
      await expect(dao.connect(user1).createProposal("User proposal", 3600))
        .to.be.revertedWithCustomError(dao, "NotAuthorized");
      
      await expect(dao.connect(user2).createProposal("Another user proposal", 3600))
        .to.be.revertedWithCustomError(dao, "NotAuthorized");
    });

    it("should show correct canPropose status", async function () {
      expect(await dao.canPropose(owner.address)).to.be.true;
      expect(await dao.canPropose(user1.address)).to.be.false;
      expect(await dao.canPropose(user2.address)).to.be.false;
    });
  });

  describe("Authorization Management", function () {
    it("should allow owner to authorize specific proposers", async function () {
      await dao.authorizeProposer(user1.address);
      
      expect(await dao.authorizedProposers(user1.address)).to.be.true;
      expect(await dao.canPropose(user1.address)).to.be.true;
    });

    it("should prevent non-owner from authorizing proposers", async function () {
      await expect(dao.connect(user1).authorizeProposer(user2.address))
        .to.be.reverted;
    });

    it("should allow authorized user to create proposals", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.connect(user1).createProposal("Authorized user proposal", 3600);
      
      const count = await dao.getProposalCount();
      expect(count).to.equal(1);
      
      const creator = await dao.getProposalCreator(1);
      expect(creator).to.equal(user1.address);
    });

    it("should allow owner to revoke authorization", async function () {
      await dao.authorizeProposer(user1.address);
      expect(await dao.canPropose(user1.address)).to.be.true;
      
      await dao.revokeProposer(user1.address);
      expect(await dao.authorizedProposers(user1.address)).to.be.false;
      expect(await dao.canPropose(user1.address)).to.be.false;
    });

    it("should prevent revoked user from creating proposals", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.revokeProposer(user1.address);
      
      await expect(dao.connect(user1).createProposal("Revoked user proposal", 3600))
        .to.be.revertedWithCustomError(dao, "NotAuthorized");
    });

    it("should prevent authorization of zero address", async function () {
      await expect(dao.authorizeProposer(ethers.ZeroAddress))
        .to.be.revertedWithCustomError(dao, "InvalidRecipient");
    });

    it("should emit events for authorization and revocation", async function () {
      await expect(dao.authorizeProposer(user1.address))
        .to.emit(dao, "ProposerAuthorized")
        .withArgs(user1.address);
      
      await expect(dao.revokeProposer(user1.address))
        .to.emit(dao, "ProposerRevoked")
        .withArgs(user1.address);
    });
  });

  describe("Proposal Creation Events", function () {
    it("should emit ProposalCreated with creator address for owner", async function () {
      const tx = await dao.createProposal("Test proposal", 3600);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const expectedEndTime = block.timestamp + 3600;
      
      await expect(tx)
        .to.emit(dao, "ProposalCreated")
        .withArgs(1, "Test proposal", expectedEndTime, owner.address);
    });

    it("should emit ProposalCreated for authorized user", async function () {
      await dao.authorizeProposer(user1.address);
      
      const tx = await dao.connect(user1).createProposal("Authorized proposal", 3600);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const expectedEndTime = block.timestamp + 3600;
      
      await expect(tx)
        .to.emit(dao, "ProposalCreated")
        .withArgs(1, "Authorized proposal", expectedEndTime, user1.address);
    });
  });

  describe("Multiple Authorized Proposers", function () {
    it("should handle multiple authorized proposers", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.authorizeProposer(user2.address);
      
      await dao.createProposal("Owner proposal", 3600);
      await dao.connect(user1).createProposal("User1 proposal", 3600);
      await dao.connect(user2).createProposal("User2 proposal", 3600);
      
      const count = await dao.getProposalCount();
      expect(count).to.equal(3);
      
      expect(await dao.getProposalCreator(1)).to.equal(owner.address);
      expect(await dao.getProposalCreator(2)).to.equal(user1.address);
      expect(await dao.getProposalCreator(3)).to.equal(user2.address);
    });

    it("should maintain individual authorization states", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.authorizeProposer(user2.address);
      
      await dao.revokeProposer(user1.address);
      
      expect(await dao.canPropose(user1.address)).to.be.false;
      expect(await dao.canPropose(user2.address)).to.be.true;
      
      await expect(dao.connect(user1).createProposal("Should fail", 3600))
        .to.be.revertedWithCustomError(dao, "NotAuthorized");
      
      await dao.connect(user2).createProposal("Should succeed", 3600);
      expect(await dao.getProposalCount()).to.equal(1);
    });
  });

  describe("Proposal Summary with Creator", function () {
    it("should include creator in proposal summary", async function () {
      await dao.authorizeProposer(user1.address);
      await dao.connect(user1).createProposal("Summary test", 3600);
      
      const summary = await dao.getProposalSummary(1);
      expect(summary.id).to.equal(1);
      expect(summary.question).to.equal("Summary test");
      expect(summary.creator).to.equal(user1.address);
      expect(summary.yesVotes).to.equal(0);
      expect(summary.noVotes).to.equal(0);
    });
  });
});

// ==============================
// CORE VOTING FUNCTIONALITY
// ==============================

describe("🗳️ Voting System", function () {
  it("should allow creating and voting on a proposal", async function () {
    await dao.createProposal("Abolish tax?", 3600);
    await dao.connect(user1).vote(1, true);

    const count = await dao.getProposalCount();
    expect(count).to.equal(1);

    const [id, question, yesVotes, noVotes] = await dao.getProposal(1);
    expect(id).to.equal(1);
    expect(question).to.equal("Abolish tax?");
    expect(yesVotes).to.equal(1);
    expect(noVotes).to.equal(0);

    const voted = await dao.hasVoted(1, user1.address);
    expect(voted).to.be.true;
  });

  it("should not allow double voting", async function () {
    await dao.createProposal("Tax reform?", 3600);
    await dao.connect(user1).vote(1, true);
    await expect(dao.connect(user1).vote(1, false)).to.be.revertedWith("Already voted");
  });

  it("should return correct proposal count", async function () {
    await dao.createProposal("A", 100);
    await dao.createProposal("B", 100);
    const count = await dao.getProposalCount();
    expect(count).to.equal(2);
  });

  it("should handle voting on proposals created by different users", async function () {
    await dao.authorizeProposer(user1.address);
    await dao.createProposal("Owner proposal", 3600);
    await dao.connect(user1).createProposal("User proposal", 3600);
    
    await dao.connect(user2).vote(1, true);
    await dao.connect(user2).vote(2, false);
    
    const [, , yesVotes1, noVotes1] = await dao.getProposal(1);
    const [, , yesVotes2, noVotes2] = await dao.getProposal(2);
    
    expect(yesVotes1).to.equal(1);
    expect(noVotes1).to.equal(0);
    expect(yesVotes2).to.equal(0);
    expect(noVotes2).to.equal(1);
  });

  it("should handle multiple voters correctly", async function () {
    await dao.createProposal("Multi-user vote", 3600);
    
    await dao.connect(user1).vote(1, true);
    await dao.connect(user2).vote(1, false);
    await dao.connect(user4).vote(1, true);
    
    const [, , yesVotes, noVotes] = await dao.getProposal(1);
    expect(yesVotes).to.equal(2);
    expect(noVotes).to.equal(1);
  });

  it("should handle voting after proposal expiry", async function () {
    await dao.createProposal("Short proposal", 1);
    await ethers.provider.send("evm_increaseTime", [2]);
    await ethers.provider.send("evm_mine");
    
    await expect(dao.connect(user1).vote(1, true)).to.be.revertedWith("Voting ended");
    expect(await dao.timeLeftOnProposal(1)).to.equal(0);
  });
});

// ==============================
// FUNDRAISING FUNCTIONALITY
// ==============================

describe("💰 Fundraising System", function () {
  async function createFundraiser(target = 1000, duration = 3600, flexible = false) {
    await dao.createFundraiser(await mockToken.getAddress(), target, duration, flexible);
  }

  async function donate(user, amount, id = 1) {
    const amountWei = ethers.parseUnits(amount.toString(), 18);
    await mockToken.connect(user).approve(await dao.getAddress(), amountWei);
    await dao.connect(user).donate(id, amountWei);
  }

  it("should allow donations and reflect in getter", async function () {
    await createFundraiser();
    await donate(user1, 1000);

    const [id, creator, token, target, raised, , withdrawn, isFlexible] = await dao.getFundraiser(1);
    expect(id).to.equal(1);
    expect(creator).to.equal(owner.address);
    expect(token).to.equal(await mockToken.getAddress());
    expect(target).to.equal(1000);
    expect(raised).to.equal(ethers.parseUnits("1000", 18));
    expect(withdrawn).to.be.false;
    expect(isFlexible).to.be.false;

    const donation = await dao.donationOf(1, user1.address);
    expect(donation).to.equal(ethers.parseUnits("1000", 18));

    const refunded = await dao.hasRefunded(1, user1.address);
    expect(refunded).to.be.false;
  });

  it("should revert donation after endTime", async function () {
    await createFundraiser(1000, 0);
    await expect(donate(user1, 1000)).to.be.revertedWith("Fundraiser ended");
  });

  it("should allow refund before withdrawal", async function () {
    await createFundraiser(2000, 10);
    await donate(user1, 1000);
    await ethers.provider.send("evm_increaseTime", [11]);
    await ethers.provider.send("evm_mine");
    await dao.initiateClosure(1);
    await ethers.provider.send("evm_increaseTime", [5]);
    await ethers.provider.send("evm_mine");
    await dao.connect(user1).refund(1);
    const balance = await mockToken.balanceOf(user1.address);
    expect(balance).to.equal(ethers.parseUnits("5000", 18));
  });

  it("should allow full withdraw if target met early", async function () {
    await createFundraiser(1000, 3600);
    await donate(user1, 1000);
    
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    await dao.withdraw(1);
    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    
    const expectedIncrease = ethers.parseUnits("1000", 18);
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(expectedIncrease);
  });

  it("should allow flexible withdrawal anytime", async function () {
    await createFundraiser(0, 3600, true);
    await donate(user1, 1000);
    
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    await dao.withdraw(1);
    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    
    const expectedIncrease = ethers.parseUnits("1000", 18);
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(expectedIncrease);
  });

  it("should reject non-creator withdrawal", async function () {
    await createFundraiser(1000, 3600);
    await expect(dao.connect(user1).withdraw(1)).to.be.revertedWith("Not creator");
  });

  it("should revert double withdrawal in targeted fundraiser", async function () {
    await createFundraiser(1000, 3600);
    await donate(user1, 1000);
    await dao.withdraw(1);
    await expect(dao.withdraw(1)).to.be.revertedWith("Already withdrawn");
  });

  it("should initiate closure and set reclaim deadline", async function () {
    await createFundraiser(2000, 3);
    await donate(user1, 1000);
    await ethers.provider.send("evm_increaseTime", [5]);
    await ethers.provider.send("evm_mine");
    await dao.initiateClosure(1);
    const [, , , , , endTime, , , reclaimDeadline, closureInitiated] = await dao.getFundraiser(1);
    expect(closureInitiated).to.be.true;
    expect(reclaimDeadline).to.be.gt(endTime);
  });

  it("should handle multiple donors", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 3000, 3600, false);
    
    const amount1 = ethers.parseUnits("1000", 18);
    const amount2 = ethers.parseUnits("800", 18);
    const amount3 = ethers.parseUnits("1200", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount1);
    await dao.connect(user1).donate(1, amount1);
    
    await mockToken.connect(user2).approve(await dao.getAddress(), amount2);
    await dao.connect(user2).donate(1, amount2);
    
    await mockToken.connect(user4).approve(await dao.getAddress(), amount3);
    await dao.connect(user4).donate(1, amount3);
    
    const [, , , , raised] = await dao.getFundraiser(1);
    expect(raised).to.equal(amount1 + amount2 + amount3);
    
    const donors = await dao.getDonors(1);
    expect(donors).to.have.lengthOf(3);
  });
});

// ==============================
// MULTIMEDIA FUNCTIONALITY
// ==============================

describe("🎬 Multimedia Management", function () {
  beforeEach(async () => {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
  });

  describe("Core Multimedia Features", function () {
    it("should allow creator to add multimedia and activate flag", async function () {
      const mediaItems = [
        {
          ipfsHash: "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG",
          mediaType: 0,
          filename: "project-image.jpg",
          fileSize: 1024000,
          uploadTime: 0,
          uploader: ethers.ZeroAddress,
          description: "Main project image"
        }
      ];

      await expect(dao.addMultimediaToFundraiser(1, mediaItems))
        .to.emit(dao, "MediaAdded")
        .withArgs(1, mediaItems[0].ipfsHash, 0, "project-image.jpg", owner.address)
        .and.to.emit(dao, "MultimediaActivated")
        .withArgs(1);

      expect(await dao.hasMultimedia(1)).to.be.true;
    });

    it("should enforce media type limits correctly", async function () {
      const tooManyVideos = Array(31).fill().map((_, i) => ({
        ipfsHash: `QmVideo${i.toString().padStart(3, '0')}`,
        mediaType: 1,
        filename: `video${i}.mp4`,
        fileSize: 5024000,
        uploadTime: 0,
        uploader: ethers.ZeroAddress,
        description: `Video ${i}`
      }));

      await expect(dao.addMultimediaToFundraiser(1, tooManyVideos))
        .to.be.revertedWithCustomError(dao, "MediaLimitExceeded");
    });

    it("should track media statistics accurately", async function () {
      const mixedMedia = [
        { ipfsHash: "QmImage1", mediaType: 0, filename: "img1.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Image 1" },
        { ipfsHash: "QmImage2", mediaType: 0, filename: "img2.jpg", fileSize: 2048, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Image 2" },
        { ipfsHash: "QmVideo1", mediaType: 1, filename: "vid1.mp4", fileSize: 5024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Video 1" },
        { ipfsHash: "QmAudio1", mediaType: 2, filename: "aud1.mp3", fileSize: 3024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Audio 1" },
        { ipfsHash: "QmDoc1", mediaType: 3, filename: "doc1.pdf", fileSize: 4024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Document 1" }
      ];

      await dao.addMultimediaToFundraiser(1, mixedMedia);

      const [images, videos, audio, documents, total] = await dao.getMediaStatistics(1);
      expect(images).to.equal(2);
      expect(videos).to.equal(1);
      expect(audio).to.equal(1);
      expect(documents).to.equal(1);
      expect(total).to.equal(5);
    });

    it("should handle media removal with proper counter updates", async function () {
      const mediaItems = [
        { ipfsHash: "QmImage1", mediaType: 0, filename: "img1.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Image 1" },
        { ipfsHash: "QmVideo1", mediaType: 1, filename: "vid1.mp4", fileSize: 5024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Video 1" }
      ];
      await dao.addMultimediaToFundraiser(1, mediaItems);

      await expect(dao.removeMediaFromFundraiser(1, 0))
        .to.emit(dao, "MediaRemoved")
        .withArgs(1, 0, "QmImage1");

      const [images, videos, , , total] = await dao.getMediaStatistics(1);
      expect(images).to.equal(0);
      expect(videos).to.equal(1);
      expect(total).to.equal(1);
    });
  });

  describe("Authorization System", function () {
    it("should manage media manager authorization correctly", async function () {
      await expect(dao.authorizeMediaManager(1, user1.address))
        .to.emit(dao, "MediaManagerAuthorized")
        .withArgs(1, user1.address);

      expect(await dao.canManageMedia(1, user1.address)).to.be.true;

      const mediaItems = [{ ipfsHash: "QmManagerTest", mediaType: 0, filename: "manager.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Manager test" }];
      await dao.connect(user1).addMultimediaToFundraiser(1, mediaItems);

      await expect(dao.revokeMediaManager(1, user1.address))
        .to.emit(dao, "MediaManagerRevoked")
        .withArgs(1, user1.address);

      expect(await dao.canManageMedia(1, user1.address)).to.be.false;
    });

    it("should prevent unauthorized media operations", async function () {
      const mediaItems = [{ ipfsHash: "QmUnauth", mediaType: 0, filename: "unauth.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Unauthorized" }];
      
      await expect(dao.connect(user1).addMultimediaToFundraiser(1, mediaItems))
        .to.be.revertedWithCustomError(dao, "NotFundraiserCreator");
    });
  });

  describe("Input Validation", function () {
    it("should validate IPFS hash requirements", async function () {
      const invalidMedia = [{ ipfsHash: "", mediaType: 0, filename: "empty.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Empty hash" }];
      
      await expect(dao.addMultimediaToFundraiser(1, invalidMedia))
        .to.be.revertedWithCustomError(dao, "InvalidIPFSHash");
    });

    it("should reject invalid media types", async function () {
      const invalidMedia = [{ ipfsHash: "QmValid", mediaType: 5, filename: "invalid.xyz", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Invalid type" }];
      
      await expect(dao.addMultimediaToFundraiser(1, invalidMedia))
        .to.be.revertedWithCustomError(dao, "InvalidMediaType");
    });

    it("should enforce batch size limits", async function () {
      const tooBigBatch = Array(21).fill().map((_, i) => ({
        ipfsHash: `QmBatch${i}`, mediaType: 0, filename: `file${i}.jpg`, fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: `File ${i}`
      }));

      await expect(dao.addMultimediaToFundraiser(1, tooBigBatch))
        .to.be.revertedWithCustomError(dao, "MediaLimitExceeded");
    });
  });
});

// ==============================
// UPDATE SYSTEM WITH MULTIMEDIA
// ==============================

describe("📝 Enhanced Update System", function () {
  beforeEach(async () => {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
  });

  describe("Multimedia Updates", function () {
    it("should create updates with multimedia attachments", async function () {
      const attachments = [
        { ipfsHash: "QmUpdateImg", mediaType: 0, filename: "update.jpg", fileSize: 2048, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Update image" }
      ];

      await expect(dao.postUpdateWithMultimedia(1, "Progress update with image", 1, attachments))
        .to.emit(dao, "UpdatePosted")
        .withArgs(1, 1, owner.address, "Progress update with image", 1);

      const update = await dao.getUpdateWithAttachments(1);
      expect(update.content).to.equal("Progress update with image");
      expect(update.updateType).to.equal(1);
      expect(update.attachments).to.have.lengthOf(1);
      expect(update.attachments[0].ipfsHash).to.equal("QmUpdateImg");
    });

    it("should handle update pinning system", async function () {
      await dao.postUpdate(1, "First update");
      await dao.postUpdate(1, "Second update");

      await expect(dao.pinUpdate(2))
        .to.emit(dao, "UpdatePinned")
        .withArgs(2, 1);

      const summary = await dao.getFundraiserSummary(1);
      expect(summary.pinnedUpdateId).to.equal(2);

      await expect(dao.pinUpdate(1))
        .to.emit(dao, "UpdateUnpinned")
        .withArgs(1, 2)
        .and.to.emit(dao, "UpdatePinned")
        .withArgs(1, 1);
    });

    it("should manage update authorization properly", async function () {
      await expect(dao.authorizeUpdater(1, user1.address))
        .to.emit(dao, "UpdaterAuthorized")
        .withArgs(1, user1.address);

      await dao.connect(user1).postUpdate(1, "Authorized update");
      expect(await dao.getUpdateCount()).to.equal(1);

      await dao.revokeUpdater(1, user1.address);
      await expect(dao.connect(user1).postUpdate(1, "Should fail"))
        .to.be.revertedWithCustomError(dao, "NotFundraiserCreator");
    });
  });
});

// ==============================
// STANDARD COMMISSION SYSTEM (NO MULTIMEDIA BONUS)
// ==============================

describe("💼 Standard Commission Management", function () {
  it("should set donation commission", async function () {
    await dao.setDonationCommission(700);
    const commission = await dao.donationCommission();
    expect(commission).to.equal(700);
  });

  it("should set success commission", async function () {
    await dao.setSuccessCommission(300);
    const commission = await dao.successCommission();
    expect(commission).to.equal(300);
  });

  it("should apply donation commission correctly (without multimedia bonus)", async function () {
    await dao.setDonationCommission(1000); // 10%
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    // Add multimedia to verify it doesn't affect commission
    const mediaItems = [{ ipfsHash: "QmTest", mediaType: 0, filename: "test.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Test" }];
    await dao.addMultimediaToFundraiser(1, mediaItems);
    
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const [, , , , raised] = await dao.getFundraiser(1);
    // Should apply only 10% commission, no multimedia bonus
    expect(raised).to.equal(ethers.parseUnits("900", 18));
  });

  it("should apply success commission correctly on withdraw (without multimedia bonus)", async function () {
    await dao.connect(owner).setSuccessCommission(1000); // 10%
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    // Add multimedia to verify it doesn't affect commission
    const mediaItems = [{ ipfsHash: "QmTest", mediaType: 1, filename: "test.mp4", fileSize: 5024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Test" }];
    await dao.addMultimediaToFundraiser(1, mediaItems);
    
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    const commissionBalanceBefore = await mockToken.balanceOf(user3.address);
    
    await dao.withdraw(1);
    
    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    const commissionBalanceAfter = await mockToken.balanceOf(user3.address);
    
    // Should apply only 10% commission, no multimedia bonus
    const expectedCommission = ethers.parseUnits("100", 18); // 10% of 1000
    const expectedOwnerIncrease = ethers.parseUnits("900", 18); // 1000 - 100
    
    expect(commissionBalanceAfter - commissionBalanceBefore).to.equal(expectedCommission);
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(expectedOwnerIncrease);
  });

  it("should handle zero commission", async function () {
    await dao.setDonationCommission(0);
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    const amount = ethers.parseUnits("1000", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const [, , , , raised] = await dao.getFundraiser(1);
    expect(raised).to.equal(amount); // No commission deducted
  });

  it("should handle maximum commission", async function () {
    await dao.setDonationCommission(10000); // 100%
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    const amount = ethers.parseUnits("1000", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const [, , , , raised] = await dao.getFundraiser(1);
    expect(raised).to.equal(0); // All went to commission
  });

  it("should emit commission events", async function () {
    await expect(dao.setDonationCommission(250))
      .to.emit(dao, "DonationCommissionSet")
      .withArgs(250);
    
    await expect(dao.setSuccessCommission(500))
      .to.emit(dao, "SuccessCommissionSet")
      .withArgs(500);
    
    await expect(dao.setRefundCommission(150))
      .to.emit(dao, "RefundCommissionSet")
      .withArgs(150);
  });
});

describe("🔄 Refund Commission", function () {
  const donatedAmount = ethers.parseUnits("1000", 18);

  it("should allow owner to set refund commission", async function () {
    await dao.setRefundCommission(500); // 5%
    expect(await dao.refundCommission()).to.equal(500);
  });

  it("should not charge commission on first refund but charge on second refund in same month", async function () {
    await dao.setRefundCommission(1000);

    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    const fa1 = 1;
    await mockToken.connect(user1).approve(await dao.getAddress(), donatedAmount);
    await dao.connect(user1).donate(fa1, donatedAmount);

    const beforeUser1_1 = await mockToken.balanceOf(user1.address);
    const beforeComm_1 = await mockToken.balanceOf(user3.address);

    await dao.connect(user1).refund(fa1);

    const afterUser1_1 = await mockToken.balanceOf(user1.address);
    const afterComm_1 = await mockToken.balanceOf(user3.address);

    expect(afterUser1_1 - beforeUser1_1).to.equal(donatedAmount);
    expect(afterComm_1 - beforeComm_1).to.equal(0n);

    const block1 = await ethers.provider.getBlock();
    const period = Math.floor(block1.timestamp / (30 * 24 * 3600));

    expect(await dao.monthlyRefundCount(user1.address, period)).to.equal(1);

    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    const fa2 = 2;
    await mockToken.connect(user1).approve(await dao.getAddress(), donatedAmount);
    await dao.connect(user1).donate(fa2, donatedAmount);

    const beforeUser1_2 = await mockToken.balanceOf(user1.address);
    const beforeComm_2 = await mockToken.balanceOf(user3.address);

    await dao.connect(user1).refund(fa2);

    const afterUser1_2 = await mockToken.balanceOf(user1.address);
    const afterComm_2 = await mockToken.balanceOf(user3.address);

    const expectedCommission = (donatedAmount * 1000n) / 10000n;
    const expectedRefund = donatedAmount - expectedCommission;

    expect(afterUser1_2 - beforeUser1_2).to.equal(expectedRefund);
    expect(afterComm_2 - beforeComm_2).to.equal(expectedCommission);

    expect(await dao.monthlyRefundCount(user1.address, period)).to.equal(2);
  });

  it("should handle refund commission for multiple refunds in same month", async function () {
    await dao.setRefundCommission(1000); // 10%
    
    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    
    const amount = ethers.parseUnits("1000", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(2, amount);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(3, amount);
    
    const balanceBeforeRefunds = await mockToken.balanceOf(user1.address);
    const commissionBalanceBefore = await mockToken.balanceOf(user3.address);
    
    await dao.connect(user1).refund(1); // First refund - no commission
    await dao.connect(user1).refund(2); // Second refund - 10% commission
    await dao.connect(user1).refund(3); // Third refund - 10% commission
    
    const balanceAfterRefunds = await mockToken.balanceOf(user1.address);
    const commissionBalanceAfter = await mockToken.balanceOf(user3.address);
    
    const expectedUserIncrease = amount + (amount * 90n / 100n) + (amount * 90n / 100n);
    const expectedCommissionIncrease = (amount * 10n / 100n) + (amount * 10n / 100n);
    
    expect(balanceAfterRefunds - balanceBeforeRefunds).to.equal(expectedUserIncrease);
    expect(commissionBalanceAfter - commissionBalanceBefore).to.equal(expectedCommissionIncrease);
  });
});

// ==============================
// ACCESS CONTROL & SECURITY
// ==============================

describe("🔒 Access Control & Security", function () {
  it("should only allow owner to pause", async function () {
    await expect(dao.connect(user1).pause()).to.be.reverted;
    await dao.pause();
    expect(await dao.paused()).to.be.true;
  });

  it("should only allow owner to set commissions", async function () {
    await expect(dao.connect(user1).setDonationCommission(500)).to.be.reverted;
    await expect(dao.connect(user1).setSuccessCommission(500)).to.be.reverted;
    await expect(dao.connect(user1).setRefundCommission(500)).to.be.reverted;
  });

  it("should reject commission above 100%", async function () {
    await expect(dao.setDonationCommission(10001)).to.be.revertedWith("Max 100%");
    await expect(dao.setSuccessCommission(10001)).to.be.revertedWith("Max 100%");
    await expect(dao.setRefundCommission(10001)).to.be.revertedWith("Max 100%");
  });

  it("should only allow owner to pause voting", async function () {
    await expect(dao.connect(user1).toggleVotingPause()).to.be.reverted;
    
    await dao.toggleVotingPause();
    expect(await dao.votingPaused()).to.be.true;
    
    await expect(dao.createProposal("Test", 3600)).to.be.revertedWith("Voting paused");
  });

  it("should only allow owner to pause donations", async function () {
    await expect(dao.connect(user1).toggleDonationsPause()).to.be.reverted;
    
    await dao.toggleDonationsPause();
    expect(await dao.donationsPaused()).to.be.true;
  });

  it("should only allow owner to pause withdrawals", async function () {
    await expect(dao.connect(user1).toggleWithdrawalsPause()).to.be.reverted;
    
    await dao.toggleWithdrawalsPause();
    expect(await dao.withdrawalsPaused()).to.be.true;
  });

  it("should prevent operations when paused", async function () {
    await dao.pause();
    
    await expect(dao.createProposal("Test", 3600)).to.be.reverted;
    await expect(dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false)).to.be.reverted;
  });

  it("should prevent voting when voting paused", async function () {
    await dao.createProposal("Test", 3600);
    await dao.toggleVotingPause();
    
    await expect(dao.connect(user1).vote(1, true)).to.be.revertedWith("Voting paused");
  });

  it("should prevent donations when donations paused", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    await dao.toggleDonationsPause();
    
    const amount = ethers.parseUnits("100", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await expect(dao.connect(user1).donate(1, amount)).to.be.revertedWith("Donations paused");
  });

  it("should prevent withdrawals when withdrawals paused", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await dao.toggleWithdrawalsPause();
    await expect(dao.withdraw(1)).to.be.revertedWith("Withdrawals paused");
  });

  it("should handle zero amounts", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    await expect(dao.connect(user1).donate(1, 0)).to.be.revertedWith("Zero amount");
  });

  it("should handle insufficient balance", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const hugeAmount = ethers.parseUnits("10000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), hugeAmount);
    await expect(dao.connect(user1).donate(1, hugeAmount)).to.be.reverted;
  });

  it("should prevent proposal creation with empty question", async function () {
    await expect(dao.createProposal("", 3600))
      .to.be.revertedWithCustomError(dao, "EmptyQuestion");
  });

  it("should prevent proposal creation with too long question", async function () {
    const longQuestion = "a".repeat(501);
    await expect(dao.createProposal(longQuestion, 3600))
      .to.be.revertedWithCustomError(dao, "QuestionTooLong");
  });

  it("should prevent proposal creation with invalid duration", async function () {
    const maxDuration = 365 * 24 * 3600;
    await expect(dao.createProposal("Test", maxDuration + 1))
      .to.be.revertedWithCustomError(dao, "InvalidDuration");
  });

  it("should handle multimedia pause functionality", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    await expect(dao.toggleMediaPause())
      .to.emit(dao, "MediaPauseToggled")
      .withArgs(true);

    const mediaItems = [{ ipfsHash: "QmTest", mediaType: 0, filename: "test.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Test" }];
    await expect(dao.addMultimediaToFundraiser(1, mediaItems))
      .to.be.revertedWith("Media operations paused");
  });
});

// ==============================
// TOKEN WHITELIST MANAGEMENT
// ==============================

describe("🪙 Token Whitelist Management", function () {
  let mockToken2;

  beforeEach(async () => {
    const MockToken = await ethers.getContractFactory("MockToken");
    mockToken2 = await MockToken.deploy("DAI Test", "DAI", 18, ethers.parseUnits("100000", 18), owner.address);
    await mockToken2.waitForDeployment();
  });

  it("should prevent adding invalid tokens", async function () {
    await expect(dao.whitelistToken(ethers.ZeroAddress)).to.be.reverted;
    await expect(dao.whitelistToken(user1.address)).to.be.reverted;
  });

  it("should prevent double whitelisting", async function () {
    await expect(dao.whitelistToken(await mockToken.getAddress())).to.be.revertedWith("Already whitelisted");
  });

  it("should add and remove tokens correctly", async function () {
    await dao.whitelistToken(await mockToken2.getAddress());
    
    let tokens = await dao.getWhitelistedTokens();
    expect(tokens).to.include(await mockToken2.getAddress());
    
    await dao.removeWhitelistToken(await mockToken2.getAddress());
    tokens = await dao.getWhitelistedTokens();
    expect(tokens).to.not.include(await mockToken2.getAddress());
  });

  it("should prevent fundraisers with non-whitelisted tokens", async function () {
    await expect(dao.createFundraiser(await mockToken2.getAddress(), 1000, 3600, false))
      .to.be.revertedWith("Token not allowed");
  });

  it("should emit events for token management", async function () {
    await expect(dao.whitelistToken(await mockToken2.getAddress()))
      .to.emit(dao, "TokenWhitelisted")
      .withArgs(await mockToken2.getAddress());
    
    await expect(dao.removeWhitelistToken(await mockToken2.getAddress()))
      .to.emit(dao, "TokenRemoved")
      .withArgs(await mockToken2.getAddress());
  });
});

// ==============================
// CIRCUIT BREAKER & LIMITS
// ==============================

describe("🔄 Circuit Breaker & Daily Limits", function () {
  it("should allow setting daily donation limit", async function () {
    const newLimit = ethers.parseUnits("500000", 18);
    await dao.setMaxDailyDonations(newLimit);
    expect(await dao.maxDailyDonations()).to.equal(newLimit);
  });

  it("should prevent non-owner from setting daily limit", async function () {
    const newLimit = ethers.parseUnits("500000", 18);
    await expect(dao.connect(user1).setMaxDailyDonations(newLimit)).to.be.reverted;
  });

  it("should track daily donation count for large donations", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 10000, 3600, false);
    
    const amount = ethers.parseUnits("200000", 18);
    await mockToken.connect(owner).transfer(user1.address, amount);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const today = Math.floor(Date.now() / 1000 / 86400);
    const dailyCount = await dao.getDailyDonationCount(today);
    expect(dailyCount).to.equal(amount);
  });

  it("should get today's donation count", async function () {
    const todayCount = await dao.getTodayDonationCount();
    expect(todayCount).to.be.a('bigint');
  });

  it("should emit event when setting daily limit", async function () {
    const newLimit = ethers.parseUnits("2000000", 18);
    await expect(dao.setMaxDailyDonations(newLimit))
      .to.emit(dao, "MaxDailyDonationsSet")
      .withArgs(newLimit);
  });
});

// ==============================
// REFUND EDGE CASES
// ==============================

describe("🔄 Refund Edge Cases", function () {
  it("should prevent refund for user who never donated", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 10, false);
    
    await ethers.provider.send("evm_increaseTime", [11]);
    await ethers.provider.send("evm_mine");
    await dao.initiateClosure(1);
    
    await expect(dao.connect(user2).refund(1)).to.be.revertedWith("No donation found");
  });

  it("should prevent double refund", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 2000, 10, false);
    const amount = ethers.parseUnits("1000", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await ethers.provider.send("evm_increaseTime", [11]);
    await ethers.provider.send("evm_mine");
    await dao.initiateClosure(1);
    
    await dao.connect(user1).refund(1);
    await expect(dao.connect(user1).refund(1)).to.be.revertedWith("Already refunded");
  });

  it("should prevent refund from flexible fundraiser before conditions are met", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    const amount = ethers.parseUnits("500", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await expect(dao.connect(user1).refund(1)).to.be.revertedWith("Fundraiser still active");
  });
});

// ==============================
// VIEW FUNCTIONS & GETTERS
// ==============================

describe("🔍 View Functions & Data Retrieval", function () {
  it("should return correct proposal IDs", async function () {
    await dao.createProposal("Prop 1", 3600);
    await dao.createProposal("Prop 2", 3600);
    
    const ids = await dao.getAllProposalIds();
    expect(ids).to.have.lengthOf(2);
    expect(ids[0]).to.equal(1);
    expect(ids[1]).to.equal(2);
  });

  it("should return correct fundraiser IDs", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    await dao.createFundraiser(await mockToken.getAddress(), 2000, 3600, true);
    
    const ids = await dao.getAllFundraiserIds();
    expect(ids).to.have.lengthOf(2);
    expect(ids[0]).to.equal(1);
    expect(ids[1]).to.equal(2);
  });

  it("should handle non-existent queries gracefully", async function () {
    await expect(dao.getProposal(999)).to.be.revertedWith("Invalid proposal");
    await expect(dao.getFundraiser(999)).to.be.revertedWith("Invalid fundraiser");
    await expect(dao.getProposalCreator(999)).to.be.revertedWith("Invalid proposal");
    expect(await dao.timeLeftOnProposal(999)).to.equal(0);
    expect(await dao.timeLeftOnFundraiser(999)).to.equal(0);
  });

  it("should return correct proposal summary with creator", async function () {
    await dao.authorizeProposer(user1.address);
    await dao.createProposal("Owner prop", 3600);
    await dao.connect(user1).createProposal("User prop", 3600);
    
    const summary1 = await dao.getProposalSummary(1);
    const summary2 = await dao.getProposalSummary(2);
    
    expect(summary1.creator).to.equal(owner.address);
    expect(summary1.question).to.equal("Owner prop");
    
    expect(summary2.creator).to.equal(user1.address);
    expect(summary2.question).to.equal("User prop");
  });

  it("should return enhanced fundraiser summary with multimedia data", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const mediaItems = [{ ipfsHash: "QmTest", mediaType: 0, filename: "test.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Test" }];
    await dao.addMultimediaToFundraiser(1, mediaItems);
    await dao.postUpdate(1, "Test update");
    
    const summary = await dao.getFundraiserSummary(1);
    expect(summary.mediaCount).to.equal(1);
    expect(summary.updateCount).to.equal(1);
    expect(summary.pinnedUpdateId).to.equal(0);
  });

  it("should handle zero ID queries", async function () {
    await expect(dao.getProposal(0)).to.be.revertedWith("Invalid proposal");
    await expect(dao.getFundraiser(0)).to.be.revertedWith("Invalid fundraiser");
    expect(await dao.timeLeftOnProposal(0)).to.equal(0);
    expect(await dao.timeLeftOnFundraiser(0)).to.equal(0);
  });

  it("should return correct hasVoted status", async function () {
    await dao.createProposal("Test vote", 3600);
    
    expect(await dao.hasVoted(1, user1.address)).to.be.false;
    expect(await dao.hasVoted(999, user1.address)).to.be.false;
    
    await dao.connect(user1).vote(1, true);
    expect(await dao.hasVoted(1, user1.address)).to.be.true;
  });

  it("should return correct donation amounts", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const amount = ethers.parseUnits("500", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    expect(await dao.donationOf(1, user1.address)).to.equal(amount);
    expect(await dao.donationOf(1, user2.address)).to.equal(0);
    expect(await dao.donationOf(999, user1.address)).to.equal(0);
  });

  it("should return media capacity information", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const [canAdd, reason] = await dao.canAddMedia(1, 0, 5);
    expect(canAdd).to.be.true;
    expect(reason).to.equal("Can add media");

    const [cannotAdd, limitReason] = await dao.canAddMedia(1, 0, 25);
    expect(cannotAdd).to.be.false;
    expect(limitReason).to.equal("Batch size too large (20 max)");
  });

  it("should return correct media type limits", async function () {
    expect(await dao.getMediaTypeLimit(0)).to.equal(100);
    expect(await dao.getMediaTypeLimit(1)).to.equal(30);
    expect(await dao.getMediaTypeLimit(2)).to.equal(20);
    expect(await dao.getMediaTypeLimit(3)).to.equal(50);
  });
});

// ==============================
// INTEGRATION TESTS
// ==============================

describe("🎯 Integration & Lifecycle Tests", function () {
  it("should handle complete fundraising lifecycle", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    const creatorBalanceBefore = await mockToken.balanceOf(owner.address);
    await dao.withdraw(1);
    const creatorBalanceAfter = await mockToken.balanceOf(owner.address);
    
    expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(amount);
    
    const [, , , , raised, , withdrawn] = await dao.getFundraiser(1);
    expect(raised).to.equal(0);
    expect(withdrawn).to.be.true;
  });

  it("should handle failed fundraiser with refunds", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 2000, 10, false);
    
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await ethers.provider.send("evm_increaseTime", [11]);
    await ethers.provider.send("evm_mine");
    
    await dao.initiateClosure(1);
    
    const balanceBefore = await mockToken.balanceOf(user1.address);
    await dao.connect(user1).refund(1);
    const balanceAfter = await mockToken.balanceOf(user1.address);
    
    expect(balanceAfter - balanceBefore).to.equal(amount);
  });

  it("should handle complete governance lifecycle with authorization", async function () {
    await dao.createProposal("Should we authorize more proposers?", 3600);
    
    await dao.connect(user1).vote(1, true);
    await dao.connect(user2).vote(1, true);
    await dao.connect(user3).vote(1, false);
    
    const [, , yesVotes, noVotes] = await dao.getProposal(1);
    expect(yesVotes).to.equal(2);
    expect(noVotes).to.equal(1);
    
    await dao.authorizeProposer(user1.address);
    await dao.connect(user1).createProposal("Implementation details", 3600);
    
    expect(await dao.getProposalCount()).to.equal(2);
    expect(await dao.getProposalCreator(1)).to.equal(owner.address);
    expect(await dao.getProposalCreator(2)).to.equal(user1.address);
  });

  it("should handle mixed fundraiser types and governance", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    await dao.createFundraiser(await mockToken.getAddress(), 0, 3600, true);
    
    await dao.createProposal("Should we increase commission rates?", 3600);
    
    const amount = ethers.parseUnits("500", 18);
    
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    
    await mockToken.connect(user2).approve(await dao.getAddress(), amount);
    await dao.connect(user2).donate(2, amount);
    
    await dao.connect(user1).vote(1, false);
    await dao.connect(user2).vote(1, false);
    
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    await dao.withdraw(2);
    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(amount);
    
    const [, , yesVotes, noVotes] = await dao.getProposal(1);
    expect(yesVotes).to.equal(0);
    expect(noVotes).to.equal(2);
    
    const [, , , , raised1] = await dao.getFundraiser(1);
    const [, , , , raised2] = await dao.getFundraiser(2);
    
    expect(raised1).to.equal(amount);
    expect(raised2).to.equal(0);
  });

  it("should handle authorization changes during active proposals", async function () {
    await dao.authorizeProposer(user1.address);
    await dao.connect(user1).createProposal("User1 proposal", 3600);
    
    await dao.revokeProposer(user1.address);
    
    await expect(dao.connect(user1).createProposal("Should fail", 3600))
      .to.be.revertedWithCustomError(dao, "NotAuthorized");
    
    await dao.connect(user2).vote(1, true);
    
    const [, , yesVotes] = await dao.getProposal(1);
    expect(yesVotes).to.equal(1);
  });

  it("should handle complete multimedia fundraiser lifecycle", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    await dao.setDonationCommission(500); // 5%
    await dao.setSuccessCommission(300);   // 3%
    
    const mediaItems = [
      { ipfsHash: "QmProjectImg", mediaType: 0, filename: "project.jpg", fileSize: 2048, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Main image" },
      { ipfsHash: "QmProjectVid", mediaType: 1, filename: "demo.mp4", fileSize: 10240, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Demo video" }
    ];
    await dao.addMultimediaToFundraiser(1, mediaItems);
    
    await dao.authorizeMediaManager(1, user1.address);
    await dao.authorizeUpdater(1, user2.address);
    
    const additionalMedia = [{ ipfsHash: "QmManagerImg", mediaType: 0, filename: "manager.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Manager added" }];
    await dao.connect(user1).addMultimediaToFundraiser(1, additionalMedia);
    
    const updateAttachments = [{ ipfsHash: "QmUpdateImg", mediaType: 0, filename: "progress.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Progress update" }];
    await dao.connect(user2).postUpdateWithMultimedia(1, "Great progress!", 1, updateAttachments);
    
    await dao.pinUpdate(1);
    
    const donationAmount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user3).approve(await dao.getAddress(), donationAmount);
    await dao.connect(user3).donate(1, donationAmount);
    
    // Verify standard commission was applied (5% - no multimedia bonus)
    const [, , , , raisedAfterDonation] = await dao.getFundraiser(1);
    const expectedAfterDonation = donationAmount * 95n / 100n; // 95% after 5% commission
    expect(raisedAfterDonation).to.equal(expectedAfterDonation);
    
    const ownerBalanceBefore = await mockToken.balanceOf(owner.address);
    const commissionBalanceBefore = await mockToken.balanceOf(user3.address);
    
    await dao.withdraw(1);
    
    const ownerBalanceAfter = await mockToken.balanceOf(owner.address);
    const commissionBalanceAfter = await mockToken.balanceOf(user3.address);
    
    // Verify standard commission was applied (3% - no multimedia bonus)
    const expectedWithdrawCommission = raisedAfterDonation * 3n / 100n; // 3%
    const expectedOwnerReceived = raisedAfterDonation - expectedWithdrawCommission;
    
    expect(commissionBalanceAfter - commissionBalanceBefore).to.equal(expectedWithdrawCommission);
    expect(ownerBalanceAfter - ownerBalanceBefore).to.equal(expectedOwnerReceived);
    
    const summary = await dao.getFundraiserSummary(1);
    expect(summary.mediaCount).to.equal(3);
    expect(summary.updateCount).to.equal(1);
    expect(summary.pinnedUpdateId).to.equal(1);
    expect(await dao.hasMultimedia(1)).to.be.true;
    
    const [images, videos, audio, documents, total] = await dao.getMediaStatistics(1);
    expect(images).to.equal(2);
    expect(videos).to.equal(1);
    expect(audio).to.equal(0);
    expect(documents).to.equal(0);
    expect(total).to.equal(3);
    
    const update = await dao.getUpdateWithAttachments(1);
    expect(update.content).to.equal("Great progress!");
    expect(update.updateType).to.equal(1);
    expect(update.isPinned).to.be.true;
    expect(update.attachments).to.have.lengthOf(1);
    expect(update.attachments[0].ipfsHash).to.equal("QmUpdateImg");
  });
});

// ==============================
// ADMINISTRATIVE FUNCTIONS
// ==============================

describe("🏛️ Administrative Functions", function () {
  it("should handle all pause toggles correctly", async function () {
    expect(await dao.votingPaused()).to.be.false;
    await dao.toggleVotingPause();
    expect(await dao.votingPaused()).to.be.true;
    await dao.toggleVotingPause();
    expect(await dao.votingPaused()).to.be.false;
    
    expect(await dao.donationsPaused()).to.be.false;
    await dao.toggleDonationsPause();
    expect(await dao.donationsPaused()).to.be.true;
    await dao.toggleDonationsPause();
    expect(await dao.donationsPaused()).to.be.false;
    
    expect(await dao.withdrawalsPaused()).to.be.false;
    await dao.toggleWithdrawalsPause();
    expect(await dao.withdrawalsPaused()).to.be.true;
    await dao.toggleWithdrawalsPause();
    expect(await dao.withdrawalsPaused()).to.be.false;
    
    expect(await dao.mediaPaused()).to.be.false;
    await dao.toggleMediaPause();
    expect(await dao.mediaPaused()).to.be.true;
    await dao.toggleMediaPause();
    expect(await dao.mediaPaused()).to.be.false;
  });

  it("should emit events for all administrative actions", async function () {
    await expect(dao.toggleVotingPause())
      .to.emit(dao, "VotingPauseToggled")
      .withArgs(true);
    
    await expect(dao.toggleDonationsPause())
      .to.emit(dao, "DonationsPauseToggled")
      .withArgs(true);
    
    await expect(dao.toggleWithdrawalsPause())
      .to.emit(dao, "WithdrawalsPauseToggled")
      .withArgs(true);
    
    await expect(dao.toggleMediaPause())
      .to.emit(dao, "MediaPauseToggled")
      .withArgs(true);
    
    const newLimit = ethers.parseUnits("2000000", 18);
    await expect(dao.setMaxDailyDonations(newLimit))
      .to.emit(dao, "MaxDailyDonationsSet")
      .withArgs(newLimit);
  });

  it("should handle commission settings comprehensively", async function () {
    await dao.setDonationCommission(250);  // 2.5%
    await dao.setSuccessCommission(500);   // 5%
    await dao.setRefundCommission(150);    // 1.5%
    
    expect(await dao.donationCommission()).to.equal(250);
    expect(await dao.successCommission()).to.equal(500);
    expect(await dao.refundCommission()).to.equal(150);
    
    await dao.setDonationCommission(0);
    expect(await dao.donationCommission()).to.equal(0);
    
    await dao.setSuccessCommission(10000);
    expect(await dao.successCommission()).to.equal(10000);
  });

  it("should handle commission wallet changes", async function () {
    await expect(dao.setCommissionWallet(user4.address))
      .to.emit(dao, "CommissionWalletChanged")
      .withArgs(user3.address, user4.address);
    
    await expect(dao.setCommissionWallet(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(dao, "InvalidRecipient");
  });

  it("should handle emergency withdrawals", async function () {
    // Send some tokens to the contract
    const amount = ethers.parseUnits("100", 18);
    await mockToken.connect(owner).transfer(await dao.getAddress(), amount);
    
    await expect(dao.emergencyWithdraw(await mockToken.getAddress(), owner.address, amount))
      .to.emit(dao, "EmergencyWithdraw")
      .withArgs(await mockToken.getAddress(), owner.address, amount);
    
    // Only owner should be able to do emergency withdrawals
    await expect(dao.connect(user1).emergencyWithdraw(await mockToken.getAddress(), user1.address, amount))
      .to.be.reverted;
  });
});

// ==============================
// MULTIMEDIA GALLERY FUNCTIONS
// ==============================

describe("🖼️ Multimedia Gallery Functions", function () {
  beforeEach(async () => {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
  });

  it("should handle gallery pagination correctly", async function () {
    const mediaItems = [];
    for (let i = 0; i < 5; i++) {
      mediaItems.push({
        ipfsHash: `QmTest${i}`,
        mediaType: 0,
        filename: `test${i}.jpg`,
        fileSize: 1024,
        uploadTime: 0,
        uploader: ethers.ZeroAddress,
        description: `Test image ${i}`
      });
    }
    
    await dao.addMultimediaToFundraiser(1, mediaItems);
    
    // Test pagination
    const [page1, total1] = await dao.getFundraiserGallery(1, 0, 3);
    expect(page1).to.have.lengthOf(3);
    expect(total1).to.equal(5);
    expect(page1[0].ipfsHash).to.equal("QmTest0");
    
    const [page2, total2] = await dao.getFundraiserGallery(1, 3, 3);
    expect(page2).to.have.lengthOf(2);
    expect(total2).to.equal(5);
    expect(page2[0].ipfsHash).to.equal("QmTest3");
    
    // Test out of bounds
    const [empty, total3] = await dao.getFundraiserGallery(1, 10, 3);
    expect(empty).to.have.lengthOf(0);
    expect(total3).to.equal(5);
  });

  it("should handle donor pagination correctly", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 5000, 3600, false);
    
    // Add multiple donors
    const amount = ethers.parseUnits("100", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(2, amount);
    
    await mockToken.connect(user2).approve(await dao.getAddress(), amount);
    await dao.connect(user2).donate(2, amount);
    
    await mockToken.connect(user4).approve(await dao.getAddress(), amount);
    await dao.connect(user4).donate(2, amount);
    
    const [donors, total] = await dao.getDonorsPaginated(2, 0, 2);
    expect(donors).to.have.lengthOf(2);
    expect(total).to.equal(3);
    
    const donorsCount = await dao.getDonorsCount(2);
    expect(donorsCount).to.equal(3);
  });
});

// ==============================
// ERROR HANDLING AND EDGE CASES
// ==============================

describe("⚠️ Error Handling and Edge Cases", function () {
  it("should handle invalid fundraiser IDs gracefully", async function () {
    await expect(dao.addMultimediaToFundraiser(999, []))
      .to.be.revertedWithCustomError(dao, "InvalidUpdateId");
    
    await expect(dao.postUpdate(999, "test"))
      .to.be.revertedWithCustomError(dao, "InvalidUpdateId");
    
    await expect(dao.authorizeUpdater(999, user1.address))
      .to.be.revertedWithCustomError(dao, "InvalidUpdateId");
  });

  it("should handle empty media arrays", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    // Empty array should not emit MultimediaActivated
    await dao.addMultimediaToFundraiser(1, []);
    expect(await dao.hasMultimedia(1)).to.be.false;
  });

  it("should handle update content validation", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const longContent = "a".repeat(1001);
    await expect(dao.postUpdate(1, longContent))
      .to.be.revertedWithCustomError(dao, "UpdateTooLong");
    
    const tooManyAttachments = Array(11).fill().map((_, i) => ({
      ipfsHash: `QmAttach${i}`,
      mediaType: 0,
      filename: `attach${i}.jpg`,
      fileSize: 1024,
      uploadTime: 0,
      uploader: ethers.ZeroAddress,
      description: `Attachment ${i}`
    }));
    
    await expect(dao.postUpdateWithMultimedia(1, "test", 0, tooManyAttachments))
      .to.be.revertedWithCustomError(dao, "MediaLimitExceeded");
  });

  it("should handle pin/unpin edge cases", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    // Try to pin non-existent update
    await expect(dao.pinUpdate(999))
      .to.be.revertedWith("Invalid update");
    
    // Try to unpin when nothing is pinned
    await expect(dao.unpinUpdate(1))
      .to.be.revertedWith("No pinned update");
  });

  it("should validate media removal bounds", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    const mediaItems = [
      { ipfsHash: "QmTest", mediaType: 0, filename: "test.jpg", fileSize: 1024, uploadTime: 0, uploader: ethers.ZeroAddress, description: "Test" }
    ];
    await dao.addMultimediaToFundraiser(1, mediaItems);
    
    // Try to remove invalid index
    await expect(dao.removeMediaFromFundraiser(1, 5))
      .to.be.revertedWith("Invalid media index");
  });
});

// ==============================
// UTILITY AND HELPER TESTS
// ==============================

describe("🔧 Utility Functions", function () {
  it("should return correct counts", async function () {
    await dao.createProposal("Test 1", 3600);
    await dao.createProposal("Test 2", 3600);
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    await dao.postUpdate(1, "Update 1");
    
    expect(await dao.getProposalCount()).to.equal(2);
    expect(await dao.getFundraiserCount()).to.equal(1);
    expect(await dao.getUpdateCount()).to.equal(1);
  });

  it("should handle authorization checks correctly", async function () {
    await dao.createFundraiser(await mockToken.getAddress(), 1000, 3600, false);
    
    // Initial state
    expect(await dao.canManageMedia(1, owner.address)).to.be.true;
    expect(await dao.canManageMedia(1, user1.address)).to.be.false;
    
    // After authorization
    await dao.authorizeUpdater(1, user1.address);
    expect(await dao.canManageMedia(1, user1.address)).to.be.true;
    
    await dao.authorizeMediaManager(1, user2.address);
    expect(await dao.canManageMedia(1, user2.address)).to.be.true;
  });

  it("should handle contract receive function", async function () {
    // Contract should be able to receive ETH
    const tx = await owner.sendTransaction({
      to: await dao.getAddress(),
      value: ethers.parseEther("1")
    });
    await tx.wait();
    
    const balance = await ethers.provider.getBalance(await dao.getAddress());
    expect(balance).to.equal(ethers.parseEther("1"));
  });
});