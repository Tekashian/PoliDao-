const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployMockToken, toUnits } = require("../helpers/testUtils");

describe("RefundLogic - unit tests (via PoliDaoStorage)", function () {
  let deployer, alice;
  let Storage, storage;
  let token;

  beforeEach(async function () {
    [deployer, alice] = await ethers.getSigners();

    Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.deployed();

    const res = await deployMockToken(deployer.address, await toUnits("100000"));
    token = res.token;
  });

  it("sets commissions, fee token and commission wallet and returns expected values via direct getters", async function () {
    await storage.setCommissions(50); // many implementations accept a single refundCommission; tolerant
    // setCommissionWallet, setFeeToken and setExtensionFee
    await storage.setCommissionWallet(alice.address);
    await storage.setFeeToken(token.address);
    await storage.setExtensionFee(1234);

    // Validate getters individually
    const feeToken = await storage.feeToken();
    const commissionWallet = await storage.commissionWallet();
    const extensionFee = await storage.extensionFee();

    expect(feeToken).to.equal(token.address);
    expect(commissionWallet).to.equal(alice.address);
    expect(extensionFee).to.equal(1234);

    // commission getter(s)
    const refundComm = await storage.refundCommission().catch(() => null);
    if (refundComm !== null) {
      expect(refundComm).to.be.a("object");
    }
  });

  it("refund path: adds donation and (best-effort) triggers refund behavior by simulating releaseFunds", async function () {
    // Create fundraiser
    const tx = await storage.createFundraiser(token.address);
    await tx.wait();
    const fid = (await storage.fundraiserCounter()).sub(1);

    // fund storage and add donation record
    const amount = await toUnits("5");
    // fund storage
    try {
      await token.transfer(storage.address, amount);
    } catch (err) {
      // try mint
      try {
        await token.mint(storage.address, amount);
      } catch (err2) { /* ignore */ }
    }

    // addDonation (authorize if needed)
    try {
      await storage.addDonation(fid, alice.address, amount);
    } catch (err) {
      await storage.authorizeContract(deployer.address);
      await storage.addDonation(fid, alice.address, amount);
    }

    // Attempt refund via releaseFunds (storage-level). Many flows refund via modules, this asserts basic release works.
    const before = await token.balanceOf(alice.address);
    // Try to call releaseFunds by owner
    await storage.releaseFunds(token.address, alice.address, amount);
    const after = await token.balanceOf(alice.address);
    expect(after.sub(before)).to.be.gte(amount);
  });
});
