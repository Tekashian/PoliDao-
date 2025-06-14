// test/PoliDao.test.js
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

let dao, mockToken, owner, user1, user2, user3;
let initialSupply;

beforeEach(async () => {
  [owner, user1, user2, user3] = await ethers.getSigners();

  initialSupply = 10_000;

  const MockToken = await ethers.getContractFactory("MockToken");
  mockToken = await MockToken.deploy("USDC Test", "USDC", 18, initialSupply);
  await mockToken.waitForDeployment();

  const PoliDAO = await ethers.getContractFactory("PoliDAO");
  dao = await PoliDAO.deploy(owner.address, user3.address); // user3 jako portfel prowizji
  await dao.waitForDeployment();

  await dao.whitelistToken(await mockToken.getAddress());

  const mintAmount = ethers.parseUnits("5000", 18);
  await mockToken.transfer(user1.address, mintAmount);
  await mockToken.transfer(user2.address, mintAmount);
});

describe("Voting", function () {
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
});

describe("Fundraisers", function () {
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

    const [id, creator, token, target, raised, endTime, withdrawn, isFlexible, reclaimDeadline, closureInitiated] = await dao.getFundraiser(1);
    expect(id).to.equal(1);
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
    await expect(donate(user1, 1000)).to.be.revertedWith("Ended");
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
    const balance = await mockToken.balanceOf(await user1.getAddress());
    expect(balance).to.equal(ethers.parseUnits("5000", 18));
  });

  it("should allow full withdraw if target met early", async function () {
    await createFundraiser(1000, 3600);
    await donate(user1, 1000);
    await dao.withdraw(1);
    const balance = await mockToken.balanceOf(await owner.getAddress());
    expect(balance).to.equal(ethers.parseUnits("1000", 18));
  });

  it("should allow flexible withdrawal anytime", async function () {
    await createFundraiser(0, 3600, true);
    await donate(user1, 1000);
    await dao.withdraw(1);
    const balance = await mockToken.balanceOf(await owner.getAddress());
    expect(balance).to.equal(ethers.parseUnits("1000", 18));
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
    const fundraiser = await dao.getFundraiser(1);
    expect(fundraiser.closureInitiated).to.be.true;
    expect(fundraiser.reclaimDeadline).to.be.gt(fundraiser.endTime);
  });

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

  it("should return correct fundraiser count", async function () {
    await createFundraiser();
    await createFundraiser();
    const count = await dao.getFundraiserCount();
    expect(count).to.equal(2);
  });

  it("should apply donation commission correctly", async function () {
    await dao.setDonationCommission(1000); // 10%
    await createFundraiser();
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    const fundraiser = await dao.getFundraiser(1);
    const raised = fundraiser.raised;
    expect(raised).to.equal(ethers.parseUnits("900", 18));
  });
});
