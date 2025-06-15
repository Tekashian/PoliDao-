const { expect } = require("chai");
const hre = require("hardhat");
const { ethers } = hre;

let dao, mockToken, owner, user1, user2, user3;

beforeEach(async () => {
  [owner, user1, user2, user3] = await ethers.getSigners();

  const MockToken = await ethers.getContractFactory("MockToken");
  mockToken = await MockToken.deploy("USDC Test", "USDC", 18, 10_000, owner.address);
  await mockToken.waitForDeployment();

  const PoliDAO = await ethers.getContractFactory("PoliDAO");
  dao = await PoliDAO.deploy(owner.address, user3.address);
  await dao.waitForDeployment();

  await dao.whitelistToken(await mockToken.getAddress());

  const mintAmount = ethers.parseUnits("5000", 18);
  await mockToken.connect(owner).transfer(user1.address, mintAmount);
  await mockToken.connect(owner).transfer(user2.address, mintAmount);
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

    const [id, , token, target, raised, , withdrawn, isFlexible] = await dao.getFundraiser(1);
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
    const balance = await mockToken.balanceOf(user1.address);
    expect(balance).to.equal(ethers.parseUnits("5000", 18));
  });

  it("should allow full withdraw if target met early", async function () {
    await createFundraiser(1000, 3600);
    await donate(user1, 1000);
    await dao.withdraw(1);
    const balance = await mockToken.balanceOf(owner.address);
    expect(balance).to.equal(ethers.parseUnits("1000", 18));
  });

  it("should allow flexible withdrawal anytime", async function () {
    await createFundraiser(0, 3600, true);
    await donate(user1, 1000);
    await dao.withdraw(1);
    const balance = await mockToken.balanceOf(owner.address);
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
    const [, , , , , endTime, , , reclaimDeadline, closureInitiated] = await dao.getFundraiser(1);
    expect(closureInitiated).to.be.true;
    expect(reclaimDeadline).to.be.gt(endTime);
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

  it("should apply donation commission correctly", async function () {
    await dao.setDonationCommission(1000); // 10%
    await createFundraiser();
    const amount = ethers.parseUnits("1000", 18);
    await mockToken.connect(user1).approve(await dao.getAddress(), amount);
    await dao.connect(user1).donate(1, amount);
    const [, , , , raised] = await dao.getFundraiser(1);
    expect(raised).to.equal(ethers.parseUnits("900", 18));
  });

  it("should prevent reentrancy on refund", async function () {
    const Attacker = await ethers.getContractFactory("ReentrancyAttackMock");
    const attacker = await Attacker.deploy(await dao.getAddress(), await mockToken.getAddress());
    await attacker.waitForDeployment();

    await dao.createFundraiser(await mockToken.getAddress(), 1000, 10, false);
    await mockToken.connect(user1).transfer(await attacker.getAddress(), ethers.parseUnits("100", 18));
    await mockToken.connect(user1).approve(await attacker.getAddress(), ethers.parseUnits("100", 18));
    await attacker.connect(user1).donateToFundraiser(1, ethers.parseUnits("100", 18));
    await donate(user1, 1000);
    await ethers.provider.send("evm_increaseTime", [11]);
    await ethers.provider.send("evm_mine");
    await dao.initiateClosure(1);
    await ethers.provider.send("evm_increaseTime", [1]);
    await ethers.provider.send("evm_mine");
    await attacker.connect(user1).attack(1, false);
    await expect(attacker.connect(user1).attack(1, false)).to.be.revertedWith("Already refunded");
  });

  it("should prevent reentrancy on withdraw", async function () {
    const Attacker = await ethers.getContractFactory("ReentrancyAttackMock");
    const attacker = await Attacker.deploy(await dao.getAddress(), await mockToken.getAddress());
    await attacker.waitForDeployment();

    await dao.createFundraiser(await mockToken.getAddress(), 1000, 10, true);
    await mockToken.connect(user1).transfer(await attacker.getAddress(), ethers.parseUnits("100", 18));
    await mockToken.connect(user1).approve(await attacker.getAddress(), ethers.parseUnits("100", 18));
    await attacker.connect(user1).donateToFundraiser(1, ethers.parseUnits("100", 18));
    await donate(user1, 900);
    await expect(attacker.connect(user1).attack(1, true)).to.be.reverted;
  });

  it("should apply success commission correctly on withdraw", async function () {
    // ustawiamy 10% prowizji od wypłat
    await dao.connect(owner).setSuccessCommission(1000);
    await createFundraiser(1000, 3600, false);
    await donate(user1, 1000);
    console.log(">>> przed wypłatą:", {
      commissionWallet: (await mockToken.balanceOf(user3.address)).toString(),
      owner: (await mockToken.balanceOf(owner.address)).toString()
    });
    await dao.withdraw(1);
    console.log(">>> po wypłacie:", {
      commissionWallet: (await mockToken.balanceOf(user3.address)).toString(),
      owner: (await mockToken.balanceOf(owner.address)).toString()
    });
    const commission = ethers.parseUnits("100", 18);
    expect(await mockToken.balanceOf(user3.address)).to.equal(commission);
    const net = ethers.parseUnits("900", 18);
    expect(await mockToken.balanceOf(owner.address)).to.equal(net);
  });
});
