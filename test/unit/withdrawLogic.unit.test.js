const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployMockToken, toUnits } = require("../../helpers/testUtils");

describe("WithdrawLogic - unit tests (via PoliDaoStorage releaseFunds)", function () {
  let deployer, bob;
  let Storage, storage;
  let token;

  beforeEach(async function () {
    [deployer, bob] = await ethers.getSigners();

    Storage = await ethers.getContractFactory("PoliDaoStorage");
    storage = await Storage.deploy();
    await storage.deployed();

    const res = await deployMockToken(deployer.address, await toUnits("100000"));
    token = res.token;

    // fund storage with some token balance
    const amt = await toUnits("1000");
    try {
      await token.transfer(storage.address, amt);
    } catch (err) {
      try {
        await token.mint(storage.address, amt);
      } catch (err2) {
        // if unable to fund, fail early to avoid false positives
        throw new Error("Unable to fund storage with MockToken for withdraw tests; update MockToken.");
      }
    }
  });

  it("only authorized/owner can call releaseFunds: unauthorized call reverts", async function () {
    const amount = await toUnits("1");
    let reverted = false;
    try {
      await storage.connect(bob).releaseFunds(token.address, bob.address, amount);
    } catch (err) {
      reverted = true;
    }
    expect(reverted).to.equal(true);

    // authorize bob and then succeed
    await storage.authorizeContract(bob.address);
    await expect(storage.connect(bob).releaseFunds(token.address, bob.address, amount)).to.not.be.reverted;
  });

  it("releaseFunds moves tokens from storage to recipient and emits FundsReleased event", async function () {
    const amount = await toUnits("2");
    const before = await token.balanceOf(bob.address);
    // owner calls releaseFunds
    await expect(storage.releaseFunds(token.address, bob.address, amount))
      .to.emit(storage, "FundsReleased")
      .withArgs(token.address, bob.address, amount, (await ethers.getSigners())[0].address);

    const after = await token.balanceOf(bob.address);
    expect(after.sub(before)).to.equal(amount);
  });
});