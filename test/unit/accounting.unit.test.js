const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PoliDaoAccounting - unit", function () {
  async function deployFixture() {
    const [owner, core, stranger, refundsEOA] = await ethers.getSigners();

    // Mock Storage z minimalnym API (już masz kontrakt)
    const MockStorage = await ethers.getContractFactory("MockStorageForAccounting");
    const mockStorage = await MockStorage.deploy();
    await mockStorage.waitForDeployment();

    // fundraiser #1 -> raisedAmount = 1000
    await (await mockStorage.setFundraiser(1, 1000n)).wait();

    // Deploy Accounting(storage, owner)
    const Accounting = await ethers.getContractFactory("PoliDaoAccounting");
    const accounting = await Accounting.deploy(await mockStorage.getAddress(), await owner.getAddress());
    await accounting.waitForDeployment();

    // Ustaw Core (ACL)
    await (await accounting.connect(owner).setCore(await core.getAddress())).wait();

    return { owner, core, stranger, refundsEOA, mockStorage, accounting };
  }

  it("currentBalance = raised − withdrawn − refunded (początek)", async function () {
    const { accounting } = await deployFixture();
    expect(await accounting.currentBalance(1)).to.equal(1000n);
    expect(await accounting.withdrawnAmount(1)).to.equal(0n);
    expect(await accounting.refundedAmount(1)).to.equal(0n);
  });

  it("recordWithdrawal zwiększa withdrawn i zmniejsza currentBalance", async function () {
    const { core, accounting } = await deployFixture();
    await expect(accounting.connect(core).recordWithdrawal(1, 200n))
      .to.emit(accounting, "WithdrawalRecorded")
      .withArgs(1, 200n);
    expect(await accounting.withdrawnAmount(1)).to.equal(200n);
    expect(await accounting.currentBalance(1)).to.equal(800n);
  });

  it("recordRefund zwiększa refunded i zmniejsza currentBalance", async function () {
    const { core, accounting } = await deployFixture();
    await (await accounting.connect(core).recordWithdrawal(1, 300n)).wait(); // saldo 700
    await expect(accounting.connect(core).recordRefund(1, 150n))
      .to.emit(accounting, "RefundRecorded")
      .withArgs(1, 150n);
    expect(await accounting.refundedAmount(1)).to.equal(150n);
    expect(await accounting.currentBalance(1)).to.equal(550n);
  });

  it("0-amount nie zmienia stanu", async function () {
    const { core, accounting } = await deployFixture();
    await (await accounting.connect(core).recordWithdrawal(1, 0n)).wait();
    await (await accounting.connect(core).recordRefund(1, 0n)).wait();
    expect(await accounting.withdrawnAmount(1)).to.equal(0n);
    expect(await accounting.refundedAmount(1)).to.equal(0n);
    expect(await accounting.currentBalance(1)).to.equal(1000n);
  });

  it("tylko core może księgować (stranger reverts)", async function () {
    const { stranger, accounting } = await deployFixture();
    await expect(accounting.connect(stranger).recordWithdrawal(1, 10n)).to.be.reverted;
    await expect(accounting.connect(stranger).recordRefund(1, 10n)).to.be.reverted;
  });
});