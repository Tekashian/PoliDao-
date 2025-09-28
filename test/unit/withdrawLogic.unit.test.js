const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deploySystemFixture } = require("../fixtures/deploySystemFixture");

describe("WithdrawLogic - unit tests (via PoliDaoStorage releaseFunds)", function () {
  it("only core can call releaseFunds: unauthorized call reverts", async function () {
    const { storage, alice } = await loadFixture(deploySystemFixture);
    await expect(
      storage.connect(alice).releaseFunds(ethers.ZeroAddress, alice.address, 1)
    ).to.be.revertedWith("Storage: only Core");
  });
});
